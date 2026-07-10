import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class FingerprintDedupTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }
    let h10 = EpochMs(495_500) * 3_600_000
    var h11: EpochMs { h10 + 3_600_000 }
    func cap(_ content: String) -> CaptureInput {
        CaptureInput(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: content)
    }

    func testFirstCaptureCommitsAllItems() throws {
        guard case .committed = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10) else { return XCTFail() }
        let fp = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fingerprints") }
        XCTAssertEqual(fp, 2, "both lines fingerprinted")
    }
    func testRecaptureWithNoNewItemsDeduplicates() throws {
        _ = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10)
        // next hour, same two messages + only whitespace/order noise -> no novel items
        let r = try store.commitCapture(cap("Bob: hello\nAlice: hi"), nowMs: h11)
        XCTAssertEqual(r, .deduplicated, "reordered same messages -> no new facts")
    }
    func testRecaptureWithOneNewItemCommits() throws {
        _ = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10)
        guard case .committed = try store.commitCapture(cap("Alice: hi\nBob: hello\nCarol: new msg"), nowMs: h11)
        else { return XCTFail("a genuinely new line must commit") }
        let fp = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fingerprints") }
        XCTAssertEqual(fp, 3, "third line adds one fingerprint")
    }
}
