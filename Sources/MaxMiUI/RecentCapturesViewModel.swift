import Foundation
import MaxMiCore
import Observation

@MainActor
@Observable
public final class RecentCapturesViewModel {
    public private(set) var rows: [RecentCaptureRow] = []

    private let load: @Sendable () async -> [RecentCaptureDTO]
    private let now: () -> EpochMs

    public init(
        load: @escaping @Sendable () async -> [RecentCaptureDTO],
        now: @escaping () -> EpochMs
    ) {
        self.load = load
        self.now = now
    }

    public func refresh() async {
        let nowMs = now()
        rows = await load()
            .sorted { $0.capturedAtMs > $1.capturedAtMs }
            .map { capture in
                let count = capture.characterCount > 0
                    ? "\(capture.characterCount.formatted()) characters"
                    : "Imported context"
                let truncation = capture.truncated ? " · bounded" : ""
                let sourceTitle = capture.title?.isEmpty == false ? capture.title! : capture.appLabel
                let summary: String
                if let displaySummary = capture.displaySummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !displaySummary.isEmpty {
                    summary = displaySummary
                } else if capture.summaryStatus == "failed" {
                    summary = "Summary unavailable — the capture is still saved locally."
                } else if capture.summaryStatus == "skipped" {
                    summary = "Previously captured in \(sourceTitle)."
                } else {
                    summary = "Summarizing what you're doing…"
                }
                return RecentCaptureRow(
                    id: capture.id,
                    appLabel: capture.appLabel,
                    summary: summary,
                    sourceTitle: sourceTitle,
                    contentKind: capture.contentKind,
                    timeAgo: Self.timeAgo(capture.capturedAtMs, nowMs: nowMs),
                    detail: "\(Self.kindLabel(capture.contentKind)) · \(count)\(truncation) · \(capture.parserID)"
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

    private static func kindLabel(_ kind: CaptureContentKind) -> String {
        switch kind {
        case .webpage: return "Webpage"
        case .conversation: return "Conversation"
        case .document: return "Document"
        case .terminal: return "Terminal"
        case .email: return "Email"
        case .generic: return "Capture"
        }
    }
}
