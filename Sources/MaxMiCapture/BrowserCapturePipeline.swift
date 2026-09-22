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
        contentBudget: Int = WebAppCaptureParser.contentCap,
        registry: ParserRegistry = ParserRegistry()
    ) throws -> BrowserCaptureResult {
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        let web = try WebAppCaptureParser.parse(tab: tab, window: window, contentBudget: contentBudget)
        // Host routing (spec §7b): a registered host parser claims the tab; otherwise the tab is
        // a generic web page. Either way `contentKind` stays whatever `classify` decided (§12 Q3).
        let hostContext = ParseContext(
            app: AppInfo(bundleID: browser.bundleID, name: browser.displayName,
                         windowTitle: windowTitle),
            url: tab.url
        )
        // `try` is not optional politeness: a host parser may throw `ParserRefusal` for a tab it
        // will not let be stored. The refusal propagates to `AppWiring` as `.parserNoContent`;
        // it is never swallowed into a generic capture.
        let routed = try CaptureDispatch.structuredCapture(
            window: window, context: hostContext, registry: registry,
            fallback: { window, _, _ in WebPageParser.parse(window: window, tab: tab) }
        )
        let unboundedStructured: CapturedContent
        var hostParserMarker: String? = nil
        switch routed {
        case .parsed(let content, let parserName):
            unboundedStructured = content
            hostParserMarker = parserName
        case .fellThrough(let content, let notHandledBy):
            unboundedStructured = content
            // Spec §8: a registered host parser that returned nil is a non-silent degradation.
            hostParserMarker = notHandledBy.map { CaptureDispatch.fallbackParserID(failedParser: $0) }
        }
        let structured = CaptureAccumulator.bound(unboundedStructured, to: contentBudget)
        if case .generic(let page) = structured, page.regions.isEmpty {
            throw ExtractionError.emptyContent
        }
        let quality = tab.quality
        let parserID = ([
            "BrowserWeb.v2",
            browser.browserEngine?.rawValue ?? "unknown",
            web.app.rawValue,
            tab.urlSource.rawValue,
            "quality-\(quality.rawValue)",
        ] + (hostParserMarker.map { [$0] } ?? [])).joined(separator: "/")
        return BrowserCaptureResult(
            url: tab.url,
            capture: ParsedCapture(
                sourceApp: web.capture.sourceApp,
                sourceKey: web.capture.sourceKey,
                sourceTitle: web.capture.sourceTitle,
                content: ContentRenderer.render(structured, style: .full),
                contentKind: web.capture.contentKind,
                parserVersion: 3,
                accumulationPolicy: web.capture.accumulationPolicy,
                offscreenPolicy: web.capture.offscreenPolicy,
                structured: structured
            ),
            parserID: parserID,
            quality: quality,
            // Three independent ways content can have been dropped: the tab text hit the
            // extractor's cap, bounding the typed shape shed blocks or messages, or the rendered
            // form is sitting on the cap.
            truncated: tab.truncated || web.truncated
                || structured != unboundedStructured
                || ContentRenderer.render(structured, style: .full).count
                    >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
    }
}
