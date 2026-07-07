import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class LazyToolsTests: XCTestCase {
    func testMAXMI_DB_PATH_UsedWhenSet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dbPath = tempDir.appendingPathComponent("test.db").path

        // Create and seed a database
        let db = try MaxMiDatabase(path: dbPath)
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        let nowMs = EpochMs(Date().timeIntervalSince1970 * 1000)
        let result = try store.commitCapture(
            CaptureInput(sourceApp: "TestApp", sourceKey: "test://url", sourceTitle: "Test Thread", content: "test content"),
            nowMs: nowMs
        )
        guard case .committed(let versionID, _) = result else {
            XCTFail("Failed to commit capture")
            return
        }

        // Get threadID from the version
        let threadID = try await db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT thread_id FROM versions WHERE id=?", arguments: [versionID])!
        }

        // Insert a fact
        let facts = try await store.insertDerivatives(versionID: versionID, threadID: threadID, facts: ["Test fact"], nowMs: nowMs)
        XCTAssertEqual(facts.count, 1)

        // Set MAXMI_DB_PATH and test
        setenv("MAXMI_DB_PATH", dbPath, 1)
        defer { unsetenv("MAXMI_DB_PATH") }

        let lazyTools = LazyTools()
        let result2 = await lazyTools.call(name: "list_active_threads", arguments: [:])

        XCTAssertFalse(result2.isError, "Expected success, got error: \(result2.text)")
        XCTAssertTrue(result2.text.contains("Test Thread"), "Expected thread title in result")

        try? FileManager.default.removeItem(atPath: tempDir.path)
    }

    func testNoDBAtPath_ReturnsNoDBText() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.db").path

        setenv("MAXMI_DB_PATH", tempPath, 1)
        defer { unsetenv("MAXMI_DB_PATH") }

        let lazyTools = LazyTools()
        let result = await lazyTools.call(name: "list_active_threads", arguments: [:])

        XCTAssertFalse(result.isError, "No DB should not be an error")
        XCTAssertEqual(result.text, MemoryQueries.noDBText)
    }

    func testUnknownTool_WithoutDB_ReturnsErrorTrue() async throws {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.db").path

        setenv("MAXMI_DB_PATH", tempPath, 1)
        defer { unsetenv("MAXMI_DB_PATH") }

        let lazyTools = LazyTools()
        let result = await lazyTools.call(name: "unknown_tool", arguments: [:])

        XCTAssertTrue(result.isError, "Unknown tool should return isError=true")
        XCTAssertTrue(result.text.contains("Unknown tool"))
    }

    func testUnknownTool_WithDB_ReturnsErrorTrue() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dbPath = tempDir.appendingPathComponent("test.db").path

        // Create a minimal database
        _ = try MaxMiDatabase(path: dbPath)

        setenv("MAXMI_DB_PATH", dbPath, 1)
        defer { unsetenv("MAXMI_DB_PATH") }

        let lazyTools = LazyTools()
        let result = await lazyTools.call(name: "unknown_tool", arguments: [:])

        XCTAssertTrue(result.isError, "Unknown tool should return isError=true even with DB")
        XCTAssertTrue(result.text.contains("Unknown tool"))

        try? FileManager.default.removeItem(atPath: tempDir.path)
    }

    func testKeyProviderFailure_ThenRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dbPath = tempDir.appendingPathComponent("test.db").path
        defer { try? FileManager.default.removeItem(atPath: tempDir.path) }

        // Create and seed a database with testCipher
        let db = try MaxMiDatabase(path: dbPath)
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        let nowMs = EpochMs(Date().timeIntervalSince1970 * 1000)
        let result = try store.commitCapture(
            CaptureInput(sourceApp: "TestApp", sourceKey: "test://url", sourceTitle: "Test Thread", content: "test content"),
            nowMs: nowMs
        )
        guard case .committed(let versionID, _) = result else {
            XCTFail("Failed to commit capture")
            return
        }
        let threadID = try await db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT thread_id FROM versions WHERE id=?", arguments: [versionID])!
        }
        let facts = try await store.insertDerivatives(versionID: versionID, threadID: threadID, facts: ["Test fact"], nowMs: nowMs)
        XCTAssertEqual(facts.count, 1)

        setenv("MAXMI_DB_PATH", dbPath, 1)
        defer { unsetenv("MAXMI_DB_PATH") }

        // Failing provider
        var shouldFail = true
        let lazyTools = LazyTools(keyProvider: {
            if shouldFail {
                throw KeychainKeyStore.KeyError.unavailable(-1)
            }
            return Data(repeating: 7, count: 32)  // same bytes as testCipher
        })

        // First call: locked
        let result1 = await lazyTools.call(name: "list_active_threads", arguments: [:])
        XCTAssertTrue(result1.isError, "Expected error when key unavailable")
        XCTAssertEqual(result1.text, "Memory is locked — open the MaxMi app once to unlock.")

        // Recovery: provider stops throwing
        shouldFail = false

        // Second call: succeeds
        let result2 = await lazyTools.call(name: "list_active_threads", arguments: [:])
        XCTAssertFalse(result2.isError, "Expected success after recovery, got: \(result2.text)")
        XCTAssertTrue(result2.text.contains("Test Thread"), "Expected thread title in result")
    }
}
