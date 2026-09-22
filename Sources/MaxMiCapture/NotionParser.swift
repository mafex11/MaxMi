import Foundation
import MaxMiCore

/// Native Notion app. Window title is the page name; body comes from generic v2.
public struct NotionParser: SourceParser {
    // Whole-page `.replace` accumulation bounds ONE capture to `pageBudget`, so the scroll
    // ceiling is `pageBudget` too — a larger one would be unreachable.
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(
        maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window,
                              budget: StructuredEntityExtraction.pageBudget,
                              offscreenPolicy: Self.offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let page = GenericV2Content.page(window: window,
                                              budget: StructuredEntityExtraction.pageBudget,
                                              offscreenPolicy: Self.offscreen) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(page.content, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: page.content,
                             truncated: page.truncated)
    }
}
