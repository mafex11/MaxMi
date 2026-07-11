import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class ActivityStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }
    let t0 = EpochMs(496_000) * 3_600_000

    func testEvidenceEncryptedAndCoalesced() throws {
        let s = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "did a thing", nowMs: t0)
        let s2 = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "did a thing", nowMs: t0+1000)
        XCTAssertEqual(s, s2)
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT content_ciphertext FROM activity_session_evidence WHERE session_id=?", arguments: [s])
            XCTAssertEqual(rows.count, 1, "duplicate content coalesced")
            XCTAssertTrue((rows[0]["content_ciphertext"] as String).hasPrefix("enc:v1:"))
        }
        XCTAssertEqual(try store.sessionEvidence(s), ["did a thing"])
    }

    func testCloseAndSummarizeWithStaleGuard() throws {
        let s = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "wrote the parser", nowMs: t0)
        try store.closeSession(s, nowMs: t0+60_000)
        let h = try store.sessionSourceHash(s)
        XCTAssertTrue(try store.setSessionSummary(s, summary: "Worked on the parser", expectedSourceHash: h, modelID: "gemini-2.5-flash-lite", promptVersion: "v1", nowMs: t0+61_000))
        XCTAssertFalse(try store.setSessionSummary(s, summary: "stale", expectedSourceHash: "WRONGHASH", modelID: "m", promptVersion: "v1", nowMs: t0+62_000), "stale hash must no-op")
        let recent = try store.recentSessions(limit: 10)
        XCTAssertEqual(recent.first?.summary, "Worked on the parser")
        XCTAssertEqual(recent.first?.summaryStatus, "summarized")
    }

    func testDeleteActivityForAppCascades() throws {
        let s = try store.recordActivityCapture(appBundle: "com.secret", appLabel: "S", versionID: nil, content: "x", nowMs: t0)
        try store.closeActiveSession(nowMs: t0+1)
        try store.deleteActivityForApp("com.secret")
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_sessions WHERE app_bundle='com.secret'"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_session_evidence"), 0, "evidence cascade-deleted")
        }
    }

    func testCrashRepairClosesDanglingVisits() throws {
        _ = try store.openVisit(appBundle: "com.x", appLabel: "X", nowMs: t0)
        try store.closeOpenVisits(nowMs: t0+5000)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_app_visits WHERE ended_at IS NULL"), 0)
        }
    }

    func testObservedActivityApps() throws {
        // Record sessions for multiple apps
        let s1 = try store.recordActivityCapture(appBundle: "com.apple.Safari", appLabel: "Safari", versionID: nil, content: "browsing", nowMs: t0)
        try store.closeSession(s1, nowMs: t0+1000)
        let s2 = try store.recordActivityCapture(appBundle: "com.microsoft.VSCode", appLabel: "Visual Studio Code", versionID: nil, content: "coding", nowMs: t0+2000)
        try store.closeSession(s2, nowMs: t0+3000)
        // Same app again with updated label (most recent should win)
        let s3 = try store.recordActivityCapture(appBundle: "com.apple.Safari", appLabel: "Safari (Updated)", versionID: nil, content: "more browsing", nowMs: t0+4000)
        try store.closeSession(s3, nowMs: t0+5000)

        let apps = try store.observedActivityApps()
        XCTAssertEqual(apps.count, 2, "two distinct apps")

        // Check Safari has updated label
        let safari = apps.first { $0.bundle == "com.apple.Safari" }
        XCTAssertEqual(safari?.label, "Safari (Updated)", "most recent label")

        // Check VSCode
        let vscode = apps.first { $0.bundle == "com.microsoft.VSCode" }
        XCTAssertEqual(vscode?.label, "Visual Studio Code")
    }
}
