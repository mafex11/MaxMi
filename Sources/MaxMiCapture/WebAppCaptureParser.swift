import Foundation
import MaxMiCore

public enum WebAppKind: String, Sendable, CaseIterable {
    case generic
    case gmail
    case slack
    case discord
    case whatsapp
    case teams
    case outlook
    case linkedin
}

public struct WebAppParseResult: Sendable, Equatable {
    public let capture: ParsedCapture
    public let app: WebAppKind
    /// True when the metadata capture's bounded tab text dropped content. The browser pipeline
    /// independently records truncation while bounding its selected structured shape.
    public let truncated: Bool
}

/// Classifies browser URLs while retaining a URL-keyed `Web` thread. The browser pipeline owns
/// the structured content shape: registered host parsers claim their hosts and unclaimed pages
/// fall through to `WebPageParser`.
public enum WebAppCaptureParser {
    /// The browser content cap. Public because it is the default of a public parameter.
    public static let contentCap = 16_000

    /// Classifies a URL for the parser ID, `contentKind` and accumulation policy ONLY. Since
    /// M8 Phase D the content shape comes from `ParserRegistry`'s host map (spec §7b), so a new
    /// web app is added by registering a `StructuredParser` with a `hosts:` entry, not here.
    public static func classify(url: String) -> WebAppKind {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased() else { return .generic }
        if host == "mail.google.com" { return .gmail }
        if host == "app.slack.com" || host.hasSuffix(".slack.com") { return .slack }
        if host == "discord.com" || host == "www.discord.com" { return .discord }
        if host == "web.whatsapp.com" { return .whatsapp }
        if host == "teams.microsoft.com" || host == "teams.live.com"
            || host == "teams.cloud.microsoft" { return .teams }
        if host == "outlook.office.com" || host == "outlook.live.com"
            || host == "outlook.office365.com" { return .outlook }
        if host == "linkedin.com" || host == "www.linkedin.com" { return .linkedin }
        return .generic
    }

    /// Produces browser identity and capture metadata only. The typed content shape is selected
    /// by `BrowserCapturePipeline` through the host parser map.
    public static func parse(
        tab: TabCapture,
        window _: AXNode,
        contentBudget: Int = contentCap
    ) throws -> WebAppParseResult {
        let app = classify(url: tab.url)
        let isLinkedInMessaging = app == .linkedin
            && (URLComponents(string: tab.url)?.path.hasPrefix("/messaging") == true)
        let isConversation = [.slack, .discord, .whatsapp, .teams].contains(app)
            || isLinkedInMessaging
        let isEmail = app == .gmail || app == .outlook
        guard !tab.content.isEmpty else { throw ExtractionError.emptyContent }
        let content = String(tab.content.prefix(max(0, contentBudget)))
        let truncated = content != tab.content
        let accumulation: CaptureAccumulationPolicy = isConversation ? .appendItems : .replace
        // Kind is NOT derived from the shape: Gmail/Outlook stay .email and every other page
        // stays .webpage (spec 12 Q3).
        let kind: CaptureContentKind = isConversation ? .conversation : (isEmail ? .email : .webpage)
        let capture = ParsedCapture(
            sourceApp: "Web",
            sourceKey: URLKeyNormalizer.normalize(tab.url),
            sourceTitle: tab.title,
            content: content,
            contentKind: kind,
            parserVersion: 3,
            accumulationPolicy: accumulation,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000),
            structured: nil,
            truncated: truncated
        )
        return WebAppParseResult(
            capture: capture, app: app, truncated: truncated
        )
    }
}
