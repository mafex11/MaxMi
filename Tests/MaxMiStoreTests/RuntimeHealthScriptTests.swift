import Foundation
import GRDB
import XCTest
@testable import MaxMiStore

final class RuntimeHealthScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRuntimeHealthReportsOnlyBoundedAggregateMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("fixture.db")
        let database = try MaxMiDatabase(path: databaseURL.path)
        try database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO capture_health_events (
                  id, at_ms, app_bundle, app_label, trigger, parser, outcome, duration_ms
                ) VALUES ('health', 1, 'TOP_SECRET_BUNDLE', 'TOP_SECRET_LABEL',
                          'unknown', 'fixture', 'captured', 12)
                """)
        }
        try database.dbQueue.close()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repositoryRoot.appendingPathComponent("tools/check-runtime-health.sh").path]
        var environment = ProcessInfo.processInfo.environment
        environment["MAXMI_DB_PATH"] = databaseURL.path
        environment["MAXMI_APP_SUPPORT_DIR"] = directory.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("runtime_health_version=1"))
        XCTAssertTrue(text.contains("capture_events=1"))
        XCTAssertTrue(text.contains("capture_avg_duration_ms=12.0"))
        XCTAssertFalse(text.contains("TOP_SECRET"))
    }

    func testRuntimeScriptsDoNotReferenceCapturedContentColumns() throws {
        for name in ["check-runtime-health.sh", "profile-runtime.sh"] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent("tools/\(name)"),
                encoding: .utf8
            ).lowercased()
            for forbidden in [
                "source_key", "source_title", "source_app", "last_error",
                "content_ciphertext", "display_summary_ciphertext", "title_ciphertext",
                "details_ciphertext", "resolution_evidence_ciphertext"
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(name) references \(forbidden)")
            }
        }
    }
}
