import Foundation
import GRDB
import XCTest
@testable import MaxMiStore

final class Phase7BaselineScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptURL: URL {
        repositoryRoot.appendingPathComponent("tools/check-phase7-baseline.sh")
    }

    func testReportsOnlyAggregateContentFreeMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("fixture.db")

        do {
            let database = try MaxMiDatabase(path: databaseURL.path)
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
                    INSERT INTO derivatives
                      (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                    VALUES ('fact-1', 'thread-1', 'version-1', 'TOP_SECRET_FACT', 'hash-2', 1, 'pending')
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
                try db.execute(sql: """
                    INSERT INTO capture_health_events
                      (id, at_ms, app_bundle, app_label, trigger, parser, outcome)
                    VALUES ('health-1', 1, 'TOP_SECRET_BUNDLE', 'TOP_SECRET_LABEL',
                            'activation', 'fixture', 'captured')
                    """)
            }
        }

        let result = try runScript(databaseURL: databaseURL, skipProcessCheck: true)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("phase7_baseline_version=1"))
        XCTAssertTrue(result.stdout.contains("latest_migration=v9"))
        XCTAssertTrue(result.stdout.contains("integrity=ok"))
        XCTAssertTrue(result.stdout.contains("threads=1"))
        XCTAssertTrue(result.stdout.contains("versions=1"))
        XCTAssertTrue(result.stdout.contains("facts=1"))
        XCTAssertTrue(result.stdout.contains("latest_contexts=1"))
        XCTAssertTrue(result.stdout.contains("retry_total=1"))
        XCTAssertFalse(result.stdout.contains("TOP_SECRET"))
    }

    func testRejectsMissingDatabaseWithoutPrintingPath() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TOP_SECRET_\(UUID().uuidString).db")
        let result = try runScript(databaseURL: missingURL, skipProcessCheck: true)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "error=database_not_found\n")
        XCTAssertFalse(result.stdout.contains("TOP_SECRET"))
    }

    func testRejectsUnsupportedSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("old.db")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.create(table: "threads") { table in table.column("id", .text).primaryKey() }
        }

        let result = try runScript(databaseURL: databaseURL, skipProcessCheck: true)

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stdout.contains("error=unsupported_schema"))
        XCTAssertTrue(result.stdout.contains("missing_table=versions"))
    }

    func testScriptDoesNotQueryForbiddenContentColumns() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8).lowercased()
        for forbidden in [
            "source_key", "source_title", "source_app", "last_error", "content_ciphertext",
            "display_summary_ciphertext", "title_ciphertext", "details_ciphertext",
            "resolution_evidence_ciphertext"
        ] {
            XCTAssertFalse(source.contains(forbidden), "baseline script references \(forbidden)")
        }
    }

    private func runScript(databaseURL: URL, skipProcessCheck: Bool) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MAXMI_DB_PATH"] = databaseURL.path
        environment["MAXMI_APP_SUPPORT_DIR"] = databaseURL.deletingLastPathComponent().path
        environment["MAXMI_APP_PATH"] = repositoryRoot.appendingPathComponent("missing-test-app").path
        if skipProcessCheck { environment["MAXMI_SKIP_PROCESS_CHECK"] = "1" }
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
