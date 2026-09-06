import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CaptureEventStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(1_800_000_000_000)

    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    private func seedThreadAndVersion() throws -> (threadID: String, versionID: String) {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "Idea",
                         content: "first line"),
            nowMs: t0
        ) else {
            throw XCTSkip("commitCapture must commit a first capture")
        }
        let threadID = try store.threadID(forKey: "note:one")
        return (threadID, versionID)
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: CaptureEventRecord) throws -> T {
        let json = try XCTUnwrap(record.payloadJSON)
        return try CapturedContentEnvelope.makeDecoder().decode(type, from: Data(json.utf8))
    }

    /// The `focus` write, which most of these tests only need as "a row exists at this time".
    private func recordFocus(nowMs: EpochMs, appBundle: String = "com.example.editor",
                             windowTitle: String? = nil,
                             trigger: CaptureTrigger = .periodic) throws {
        try store.recordCaptureEvent(
            kind: .focus, appBundle: appBundle, threadID: nil, versionID: nil, trigger: trigger,
            payload: FocusEventPayload(bundleID: appBundle, appLabel: "Editor",
                                       windowTitle: windowTitle),
            nowMs: nowMs)
    }

    func testFocusPayloadRoundTripsAndIsEncryptedAtRest() throws {
        try store.recordCaptureEvent(
            kind: .focus, appBundle: "com.example.editor", threadID: nil, versionID: nil,
            trigger: .unknown,
            payload: FocusEventPayload(bundleID: "com.example.editor", appLabel: "Editor",
                                       windowTitle: "quarterly-plan"),
            nowMs: t0)

        let record = try XCTUnwrap(store.recentCaptureEvents().first)
        XCTAssertEqual(record.kind, .focus)
        XCTAssertEqual(record.appBundle, "com.example.editor",
                       "plaintext, so a row is attributable without a decrypt")
        XCTAssertNil(record.threadID)
        XCTAssertNil(record.versionID)
        XCTAssertEqual(record.trigger, .unknown)
        XCTAssertEqual(record.atMs, t0)
        let payload = try decode(FocusEventPayload.self, from: record)
        XCTAssertEqual(payload.windowTitle, "quarterly-plan")

        let stored = try XCTUnwrap(db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT payload_ciphertext FROM capture_events")
        })
        XCTAssertTrue(stored.hasPrefix("enc:v1:"))
        XCTAssertFalse(stored.contains("quarterly-plan"))
    }

    func testNavigationTypingDialogAndDeltaPayloadsRoundTrip() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .navigation, appBundle: "com.example.browser", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .browserNavigation,
            payload: NavigationEventPayload(fromURL: "https://example.com/a",
                                            toURL: "https://example.com/b"),
            nowMs: t0 + 1)
        try store.recordCaptureEvent(
            kind: .typing, appBundle: "com.example.chat", threadID: seeded.threadID,
            versionID: nil, trigger: .accessibilityChanged,
            payload: TypingEvent(insertedText: " world", fieldRole: "AXTextArea",
                                 fieldIdentifier: "composer", totalLength: 11, replaced: false),
            nowMs: t0 + 2)
        try store.recordCaptureEvent(
            kind: .dialog, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .accessibilityChanged,
            payload: DialogEventPayload(blocks: [Block(type: .label, text: "Discard")]),
            nowMs: t0 + 3)
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "second line")],
                                  addedChars: 12),
            nowMs: t0 + 4)

        let records = try store.recentCaptureEvents()
        XCTAssertEqual(records.map(\.kind), [.contentDelta, .dialog, .typing, .navigation])

        let delta = try decode(CaptureDelta.self, from: records[0])
        XCTAssertEqual(delta.addedBlocks.map(\.text), ["second line"])
        XCTAssertEqual(try decode(DialogEventPayload.self, from: records[1]).blocks.map(\.text),
                       ["Discard"])
        XCTAssertEqual(try decode(TypingEvent.self, from: records[2]).insertedText, " world")
        XCTAssertEqual(try decode(NavigationEventPayload.self, from: records[3]).fromURL,
                       "https://example.com/a")
    }

    func testHourBucketAndIdentifierAreDerivedFromTheTimestamp() throws {
        try recordFocus(nowMs: t0, trigger: .appActivated)
        let bucket = try db.dbQueue.read { d in
            try Int64.fetchOne(d, sql: "SELECT hour_bucket FROM capture_events")
        }
        XCTAssertEqual(bucket, HourBucket.bucket(forMs: t0))
        let id = try XCTUnwrap(store.recentCaptureEvents().first?.id)
        XCTAssertEqual(id.count, 36, "Ident.uuidv7 produces a hyphenated uuid string")
    }

    /// The whole point of the plaintext `app_bundle` column: a row is attributable to an app
    /// without decrypting anything, which is what makes spec 11 criterion 4 ("nothing is written
    /// for a denylisted, excluded, or non-consented app") a query anyone can run. Before this
    /// column the only app identifier in a row lived inside the encrypted `focus` payload.
    func testEventsAreAttributableToTheirAppWithoutDecrypting() throws {
        try recordFocus(nowMs: t0, appBundle: "com.example.editor")
        try recordFocus(nowMs: t0 + 1, appBundle: "com.example.excluded")
        try recordFocus(nowMs: t0 + 2, appBundle: "com.example.excluded")

        let excludedRows = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT count(*) FROM capture_events WHERE app_bundle=? AND at_ms > ?
                """, arguments: ["com.example.excluded", t0])
        }
        XCTAssertEqual(excludedRows, 2, "the exit-criterion query runs on plaintext alone")
        let records = try store.recentCaptureEvents()
        XCTAssertEqual(records.first?.appBundle, "com.example.excluded")
        XCTAssertEqual(records.filter { $0.appBundle == "com.example.editor" }.count, 1)
    }

    func testDeletingTheThreadCascadesItsEvents() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedChars: 1), nowMs: t0 + 1)
        try db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM latest_contexts WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM message_fingerprints WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM versions WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM threads WHERE id=?", arguments: [seeded.threadID])
        }
        XCTAssertTrue(try store.recentCaptureEvents().isEmpty)
    }

    func testDeletingTheVersionNullsVersionIDButKeepsTheEvent() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedChars: 1), nowMs: t0 + 1)
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE latest_contexts SET version_id=NULL WHERE thread_id=?",
                          arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM versions WHERE id=?", arguments: [seeded.versionID])
        }
        let record = try XCTUnwrap(store.recentCaptureEvents().first)
        XCTAssertEqual(record.threadID, seeded.threadID)
        XCTAssertNil(record.versionID)
    }

    /// `app_bundle` is nullable, so a hand-written row may omit it. The reader must not drop it.
    private func insertAncientRow(atMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                            trigger, payload_ciphertext, hour_bucket)
                VALUES ('ancient',NULL,NULL,NULL,?,'focus','periodic',NULL,0)
                """, arguments: [atMs])
        }
    }

    func testTrimDeletesEventsOlderThanThirtyDays() throws {
        try insertAncientRow(atMs: t0 - EpochMs(CaptureEventRetention.days) * 86_400_000 - 1)
        try recordFocus(nowMs: t0)
        XCTAssertEqual(try store.recentCaptureEvents().map(\.id).contains("ancient"), false)
    }

    func testTrimRunsAtMostOncePerHour() throws {
        // First write trims (last-trim is unset) and records t0 as the trim time.
        try recordFocus(nowMs: t0)
        try insertAncientRow(atMs: t0 - EpochMs(CaptureEventRetention.days) * 86_400_000 - 1)
        // Inside the gate: the stale row survives, so no capture pays for a DELETE.
        try recordFocus(nowMs: t0 + 1_000)
        XCTAssertTrue(try store.recentCaptureEvents().map(\.id).contains("ancient"))

        // An hour later the gate opens.
        try recordFocus(nowMs: t0 + CaptureEventRetention.trimIntervalMs)
        XCTAssertFalse(try store.recentCaptureEvents().map(\.id).contains("ancient"))
    }

    func testCaptureEventsWindowIsInclusiveAndChronological() throws {
        for offset in [0, 10, 20, 30] {
            try recordFocus(nowMs: t0 + EpochMs(offset), windowTitle: "w\(offset)")
        }
        let window = try store.captureEvents(fromMs: t0 + 10, toMs: t0 + 20)
        XCTAssertEqual(window.map(\.atMs), [t0 + 10, t0 + 20])
    }

    func testRecentCaptureEventsLimitIsBounded() throws {
        for offset in 0..<5 {
            try recordFocus(nowMs: t0 + EpochMs(offset))
        }
        XCTAssertEqual(try store.recentCaptureEvents(limit: 0).count, 1)
        XCTAssertEqual(try store.recentCaptureEvents(limit: 10_000).count, 5)
    }

    func testDialogPayloadIsCappedAtOneThousandRenderedChars() {
        let blocks = (0..<20).map { Block(type: .paragraph, text: String(repeating: "d", count: 100) + "\($0)") }
        let capped = DialogEventPayload.capped(blocks)
        XCTAssertLessThanOrEqual(ContentRenderer.renderBlocks(capped).count,
                                 CaptureEventRetention.dialogPayloadCap)
        XCTAssertLessThan(capped.count, blocks.count)
        XCTAssertEqual(capped.first?.text, blocks.first?.text, "the first block is always kept")
    }

    func testDialogPayloadKeepsASingleOversizeBlock() {
        let one = [Block(type: .paragraph, text: String(repeating: "d", count: 5_000))]
        XCTAssertEqual(DialogEventPayload.capped(one).count, 1)
    }
}
