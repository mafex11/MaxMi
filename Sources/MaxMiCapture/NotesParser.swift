import Foundation
import MaxMiCore

/// Apple Notes documents are anchored to the stable note-body text area.
public struct NotesParser: SourceParser, StructuredParser {
    // Stored Notes documents are hard-bounded to `pageBudget`, so the scroll ceiling is the
    // same — a larger one would be unreachable.
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(
        maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)

    public static let config = ParserConfig(
        app: "Notes",
        bundleIDs: [ParserRegistry.notesBundleID],
        offscreenPolicy: NotesParser.offscreen
    )

    /// Notes exposes the editor as one text area with a stable identifier, which keeps the note
    /// list and folder sidebar out of the document.
    static let bodyIdentifier = "Note Body Text View"
    /// Notes appends this to a collaborator line on a shared note.
    static let sharedSuffix = "— Shared"

    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        let structured = CaptureAccumulator.boundHard(unbounded, to: StructuredEntityExtraction.pageBudget)
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             // Whole-page semantics (spec 4d): one extraction is the window's
                             // current state, so it supersedes the previous one.
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured,
                             truncated: structured != unbounded)
    }

    /// The first physical body line is the note title. A blank first line defers to the window
    /// title, and only then to the stable untitled fallback.
    static func noteTitle(fromBody lines: [String], windowTitle: String?) -> String {
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        let fallback = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "untitled" : fallback
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let body = AXQuery.find("//*[identifier=\"\(Self.bodyIdentifier)\"]", in: snapshot),
              body.subrole != GenericPageExtractor.secureSubrole,
              let raw = body.value,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var lines = raw.components(separatedBy: "\n")
        let title = Self.noteTitle(fromBody: lines, windowTitle: context.windowTitle)
        if !lines.isEmpty { lines.removeFirst() }

        var author = Authorship.user
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(Self.sharedSuffix)
        }) {
            let header = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(header.dropLast(Self.sharedSuffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            author = name.isEmpty ? .unknown : .other(name)
            lines.remove(at: index)
        }

        let blocks = lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Block(type: .paragraph, text: $0, authoredByUser: false) }
        return .document(Document(title: title, blocks: blocks, author: author, url: nil))
    }
}
