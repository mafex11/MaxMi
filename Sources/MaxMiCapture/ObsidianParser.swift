import Foundation
import MaxMiCore

/// Native Obsidian app. Title "<note> - <vault> - Obsidian <ver>" -> obsidian:<vault>/<note>.
public struct ObsidianParser: SourceParser {
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
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured,
                             truncated: structured != unbounded)
    }
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "obsidian:unknown" }
        let parts = title.components(separatedBy: " - ")
        // "<note> - <vault> - Obsidian <version>": parse from end since note may contain " - "
        if parts.count >= 3, parts.last?.hasPrefix("Obsidian") == true {
            let vault = parts[parts.count - 2]
            let note = parts.dropLast(2).joined(separator: " - ")
            return "obsidian:\(docSlug(vault))/\(docSlug(note))"
        }
        return "obsidian:\(docSlug(title))"
    }
}

extension ObsidianParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Obsidian",
        bundleIDs: [ParserRegistry.obsidianBundleID],
        // Obsidian is Electron and does not always expose an AXWebArea above the vault view.
        attributeSet: ["AXDOMClassList"],
        // The existing constant: 3 scroll steps with a 32_000 ceiling.
        offscreenPolicy: ObsidianParser.offscreen
    )

    /// CodeMirror's editor root (edit mode) and the rendered pane (reading mode).
    static let editorClass = "cm-editor"
    static let previewClass = "markdown-preview-view"

    /// "<note> - <vault> - Obsidian <version>" -> "<note>". Same split `key(fromTitle:)` uses:
    /// parsed from the end, because a note name may itself contain " - ".
    static func noteName(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "untitled" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last?.hasPrefix("Obsidian") == true {
            return parts.dropLast(2).joined(separator: " - ")
        }
        return title
    }

    /// Edit mode wins over reading mode: in split view, the editor is what the user is changing.
    static func paneRoot(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[domClass*=\"\(editorClass)\"]", in: snapshot)
            ?? AXQuery.find("//*[domClass*=\"\(previewClass)\"]", in: snapshot)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let unbounded = unboundedDocument(snapshot, context: context) else { return nil }
        return CaptureAccumulator.bound(unbounded, to: StructuredEntityExtraction.pageBudget)
    }

    func unboundedDocument(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let pane = Self.paneRoot(in: snapshot) else { return nil }
        let texts = AXQuery.all(in: pane) {
            ($0.role == "AXHeading" || $0.role == "AXStaticText")
                && !$0.hidden
                && !$0.isSecureField
        }
        var seen = Set<String>()
        let blocks = AXQuery.sortedByVisualOrder(texts, relativeTo: pane.frame)
            .compactMap { node -> Block? in
                guard let text = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, seen.insert(text).inserted else { return nil }
                let type: BlockType = node.role == "AXHeading"
                    ? .heading(level: min(max(node.headingLevel ?? 2, 1), 6))
                    : .paragraph
                return Block(type: type, text: text, authoredByUser: false)
            }
        guard !blocks.isEmpty else { return nil }
        return .document(Document(title: Self.noteName(fromTitle: context.windowTitle),
                                  blocks: blocks, author: .user, url: nil))
    }
}
