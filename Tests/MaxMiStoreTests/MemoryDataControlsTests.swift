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
        let journalMode = try backup.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(journalMode, "delete")
    }

    func testRestoreUsesValidatedCopyAndPreservesCurrentDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeURL = root.appendingPathComponent("maxmi.db")
        let selectedURL = root.appendingPathComponent("selected.db")
        let archivesURL = root.appendingPathComponent("Backups", isDirectory: true)

        let activeDatabase = try MaxMiDatabase(path: activeURL.path)
        let activeStore = Store(db: activeDatabase, cipher: AESGCMFieldCipher.testCipher)
        _ = try activeStore.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "restored", sourceTitle: "", content: "one"),
            nowMs: t0
        )
        try activeStore.backupDatabase(to: selectedURL)
        _ = try activeStore.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "newer", sourceTitle: "", content: "two"),
            nowMs: t0 + 1
        )
        try activeDatabase.dbQueue.close()

        let result = try DatabaseRecovery.restore(
            backupURL: selectedURL,
            databaseURL: activeURL,
            archiveDirectory: archivesURL
        )
        XCTAssertEqual(result.migrationIdentifier, "v9")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.preservedDatabaseURL.path))

        let restored = try MaxMiDatabase(path: activeURL.path, readOnly: true)
        defer { try? restored.dbQueue.close() }
        let keys = try restored.dbQueue.read {
            try String.fetchAll($0, sql: "SELECT source_key FROM threads ORDER BY source_key")
        }
        XCTAssertEqual(keys, ["restored"])

        let preserved = try MaxMiDatabase(path: result.preservedDatabaseURL.path, readOnly: true)
        defer { try? preserved.dbQueue.close() }
        let preservedCount = try preserved.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM threads")
        }
        XCTAssertEqual(preservedCount, 2)
    }

    func testRestoreRejectsNonMaxMiDatabaseWithoutChangingActiveDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeURL = root.appendingPathComponent("maxmi.db")
        let invalidURL = root.appendingPathComponent("invalid.db")

        let activeDatabase = try MaxMiDatabase(path: activeURL.path)
        let activeStore = Store(db: activeDatabase, cipher: AESGCMFieldCipher.testCipher)
        _ = try activeStore.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "unchanged", sourceTitle: "", content: "one"),
            nowMs: t0
        )
        try activeDatabase.dbQueue.close()

        let unrelated = try DatabaseQueue(path: invalidURL.path)
        try unrelated.write { try $0.execute(sql: "CREATE TABLE unrelated (id INTEGER)") }
        try unrelated.close()

        XCTAssertThrowsError(try DatabaseRecovery.restore(
            backupURL: invalidURL,
            databaseURL: activeURL,
            archiveDirectory: root.appendingPathComponent("Backups", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? DatabaseRecoveryError, .incompatibleBackup)
        }

        let active = try MaxMiDatabase(path: activeURL.path, readOnly: true)
        defer { try? active.dbQueue.close() }
        let keys = try active.dbQueue.read {
            try String.fetchAll($0, sql: "SELECT source_key FROM threads")
        }
        XCTAssertEqual(keys, ["unchanged"])
    }

    func testRestoreUpgradesNMinusOneBackupAndPreservesEncryptedRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeURL = root.appendingPathComponent("maxmi.db")
        let v8URL = root.appendingPathComponent("maxmi-v8.db")

        let v8 = try MaxMiDatabase(path: v8URL.path, migrate: false)
        try Migrations.migrator.migrate(v8.dbQueue, upTo: "v8")
        let v8Store = Store(db: v8, cipher: AESGCMFieldCipher.testCipher)
        _ = try v8Store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "v8", sourceTitle: "", content: "encrypted"),
            nowMs: t0
        )
        try v8.dbQueue.inDatabase { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try v8.dbQueue.close()

        let active = try MaxMiDatabase(path: activeURL.path)
        try active.dbQueue.close()
        let result = try DatabaseRecovery.restore(
            backupURL: v8URL,
            databaseURL: activeURL,
            archiveDirectory: root.appendingPathComponent("Backups", isDirectory: true)
        )
        XCTAssertEqual(result.migrationIdentifier, "v9")

        let restored = try MaxMiDatabase(path: activeURL.path, readOnly: true)
        defer { try? restored.dbQueue.close() }
        try restored.dbQueue.read { database in
            XCTAssertEqual(
                try String.fetchOne(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v9"
            )
            let ciphertext = try String.fetchOne(database, sql: "SELECT content FROM versions")
            XCTAssertTrue(ciphertext?.hasPrefix("enc:v1:") == true)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT count(*) FROM threads"), 1)
        }
    }

    func testRecoveryHelperRestoresAfterParentExitAndWritesSafeOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeURL = root.appendingPathComponent("maxmi.db")
        let selectedURL = root.appendingPathComponent("selected.db")
        let resultURL = root.appendingPathComponent("result.json")

        let active = try MaxMiDatabase(path: activeURL.path)
        let activeStore = Store(db: active, cipher: AESGCMFieldCipher.testCipher)
        _ = try activeStore.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "selected", sourceTitle: "", content: "one"),
            nowMs: t0
        )
        try activeStore.backupDatabase(to: selectedURL)
        _ = try activeStore.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "newer", sourceTitle: "", content: "two"),
            nowMs: t0 + 1
        )
        try active.dbQueue.close()

        let helperURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/MaxMiRecovery")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))
        let helper = Process()
        helper.executableURL = helperURL
        helper.arguments = [
            "--backup", selectedURL.path,
            "--database", activeURL.path,
            "--archive", root.appendingPathComponent("Backups").path,
            "--result", resultURL.path,
            "--wait-for-pid", "2000000000"
        ]
        try helper.run()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)

        let outcome = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any]
        XCTAssertEqual(outcome?["status"] as? String, "restore_succeeded")
        XCTAssertNotNil(outcome?["preservedFilename"] as? String)
        XCTAssertEqual(Set(outcome?.keys.map { $0 } ?? []), Set(["status", "preservedFilename"]))

        let restored = try MaxMiDatabase(path: activeURL.path, readOnly: true)
        defer { try? restored.dbQueue.close() }
        let keys = try restored.dbQueue.read {
            try String.fetchAll($0, sql: "SELECT source_key FROM threads")
        }
        XCTAssertEqual(keys, ["selected"])
    }
}
