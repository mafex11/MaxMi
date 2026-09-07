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

    func testVersionMismatchQueuesConversationForAnyAppAndDocumentForAnyApp() throws {
        try seedLatestContext(sourceApp: "Slack", contentKind: .conversation, promptVersion: "old")
        try seedLatestContext(sourceApp: "Notes", contentKind: .document, promptVersion: "old")

        let pending = try store.captureContextsNeedingSummary(nowMs: t0 + 20_000, settleMs: 0, limit: 10)

        XCTAssertEqual(Set(pending.map(\.promptVersion)), Set([
            CaptureDisplaySummaryFormat.recentConversation,
            CaptureDisplaySummaryFormat.standard,
        ]))
    }

    func testPendingContextCarriesStructuredDeltaAndTypedText() throws {
        let structured = CapturedContent.generic(.init(
            regions: [.init(
                kind: .main,
                blocks: [.init(type: .paragraph, text: "Current document text.")]
            )],
            focused: nil,
            url: nil
        ))
        let capture = CaptureEnvelope(
            sourceApp: "TestApp",
            sourceKey: "test:structured",
            sourceTitle: "Test document",
            content: "ignored",
            contentKind: .generic,
            parserID: "TestParser",
            parserVersion: 1,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(),
            trigger: .periodic,
            truncated: false,
            structured: structured
        )
        let result = try store.commitCapture(capture, nowMs: t0)
        guard case let .committed(versionID, _, _) = result else {
            return XCTFail("Expected a committed capture.")
        }
        let threadID = try XCTUnwrap(
            store.threadID(sourceApp: "TestApp", sourceKey: "test:structured")
        )
        let earlierDelta = CaptureDelta(addedBlocks: [
            .init(type: .paragraph, text: "Earlier text."),
        ])
        let delta = CaptureDelta(addedBlocks: [
            .init(type: .paragraph, text: "Newly added text."),
        ])
        try store.recordCaptureEvent(
            kind: .contentDelta,
            appBundle: "test.bundle",
            threadID: threadID,
            versionID: versionID,
            trigger: .periodic,
            payload: earlierDelta,
            nowMs: t0
        )
        try store.recordCaptureEvent(
            kind: .contentDelta,
            appBundle: "test.bundle",
            threadID: threadID,
            versionID: versionID,
            trigger: .periodic,
            payload: delta,
            nowMs: t0 + 1
        )
        try store.recordCaptureEvent(
            kind: .typing,
            appBundle: "test.bundle",
            threadID: threadID,
            versionID: versionID,
            trigger: .periodic,
            payload: TypingEvent(
                insertedText: "older draft",
                fieldRole: "AXTextArea",
                fieldIdentifier: nil,
                totalLength: 11,
                replaced: false
            ),
            nowMs: t0
        )
        try store.recordCaptureEvent(
            kind: .typing,
            appBundle: "test.bundle",
            threadID: threadID,
            versionID: versionID,
            trigger: .periodic,
            payload: TypingEvent(
                insertedText: "draft reply",
                fieldRole: "AXTextArea",
                fieldIdentifier: nil,
                totalLength: 11,
                replaced: false
            ),
            nowMs: t0 + 1
        )

        let candidate = try XCTUnwrap(
            store.captureContextsNeedingSummary(nowMs: t0 + 11_000).first
        )

        XCTAssertEqual(candidate.structured, structured)
        XCTAssertEqual(candidate.delta, delta)
        XCTAssertEqual(candidate.typedText, "draft reply")
        XCTAssertEqual(candidate.capturedAt, t0)
        XCTAssertEqual(candidate.trigger, .periodic)
    }

    private func seedLatestContext(
        sourceApp: String,
        contentKind: CaptureContentKind,
        promptVersion: String
    ) throws {
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: sourceApp,
                sourceKey: "\(sourceApp):\(contentKind.rawValue)",
                sourceTitle: "Test context",
                content: "summary input",
                contentKind: contentKind,
                parserID: "TestParser",
                parserVersion: 1,
                accumulationPolicy: .replace,
                offscreenPolicy: .visibleOnly(),
                trigger: .periodic,
                truncated: false
            ),
            nowMs: t0
        )
        let candidate = try XCTUnwrap(
            store.captureContextsNeedingSummary(nowMs: t0, settleMs: 0, limit: 10)
                .first(where: { $0.appLabel == sourceApp })
        )
        XCTAssertTrue(try store.saveCaptureDisplaySummary(
            threadID: candidate.threadID,
            summary: "Existing summary",
            expectedSourceHash: candidate.expectedSourceHash,
            modelID: "test-model",
            promptVersion: promptVersion,
            nowMs: t0
        ))
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
