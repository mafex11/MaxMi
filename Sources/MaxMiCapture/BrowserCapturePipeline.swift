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
    public static func parse(
        window: AXNode,
        windowTitle: String?,
        browser: ApplicationDescriptor
    ) throws -> BrowserCaptureResult {
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        let web = WebAppCaptureParser.parse(tab: tab, window: window)
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
            truncated: tab.truncated || web.capture.content.count >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
    }
}
