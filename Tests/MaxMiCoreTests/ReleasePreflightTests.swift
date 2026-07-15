import Foundation
import XCTest

final class ReleasePreflightTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testVersionSourcesAreSynchronized() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("tools/check-version-sync.sh").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("version_sync=pass"))
        XCTAssertTrue(text.contains("version=0.2.0"))
    }

    func testReleasePipelineContainsRequiredTrustGates() throws {
        let source = try String(contentsOf: root.appendingPathComponent("release.sh"), encoding: .utf8)
        for required in [
            "swift test",
            "check-version-sync.sh",
            "check-bundle-secrets.sh",
            "codesign --verify",
            "flags=.*runtime",
            "notarytool submit",
            "stapler validate",
            "spctl --assess",
            "shasum -a 256",
            "security cms -S",
        ] {
            XCTAssertTrue(source.contains(required), "missing release gate: \(required)")
        }
    }
}
