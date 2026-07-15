import Foundation
import XCTest
@testable import MaxMiCore

final class SafeLoggerTests: XCTestCase {
    func testErrorDescriptionAndDomainNeverReachLog() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = SafeLogger(directoryURL: directory, processName: "test")
        let error = NSError(
            domain: "TOP_SECRET_DOMAIN",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "TOP_SECRET_DESCRIPTION"]
        )

        logger.log(.error, subsystem: .capture, event: .captureCommitFailed, error: error)

        let text = try String(contentsOf: logger.activeFileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("TOP_SECRET"))
        XCTAssertTrue(text.contains("\"system_error_code\":42"))
        XCTAssertTrue(text.contains("\"event\":\"capture_commit_failed\""))
    }

    func testRotatesWithinConfiguredFileCountAndPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = SafeLogger(
            directoryURL: directory,
            processName: "test",
            maximumFileBytes: 300,
            maximumFiles: 3
        )

        for _ in 0..<20 {
            logger.log(.warning, subsystem: .pipeline, event: .pendingWorkReadFailed)
        }

        let files = logger.logFilesNewestFirst()
        XCTAssertEqual(files.count, 3)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? 0, 300)
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
    }

    func testConcurrentWritesRemainValidJSONLines() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = SafeLogger(
            directoryURL: directory,
            processName: "test",
            maximumFileBytes: 1_000_000
        )
        let group = DispatchGroup()

        for index in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                logger.log(
                    .info,
                    subsystem: .diagnostics,
                    event: .diagnosticsExported,
                    fields: SafeLogFields(count: index)
                )
                group.leave()
            }
        }
        group.wait()

        let text = try String(contentsOf: logger.activeFileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(object?["event"] as? String, "diagnostics_exported")
        }
    }

    func testTokenRejectsPotentialFreeFormContent() {
        XCTAssertNotNil(SafeLogToken(validating: "BrowserWeb.v2/chromium"))
        XCTAssertNil(SafeLogToken(validating: "private message text"))
        XCTAssertNil(SafeLogToken(validating: "https://example.com?q=private"))
        XCTAssertNil(SafeLogToken(validating: String(repeating: "a", count: 97)))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
