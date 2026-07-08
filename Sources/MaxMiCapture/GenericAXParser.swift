import Foundation

/// Fallback for any capturable app without a dedicated parser: visible text in
/// visual order, keyed by bundle id + window title (coarse but guarantees coverage).
public struct GenericAXParser: SourceParser {
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // Reuse M1's proven visual-order text collection.
        let content = (try? BrowserTabExtractor.visualOrderText(in: window)) ?? ""
        guard !content.isEmpty else { return nil }   // no empty threads
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: content
        )
    }
}
