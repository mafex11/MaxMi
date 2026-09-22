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
        let tab: TabCapture
        let tabHasNoReadableText: Bool
        do {
            tab = try BrowserTabExtractor.extract(
                window: window,
                windowTitle: windowTitle,
                engine: browser.browserEngine
            )
            tabHasNoReadableText = false
        } catch ExtractionError.emptyContent {
            // A contenteditable compose body is not a static-text tab line. Preserve the normal
            // empty-page refusal for generic tabs below, but let a host parser make its explicit
            // parse/refusal decision first. This sentinel is metadata-only: host content replaces
            // it before a `ParsedCapture` is returned.
            guard let url = BrowserTabExtractor.currentURL(
                window: window, windowTitle: windowTitle, engine: browser.browserEngine
            ) else {
                throw ExtractionError.emptyContent
            }
            tab = TabCapture(
                url: url,
                title: windowTitle ?? window.title,
                content: "host-parser",
                urlSource: .webArea,
                quality: .standard
            )
            tabHasNoReadableText = true
        }
        let hostContext = ParseContext(
            app: AppInfo(bundleID: browser.bundleID, name: browser.displayName,
                         windowTitle: windowTitle),
            url: tab.url
        )
        // Routed FIRST: an empty compose-only tab refuses rather than allowing the metadata
        // parser's empty-tab failure to hide the parser's explicit decision.
        let routed = try CaptureDispatch.structuredCapture(
            window: window, context: hostContext, registry: registry,
            fallback: { window, _, _ in WebPageParser.parse(window: window, tab: tab) }
        )
        let web = try WebAppCaptureParser.parse(tab: tab, window: window, contentBudget: contentBudget)
        let structured: CapturedContent
        let hostClaimed: Bool
        var hostMarker: String?
        var structuredWasBounded = false
        switch routed {
        case .parsed(let content, let parserName):
            let bounded = CaptureAccumulator.boundHard(content, to: contentBudget)
            structured = bounded
            hostClaimed = true
            hostMarker = parserName
            structuredWasBounded = bounded != content
        case .fellThrough(let content, let notHandledBy):
            if tabHasNoReadableText { throw ExtractionError.emptyContent }
            // Keep the generic browser path's pre-Phase-D soft bound: generic pages retain their
            // last readable block instead of being hard-trimmed into an empty page.
            let bounded = CaptureAccumulator.bound(content, to: contentBudget)
            structured = bounded
            hostClaimed = false
            hostMarker = notHandledBy.map { CaptureDispatch.fallbackParserID(failedParser: $0) }
            structuredWasBounded = bounded != content
        }
        if case .generic(let page) = structured, page.regions.isEmpty {
            throw ExtractionError.emptyContent
        }
        let quality: BrowserCaptureQuality
        if hostClaimed {
            quality = .high
        } else {
            quality = tab.quality
        }
        let parserID = ([
            "BrowserWeb.v2",
            browser.browserEngine?.rawValue ?? "unknown",
            web.app.rawValue,
            tab.urlSource.rawValue,
            "quality-\(quality.rawValue)",
        ] + (hostMarker.map { [$0] } ?? [])).joined(separator: "/")
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
            truncated: tab.truncated || web.truncated
                || structuredWasBounded
                || ContentRenderer.render(structured, style: .full).count
                    >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
    }
}
