import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class EncryptionAtRestTests: XCTestCase {
    var db: MaxMiDatabase!
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    @discardableResult
    func commit(_ content: String, url: String = "https://e.com/p") throws -> (vid: String, tid: String) {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: "T", content: content), nowMs: t0)
        else { fatalError() }
        return (vid, try store.threadID(forKey: url))
    }

    func testVersionContentIsCiphertextAtRest() throws {
        try commit("secret page text")
        let raw = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT content FROM versions")! }
        XCTAssertTrue(raw.hasPrefix("enc:v1:"))
        XCTAssertFalse(raw.contains("secret"))
    }

    func testDerivativeContentIsCiphertextAtRest() throws {
        let (vid, tid) = try commit("x")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["A secret fact."], nowMs: t0)
        let raw = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT content FROM derivatives")! }
        XCTAssertTrue(raw.hasPrefix("enc:v1:"))
        XCTAssertFalse(raw.contains("secret"))
    }

    func testHashesAndWordCountFromPlaintext() throws {
        try commit("two words")
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT content_hash, word_count FROM versions")!
            XCTAssertEqual(row["content_hash"] as String, ContentHash.sha256Hex("two words"))
            XCTAssertEqual(row["word_count"] as Int, 2)
        }
    }

    func testDedupStillWorksAcrossNonDeterministicEncryption() throws {
        try commit("same content")
        let second = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "https://e.com/p", sourceTitle: "T", content: "same content"),
            nowMs: t0 + 1000)
        XCTAssertEqual(second, .deduplicated)
    }

    func testReadPathsDecrypt() throws {
        let (vid, tid) = try commit("readable content")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["Readable fact."], nowMs: t0)
        let work = try store.pendingWork(nowMs: t0 + 400_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.first?.content, "readable content")
        XCTAssertEqual(try store.pendingDerivatives(versionID: vid).first?.content, "Readable fact.")
        let threads = try store.recentThreads(limit: 5)
        XCTAssertEqual(threads.first?.recentFacts.first, "Readable fact.")
    }

    func testMixedStateReads() throws {
        // simulate a pre-M3 plaintext row next to an encrypted one
        let (vid, tid) = try commit("encrypted era")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["New fact."], nowMs: t0)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                VALUES ('legacy', ?, ?, 'Legacy plaintext fact.', 'h-legacy', ?, 'completed')
                """, arguments: [tid, vid, t0 - 1000])
        }
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("New fact."))
        XCTAssertTrue(threads.first!.recentFacts.contains("Legacy plaintext fact."), "passthrough decrypt")
    }

    func testCorruptRowYieldsMarkerNotThrow() throws {
        let (vid, tid) = try commit("x")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["Good fact."], nowMs: t0)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                VALUES ('corrupt', ?, ?, 'enc:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'h-c', ?, 'completed')
                """, arguments: [tid, vid, t0 + 5000])
        }
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("[unreadable memory]"))
        XCTAssertTrue(threads.first!.recentFacts.contains("Good fact."), "query continues past corrupt row")
    }
}
