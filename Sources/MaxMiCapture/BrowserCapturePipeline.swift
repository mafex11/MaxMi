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
    /// Every host-routed conversation is hard-bounded on the v2 path. The generic browser budget
    /// remains separate because generic pages preserve their last readable block when over cap.
    static let conversationContentCap = 8_000

    /// `contentBudget` is the generic browser budget forwarded to `WebAppCaptureParser.parse`;
    /// it exists only so a test can drive the generic path without a 16k fixture.
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
        case .parsed(let content, let parserName, let parserTruncated):
            let cap: Int
            if case .conversation = content {
                cap = Self.conversationContentCap
            } else {
                cap = contentBudget
            }
            let bounded = CaptureAccumulator.boundHard(content, to: cap)
            structured = bounded
            hostClaimed = true
            hostMarker = parserName
            structuredWasBounded = bounded != content || parserTruncated
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
