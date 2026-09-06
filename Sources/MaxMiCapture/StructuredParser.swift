import Foundation
import MaxMiCore

/// Per-parser declaration: which app it claims, which browser hosts it claims, which extra AX
/// attributes it needs, and how it wants off-screen content bounded.
public struct ParserConfig: Sendable, Equatable {
    public let app: String
    public let bundleIDs: [String]
    /// Browser hosts this parser claims. A leading-dot entry (".slack.com") is a suffix match.
    public let hosts: [String]
    /// Extra AX attribute names `AXReader` must fetch for this app. Only "AXDOMClassList" and
    /// "AXDOMIdentifier" are honoured today; they bypass the AXWebArea gate for Electron trees.
    public let attributeSet: [String]
    public let offscreenPolicy: OffscreenCapturePolicy
    /// For browser hosts: beat the generic web path (and any native claim on the same window).
    public let preferOverNative: Bool
    public let minAppVersion: String?

    public init(
        app: String,
        bundleIDs: [String],
        hosts: [String] = [],
        attributeSet: [String] = [],
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly(),
        preferOverNative: Bool = false,
        minAppVersion: String? = nil
    ) {
        self.app = app
        self.bundleIDs = bundleIDs
        self.hosts = hosts
        self.attributeSet = attributeSet
        self.offscreenPolicy = offscreenPolicy
        self.preferOverNative = preferOverNative
        self.minAppVersion = minAppVersion
    }
}

/// Everything a structured parser is allowed to know beyond the AX tree.
public struct ParseContext: Sendable {
    public let app: AppInfo
    public let windowTitle: String?
    public let url: String?
    public let previousStructured: CapturedContent?
    public let now: EpochMs

    public init(app: AppInfo, windowTitle: String?, url: String?,
                previousStructured: CapturedContent?, now: EpochMs) {
        self.app = app
        self.windowTitle = windowTitle
        self.url = url
        self.previousStructured = previousStructured
        self.now = now
    }

    /// Convenience for the `SourceParser.parseStructured(window:app:)` bridges, where the only
    /// thing known beyond `AppInfo` is sometimes a URL.
    public init(app: AppInfo, url: String? = nil, previousStructured: CapturedContent? = nil,
                now: EpochMs = EpochMs(Date().timeIntervalSince1970 * 1000)) {
        self.init(app: app, windowTitle: app.windowTitle, url: url,
                  previousStructured: previousStructured, now: now)
    }
}

/// Parser protocol v2. `nil` means NOT_HANDLED and routes to `GenericPageExtractor` (spec §4f
/// rule 3) — it is never an error and never a lost capture. Thread keys and accumulation
/// policies stay on `SourceParser.parse` (spec §4f rule 1), so this protocol owns content only.
///
/// `parse` throws for exactly one purpose: `ParserRefusal` means "store NOTHING for this window",
/// which is different from nil. `CaptureDispatch.parseDetailed` already maps a refusal to
/// `.noContent`, and the browser pipeline rethrows it, so a refusing parser is never reported as
/// a `GenericPageExtractor.v2/fallback/...` degradation.
public protocol StructuredParser: Sendable {
    static var config: ParserConfig { get }
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent?
}
