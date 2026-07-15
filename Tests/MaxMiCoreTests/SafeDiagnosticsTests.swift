import Foundation
import XCTest
@testable import MaxMiCore

final class SafeDiagnosticsTests: XCTestCase {
    func testBundleContainsFixedManifestAndOnlySanitizedLogs() throws {
        let root = temporaryDirectory()
        let logs = root.appendingPathComponent("source-logs", isDirectory: true)
        let destination = root.appendingPathComponent("MaxMi Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = SafeLogger(directoryURL: logs, processName: "maxmi")
        logger.log(
            .error,
            subsystem: .capture,
            event: .captureCommitFailed,
            error: NSError(
                domain: "TOP_SECRET_DOMAIN",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "TOP_SECRET_DESCRIPTION"]
            )
        )
        let malicious = logs.appendingPathComponent("tampered.log")
        try Data("{\"event\":\"TOP_SECRET_EVENT\",\"private\":\"TOP_SECRET_PAYLOAD\"}\n".utf8)
            .write(to: malicious)

        let entries = try SafeDiagnosticsBundleWriter.write(
            manifest: fixtureManifest(),
            logDirectory: logs,
            to: destination
        )

        XCTAssertEqual(entries, 1)
        let exported = try recursiveText(in: destination)
        XCTAssertFalse(exported.contains("TOP_SECRET"))
        XCTAssertTrue(exported.contains("capture_commit_failed"))
        XCTAssertTrue(exported.contains("\"formatVersion\" : 1"))
        XCTAssertEqual(mode(destination), 0o700)
        XCTAssertEqual(mode(destination.appendingPathComponent("manifest.json")), 0o600)
        XCTAssertEqual(mode(destination.appendingPathComponent("logs")), 0o700)
    }

    func testExistingDestinationIsNeverReplaced() throws {
        let root = temporaryDirectory()
        let destination = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try SafeDiagnosticsBundleWriter.write(
                manifest: fixtureManifest(),
                logDirectory: root.appendingPathComponent("logs"),
                to: destination
            )
        ) { error in
            XCTAssertEqual(error as? SafeDiagnosticsError, .destinationExists)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    private func fixtureManifest() -> SafeDiagnosticsManifest {
        SafeDiagnosticsManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: SafeLogToken(validating: "0.2.0")!,
            appBuild: SafeLogToken(validating: "1")!,
            encryptionAvailable: true,
            permissions: SafeDiagnosticsPermissions(
                accessibility: true,
                microphone: false,
                screenRecording: false
            ),
            processes: SafeDiagnosticsProcesses(app: 1, mcp: 0),
            database: SafeDiagnosticsDatabase(
                latestMigration: SafeLogToken(validating: "v9")!,
                migrationCount: 9,
                integrityOK: true,
                databaseBytes: 100,
                walBytes: 20,
                shmBytes: 10,
                threads: 1,
                versions: 1,
                facts: 2,
                latestContexts: 1,
                recordings: 0,
                captureHealthEvents: 1,
                retryTotal: 0,
                retryOverdue: 0,
                retryMaxAttempts: 0,
                contextSummariesPending: 0,
                contextSummariesFailed: 0,
                activitySummariesPending: 0,
                activitySummariesFailed: 0,
                agentRunsRunning: 0,
                agentRunsFailed: 0,
                actionItemsOpen: 0
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recursiveText(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var text = ""
        while let file = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            text += String(decoding: try Data(contentsOf: file), as: UTF8.self)
        }
        return text
    }

    private func mode(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
