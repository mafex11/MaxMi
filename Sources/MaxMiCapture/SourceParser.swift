import Foundation
import MaxMiCore

public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowTitle: String?
    /// Stable CGWindowID of the focused window when known — lets terminal threads separate by
    /// window even when no cwd is sniffable. nil for callers that don't resolve it.
    public let windowID: UInt32?
    public init(bundleID: String, name: String, windowTitle: String?, windowID: UInt32? = nil) {
        self.bundleID = bundleID; self.name = name; self.windowTitle = windowTitle; self.windowID = windowID
    }
}

public struct ParsedCapture: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public let contentKind: CaptureContentKind
    public let parserVersion: Int
    public let accumulationPolicy: CaptureAccumulationPolicy
    public let offscreenPolicy: OffscreenCapturePolicy
    /// The typed shape, when this parser has been migrated. nil for an unmigrated parser, which
    /// is handed a `LegacyContentAdapter` shape by `resolvedStructured`.
    public let structured: CapturedContent?

    public init(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String,
        contentKind: CaptureContentKind = .generic,
        parserVersion: Int = 1,
        accumulationPolicy: CaptureAccumulationPolicy = .rollingText,
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly(),
        structured: CapturedContent? = nil
    ) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
        self.contentKind = contentKind
        self.parserVersion = max(1, parserVersion)
        self.accumulationPolicy = accumulationPolicy
        self.offscreenPolicy = offscreenPolicy
        self.structured = structured
    }

    /// The typed shape this capture will be stored as (spec 4f rule 2). A convenience for
    /// in-process callers; `CaptureEnvelope.init` is the single write-path resolution site.
    public var resolvedStructured: CapturedContent {
        structured ?? LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)
    }

    public func envelope(
        cleanSourceKey: String,
        parserID: String,
        trigger: CaptureTrigger,
        truncated: Bool,
        structured: CapturedContent? = nil
    ) -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: sourceApp,
            sourceKey: cleanSourceKey,
            sourceTitle: sourceTitle,
            content: content,
            contentKind: contentKind,
            parserID: parserID,
            parserVersion: parserVersion,
            accumulationPolicy: accumulationPolicy,
            offscreenPolicy: offscreenPolicy,
            trigger: trigger,
            truncated: truncated,
            structured: structured ?? self.structured
        )
    }
}

/// Turns a window's AX tree into a capture, or nil if it can't handle it.
/// Throwing is treated identically to nil by the caller (log + fall through), never a crash.
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
    /// The structured shape, or nil = NOT_HANDLED. A migrated parser implements this as its
    /// single source of truth and reduces `parse` to a render wrapper, so one capture is one
    /// AX walk. An unmigrated parser implements only `parse`.
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent?
}

public extension SourceParser {
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? { nil }
}
