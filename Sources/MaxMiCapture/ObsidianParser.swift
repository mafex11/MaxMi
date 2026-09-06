import Foundation
import MaxMiCore

/// Native Obsidian app. Title "<note> - <vault> - Obsidian <ver>" -> obsidian:<vault>/<note>.
public struct ObsidianParser: SourceParser {
    static let offscreen: OffscreenCapturePolicy = .accessibilityScroll(maxSteps: 3)
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window, offscreenPolicy: Self.offscreen)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: structured)
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
