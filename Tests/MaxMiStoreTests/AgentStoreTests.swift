import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class AgentStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    var sessionCounter: Int = 0
    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        sessionCounter = 0
    }
    let t0 = EpochMs(497_000) * 3_600_000

    func seedSessions(_ n: Int) throws {
        for _ in 0..<n {
            let i = sessionCounter
            sessionCounter += 1
            let sessionID = try store.recordActivityCapture(
                appBundle: "com.test.App\(i % 3)",
                appLabel: "Test App",
                versionID: nil,
                content: "Session \(i) content",
                nowMs: t0 + EpochMs(i * 10)
            )
            try store.closeSession(sessionID, nowMs: t0 + EpochMs(i * 10) + 1)
            let hash = try store.sessionSourceHash(sessionID)
            _ = try store.setSessionSummary(
                sessionID,
                summary: "Summary for session \(i)",
                expectedSourceHash: hash,
                modelID: "test-model",
                promptVersion: "v1",
                nowMs: t0 + EpochMs(i * 10) + 2
            )
        }
    }

    func testClaimCompleteAdvancesKeysetCursorNoSkipAcrossPages() throws {
        try seedSessions(120)
        var runs = 0
        while let page = try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0 + EpochMs(runs)) {
            _ = try store.completeAgentRun(runID: page.runID, ops: [], nowMs: t0 + EpochMs(runs))
            runs += 1
            if runs > 10 { break }
        }
        XCTAssertEqual(runs, 3, "120 sessions / 50 per page = 3 runs, none skipped")
        XCTAssertNil(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+999), "nothing new -> nil")
    }

    func testStaleLeaseRecovered() throws {
        try seedSessions(10)
        let p1 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 1000, nowMs: t0))
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 1000, nowMs: t0 + 5000))
        XCTAssertEqual(p1.summaries, p2.summaries, "stale lease reclaimed, window not lost")
    }

    func testCreateResolveDismissAndTerminalAndIdempotency() throws {
        try seedSessions(2)
        let p = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        let res = try store.completeAgentRun(runID: p.runID,
            ops: [.create(kind:"todo", title:"Reply to Alice", details:"re: deploy", sourceRefs: p.sourceIDs)], nowMs: t0)
        XCTAssertEqual(res.newCount, 1)
        let id = try store.actionItems(status:"open", limit:10)[0].id
        try db.dbQueue.read { d in XCTAssertTrue((try String.fetchOne(d, sql:"SELECT title_ciphertext FROM agent_action_items")!).hasPrefix("enc:v1:")) }
        let res2 = try store.completeAgentRun(runID: p.runID, ops: [.create(kind:"todo",title:"Reply to Alice",details:nil,sourceRefs:p.sourceIDs)], nowMs: t0+1)
        XCTAssertEqual(res2.newCount, 0, "already-completed run is a no-op")
        try store.dismissActionItem(id, nowMs: t0+10)
        try seedSessions(1)
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+100))
        let res3 = try store.completeAgentRun(runID: p2.runID, ops: [.resolve(id: id, evidence:"done")], nowMs: t0+100)
        XCTAssertEqual(res3.resolvedCount, 0, "dismissed is terminal")
    }

    func testNeverResolveOnAbsenceAndUnknownIgnored() throws {
        try seedSessions(2)
        let p1 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        let res1 = try store.completeAgentRun(runID: p1.runID,
            ops: [.create(kind:"todo", title:"Task A", details:nil, sourceRefs: p1.sourceIDs)], nowMs: t0)
        XCTAssertEqual(res1.newCount, 1)
        let itemID = try store.actionItems(status:"open", limit:10)[0].id

        try seedSessions(1)
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+100))
        let res2 = try store.completeAgentRun(runID: p2.runID, ops: [.resolve(id: "unknown-id", evidence:"done")], nowMs: t0+100)
        XCTAssertEqual(res2.resolvedCount, 0, "unknown id ignored")

        let items = try store.actionItems(status:"open", limit:10)
        XCTAssertEqual(items.count, 1, "item still open when not mentioned")
        XCTAssertEqual(items[0].id, itemID)
    }

    func testSourceRefsMustBelongToPage() throws {
        try seedSessions(2)
        let p = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        let invalidSourceRefs = ["invalid-session-id-1", "invalid-session-id-2"]
        let res = try store.completeAgentRun(runID: p.runID,
            ops: [.create(kind:"todo", title:"Task", details:nil, sourceRefs: invalidSourceRefs)], nowMs: t0)
        XCTAssertEqual(res.newCount, 1, "item created")

        let items = try store.actionItems(status:"open", limit:10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sourceRefs, [], "invalid source refs dropped")
    }

    func testUnexpiredLeaseBlocksSecondClaim() throws {
        try seedSessions(10)
        _ = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        XCTAssertNil(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+1), "unexpired running lease blocks a second claim")
    }
}
