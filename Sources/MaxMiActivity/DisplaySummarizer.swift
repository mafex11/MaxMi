import Foundation
import MaxMiCore

public struct DisplaySummarizer: Sendable {
    private let repo: any ActivitySummaryRepository
    private let relay: any ActivityGenerationRelay
    private let maxEvidenceChars: Int

    public init(repo: any ActivitySummaryRepository, relay: any ActivityGenerationRelay, maxEvidenceChars: Int = 12_000) {
        self.repo = repo
        self.relay = relay
        self.maxEvidenceChars = maxEvidenceChars
    }

    public func summarizeDue(nowMs: EpochMs) async {
        let pending = await repo.sessionsNeedingSummary(nowMs: nowMs)

        for session in pending {
            do {
                let summary = try await relay.summarizeSession(appLabel: session.appLabel, evidence: session.evidence)
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
