import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MarkExtractedTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let h10 = EpochMs(495_442) * 3_600_000
    var h11: EpochMs { h10 + 3_600_000 }

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db)
    }
    @discardableResult
    func commit(_ content: String, at: EpochMs, url: String = "https://e.com/p") throws -> (vid: String, hash: String) {
        guard case .committed(let v, let h) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: nil, content: content), nowMs: at)
        else { fatalError("dedup unexpected") }
        return (v, h)
    }

    func testFreshMutableVersionIsNotYetWork() throws {
        try commit("just captured", at: h10)
        let work = try store.pendingWork(nowMs: h10 + 60_000, idleThresholdMs: 300_000)
        XCTAssertTrue(work.isEmpty, "not idle, not frozen -> no work")
    }
    func testIdleVersionBecomesWork() throws {
        try commit("sat here a while", at: h10)
        let work = try store.pendingWork(nowMs: h10 + 301_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1)
        XCTAssertNil(work[0].previousFrozenContent)
    }
    func testImplicitlyFrozenPastHourIsWorkWithFrozenBaseline() throws {
        try commit("hour ten content", at: h10)
        _ = try commit("hour eleven content", at: h11)   // freezes h10 row
        // h11 row: not idle yet -> only... wait, h10 row was completed? No: both pending.
        let work = try store.pendingWork(nowMs: h11 + 1_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1, "frozen h10 row is work; fresh h11 row is not")
        XCTAssertEqual(work[0].hourBucket, 495_442)
        XCTAssertNil(work[0].previousFrozenContent, "h10 has no earlier frozen version")
    }
    func testPreviousFrozenContentJoin() throws {
        let a = try commit("old text", at: h10)
        _ = try store.markExtracted(versionID: a.vid, contentHashRead: a.hash)
        _ = try commit("new text", at: h11)              // freezes h10
        let work = try store.pendingWork(nowMs: h11 + 3_600_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work[0].previousFrozenContent, "old text")
    }
    func testMarkExtractedHashGuard() throws {
        let a = try commit("v1 content", at: h10)
        // capture lands mid-flight, content moves:
        _ = try commit("v2 content", at: h10 + 60_000)
        XCTAssertFalse(try store.markExtracted(versionID: a.vid, contentHashRead: a.hash),
                       "stale hash must not complete")
        try db.dbQueue.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT extract_status FROM versions"), "pending")
        }
        // pipeline re-reads current content, completes with fresh hash:
        let fresh = ContentHash.sha256Hex("v2 content")
        XCTAssertTrue(try store.markExtracted(versionID: a.vid, contentHashRead: fresh))
    }
    func testInsertDerivativesDedupsByThreadAndHash() throws {
        let a = try commit("content", at: h10)
        let tid = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT id FROM threads")! }
        let first = try store.insertDerivatives(versionID: a.vid, threadID: tid,
                                                facts: ["Fact one.", "Fact two."], nowMs: h10)
        XCTAssertEqual(first.count, 2)
        let second = try store.insertDerivatives(versionID: a.vid, threadID: tid,
                                                 facts: ["Fact two.", "Fact three."], nowMs: h10)
        XCTAssertEqual(second.map(\.content), ["Fact three."], "re-run is idempotent")
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM derivatives"), 3)
        }
    }
    func testRetryQueueBackoffAndDrain() throws {
        let a = try commit("x", at: h10)
        try store.enqueueRetry(kind: "extract", versionID: a.vid, derivativeID: nil, error: "offline", nowMs: h10)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 1_000).isEmpty, "30s backoff not elapsed")
        let due = try store.dueRetries(nowMs: h10 + 31_000)
        XCTAssertEqual(due.count, 1)
        // re-enqueue same target doubles backoff (attempts=1 -> 60s)
        try store.enqueueRetry(kind: "extract", versionID: a.vid, derivativeID: nil, error: "offline", nowMs: h10 + 31_000)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 61_000).isEmpty)
        XCTAssertEqual(try store.dueRetries(nowMs: h10 + 92_000).count, 1)
        try store.clearRetry(id: due[0].id)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 999_000).isEmpty)
    }
}
