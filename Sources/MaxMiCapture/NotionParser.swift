import Foundation
import MaxMiCore

/// Native Notion documents are anchored to the DOM class of their main page frame.
public struct NotionParser: SourceParser {
    // Whole-page `.replace` accumulation bounds ONE capture to `pageBudget`, so the scroll
    // ceiling is `pageBudget` too — a larger one would be unreachable.
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(
        maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let context = ParseContext(app: app)
        guard let structured = try parse(window, context: context),
              let unbounded = unboundedDocument(window, context: context) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured,
                             truncated: structured != unbounded)
    }
}

extension NotionParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Notion",
        bundleIDs: [ParserRegistry.notionBundleID],
        hosts: ["www.notion.so", "notion.so", ".notion.site"],
        // Notion's Electron shell does not always expose an AXWebArea above the page.
        attributeSet: ["AXDOMClassList"],
        offscreenPolicy: NotionParser.offscreen,
        preferOverNative: true
    )

    /// The page body, in the main view or in a peek (side-panel) view.
    static let frameClasses = ["notion-frame", "notion-peek-renderer"]
    /// Chrome that lives inside the frame: the comment/backlink rail, and the property table.
    static let skippedClasses = ["layout-margin-right", "notion-page-properties"]
    static let topbarClass = "notion-topbar"

    static func pageRoot(in snapshot: AXNode) -> AXNode? {
        for pageClass in frameClasses {
            if let root = AXQuery.find("//*[domClass*=\"\(pageClass)\"]", in: snapshot) {
                return root
            }
        }
        return nil
    }

    static func pageTitle(in snapshot: AXNode, windowTitle: String?) -> String {
        if let topbar = AXQuery.find("//*[domClass*=\"\(topbarClass)\"]", in: snapshot),
           let first = AXQuery.collectStaticTexts(in: topbar).first {
            return first
        }
        let fallback = (windowTitle ?? "")
            .replacingOccurrences(of: " — Notion", with: "")
            .replacingOccurrences(of: " - Notion", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "untitled" : fallback
    }

    /// Text-bearing nodes under the page root, skipping the chrome subtrees. Headings keep their
    /// level; everything else is a paragraph.
    static func blocks(under root: AXNode) -> [Block] {
        var found: [AXNode] = []
        func visit(_ node: AXNode) {
            if node.hidden || node.isSecureField { return }
            let classes = (node.domClassList ?? []).map { $0.lowercased() }
            if skippedClasses.contains(where: { skipped in
                classes.contains { $0.contains(skipped) }
            }) { return }
            if node.role == "AXHeading" || node.role == "AXStaticText" {
                found.append(node)
                // A text-bearing node stops recursion, so a paragraph and its runs do not both
                // appear (the Phase A generic-extractor rule, applied here too).
                return
            }
            for child in node.children { visit(child) }
        }
        for child in root.children { visit(child) }
        var seen = Set<String>()
        return AXQuery.sortedByVisualOrder(found, relativeTo: root.frame)
            .compactMap { node -> Block? in
                guard let text = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, seen.insert(text).inserted else { return nil }
                let type: BlockType = node.role == "AXHeading"
                    ? .heading(level: min(max(node.headingLevel ?? 2, 1), 6))
                    : .paragraph
                return Block(type: type, text: text, authoredByUser: false)
            }
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let unbounded = unboundedDocument(snapshot, context: context) else { return nil }
        return CaptureAccumulator.bound(unbounded, to: StructuredEntityExtraction.pageBudget)
    }

    func unboundedDocument(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let root = Self.pageRoot(in: snapshot) else { return nil }
        let title = Self.pageTitle(in: snapshot, windowTitle: context.windowTitle)
        let blocks = Self.blocks(under: root).filter { $0.text != title }
        guard !blocks.isEmpty else { return nil }
        return .document(Document(title: title, blocks: blocks, author: .user, url: context.url))
    }
}
