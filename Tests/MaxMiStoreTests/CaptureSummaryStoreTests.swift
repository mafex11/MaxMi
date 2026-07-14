import XCTest
@testable import MaxMiStore
import MaxMiCore

final class CaptureSummaryStoreTests: XCTestCase {
    private var store: Store!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }

    func testNewContextBecomesDueAndSummaryIsEncrypted() throws {
        _ = try store.commitCapture(envelope("working on capture summaries"), nowMs: t0)
        let pending = try store.captureContextsNeedingSummary(nowMs: t0 + 11_000)
        let candidate = try XCTUnwrap(pending.first)

        XCTAssertTrue(try store.saveCaptureDisplaySummary(
            threadID: candidate.threadID,
            summary: "You're adding summaries to MaxMi.",
            expectedSourceHash: candidate.expectedSourceHash,
            modelID: "test-model",
            promptVersion: "v1",
            nowMs: t0 + 11_000
        ))

        let context = try XCTUnwrap(store.latestContexts(limit: 1).first)
        XCTAssertEqual(context.displaySummary, "You're adding summaries to MaxMi.")
        XCTAssertEqual(context.summaryStatus, "completed")
        let raw = try store.db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT display_summary_ciphertext FROM latest_contexts")
        }
        XCTAssertNotEqual(raw, context.displaySummary)
    }

    func testStaleSummaryCannotOverwriteChangedContext() throws {
        _ = try store.commitCapture(envelope("first state"), nowMs: t0)
        let stale = try XCTUnwrap(store.captureContextsNeedingSummary(nowMs: t0 + 11_000).first)
        _ = try store.commitCapture(envelope("second state"), nowMs: t0 + 12_000)

        XCTAssertFalse(try store.saveCaptureDisplaySummary(
            threadID: stale.threadID,
            summary: "Stale summary",
            expectedSourceHash: stale.expectedSourceHash,
            modelID: "test-model",
            promptVersion: "v1",
            nowMs: t0 + 13_000
        ))
        XCTAssertNil(try store.latestContexts(limit: 1).first?.displaySummary)
    }

    func testUnchangedCaptureDoesNotResetCompletedSummary() throws {
        let capture = envelope("same state")
        _ = try store.commitCapture(capture, nowMs: t0)
        let candidate = try XCTUnwrap(store.captureContextsNeedingSummary(nowMs: t0 + 11_000).first)
        _ = try store.saveCaptureDisplaySummary(
            threadID: candidate.threadID,
            summary: "You're reviewing the same state.",
            expectedSourceHash: candidate.expectedSourceHash,
            modelID: "test-model",
            promptVersion: "v1",
            nowMs: t0 + 11_000
        )

        XCTAssertEqual(try store.commitCapture(capture, nowMs: t0 + 12_000), .deduplicated)
        XCTAssertEqual(try store.latestContexts(limit: 1).first?.summaryStatus, "completed")
    }

    private func envelope(_ content: String) -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: "Cursor",
            sourceKey: "cursor:test",
            sourceTitle: "Test project",
            content: content,
            contentKind: .document,
            parserID: "GenericAXParser",
            parserVersion: 1,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .visibleOnly(),
            trigger: .appActivated,
            truncated: false
        )
    }
}
