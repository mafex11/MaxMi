import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiActivity

struct StoreActivitySummaryRepository: ActivitySummaryRepository, @unchecked Sendable {
    let store: Store

    func sessionsNeedingSummary(nowMs: EpochMs) async -> [PendingSession] {
        do {
            let sessions = try store.sessionsNeedingSummary(nowMs: nowMs, limit: 10)
            return try sessions.map { session in
                let evidence = try store.sessionEvidence(session.id)
                let sourceHash = try store.sessionSourceHash(session.id)
                return PendingSession(
                    id: session.id,
                    appLabel: session.appLabel,
                    evidence: evidence,
                    expectedSourceHash: sourceHash
                )
            }
        } catch {
            return []
        }
    }

    func saveSummary(sessionID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async {
        do {
            _ = try store.setSessionSummary(
                sessionID,
                summary: summary,
                expectedSourceHash: expectedSourceHash,
                modelID: "gemini-2.5-flash-lite",
                promptVersion: "v1",
                nowMs: nowMs
            )
        } catch {
        }
    }

    func markFailed(sessionID: String, error: String, nowMs: EpochMs) async {
        do {
            try store.markSessionSummaryFailed(sessionID, error: error, nowMs: nowMs)
        } catch {
        }
    }
}
