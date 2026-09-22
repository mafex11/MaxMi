import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiActivity

private enum ActivitySummaryPromptVersion {
    static let timeline = "v2-timeline"
}

struct StoreActivitySummaryRepository: ActivitySummaryRepository, @unchecked Sendable {
    let store: Store
    let modelID: String

    func sessionsNeedingSummary(nowMs: EpochMs) async -> [PendingSession] {
        do {
            let sessions = try store.sessionsNeedingSummary(nowMs: nowMs, limit: 10)
            let timelineRepository = StoreTimelineRepository(store: store)
            return try sessions.map { session in
                let toMs = session.endedAtMs ?? session.lastActivityAtMs
                let timeline = try TimelineBuilder(repo: timelineRepository).build(
                    fromMs: session.startedAtMs,
                    toMs: toMs
                )
                return PendingSession(
                    id: session.id,
                    appLabel: session.appLabel,
                    timelineText: SessionSummaryInputBuilder.timelineText(timeline),
                    expectedSourceHash: try store.sessionSourceHash(session.id)
                )
            }
        } catch {
            return []
        }
    }

    func saveSummary(sessionID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async {
        _ = try? store.setSessionSummary(
            sessionID,
            summary: summary,
            expectedSourceHash: expectedSourceHash,
            modelID: modelID,
            promptVersion: ActivitySummaryPromptVersion.timeline,
            nowMs: nowMs
        )
    }

    func markFailed(sessionID: String, error: String, nowMs: EpochMs) async {
        do {
            try store.markSessionSummaryFailed(sessionID, error: error, nowMs: nowMs)
        } catch {
        }
    }
}
