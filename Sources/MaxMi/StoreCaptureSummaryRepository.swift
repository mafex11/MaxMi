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
                    sourceTitle: capture.sourceTitle,
                    url: capture.url,
                    contentKind: capture.contentKind,
                    capturedAt: capture.capturedAt,
                    trigger: capture.trigger,
                    structured: capture.structured,
                    delta: capture.delta,
                    typedText: capture.typedText,
                    expectedSourceHash: capture.expectedSourceHash,
                    promptVersion: capture.promptVersion
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
        promptVersion: String,
        nowMs: EpochMs
    ) async {
        _ = try? store.saveCaptureDisplaySummary(
            threadID: threadID,
            summary: summary,
            expectedSourceHash: expectedSourceHash,
            modelID: modelID,
            promptVersion: promptVersion,
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
