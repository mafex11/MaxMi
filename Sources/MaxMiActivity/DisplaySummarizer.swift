import Foundation
import MaxMiCore

public struct DisplaySummarizer: Sendable {
    private let repo: any ActivitySummaryRepository
    private let relay: any ActivityGenerationRelay

    public init(repo: any ActivitySummaryRepository, relay: any ActivityGenerationRelay) {
        self.repo = repo
        self.relay = relay
    }

    public func summarizeDue(nowMs: EpochMs) async {
        let pending = await repo.sessionsNeedingSummary(nowMs: nowMs)

        for session in pending {
            do {
                let summary = try await relay.summarizeSession(
                    appLabel: session.appLabel,
                    timelineText: session.timelineText
                )
                await repo.saveSummary(sessionID: session.id, summary: summary, expectedSourceHash: session.expectedSourceHash, nowMs: nowMs)
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .activity,
                    event: .activitySummaryFailed,
                    error: error
                )
                await repo.markFailed(sessionID: session.id, error: error.localizedDescription, nowMs: nowMs)
            }
        }
    }
}
