import Foundation
import MaxMiCore

public extension ParserRegistry {
    static func host(fromURL url: String?) -> String? {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    func structuredParser(for bundleID: String) -> (any StructuredParser)? {
        structuredParsers[bundleID]
    }

    func structuredParser(forHost host: String) -> (any StructuredParser)? {
        let host = host.lowercased()
        if let exact = hostParsers[host] { return exact }
        // A ".slack.com" entry claims every subdomain, mirroring WebAppCaptureParser.classify.
        for (pattern, parser) in hostParsers.sorted(by: { $0.key.count > $1.key.count })
        where pattern.hasPrefix(".") && host.hasSuffix(pattern) {
            return parser
        }
        return nil
    }

    /// A host parser with `preferOverNative` beats a native claim; otherwise native wins and a
    /// host parser is the last resort.
    func structuredParser(bundleID: String, url: String?) -> (any StructuredParser)? {
        let hostParser = Self.host(fromURL: url).flatMap { structuredParser(forHost: $0) }
        if let hostParser, type(of: hostParser).config.preferOverNative { return hostParser }
        if let native = structuredParsers[bundleID] { return native }
        return hostParser
    }

    func forcedAttributes(for bundleID: String) -> Set<String> {
        guard let parser = structuredParsers[bundleID] else { return [] }
        return Set(type(of: parser).config.attributeSet)
    }

    var registeredStructuredHosts: [String] { hostParsers.keys.sorted() }
}

public extension CaptureDispatch {
    enum StructuredParseResult: Sendable, Equatable {
        case parsed(CapturedContent, parserName: String)
        /// `GenericPageExtractor` output. `notHandledBy` names the registered parser that
        /// returned nil, or is nil when no parser claimed the window at all.
        case fellThrough(CapturedContent, notHandledBy: String?)
    }

    /// The §8 marker for a fall-through is composed by the existing
    /// `CaptureDispatch.fallbackParserID(failedParser:)`. No second helper is added here.
    ///
    /// A thrown `ParserRefusal` is deliberately NOT caught: refusing means store nothing, and
    /// both call paths already handle that (native: `parseDetailed` returns `.noContent`;
    /// browser: `BrowserCapturePipeline.parse` rethrows and `AppWiring` records
    /// `.skipped(.parserNoContent)`).
    /// `fallback` is what NOT_HANDLED degrades to. It defaults to a `GenericPageExtractor` walk
    /// (spec §4f rule 3); the browser pipeline passes `WebPageParser`, because a web tab's
    /// degradation is the landmark page rooted at its `AXWebArea`, not the whole browser window.
    /// The claiming parser's `offscreenPolicy` is resolved here so both fallbacks honour it.
    static func structuredCapture(
        window: AXNode,
        context: ParseContext,
        registry: ParserRegistry,
        fallback: (AXNode, ParseContext, GenericPageExtractor.Options) -> CapturedContent = {
            window, context, options in
            .generic(GenericPageExtractor.extract(
                window: window, focusedElement: nil, url: context.url, options: options).page)
        }
    ) throws -> StructuredParseResult {
        let parser = registry.structuredParser(bundleID: context.app.bundleID, url: context.url)
        let parserName = parser.map { String(describing: type(of: $0)) }
        if let parser, let content = try parser.parse(window, context: context) {
            return .parsed(content, parserName: parserName ?? "unknown")
        }
        var options = GenericPageExtractor.Options()
        if let parser { options.offscreenPolicy = type(of: parser).config.offscreenPolicy }
        return .fellThrough(fallback(window, context, options), notHandledBy: parserName)
    }
}
