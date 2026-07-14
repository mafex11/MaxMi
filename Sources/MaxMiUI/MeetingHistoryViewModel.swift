import Foundation
import Observation
import MaxMiCore

@MainActor
@Observable
public final class MeetingHistoryViewModel {
    public private(set) var rows: [MeetingHistoryRow] = []
    private let load: @Sendable () async -> [MeetingHistoryDTO]
    private let now: @Sendable () -> EpochMs

    public init(
        load: @escaping @Sendable () async -> [MeetingHistoryDTO],
        now: @escaping @Sendable () -> EpochMs
    ) {
        self.load = load
        self.now = now
    }

    public func refresh() async {
        let nowMs = now()
        rows = await load().map { item in
            MeetingHistoryRow(
                id: item.id,
                title: item.title?.isEmpty == false
                    ? item.title! : (item.isVoiceNote ? "Voice note" : "Meeting"),
                source: item.isVoiceNote ? "Voice Note" : item.appLabel,
                timeAgo: Self.timeAgo(item.startedAtMs, nowMs: nowMs),
                duration: Self.duration(start: item.startedAtMs, end: item.endedAtMs),
                status: item.transcriptionStatus.capitalized,
                isVoiceNote: item.isVoiceNote
            )
        }
    }

    private static func timeAgo(_ atMs: EpochMs, nowMs: EpochMs) -> String {
        let seconds = max(0, (nowMs - atMs) / 1_000)
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private static func duration(start: EpochMs, end: EpochMs?) -> String {
        guard let end else { return "In progress" }
        let seconds = max(0, (end - start) / 1_000)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}
