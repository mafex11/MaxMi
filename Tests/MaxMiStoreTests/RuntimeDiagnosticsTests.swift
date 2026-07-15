import Foundation
import GRDB
import XCTest
import MaxMiCore
@testable import MaxMiStore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testSnapshotContainsOnlyAggregateMetrics() throws {
        let database = try MaxMiDatabase.inMemory()
        let store = Store(db: database, cipher: AESGCMFieldCipher.testCipher)
        try database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO threads
                  (id, source_app, source_key, source_title, created_at, updated_at)
                VALUES ('thread-1', 'TOP_SECRET_APP', 'TOP_SECRET_KEY', 'TOP_SECRET_TITLE', 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO versions
                  (id, thread_id, hour_bucket, content, content_hash, committed_at, extract_status)
                VALUES ('version-1', 'thread-1', 1, 'TOP_SECRET_CONTEXT', 'hash-1', 1, 'pending')
                """)
            try db.execute(sql: """
                INSERT INTO latest_contexts
                  (thread_id, version_id, content_ciphertext, content_hash, content_kind,
                   parser_id, parser_version, accumulation_policy, offscreen_mode, trigger,
                   captured_at, summary_status)
                VALUES ('thread-1', 'version-1', 'TOP_SECRET_LATEST', 'hash-1', 'generic',
                        'fixture', 1, 'replace', 'visibleOnly', 'unknown', 1, 'pending')
                """)
            try db.execute(sql: """
                INSERT INTO retry_queue
                  (id, kind, version_id, attempts, next_attempt_at, last_error)
                VALUES ('retry-1', 'extract', 'version-1', 2, 1, 'TOP_SECRET_ERROR')
                """)
        }

        let snapshot = try store.runtimeDiagnostics(nowMs: 2)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertEqual(snapshot.latestMigration.value, "v9")
        XCTAssertTrue(snapshot.integrityOK)
        XCTAssertEqual(snapshot.threads, 1)
        XCTAssertEqual(snapshot.versions, 1)
        XCTAssertEqual(snapshot.latestContexts, 1)
        XCTAssertEqual(snapshot.retryTotal, 1)
        XCTAssertEqual(snapshot.retryOverdue, 1)
        XCTAssertEqual(snapshot.retryMaxAttempts, 2)
        XCTAssertFalse(encoded.contains("TOP_SECRET"))
    }

    func testFileBackedSnapshotReportsDatabaseSizes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.db")
        let database = try MaxMiDatabase(path: url.path)
        let store = Store(db: database, cipher: AESGCMFieldCipher.testCipher)

        let snapshot = try store.runtimeDiagnostics(nowMs: 1, databaseURL: url)

        XCTAssertGreaterThan(snapshot.databaseBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.walBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.shmBytes, 0)
    }
}
