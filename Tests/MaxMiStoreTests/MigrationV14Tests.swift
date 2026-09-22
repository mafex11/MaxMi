import XCTest
import GRDB
@testable import MaxMiStore

final class MigrationV14Tests: XCTestCase {
    func testReminderColumnsIndexAndMigrationHeadAreV14() throws {
        let db = try MaxMiDatabase.inMemory()

        try db.dbQueue.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(agent_action_items)")
            XCTAssertEqual(
                Set(columns.map { $0["name"] as String }),
                Set([
                    "id", "kind", "status", "title_ciphertext", "details_ciphertext",
                    "source_refs", "detected_at", "updated_at", "resolved_at",
                    "resolution_evidence_ciphertext", "idem_key", "remind_at_ms", "reminded_at_ms",
                ])
            )
            let indexes = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='agent_action_items'"
            )
            XCTAssertTrue(indexes.contains("idx_items_status_remind_at_ms"))
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                ),
                "v14"
            )
        }

        XCTAssertEqual(Migrations.currentIdentifier, "v14")
        XCTAssertTrue(Set(Migrations.migrator.migrations).isSuperset(of: ["v12", "v13", "v14"]))
        XCTAssertEqual(Array(Migrations.migrator.migrations.suffix(3)), ["v12", "v13", "v14"])
    }
}
