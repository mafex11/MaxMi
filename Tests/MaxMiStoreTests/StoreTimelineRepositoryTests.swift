import XCTest
@testable import MaxMiStore
import MaxMiCore

final class StoreTimelineRepositoryTests: XCTestCase {
    private var store: Store!
    private var db: MaxMiDatabase!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    private func recordFocus(atMs: EpochMs) throws {
        try store.recordCaptureEvent(
            kind: .focus,
            appBundle: "com.example.editor",
            threadID: nil,
            versionID: nil,
            trigger: .periodic,
            payload: FocusEventPayload(
                bundleID: "com.example.editor",
                appLabel: "Editor",
                windowTitle: nil),
            nowMs: atMs)
    }

    func testCaptureEventsSkipsCorruptPayloadAndReportsSkippedCount() throws {
        try recordFocus(atMs: t0)
        try recordFocus(atMs: t0 + 10)
        try recordFocus(atMs: t0 + 20)
        try db.dbQueue.write { database in
            try database.execute(
                sql: "UPDATE capture_events SET payload_ciphertext='garbage' WHERE at_ms=?",
                arguments: [t0 + 10])
        }

        let repository = StoreTimelineRepository(store: store)
        let result = try repository.captureEventsAndSkippedCount(fromMs: t0, toMs: t0 + 20)

        XCTAssertEqual(result.events.map(\.atMs), [t0, t0 + 20])
        XCTAssertEqual(result.skippedCount, 1)
    }
}
