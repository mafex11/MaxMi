import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CaptureHealthStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(1_800_000_000_000)

    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    func testV6CaptureHealthTableExists() throws {
        try db.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("capture_health_events"))
        }
    }

    func testRecordAndReadCapturedOutcomeWithoutContentFields() throws {
        try store.recordCaptureHealth(
            appBundle: "com.apple.Safari",
            appLabel: "Safari",
            trigger: .appActivated,
            parser: "BrowserTabExtractor",
            outcome: .captured(versionID: "v1", characterCount: 321, truncated: false),
            durationMs: 42,
            atMs: t0
        )

        let event = try XCTUnwrap(store.recentCaptureHealth().first)
        XCTAssertEqual(event.appBundle, "com.apple.Safari")
        XCTAssertEqual(event.outcome, .captured)
        XCTAssertEqual(event.characterCount, 321)
        XCTAssertEqual(event.durationMs, 42)
        XCTAssertEqual(event.versionID, "v1")

        let columns = try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "PRAGMA table_info(capture_health_events)")
                .map { $0["name"] as String }
        }
        for forbidden in ["content", "source_key", "url", "title", "error"] {
            XCTAssertFalse(columns.contains(forbidden), "health ledger must not contain \(forbidden)")
        }
    }

    func testSkipAndFailureReasonsRoundTrip() throws {
        try store.recordCaptureHealth(
            appBundle: "dev.mafex.maxmi", appLabel: "MaxMi", trigger: .appActivated,
            parser: "PolicyGate", outcome: .skipped(.excludedApp), durationMs: 0, atMs: t0
        )
        try store.recordCaptureHealth(
            appBundle: "com.example.App", appLabel: "App", trigger: .periodic,
            parser: "GenericAXParser", outcome: .failed(.storeCommitFailed),
            durationMs: 5, atMs: t0 + 1
        )

        let events = try store.recentCaptureHealth(limit: 10)
        XCTAssertEqual(events.map(\.outcome), [.failed, .skipped])
        XCTAssertEqual(events.map(\.reason), ["storeCommitFailed", "excludedApp"])
    }

    func testLedgerRetainsOnlyConfiguredLatestRows() throws {
        for i in 0..<8 {
            try store.recordCaptureHealth(
                appBundle: "com.example.App", appLabel: "App", trigger: .periodic,
                parser: "GenericAXParser", outcome: .deduplicated(characterCount: i, truncated: false),
                durationMs: i, atMs: t0 + EpochMs(i), retainLatest: 3
            )
        }

        let events = try store.recentCaptureHealth(limit: 100)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.characterCount), [7, 6, 5])
    }
}
