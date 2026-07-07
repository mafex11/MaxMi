import XCTest
@testable import MaxMiMCP

final class StdioIntegrationTests: XCTestCase {
    func testHandshake_WhileStdinOpen_RepliesImmediately() throws {
        // Locate the built MaxMiMCP binary
        let binaryPath: String
        if let envPath = ProcessInfo.processInfo.environment["SWIFT_BUILD_BIN"] {
            binaryPath = (envPath as NSString).appendingPathComponent("MaxMiMCP")
        } else {
            // Fall back to typical .build/debug location
            let cwd = FileManager.default.currentDirectoryPath
            binaryPath = (cwd as NSString).appendingPathComponent(".build/debug/MaxMiMCP")
        }

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            XCTFail("MaxMiMCP binary not found at \(binaryPath). Run 'swift build' first.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // discard stderr

        try process.run()

        // Send initialize request
        let initRequest = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        """
        let requestData = (initRequest + "\n").data(using: .utf8)!
        stdinPipe.fileHandleForWriting.write(requestData)

        // CRITICAL: DO NOT close stdin yet — keep it open while reading
        // This tests that fflush works and the reply arrives on a pipe while stdin is held open

        // Try to read reply with a 2-second timeout
        let expectation = XCTestExpectation(description: "Receive initialize response")

        DispatchQueue.global().async {
            let data = stdoutPipe.fileHandleForReading.availableData
            if !data.isEmpty {
                expectation.fulfill()
            }
        }

        let result = XCTWaiter.wait(for: [expectation], timeout: 2.0)

        // Clean up
        stdinPipe.fileHandleForWriting.closeFile()
        process.terminate()
        process.waitUntilExit()

        XCTAssertEqual(result, .completed, "Should receive reply within 2 seconds while stdin is open")
    }
}
