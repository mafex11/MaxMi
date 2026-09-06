import Foundation
import MaxMiCore

/// Native Notion app. Window title is the page name; body comes from generic v2.
public struct NotionParser: SourceParser {
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(maxSteps: 3)
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window, offscreenPolicy: Self.offscreen)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured)
    }
}
