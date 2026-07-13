import Foundation
import MaxMiCore

/// Content-free diagnostic data presented by the Capture Health UI.
public struct CaptureHealthDTO: Identifiable, Sendable, Equatable {
    public let id: String
    public let atMs: EpochMs
    public let appLabel: String
    public let trigger: CaptureTrigger
    public let parser: String
    public let outcome: CaptureOutcomeKind
    public let reason: String?
    public let characterCount: Int
    public let durationMs: Int
    public let truncated: Bool

    public init(
        id: String,
        atMs: EpochMs,
        appLabel: String,
        trigger: CaptureTrigger,
        parser: String,
        outcome: CaptureOutcomeKind,
        reason: String?,
        characterCount: Int,
        durationMs: Int,
        truncated: Bool
    ) {
        self.id = id
        self.atMs = atMs
        self.appLabel = appLabel
        self.trigger = trigger
        self.parser = parser
        self.outcome = outcome
        self.reason = reason
        self.characterCount = characterCount
        self.durationMs = durationMs
        self.truncated = truncated
    }
}

public struct CaptureHealthRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let appLabel: String
    public let outcome: CaptureOutcomeKind
    public let status: String
    public let detail: String
    public let timeAgo: String
    public let parser: String
    public let trigger: String
    public let duration: String
}

public struct CaptureHealthSummary: Sendable, Equatable {
    public let captured: Int
    public let deduplicated: Int
    public let skipped: Int
    public let failed: Int

    public static let empty = CaptureHealthSummary(captured: 0, deduplicated: 0, skipped: 0, failed: 0)
}
