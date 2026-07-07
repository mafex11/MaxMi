import XCTest
import GRDB
@testable import MaxMiStore

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
}
