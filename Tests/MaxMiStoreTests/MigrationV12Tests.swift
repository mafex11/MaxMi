import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationV12Tests: XCTestCase {
    private var store: Store!
    private var db: MaxMiDatabase!

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    func testContextEmbeddingsMigrationUsesVec0AndMovesHeadToV12() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            XCTAssertTrue(try d.tableExists("context_embeddings"))
            let vector = [Float](repeating: 0.25, count: 1_536)
            let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            try d.execute(
                sql: "INSERT INTO context_embeddings (version_id, embedding) VALUES (?, ?)",
                arguments: ["v1", blob]
            )
        }
        XCTAssertEqual(Migrations.currentIdentifier, "v12")
        XCTAssertTrue(Set(Migrations.migrator.migrations).contains("v12"))
        let marker = try db.dbQueue.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT value FROM settings WHERE key=?",
                arguments: ["context_embeddings_since_ms"]
            )
        }
        XCTAssertNotNil(EpochMs(marker ?? ""))
    }

    func testMissingContextWorkNeverSelectsPreMigrationVersion() throws {
        let oldVersionID = try seedVersion(committedAt: 1)
        try store.setContextEmbeddingSinceMs(2)

        let work = try store.pendingContextEmbeddingWork(nowMs: 3)

        XCTAssertFalse(work.map(\.id).contains(oldVersionID))
    }

    private func seedVersion(committedAt: EpochMs) throws -> String {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: "FixtureWeb",
                sourceKey: "fixture:\(committedAt)",
                sourceTitle: "Fixture",
                content: "Synthetic captured content at \(committedAt)."
            ),
            nowMs: committedAt
        ) else {
            throw FixtureError.captureDidNotCommit
        }
        return versionID
    }

    private enum FixtureError: Error {
        case captureDidNotCommit
    }
}
