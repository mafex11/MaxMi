import Foundation

/// Native Obsidian app. Title "<note> - <vault> - Obsidian <ver>" -> obsidian:<vault>/<note>.
public struct ObsidianParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle, content: body)
    }
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "obsidian:unknown" }
        let parts = title.components(separatedBy: " - ")
        // "<note> - <vault> - Obsidian <version>": note=parts[0], vault=parts[1]
        if parts.count >= 3, parts.last?.hasPrefix("Obsidian") == true {
            return "obsidian:\(docSlug(parts[1]))/\(docSlug(parts[0]))"
        }
        return "obsidian:\(docSlug(title))"
    }
}
