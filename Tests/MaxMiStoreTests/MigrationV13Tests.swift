import XCTest
import GRDB
@testable import MaxMiStore

final class MigrationV13Tests: XCTestCase {
    func testCheckinsMigrationHasExactColumnsAndHead() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            let columns = try Row.fetchAll(d, sql: "PRAGMA table_info(checkins)")
            XCTAssertEqual(Set(columns.map { $0["name"] as String }), Set([
                "day_bucket", "generated_at_ms", "summary_ciphertext", "open_item_ids",
                "resolved_yesterday_count", "dismissed_at_ms", "prompt_version",
            ]))
            XCTAssertEqual(
                try String.fetchOne(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v13"
            )
        }
        XCTAssertEqual(Migrations.currentIdentifier, "v13")
    }
}
