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

    func testPruneDeletesContextEmbeddingsForPrunedVersions() throws {
        guard case .committed(let oldVersionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "old-context", sourceTitle: "Old",
                         content: "old context content"),
            nowMs: t0
        ) else {
            return XCTFail("old fixture must commit")
        }
        guard case .committed(let newVersionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "new-context", sourceTitle: "New",
                         content: "new context content"),
            nowMs: t0 + 100_000
        ) else {
            return XCTFail("new fixture must commit")
        }
        let vector = [Float](repeating: 0.25, count: 1_536)
        try store.insertContextEmbedding(versionID: oldVersionID, vector: vector)
        try store.insertContextEmbedding(versionID: newVersionID, vector: vector)

        _ = try store.pruneMemory(olderThan: t0 + 50_000)

        let remaining = try store.db.dbQueue.read { d in
            try String.fetchAll(d, sql: "SELECT version_id FROM context_embeddings")
        }
        XCTAssertEqual(remaining, [newVersionID])
    }

    func testDeleteAllMemoryDeletesContextEmbeddings() throws {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "context", sourceTitle: "Context",
                         content: "context content"),
            nowMs: t0
        ) else {
            return XCTFail("fixture must commit")
        }
        try store.insertContextEmbedding(
            versionID: versionID,
            vector: [Float](repeating: 0.25, count: 1_536)
        )

        _ = try store.deleteAllMemory()

        let count = try store.db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT count(*) FROM context_embeddings")
        }
        XCTAssertEqual(count, 0)
    }

    func testDeleteAllMemoryRemovesCheckinsAndContextEmbeddings() throws {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "combined", sourceTitle: "Combined",
                         content: "combined content"),
            nowMs: t0
        ) else {
            return XCTFail("fixture must commit")
        }
        try store.insertContextEmbedding(
            versionID: versionID,
            vector: [Float](repeating: 0.25, count: 1_536)
        )
        try store.saveCheckin(
            dayBucket: 20_833,
            generatedAtMs: t0,
            summary: "Combined fixture",
            openItemIDs: [],
            resolvedYesterdayCount: 0,
            promptVersion: "checkin-v1"
        )

        _ = try store.deleteAllMemory()

        try store.db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM checkins"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM context_embeddings"), 0)
        }
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
        XCTAssertEqual(result.migrationIdentifier, "v13")
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

    func testRestoreUpgradesV11BackupAndPreservesEncryptedRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeURL = root.appendingPathComponent("maxmi.db")
        let v11URL = root.appendingPathComponent("maxmi-v11.db")

        let v11 = try MaxMiDatabase(path: v11URL.path, migrate: false)
        try Migrations.migrator.migrate(v11.dbQueue, upTo: "v11")
        // Seeded with the v8 column set on purpose: `Store.commitCapture` writes the CURRENT
        // schema (v10 `structured_ciphertext`), so it cannot be used to fill an old backup.
        try seedV8Row(v11, content: "encrypted")
        try v11.dbQueue.inDatabase { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try v11.dbQueue.close()

        let active = try MaxMiDatabase(path: activeURL.path)
        try active.dbQueue.close()
        let result = try DatabaseRecovery.restore(
            backupURL: v11URL,
            databaseURL: activeURL,
            archiveDirectory: root.appendingPathComponent("Backups", isDirectory: true)
        )
        XCTAssertEqual(result.migrationIdentifier, "v13")

        let restored = try MaxMiDatabase(path: activeURL.path, readOnly: true)
        defer { try? restored.dbQueue.close() }
        try restored.dbQueue.read { database in
            XCTAssertEqual(
                try String.fetchOne(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v13"
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

    /// One thread + version + latest_context written with the v8 column set only, encrypted with
    /// the same cipher a real capture would use.
    private func seedV8Row(_ database: MaxMiDatabase, content: String) throws {
        let cipher = AESGCMFieldCipher.testCipher
        let ciphertext = try cipher.encrypt(content)
        let hash = ContentHash.sha256Hex(content)
        try database.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash,
                                     created_at, updated_at)
                VALUES ('thread-v8','Web','v8','',?,?,?)
                """, arguments: [hash, t0, t0])
            try d.execute(sql: """
                INSERT INTO versions (id, thread_id, hour_bucket, content, content_hash,
                                      word_count, is_frozen, committed_at, extract_status, metadata)
                VALUES ('version-v8','thread-v8',?,?,?,1,0,?,'pending',NULL)
                """, arguments: [HourBucket.bucket(forMs: t0), ciphertext, hash, t0])
            try d.execute(sql: """
                INSERT INTO latest_contexts (
                  thread_id, version_id, content_ciphertext, content_hash, content_kind,
                  parser_id, parser_version, accumulation_policy, offscreen_mode,
                  offscreen_max_steps, offscreen_max_chars, trigger, captured_at,
                  character_count, truncated
                ) VALUES ('thread-v8','version-v8',?,?,'generic','legacy',1,'replace',
                          'visibleOnly',0,32000,'unknown',?,?,0)
                """, arguments: [ciphertext, hash, t0, content.count])
        }
    }

    private func seedCaptureEvent(atMs: EpochMs, threadKey: String) throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: threadKey, sourceTitle: "T",
                         content: "content \(threadKey)"),
            nowMs: atMs
        )
        try recordCaptureEvent(atMs: atMs, threadID: try store.threadID(forKey: threadKey))
    }

    private func recordCaptureEvent(atMs: EpochMs, threadID: String?) throws {
        try store.recordCaptureEvent(
            kind: .contentDelta,
            appBundle: "com.example.web",
            threadID: threadID,
            versionID: nil,
            trigger: .periodic,
            payload: CaptureDelta(addedChars: 4),
            nowMs: atMs
        )
    }

    func testPruneDeletesCaptureEventsOlderThanTheCutoffAndCountsThem() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "old")
        try recordCaptureEvent(atMs: t0 + 100_000, threadID: try store.threadID(forKey: "old"))
        try seedCaptureEvent(atMs: t0 + 100_000, threadKey: "new")
        try recordCaptureEvent(atMs: t0, threadID: nil)
        try recordCaptureEvent(atMs: t0 + 100_000, threadID: nil)

        let result = try store.pruneMemory(olderThan: t0 + 50_000)
        XCTAssertEqual(result.events, 3)
        let remaining = try store.recentCaptureEvents()
        let newThreadID = try store.threadID(forKey: "new")
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains {
            $0.threadID == newThreadID && $0.atMs == t0 + 100_000
        })
        XCTAssertTrue(remaining.contains { $0.threadID == nil && $0.atMs == t0 + 100_000 })
        XCTAssertFalse(remaining.contains { $0.threadID == nil && $0.atMs == t0 })
    }

    func testDeleteAllMemoryRemovesCaptureEventsAndCountsThem() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "one")
        try recordCaptureEvent(atMs: t0, threadID: nil)
        let result = try store.deleteAllMemory()
        XCTAssertEqual(result.events, 2)
        XCTAssertTrue(try store.recentCaptureEvents().isEmpty)
    }

    /// The trim gate must not survive a delete-all: a fresh database should trim on its first
    /// write, not wait an hour.
    func testDeleteAllMemoryClearsTheTrimGate() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "one")
        _ = try store.deleteAllMemory()
        let gate = try store.db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?",
                                arguments: [CaptureEventRetention.lastTrimSettingsKey])
        }
        XCTAssertNil(gate)
    }
}
