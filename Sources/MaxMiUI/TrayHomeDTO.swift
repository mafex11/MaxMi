import Foundation
import MaxMiCore

public enum TrayCaptureState: String, Sendable {
    case capturing
    case paused
    case needsAttention
}

public struct TrayStatusDTO: Sendable, Equatable {
    public let state: TrayCaptureState
    public let title: String
    public let detail: String
    public let captureCount: Int

    public init(state: TrayCaptureState, title: String, detail: String, captureCount: Int) {
        self.state = state
        self.title = title
        self.detail = detail
        self.captureCount = captureCount
    }
}

public struct TraySearchResultDTO: Identifiable, Sendable, Equatable {
    public let id: String
    public let appLabel: String
    public let title: String
    public let snippet: String
    public let contentKind: CaptureContentKind
    public let capturedAtMs: EpochMs
    public let matchKind: String

    public init(id: String, appLabel: String, title: String, snippet: String,
                contentKind: CaptureContentKind, capturedAtMs: EpochMs, matchKind: String) {
        self.id = id
        self.appLabel = appLabel
        self.title = title
        self.snippet = snippet
        self.contentKind = contentKind
        self.capturedAtMs = capturedAtMs
        self.matchKind = matchKind
    }
}

