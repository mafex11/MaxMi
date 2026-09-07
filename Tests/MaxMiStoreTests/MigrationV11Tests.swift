import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationV11Tests: XCTestCase {
    func testCurrentIdentifierIsV13() {
        XCTAssertEqual(Migrations.currentIdentifier, "v13")
    }

    func testCaptureEventsTableShape() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("capture_events"))
            let columns = try Row.fetchAll(d, sql: "PRAGMA table_info(capture_events)")
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"] as String, $0) })
            XCTAssertEqual(Set(byName.keys), [
                "id", "app_bundle", "thread_id", "version_id", "at_ms", "kind", "trigger",
                "payload_ciphertext", "hour_bucket",
            ])
            // Plaintext and nullable: a bundle id is an identifier, not content, and it is what
            // makes spec 11 criterion 4 checkable without a decrypt (spec 5b as amended).
            XCTAssertEqual(byName["app_bundle"]?["type"] as String?, "TEXT")
            XCTAssertEqual(byName["app_bundle"]?["notnull"] as Int?, 0)
            // Nullable on purpose: a focus event precedes any thread for that window (12 Q4),
            // and version pruning must not delete events.
            XCTAssertEqual(byName["thread_id"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["version_id"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["payload_ciphertext"]?["type"] as String?, "TEXT")
            XCTAssertEqual(byName["payload_ciphertext"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["at_ms"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["kind"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["trigger"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["hour_bucket"]?["notnull"] as Int?, 1)
        }
    }

    func testBothIndexesExist() throws {
        let db = try MaxMiDatabase.inMemory()
        let names = try db.dbQueue.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='capture_events'")
        }
        XCTAssertTrue(names.contains("idx_capture_events_at"), "\(names)")
        XCTAssertTrue(names.contains("idx_capture_events_thread"), "\(names)")
    }

    func testKindCheckConstraintRejectsAnUnknownKind() throws {
        let db = try MaxMiDatabase.inMemory()
        XCTAssertThrowsError(try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                            trigger, payload_ciphertext, hour_bucket)
                VALUES ('e1',NULL,NULL,NULL,1,'scrolling','periodic',NULL,0)
                """)
        })
    }

    func testEveryCaptureEventKindPassesTheCheckConstraint() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            for (index, kind) in CaptureEventKind.allCases.enumerated() {
                try d.execute(sql: """
                    INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                                trigger, payload_ciphertext, hour_bucket)
                    VALUES (?,NULL,NULL,NULL,?,?,'periodic',NULL,0)
                    """, arguments: ["e\(index)", index, kind.rawValue])
            }
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM capture_events"),
                           CaptureEventKind.allCases.count)
        }
    }

    /// A v10 database must migrate forward and keep its rows.
    func testV10DatabaseMigratesForwardWithoutDataLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try MaxMiDatabase(path: url.path, migrate: false)
        try Migrations.migrator.migrate(old.dbQueue, upTo: "v10")
        try old.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Notes','note:one','Idea',NULL,1,1)")
        }
        try old.dbQueue.close()

        let migrated = try MaxMiDatabase(path: url.path)
        defer { try? migrated.dbQueue.close() }
        try migrated.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("capture_events"))
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 1)
            XCTAssertEqual(
                try String.fetchOne(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v13")
        }
    }
}
