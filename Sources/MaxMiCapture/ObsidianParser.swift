import Foundation
import MaxMiCore

/// Native Obsidian app. Title "<note> - <vault> - Obsidian <ver>" -> obsidian:<vault>/<note>.
public struct ObsidianParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle, content: body,
                             contentKind: .document, accumulationPolicy: .rollingText,
                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
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
