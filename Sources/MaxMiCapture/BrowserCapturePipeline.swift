import Foundation
import MaxMiCore

public struct BrowserCaptureResult: Sendable, Equatable {
    public let url: String
    public let capture: ParsedCapture
    public let parserID: String
    public let quality: BrowserCaptureQuality
    public let truncated: Bool
    public let webApp: WebAppKind
}

/// Pure browser capture pipeline used by the app and fixture tests.
public enum BrowserCapturePipeline {
    /// `contentBudget` is forwarded to `WebAppCaptureParser.parse` and exists only so a test can
    /// drive the budget without a 16k fixture; production always uses the default.
    public static func parse(
        window: AXNode,
        windowTitle: String?,
        browser: ApplicationDescriptor,
        contentBudget: Int = WebAppCaptureParser.contentCap
    ) throws -> BrowserCaptureResult {
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        let web = try WebAppCaptureParser.parse(tab: tab, window: window, contentBudget: contentBudget)
        let quality: BrowserCaptureQuality
        if web.preservedBoundaries {
            quality = .high
        } else {
            quality = tab.quality
        }
        let parserID = [
            "BrowserWeb.v2",
            browser.browserEngine?.rawValue ?? "unknown",
            web.app.rawValue,
            tab.urlSource.rawValue,
            "quality-\(quality.rawValue)",
        ].joined(separator: "/")
        return BrowserCaptureResult(
            url: tab.url,
            capture: web.capture,
            parserID: parserID,
            quality: quality,
            // Three independent ways content can have been dropped: the tab text hit the
            // extractor's cap, bounding the typed shape shed blocks or messages, or the rendered
            // form is sitting on the cap.
            truncated: tab.truncated || web.truncated
                || web.capture.content.count >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
    }
}
