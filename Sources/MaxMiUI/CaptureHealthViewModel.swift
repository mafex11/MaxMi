import Foundation
import MaxMiCore
import Observation

@MainActor
@Observable
public final class CaptureHealthViewModel {
    public private(set) var rows: [CaptureHealthRow] = []
    public private(set) var summary = CaptureHealthSummary.empty

    private let load: @Sendable () async -> [CaptureHealthDTO]
    private let now: () -> EpochMs

    public init(
        load: @escaping @Sendable () async -> [CaptureHealthDTO],
        now: @escaping () -> EpochMs
    ) {
        self.load = load
        self.now = now
    }

    public func refresh() async {
        let events = await load().sorted { $0.atMs > $1.atMs }
        let nowMs = now()

        summary = CaptureHealthSummary(
            captured: events.count { $0.outcome == .captured },
            deduplicated: events.count { $0.outcome == .deduplicated },
            skipped: events.count { $0.outcome == .skipped },
            failed: events.count { $0.outcome == .failed }
        )
        rows = events.map { event in
            CaptureHealthRow(
                id: event.id,
                appLabel: event.appLabel,
                outcome: event.outcome,
                status: statusLabel(event.outcome),
                detail: detailLabel(event),
                timeAgo: timeAgo(event.atMs, nowMs: nowMs),
                parser: event.parser,
                trigger: words(event.trigger.rawValue),
                duration: "\(event.durationMs) ms"
            )
        }
    }

    private func detailLabel(_ event: CaptureHealthDTO) -> String {
        if let reason = event.reason {
            return words(reason)
        }
        switch event.outcome {
        case .captured, .deduplicated:
            let suffix = event.truncated ? " · truncated" : ""
            return "\(event.characterCount) characters\(suffix)"
        case .skipped:
            return "Skipped by capture policy"
        case .failed:
            return "Capture attempt failed"
        }
    }

    private func statusLabel(_ outcome: CaptureOutcomeKind) -> String {
        switch outcome {
        case .captured: return "Captured"
        case .deduplicated: return "Unchanged"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }

    private func timeAgo(_ atMs: EpochMs, nowMs: EpochMs) -> String {
        let seconds = max(0, (nowMs - atMs) / 1_000)
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func words(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        let spaced = raw.dropFirst().reduce(String(first).uppercased()) { result, character in
            character.isUppercase ? result + " " + character.lowercased() : result + String(character)
        }
        return spaced
    }
}
