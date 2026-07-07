import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CommitCaptureTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }
    func input(_ content: String, url: String = "https://example.com/a") -> CaptureInput {
        CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: "T", content: content)
    }
    let h10 = EpochMs(495_442) * 3_600_000        // some hour start
    var h11: EpochMs { h10 + 3_600_000 }

    func testNewPageCreatesThreadAndPendingVersion() throws {
        guard case .committed(let vid, let hash) = try store.commitCapture(input("hello world"), nowMs: h10)
        else { return XCTFail() }
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 1)
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions WHERE id=?", arguments: [vid])!
            XCTAssertEqual(row["extract_status"], "pending")
            XCTAssertEqual(row["is_frozen"], 0)
            XCTAssertEqual(row["word_count"], 2)
            XCTAssertEqual(row["content_hash"] as String, hash)
        }
    }
    func testIdenticalContentDeduplicates() throws {
        _ = try store.commitCapture(input("same"), nowMs: h10)
        XCTAssertEqual(try store.commitCapture(input("same"), nowMs: h10 + 1000), .deduplicated)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM versions"), 1)
        }
    }
    func testWithinHourRewritesInPlaceAndResetsPending() throws {
        guard case .committed(let v1, _) = try store.commitCapture(input("first"), nowMs: h10) else { return XCTFail() }
        // simulate pipeline finishing on v1
        try db.dbQueue.write { try $0.execute(sql: "UPDATE versions SET extract_status='completed'") }
        guard case .committed(let v2, _) = try store.commitCapture(input("first plus more"), nowMs: h10 + 60_000) else { return XCTFail() }
        XCTAssertEqual(v1, v2, "same hour -> same row")
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions")!
            let decrypted = try AESGCMFieldCipher.testCipher.decrypt(row["content"])
            XCTAssertEqual(decrypted, "first plus more")
            XCTAssertEqual(row["extract_status"], "pending", "content change resets status")
        }
    }
    func testHourRolloverFreezesOldCreatesNew() throws {
        _ = try store.commitCapture(input("hour ten"), nowMs: h10)
        _ = try store.commitCapture(input("hour eleven"), nowMs: h11)
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT * FROM versions ORDER BY hour_bucket")
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["is_frozen"], 1)
            XCTAssertEqual(rows[1]["is_frozen"], 0)
        }
    }
    func testClockSteppedBackWritesIntoFrozenRow() throws {
        _ = try store.commitCapture(input("a"), nowMs: h10)
        _ = try store.commitCapture(input("b"), nowMs: h11)      // freezes h10 row
        _ = try store.commitCapture(input("c"), nowMs: h10 + 1)  // clock stepped back
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions WHERE hour_bucket=?",
                                       arguments: [495_442])!
            let decrypted = try AESGCMFieldCipher.testCipher.decrypt(row["content"])
            XCTAssertEqual(decrypted, "c")
            XCTAssertEqual(row["is_frozen"], 0, "un-frozen by write")
        }
    }
    func testDistinctURLsDistinctThreads() throws {
        _ = try store.commitCapture(input("a", url: "https://x.com/1"), nowMs: h10)
        _ = try store.commitCapture(input("b", url: "https://x.com/2"), nowMs: h10)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 2)
        }
    }
}
