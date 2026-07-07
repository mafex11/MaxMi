import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class BackfillTests: XCTestCase {
    var db: MaxMiDatabase!
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    /// Seed pre-M3 state: plaintext rows written with raw SQL (bypassing the encrypting Store).
    func seedPlaintext(rows: Int) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://e.com','T',NULL,?,?)",
                          arguments: [t0, t0])
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v1','t1',495442,'plain page text','h1',3,1,?,'completed')
                """, arguments: [t0])
            for i in 0..<rows {
                try d.execute(sql: """
                    INSERT INTO derivatives (id,thread_id,version_id,content,content_hash,committed_at,embedding_status)
                    VALUES (?, 't1','v1', ?, ?, ?, 'completed')
                    """, arguments: ["d\(i)", "Plain fact \(i).", "h-d\(i)", t0 + EpochMs(i)])
            }
        }
    }

    func testBackfillEncryptsEverythingAndSetsFlag() throws {
        try seedPlaintext(rows: 450)   // > 2 batches of 200
        XCTAssertFalse(try store.isContentEncrypted())
        let n = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(n, 451)         // 450 derivatives + 1 version
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql:
                "SELECT count(*) FROM derivatives WHERE content NOT LIKE 'enc:v1:%'"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql:
                "SELECT count(*) FROM versions WHERE content NOT LIKE 'enc:v1:%'"), 0)
        }
        XCTAssertTrue(try store.isContentEncrypted())
    }

    func testBackfillPreservesReadability() throws {
        try seedPlaintext(rows: 3)
        _ = try store.encryptExistingContent(nowMs: t0)
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("Plain fact 2."))
    }

    func testSecondRunIsNoOp() throws {
        try seedPlaintext(rows: 5)
        _ = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(try store.encryptExistingContent(nowMs: t0), 0, "flag short-circuits")
    }

    func testInterruptedRunResumes() throws {
        try seedPlaintext(rows: 10)
        // encrypt only some rows manually to simulate a crash mid-run (flag unset)
        let c = AESGCMFieldCipher.testCipher
        try db.dbQueue.write { d in
            let enc = try c.encrypt("Plain fact 0.")
            try d.execute(sql: "UPDATE derivatives SET content=? WHERE id='d0'", arguments: [enc])
        }
        let n = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(n, 10, "9 remaining derivatives + 1 version; d0 skipped by prefix check")
        XCTAssertTrue(try store.isContentEncrypted())
    }

    func testHashesUntouchedByBackfill() throws {
        try seedPlaintext(rows: 1)
        _ = try store.encryptExistingContent(nowMs: t0)
        try db.dbQueue.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT content_hash FROM versions"), "h1",
                           "backfill must not recompute hashes")
        }
    }
}
