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
        GenericV2Content.page(window: window,
                              budget: StructuredEntityExtraction.pageBudget,
                              offscreenPolicy: Self.offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let page = GenericV2Content.page(window: window,
                                              budget: StructuredEntityExtraction.pageBudget,
                                              offscreenPolicy: Self.offscreen) else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(page.content, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: page.content,
                             truncated: page.truncated)
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
