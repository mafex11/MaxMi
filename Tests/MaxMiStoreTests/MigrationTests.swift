import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationTests: XCTestCase {
    func testSchemaAndVecPresent() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            for t in ["threads", "versions", "derivatives", "retry_queue", "settings", "schema_migrations"] {
                XCTAssertTrue(try d.tableExists(t), "missing table \(t)")
            }
            // sqlite-vec is alive on this connection
            let v = try String.fetchOne(d, sql: "SELECT vec_version()")
            XCTAssertNotNil(v)
            // vec0 virtual table exists
            let n = try Int.fetchOne(d, sql:
                "SELECT count(*) FROM sqlite_master WHERE name='derivative_embeddings'")
            XCTAssertEqual(n, 1)
        }
    }
    func testVersionUniqueInvariantEnforced() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://x.com','X',NULL,1,1)")
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v1','t1',100,'c','h',1,0,1,'pending')
                """)
            XCTAssertThrowsError(try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v2','t1',100,'c2','h2',1,0,2,'pending')
                """)) // UNIQUE(thread_id, hour_bucket)
        }
    }
    func testFileBackedDatabaseOpensWithWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("t.db").path
        let db = try MaxMiDatabase(path: path)
        try db.dbQueue.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "PRAGMA journal_mode"), "wal")
        }
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
    func testReadOnlyOpenRejectsWritesAllowsReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("ro.db").path
        _ = try MaxMiDatabase(path: path)                     // create + migrate writable
        let ro = try MaxMiDatabase(path: path, readOnly: true)
        try ro.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("threads"))
        }
        XCTAssertThrowsError(try ro.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO settings VALUES ('k','v',1)")
        })
    }
    func testConcurrentWALRead_WhileWritableOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("wal.db").path

        // Open writable database
        let writable = try MaxMiDatabase(path: path)
        let writableStore = Store(db: writable)

        // Open read-only database on same path
        let readonly = try MaxMiDatabase(path: path, readOnly: true)
        let readonlyStore = Store(db: readonly)

        // Commit a capture through the writable store
        let nowMs = EpochMs(Date().timeIntervalSince1970 * 1000)
        let result = try writableStore.commitCapture(
            CaptureInput(sourceApp: "TestApp", sourceKey: "test://concurrent", sourceTitle: "Concurrent Test", content: "test content"),
            nowMs: nowMs
        )
        guard case .committed = result else {
            XCTFail("Failed to commit capture")
            return
        }

        // Read-only handle should see the new row (WAL isolation allows this)
        let threads = try readonlyStore.recentThreads(limit: 10)
        XCTAssertEqual(threads.count, 1, "Read-only handle should see committed write via WAL")
        XCTAssertEqual(threads[0].sourceTitle, "Concurrent Test")

        try? FileManager.default.removeItem(atPath: dir.path)
    }
}
