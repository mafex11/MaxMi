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
    /// Skipped entirely, subtree included. `AXColumn` is a dead end because it republishes the
    /// same `AXCell`s the row already emitted — walking it would print every cell a second time
    /// as a loose paragraph.
    static let skipRoles: Set<String> = ["AXScrollBar", "AXSplitter", "AXGrowArea", "AXColumn"]
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
    static let dialogRoles: Set<String> = ["AXSheet", "AXDialog", "AXPopover"]
    static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]
    static let landmarkRegions: [String: RegionKind] = [
        "AXLandmarkMain": .main,
        "AXLandmarkNavigation": .navigation,
        "AXLandmarkComplementary": .sidebar,
        "AXLandmarkBanner": .banner,
        "AXLandmarkContentInfo": .footer,
    ]
    static let sidebarNameHints = ["sidebar", "source list"]
    static let sidebarListRoles: Set<String> = ["AXOutline", "AXList", "AXTable"]
    static let sidebarMaxWidthShare = 0.35
    static let sidebarLeftEdgeShare = 0.05

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
    /// same-kind regions concatenate in (y, x) order. `order` is the claim's index at creation
    /// and breaks ties for the same reason `BlockEntry.order` does: `sorted` is not stable, and
    /// two claims of one kind can share a frame origin, or have none.
    struct Claim {
        let kind: RegionKind
        let y: CGFloat
        let x: CGFloat
        let order: Int
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
                            order: 0,
                            entries: [])]
        var order = 0
        walk(window, window: window, claimIndex: 0, parentIsSplitGroup: false,
             listDepth: 0, options: options, order: &order, claims: &claims)
        let budgeted = applyBudgets(assemble(claims), options: options)
        return Result(
            page: GenericPage(
                regions: budgeted.regions,
                focused: resolveFocusedElement(in: window, fallback: focusedElement),
                url: url
            ),
            truncated: budgeted.truncated
        )
    }

    /// The first matching rule claims this node's entire subtree as one region. nil means
    /// "not claimed" — the node inherits the enclosing region, defaulting to `.main` (rule 6).
    /// A nested claim inside a claimed subtree wins for its own subtree.
    ///
    /// Frames are compared in WINDOW-RELATIVE coordinates: `AXFrame` is global screen
    /// coordinates, so a window that is not flush against the left edge of the primary display
    /// would otherwise misclassify its sidebar.
    static func classifyRegion(_ node: AXNode, window: AXNode, parentIsSplitGroup: Bool) -> RegionKind? {
        if dialogRoles.contains(node.role) { return .dialog }
        if let subrole = node.subrole, dialogSubroles.contains(subrole) { return .dialog }
        if node.role == "AXToolbar" { return .toolbar }
        if let subrole = node.subrole, let kind = landmarkRegions[subrole] { return kind }
        // Each name is tested on its own: concatenating them would invent a hint that neither
        // carries, e.g. identifier "dataSource" + label "List of items" spanning "source list".
        let names = [node.identifier, node.label].compactMap { $0?.lowercased() }
        if names.contains(where: { name in sidebarNameHints.contains(where: name.contains) }) {
            return .sidebar
        }
        if parentIsSplitGroup, isSplitGroupSidebar(node, window: window) { return .sidebar }
        return nil
    }

    static func isSplitGroupSidebar(_ node: AXNode, window: AXNode) -> Bool {
        guard let windowFrame = window.frame, windowFrame.width > 0,
              let frame = node.frame else { return false }
        guard frame.width < sidebarMaxWidthShare * windowFrame.width else { return false }
        let relativeX = frame.minX - windowFrame.minX
        guard relativeX <= sidebarLeftEdgeShare * windowFrame.width else { return false }
        return containsListLike(node)
    }

    /// The node itself or any descendant being an outline/list/table. Finder's source list is
    /// sometimes the pane and sometimes wrapped in a group, so both count.
    static func containsListLike(_ node: AXNode) -> Bool {
        if sidebarListRoles.contains(node.role) { return true }
        return node.children.contains(where: containsListLike)
    }

    static func walk(
        _ node: AXNode,
        window: AXNode,
        claimIndex: Int,
        parentIsSplitGroup: Bool,
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

        var currentClaim = claimIndex
        if let kind = classifyRegion(node, window: window, parentIsSplitGroup: parentIsSplitGroup) {
            claims.append(Claim(kind: kind,
                                y: node.frame?.minY ?? 0,
                                x: node.frame?.minX ?? 0,
                                order: claims.count,
                                entries: []))
            currentClaim = claims.count - 1
        }

        if let block = block(for: node, listDepth: listDepth) {
            claims[currentClaim].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
            order += 1
            // A node that emits text stops recursion into its own children — this is what
            // prevents a paragraph and its five text runs all appearing.
            return
        }
        let childDepth = listContainerRoles.contains(node.role) ? listDepth + 1 : listDepth
        let childInSplitGroup = node.role == "AXSplitGroup"
        for child in node.children {
            walk(child, window: window, claimIndex: currentClaim,
                 parentIsSplitGroup: childInSplitGroup, listDepth: childDepth,
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

    /// `AXTextField`/`AXTextArea` are collected because Finder's name column is an editable
    /// field, not static text — without them a file row loses its file name. `AXImage` is not:
    /// an icon's description is chrome, and would print as a cell of its own.
    static func rowCells(_ node: AXNode) -> [String] {
        orderedDescendantText(node, roles: ["AXCell", "AXStaticText", "AXTextField", "AXTextArea"])
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
            // A cell is not a loophole around the secure-field rule: the value is never read here
            // either, and the subtree is not descended into.
            if current.subrole == secureSubrole { return }
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
                .sorted {
                    if $0.y != $1.y { return $0.y < $1.y }
                    if $0.x != $1.x { return $0.x < $1.x }
                    return $0.order < $1.order
                }
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

    /// Preferred source is the deepest node in the window tree with `focused == true`; when the
    /// tree has none, the caller's `AXReader.focusedElementSnapshot` result is used. Menu
    /// subtrees are excluded here for the same reason they are excluded from the text walk.
    static func resolveFocusedElement(in window: AXNode, fallback: AXNode?) -> FocusedElement? {
        var best: (depth: Int, node: AXNode)?
        func visit(_ node: AXNode, depth: Int) {
            if menuRoles.contains(node.role) { return }
            if node.focused, best == nil || depth > best!.depth {
                best = (depth, node)
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        guard let node = best?.node ?? fallback else { return nil }
        let isSecure = node.subrole == secureSubrole
        return FocusedElement(
            role: node.role,
            identifier: node.identifier,
            value: isSecure ? nil : node.value,
            selectedText: node.selectedText,
            isSecure: isSecure
        )
    }

    /// Rendered cost of a region's blocks. Sizing goes through the renderer so nothing has to
    /// re-render a page, and so a block never costs less than it prints.
    static func renderedSize(_ blocks: [Block]) -> Int {
        ContentRenderer.renderBlocks(blocks).count
    }

    /// `main` gets `totalBudget × mainShare`, `dialog` gets `× dialogShare`, all other regions
    /// share `× restShare` proportionally to their unbounded rendered size. Unused shares roll
    /// over rather than being lost:
    ///
    /// - `.dialog` is sized first and may borrow `main`'s whole share — and `rest`'s too when
    ///   there is no other region, so a bare alert window gets the full budget. A dialog is
    ///   short and is usually the most important thing on screen, so it is trimmed last and
    ///   only when even the rollover is not enough.
    /// - whatever `.dialog` and the rest regions leave unspent rolls into `main`, which is
    ///   therefore also what pays for a dialog that overflows its own share.
    ///
    /// Rest regions never grow past `restShare`: a long sidebar must not crowd out a short body.
    static func applyBudgets(_ regions: [Region], options: Options) -> (regions: [Region], truncated: Bool) {
        let total = max(1, options.totalBudget)
        let mainShare = budgetShare(total, options.mainShare)
        let dialogShare = budgetShare(total, options.dialogShare)
        let restShare = budgetShare(total, options.restShare)
        var truncated = false

        let rest = regions.filter { $0.kind != .main && $0.kind != .dialog }
        let dialogResult = trim(regions.first(where: { $0.kind == .dialog })?.blocks ?? [],
                                to: dialogShare + mainShare + (rest.isEmpty ? restShare : 0))
        truncated = truncated || dialogResult.truncated
        var mainAllowance = mainShare + dialogShare - renderedSize(dialogResult.blocks)

        let restSizes = rest.map { renderedSize($0.blocks) }
        let restTotal = restSizes.reduce(0, +)
        var trimmedRest: [Region] = []
        var restUsed = 0
        if restTotal <= restShare {
            trimmedRest = rest
            restUsed = restTotal
        } else {
            for (region, unbounded) in zip(rest, restSizes) {
                // restTotal > restShare >= 0 here, but the guard keeps the division total.
                let share = restTotal > 0
                    ? Int(Double(restShare) * Double(unbounded) / Double(restTotal))
                    : 0
                let result = trim(region.blocks, to: share)
                truncated = truncated || result.truncated
                if !result.blocks.isEmpty {
                    trimmedRest.append(Region(kind: region.kind, blocks: result.blocks))
                }
                restUsed += renderedSize(result.blocks)
            }
        }
        mainAllowance = max(0, mainAllowance + restShare - restUsed)

        let mainResult = trim(regions.first(where: { $0.kind == .main })?.blocks ?? [], to: mainAllowance)
        truncated = truncated || mainResult.truncated

        var out: [Region] = []
        for kind in ContentRenderer.regionOrder {
            switch kind {
            case .main:
                if !mainResult.blocks.isEmpty { out.append(Region(kind: .main, blocks: mainResult.blocks)) }
            case .dialog:
                if !dialogResult.blocks.isEmpty {
                    out.append(Region(kind: .dialog, blocks: dialogResult.blocks))
                }
            default:
                if let region = trimmedRest.first(where: { $0.kind == kind }) { out.append(region) }
            }
        }
        return (out, truncated)
    }

    /// One share of the budget. `Options` is public and mutable, so a nonsensical fraction must
    /// not be able to trap `Int(_:)` — `extract` is total.
    static func budgetShare(_ total: Int, _ fraction: Double) -> Int {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        return Int(Double(total) * min(fraction, 1))
    }

    /// Drops whole blocks from the END of the list, so what survives is the top of the page.
    /// Never splits a block, so a single block larger than the allowance is kept whole.
    static func trim(_ blocks: [Block], to allowance: Int) -> (blocks: [Block], truncated: Bool) {
        var kept: [Block] = []
        var used = 0
        for block in blocks {
            let cost = ContentRenderer.renderBlock(block).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, used + cost > allowance { break }
            kept.append(block)
            used += cost
        }
        return (kept, kept.count != blocks.count)
    }
}
