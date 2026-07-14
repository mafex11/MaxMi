import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MemoryDataControlsTests: XCTestCase {
    private var store: Store!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }

    func testPlaintextExportIsExplicitAndMode600() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "Idea", content: "export secret"),
            nowMs: t0
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try store.exportMemory(to: url), 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("export secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testPruneDeletesStaleThreadAndPreservesCurrentMemory() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "old", sourceTitle: "Old", content: "old content"),
            nowMs: t0
        )
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "new", sourceTitle: "New", content: "new content"),
            nowMs: t0 + 100_000
        )
        let result = try store.pruneMemory(olderThan: t0 + 50_000)
        XCTAssertEqual(result.threads, 1)
        XCTAssertThrowsError(try store.threadID(forKey: "old"))
        XCTAssertNoThrow(try store.threadID(forKey: "new"))
        XCTAssertEqual(try store.latestContexts(limit: 10).map(\.sourceKey), ["new"])
    }

    func testDeleteAllMemoryPreservesPrivacySettings() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "one", sourceTitle: "One", content: "content"),
            nowMs: t0
        )
        _ = try store.setDomain("example.com", blocked: true, nowMs: t0)
        let result = try store.deleteAllMemory()
        XCTAssertEqual(result.threads, 1)
        XCTAssertTrue(try store.latestContexts(limit: 10).isEmpty)
        XCTAssertEqual(try store.blockedDomains(), ["example.com"])
    }

    func testConsistentBackupCanBeOpened() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "one", sourceTitle: "One", content: "content"),
            nowMs: t0
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.backupDatabase(to: url)
        let backup = try MaxMiDatabase(path: url.path, readOnly: true)
        let count = try backup.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM threads") }
        XCTAssertEqual(count, 1)
    }
}

