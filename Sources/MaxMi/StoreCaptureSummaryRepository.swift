import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiActivity

struct StoreCaptureSummaryRepository: CaptureDisplaySummaryRepository, @unchecked Sendable {
    let store: Store
    let modelID: String

    func capturesNeedingSummary(nowMs: EpochMs) async -> [CaptureSummaryCandidate] {
        do {
            return try store.captureContextsNeedingSummary(nowMs: nowMs).map { capture in
                CaptureSummaryCandidate(
                    threadID: capture.threadID,
                    appLabel: capture.appLabel,
                    content: capture.content,
                    expectedSourceHash: capture.expectedSourceHash
                )
            }
        } catch {
            return []
        }
    }

    func saveCaptureSummary(
        threadID: String,
        summary: String,
        expectedSourceHash: String,
        nowMs: EpochMs
    ) async {
        _ = try? store.saveCaptureDisplaySummary(
            threadID: threadID,
            summary: summary,
            expectedSourceHash: expectedSourceHash,
            modelID: modelID,
            promptVersion: "capture-display-v1",
            nowMs: nowMs
        )
    }

    func markCaptureSummaryFailed(
        threadID: String,
        expectedSourceHash: String,
        nowMs: EpochMs
    ) async {
        try? store.markCaptureSummaryFailed(
            threadID: threadID,
            expectedSourceHash: expectedSourceHash,
            errorKind: "generationFailed",
            nowMs: nowMs
        )
    }
}
