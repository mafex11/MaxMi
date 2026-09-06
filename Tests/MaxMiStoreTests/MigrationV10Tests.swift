import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationV10Tests: XCTestCase {
    func testStructuredColumnsExistAndAreNullableText() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            for table in ["versions", "latest_contexts"] {
                let columns = try Row.fetchAll(d, sql: "PRAGMA table_info(\(table))")
                let column = try XCTUnwrap(
                    columns.first { ($0["name"] as String) == "structured_ciphertext" },
                    "\(table) is missing structured_ciphertext")
                XCTAssertEqual(column["type"] as String, "TEXT", "\(table)")
                XCTAssertEqual(column["notnull"] as Int, 0, "\(table).structured_ciphertext is nullable")
            }
        }
    }

    func testCurrentIdentifierIsV10() {
        XCTAssertEqual(Migrations.currentIdentifier, "v10")
    }

    func testNullStructuredCiphertextIsAcceptedByBothTables() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://x.com','X',NULL,1,1)")
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,
                                      is_frozen,committed_at,extract_status,structured_ciphertext)
                VALUES ('v1','t1',100,'c','h',1,0,1,'pending',NULL)
                """)
            try d.execute(sql: """
                INSERT INTO latest_contexts (
                  thread_id, version_id, content_ciphertext, content_hash, content_kind,
                  parser_id, parser_version, accumulation_policy, offscreen_mode,
                  offscreen_max_steps, offscreen_max_chars, trigger, captured_at,
                  character_count, truncated, structured_ciphertext
                ) VALUES ('t1','v1','c','h','generic','legacy',1,'replace','visibleOnly',0,32000,
                          'unknown',1,1,0,NULL)
                """)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM latest_contexts"), 1)
        }
    }
}
