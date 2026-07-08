import Foundation

/// Native Notion app. Window title is the page name; body is AXTextArea/AXStaticText.
public struct NotionParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle, content: body)
    }
}
