import Foundation
import XCTest

final class BundleSecretScriptTests: XCTestCase {
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/check-bundle-secrets.sh")
    }

    func testPassesBenignBundleAndRejectsProviderKeyWithoutEchoingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("MaxMi.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = app.appendingPathComponent("binary")
        try Data("benign".utf8).write(to: file)
        XCTAssertEqual(try run(app).status, 0)

        let credential = "AIza" + String(repeating: "A", count: 35)
        try Data(credential.utf8).write(to: file)
        let rejected = try run(app)
        XCTAssertEqual(rejected.status, 2)
        XCTAssertTrue(rejected.output.contains("reason=provider_key_pattern"))
        XCTAssertFalse(rejected.output.contains(credential))
    }

    func testRejectsDotenvResource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("MaxMi.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent(".env"))
        let rejected = try run(app)
        XCTAssertEqual(rejected.status, 2)
        XCTAssertTrue(rejected.output.contains("reason=dotenv_file"))
    }

    private func run(_ app: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, app.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
