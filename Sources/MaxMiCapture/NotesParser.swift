import Foundation
import MaxMiCore

/// Apple Notes. Window title is the note title.
public struct NotesParser: SourceParser {
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(maxSteps: 3)
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window, offscreenPolicy: Self.offscreen)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             // Whole-page semantics (spec 4d): one extraction is the window's
                             // current state, so it supersedes the previous one.
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured)
    }
}
