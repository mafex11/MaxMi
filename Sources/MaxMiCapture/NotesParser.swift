import Foundation
import MaxMiCore

/// Apple Notes. Window title is the note title.
public struct NotesParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle, content: body,
                             contentKind: .document, accumulationPolicy: .rollingText,
                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
    }
}
