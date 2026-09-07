import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class PendingVersionDeltaTests: XCTestCase {
    private var store: Store!
    private var db: MaxMiDatabase!
    private let captureTime = EpochMs(1_800_000_000_000)
    private let idleThreshold = EpochMs(300_000)

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    func testPendingVersionWithoutContentDeltaEventHasEmptyRenderedDelta() throws {
        let fixture = try commitFixture()

        XCTAssertEqual(try pendingVersion(id: fixture.versionID).renderedDelta, "")
    }

    func testPendingVersionWithCorruptContentDeltaPayloadHasEmptyRenderedDelta() throws {
        let fixture = try commitFixture()
        try recordDelta(CaptureDelta(
            addedBlocks: [Block(type: .paragraph, text: "synthetic delta")],
            addedChars: 15
        ), for: fixture)
        try db.dbQueue.write { d in
            try d.execute(
                sql: "UPDATE capture_events SET payload_ciphertext=? WHERE version_id=?",
                arguments: ["corrupt-fixture-ciphertext", fixture.versionID]
            )
        }

        var work: [PendingVersion]?
        XCTAssertNoThrow(
            work = try store.pendingWork(
                nowMs: captureTime + idleThreshold + 1,
                idleThresholdMs: idleThreshold
            )
        )
        let pending = try XCTUnwrap(work?.first { $0.id == fixture.versionID })
        XCTAssertEqual(pending.renderedDelta, "")
    }

    func testPendingVersionRendersContentDeltaThroughExtractInputBuilder() throws {
        let fixture = try commitFixture()
        let delta = CaptureDelta(
            addedBlocks: [
                Block(type: .heading(level: 2), text: "Synthetic heading"),
                Block(type: .paragraph, text: "Synthetic detail"),
            ],
            addedChars: 34
        )
        try recordDelta(delta, for: fixture)

        let expected = ExtractInputBuilder.build(
            delta: delta,
            previousStructured: nil,
            metadata: ExtractMetadata(
                sourceApp: fixture.sourceApp,
                sourceKey: fixture.sourceKey,
                title: fixture.sourceTitle,
                url: fixture.url,
                kind: .webpage,
                capturedAt: captureTime
            )
        )
        let pending = try pendingVersion(id: fixture.versionID)

        XCTAssertEqual(pending.renderedDelta, expected.newContent)
    }

    private func commitFixture() throws -> Fixture {
        let sourceApp = "FixtureCanvas"
        let sourceKey = "fixture:violet-board"
        let sourceTitle = "Violet Board"
        let url = "https://violet.invalid/board"
        let structured = CapturedContent.generic(GenericPage(
            regions: [
                Region(
                    kind: .main,
                    blocks: [Block(type: .paragraph, text: "Synthetic current snapshot")]
                ),
            ],
            focused: nil,
            url: url
        ))
        let envelope = CaptureEnvelope(
            sourceApp: sourceApp,
            sourceKey: sourceKey,
            sourceTitle: sourceTitle,
            content: "ignored fixture content",
            contentKind: .webpage,
            parserID: "FixtureParser",
            parserVersion: 1,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(),
            trigger: .periodic,
            truncated: false,
            structured: structured
        )
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            envelope,
            nowMs: captureTime
        ) else {
            XCTFail("fixture capture must commit")
            throw FixtureError.captureDidNotCommit
        }
        let threadID = try store.threadID(forKey: sourceKey)
        return Fixture(
            versionID: versionID,
            threadID: threadID,
            sourceApp: sourceApp,
            sourceKey: sourceKey,
            sourceTitle: sourceTitle,
            url: url
        )
    }

    private func recordDelta(_ delta: CaptureDelta, for fixture: Fixture) throws {
        try store.recordCaptureEvent(
            kind: .contentDelta,
            appBundle: "fixture.canvas",
            threadID: fixture.threadID,
            versionID: fixture.versionID,
            trigger: .periodic,
            payload: delta,
            nowMs: captureTime + 1
        )
    }

    private func pendingVersion(id: String) throws -> PendingVersion {
        let work = try store.pendingWork(
            nowMs: captureTime + idleThreshold + 1,
            idleThresholdMs: idleThreshold
        )
        return try XCTUnwrap(work.first { $0.id == id })
    }

    private struct Fixture {
        let versionID: String
        let threadID: String
        let sourceApp: String
        let sourceKey: String
        let sourceTitle: String
        let url: String
    }

    private enum FixtureError: Error {
        case captureDidNotCommit
    }
}
