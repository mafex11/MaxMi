import Foundation
import MaxMiCore

public struct MeetingHistoryDTO: Identifiable, Sendable, Equatable {
    public let id: String
    public let appLabel: String
    public let title: String?
    public let startedAtMs: EpochMs
    public let endedAtMs: EpochMs?
    public let captureMode: String
    public let transcriptionStatus: String

    public init(
        id: String,
        appLabel: String,
        title: String?,
        startedAtMs: EpochMs,
        endedAtMs: EpochMs?,
        captureMode: String,
        transcriptionStatus: String
    ) {
        self.id = id
        self.appLabel = appLabel
        self.title = title
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.captureMode = captureMode
        self.transcriptionStatus = transcriptionStatus
    }

    public var isVoiceNote: Bool {
        appLabel == "Voice Note" || captureMode.hasPrefix("voice-note")
    }
}

public struct MeetingHistoryRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let source: String
    public let timeAgo: String
    public let duration: String
    public let status: String
    public let isVoiceNote: Bool
}
