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

    public init(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String,
        contentKind: CaptureContentKind = .generic,
        parserVersion: Int = 1,
        accumulationPolicy: CaptureAccumulationPolicy = .rollingText,
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly()
    ) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
        self.contentKind = contentKind
        self.parserVersion = max(1, parserVersion)
        self.accumulationPolicy = accumulationPolicy
        self.offscreenPolicy = offscreenPolicy
    }

    public func envelope(
        cleanSourceKey: String,
        parserID: String,
        trigger: CaptureTrigger,
        truncated: Bool
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
            truncated: truncated
        )
    }
}

/// Turns a window's AX tree into a capture, or nil if it can't handle it.
/// Throwing is treated identically to nil by the caller (log + skip), never a crash.
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
}
