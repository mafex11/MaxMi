import Foundation
import MaxMiCore

/// Generic flattener v2. Replaces `DocumentExtraction.bodyText` on the fallback path: real
/// roles, heading levels, list depth, joined table rows, secure-field masking.
///
/// Pure and total — it cannot throw and always returns a `GenericPage`, possibly with zero
/// regions, which the caller treats as empty content exactly as before.
public enum GenericPageExtractor {
    public struct Options: Sendable, Equatable {
        public var totalBudget: Int = 8_000          // == DocumentExtraction.contentCap today
        public var mainShare: Double = 0.70
        public var dialogShare: Double = 0.15
        public var restShare: Double = 0.15
        public var offscreenPolicy: OffscreenCapturePolicy = .visibleOnly()
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public let page: GenericPage
        public let truncated: Bool
        public init(page: GenericPage, truncated: Bool) {
            self.page = page
            self.truncated = truncated
        }
    }

    /// Menu content is structurally excluded, not filtered by text.
    static let menuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu"]
    /// Skipped entirely, subtree included.
    static let skipRoles: Set<String> = ["AXScrollBar", "AXSplitter", "AXGrowArea"]
    static let paragraphRoles: Set<String> = ["AXStaticText", "AXParagraph"]
    static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
    static let listItemRoles: Set<String> = ["AXListItem", "AXTreeItem"]
    static let rowRoles: Set<String> = ["AXRow", "AXTableRow"]
    static let labelRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXImage",
    ]
    static let listContainerRoles: Set<String> = ["AXList", "AXOutline"]
    static let secureSubrole = "AXSecureTextField"
    static let secureMask = "«secure field»"

    /// One emitted block plus the visual position of the node it came from. `order` is a
    /// monotonic counter so sorting by (y, x, order) is deterministic even when frames are
    /// missing or identical — `Array.sort` is not stable.
    struct BlockEntry {
        let y: CGFloat
        let x: CGFloat
        let order: Int
        let block: Block
    }

    /// One region's worth of blocks plus the visual position of the node that claimed it, so
    /// same-kind regions concatenate in (y, x) order.
    struct Claim {
        let kind: RegionKind
        let y: CGFloat
        let x: CGFloat
        var entries: [BlockEntry]
    }

    /// `window` is the node `AXReader.snapshotFrontmostWindow` already resolved. The extractor
    /// never re-resolves it.
    public static func extract(
        window: AXNode,
        focusedElement: AXNode?,
        url: String?,
        options: Options = Options()
    ) -> Result {
        var claims = [Claim(kind: .main,
                            y: window.frame?.minY ?? 0,
                            x: window.frame?.minX ?? 0,
                            entries: [])]
        var order = 0
        walk(window, window: window, claimIndex: 0, listDepth: 0,
             options: options, order: &order, claims: &claims)
        return Result(
            page: GenericPage(regions: assemble(claims), focused: nil, url: url),
            truncated: false
        )
    }

    static func walk(
        _ node: AXNode,
        window: AXNode,
        claimIndex: Int,
        listDepth: Int,
        options: Options,
        order: inout Int,
        claims: inout [Claim]
    ) {
        if menuRoles.contains(node.role) { return }
        if node.hidden { return }
        if skipRoles.contains(node.role) { return }
        // A zero-width or zero-height frame means nothing under here is on screen. A nil frame
        // is "unknown", not "zero", and is walked.
        if let frame = node.frame, frame.width == 0 || frame.height == 0 { return }
        if isOffscreen(node, window: window, options: options) { return }

        if let block = block(for: node, listDepth: listDepth) {
            claims[claimIndex].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
            order += 1
            // A node that emits text stops recursion into its own children — this is what
            // prevents a paragraph and its five text runs all appearing.
            return
        }
        let childDepth = listContainerRoles.contains(node.role) ? listDepth + 1 : listDepth
        for child in node.children {
            walk(child, window: window, claimIndex: claimIndex, listDepth: childDepth,
                 options: options, order: &order, claims: &claims)
        }
    }

    static func isOffscreen(_ node: AXNode, window: AXNode, options: Options) -> Bool {
        guard options.offscreenPolicy.mode != .accessibilityScroll,
              let windowFrame = window.frame, let frame = node.frame,
              windowFrame.width > 0, windowFrame.height > 0 else { return false }
        return !windowFrame.intersects(frame)
    }

    static func block(for node: AXNode, listDepth: Int) -> Block? {
        // Checked first and at any role: a secure field's value is never read.
        if node.subrole == secureSubrole {
            return Block(type: .input(placeholder: nil), text: secureMask)
        }
        if node.role == "AXHeading" {
            let text = readableText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .heading(level: min(max(node.headingLevel ?? 2, 1), 6)), text: text)
        }
        if paragraphRoles.contains(node.role) {
            let text = readableText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .paragraph, text: text)
        }
        if inputRoles.contains(node.role) {
            let text = (node.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty field with no placeholder carries no information at all.
            guard !text.isEmpty || node.placeholder != nil else { return nil }
            return Block(type: .input(placeholder: node.placeholder), text: text)
        }
        if listItemRoles.contains(node.role) {
            let text = joinedDescendantText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .listItem(depth: max(0, listDepth - 1)), text: text)
        }
        if rowRoles.contains(node.role) {
            let cells = rowCells(node)
            guard !cells.isEmpty else { return nil }
            // `text` is the space-joined form so delta and dedup can compare rows as text;
            // `ContentRenderer` renders from `cells`.
            return Block(type: .tableRow(cells: cells, selected: node.selected),
                         text: cells.joined(separator: " "))
        }
        if labelRoles.contains(node.role) {
            let text = (node.title ?? node.label ?? node.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Block(type: .label, text: text)
        }
        return nil
    }

    static func readableText(_ node: AXNode) -> String {
        (node.value ?? node.title ?? node.label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joinedDescendantText(_ node: AXNode) -> String {
        orderedDescendantText(node, roles: ["AXStaticText", "AXHeading"]).joined(separator: " ")
    }

    static func rowCells(_ node: AXNode) -> [String] {
        orderedDescendantText(node, roles: ["AXCell", "AXStaticText"])
    }

    /// Descendant text in visual (y, x) order, adjacent duplicates dropped. A matching node
    /// with usable text is not descended into; a matching node with empty text is.
    ///
    /// `order` is the same monotonic tiebreaker `BlockEntry.order` is, and for the same reason:
    /// `sorted` is not stable, and frameless cells all collapse to (0, 0), so without it a row's
    /// `cells` — and therefore the row's `Block.text` — would be unspecified.
    static func orderedDescendantText(_ node: AXNode, roles: Set<String>) -> [String] {
        var found: [(y: CGFloat, x: CGFloat, order: Int, text: String)] = []
        var order = 0
        func visit(_ current: AXNode) {
            if menuRoles.contains(current.role) || current.hidden { return }
            if roles.contains(current.role) {
                let text = readableText(current)
                if !text.isEmpty {
                    found.append((current.frame?.minY ?? 0, current.frame?.minX ?? 0, order, text))
                    order += 1
                    return
                }
            }
            for child in current.children { visit(child) }
        }
        for child in node.children { visit(child) }
        let ordered = found.sorted {
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.order < $1.order
        }.map(\.text)
        return ordered.reduce(into: [String]()) { result, value in
            if result.last != value { result.append(value) }
        }
    }

    /// Per-region dedup key. Text alone collides across shapes: a `.paragraph` reading
    /// "Report.pdf 12 KB" is different content from the table row whose synthetic space-joined
    /// `text` happens to match, and dropping the second would lose the row's cells.
    static func dedupKey(_ block: Block) -> String {
        "\(typeTag(block.type))|\(block.text)"
    }

    /// The case discriminator only. Payload is deliberately excluded so a heading republished at
    /// a different level, or a row republished with a different `selected`, still dedups.
    static func typeTag(_ type: BlockType) -> String {
        switch type {
        case .heading:   return "heading"
        case .paragraph: return "paragraph"
        case .listItem:  return "listItem"
        case .label:     return "label"
        case .tableRow:  return "tableRow"
        case .input:     return "input"
        }
    }

    /// Group claims by kind in the renderer's canonical order; within a kind, concatenate
    /// claims in (y, x) order; within a claim, order blocks visually (y, then x, then emission
    /// order) — the same visual ordering `DocumentExtraction.bodyText` applied. Then drop
    /// duplicates of the same shape and text (see `dedupKey`), first occurrence winning.
    static func assemble(_ claims: [Claim]) -> [Region] {
        var regions: [Region] = []
        for kind in ContentRenderer.regionOrder {
            let matching = claims
                .filter { $0.kind == kind && !$0.entries.isEmpty }
                .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            guard !matching.isEmpty else { continue }
            var seen = Set<String>()
            var blocks: [Block] = []
            for claim in matching {
                let ordered = claim.entries.sorted {
                    if $0.y != $1.y { return $0.y < $1.y }
                    if $0.x != $1.x { return $0.x < $1.x }
                    return $0.order < $1.order
                }
                for entry in ordered where seen.insert(dedupKey(entry.block)).inserted {
                    blocks.append(entry.block)
                }
            }
            guard !blocks.isEmpty else { continue }
            regions.append(Region(kind: kind, blocks: blocks))
        }
        return regions
    }
}
