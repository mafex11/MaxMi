import Foundation
import MaxMiCore

/// Cursor and VS Code expose the visible buffer in an `AXTextArea` below an editor group. The
/// integrated terminal is a sibling panel, so anchoring on the group identifier excludes it.
public struct EditorParser: SourceParser, StructuredParser {
    static let contentCap = StructuredEntityExtraction.pageBudget

    public static let config = ParserConfig(
        app: "Editor",
        bundleIDs: ParserRegistry.editorBundleIDs,
        offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: contentCap)
    )

    public init() {}

    // MARK: - Titles and keys

    static func activeTabTitle(fromWindowTitle title: String?) -> String {
        let parts = titleComponents(title)
        guard !parts.isEmpty else { return "untitled" }
        return parts.first(where: looksLikeFilename) ?? parts[0]
    }

    static func looksLikeFilename(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex,
              dot != value.index(before: value.endIndex) else { return false }
        let ext = value[value.index(after: dot)...]
        return ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func workspaceName(fromWindowTitle title: String?) -> String? {
        let parts = titleComponents(title)
        guard parts.count >= 2, let file = parts.first(where: looksLikeFilename) else { return nil }
        return parts.first { $0 != file }
    }

    static func key(fromTitle title: String?) -> String {
        let parts = titleComponents(title)
        guard !parts.isEmpty else { return "editor:unknown" }
        let file = docSlug(activeTabTitle(fromWindowTitle: title))
        guard let workspace = workspaceName(fromWindowTitle: title) else { return "editor:\(file)" }
        return "editor:\(docSlug(workspace))/\(file)"
    }

    private static func titleComponents(_ title: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        return title.components(separatedBy: " — ")
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "● \u{2022}\t")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Anchor

    static func editorTextArea(in snapshot: AXNode) -> AXNode? {
        AXQuery.findAll("//AXGroup[identifier*=\"editor\"]//AXTextArea", in: snapshot)
            .filter { !$0.isSecureField }
            .filter { ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .max { ($0.value ?? "").count < ($1.value ?? "").count }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let area = Self.editorTextArea(in: snapshot), let raw = area.value else { return nil }
        let blocks = raw.components(separatedBy: "\n")
            .map { Block(type: .paragraph, text: $0, authoredByUser: false) }
        guard blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return .document(Document(
            title: Self.activeTabTitle(fromWindowTitle: context.windowTitle),
            blocks: blocks,
            author: .user,
            url: nil
        ))
    }

    // MARK: - SourceParser

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        let structured = CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
        return ParsedCapture(
            sourceApp: ApplicationRegistry.descriptor(for: app.bundleID)?.displayName ?? app.name,
            sourceKey: Self.key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .document,
            parserVersion: 3,
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: structured,
            truncated: structured != unbounded
        )
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
}
