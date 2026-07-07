import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class QueryAPITests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db)
    }

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    @discardableResult
    func seedThread(url: String, title: String?, facts: [(String, Int)], at: EpochMs) throws -> String {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: title, content: "content for \(url)"),
            nowMs: at) else { fatalError() }
        let tid = try db.dbQueue.read { try String.fetchOne($0,
            sql: "SELECT thread_id FROM versions WHERE id=?", arguments: [vid])! }
        var when = at
        for (fact, hot) in facts {
            when += 1000
            let inserted = try store.insertDerivatives(versionID: vid, threadID: tid, facts: [fact], nowMs: when)
            try store.insertEmbedding(derivativeID: inserted[0].id, vector: unit(hot))
        }
        return tid
    }

    func testFactHitsJoinsThreadAndOrdersByDistance() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("Fact near.", 0), ("Fact far.", 900)], at: t0)
        let hits = try store.factHits(near: unit(0), limit: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].content, "Fact near.")
        XCTAssertEqual(hits[0].sourceTitle, "A")
        XCTAssertEqual(hits[0].sourceKey, "https://a.com")
        XCTAssertLessThan(hits[0].distance, hits[1].distance)
    }

    func testFactHitsHonorsLimit() throws {
        try seedThread(url: "https://a.com", title: "A",
                       facts: [("F1.", 1), ("F2.", 2), ("F3.", 3)], at: t0)
        XCTAssertEqual(try store.factHits(near: unit(1), limit: 2).count, 2)
    }

    func testRecentThreadsOrderAndPerThreadFacts() throws {
        try seedThread(url: "https://old.com", title: "Old",
                       facts: [("O1.", 10), ("O2.", 11), ("O3.", 12), ("O4.", 13)], at: t0)
        try seedThread(url: "https://new.com", title: "New", facts: [("N1.", 20)], at: t0 + 60_000)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.map(\.sourceKey), ["https://new.com", "https://old.com"])
        XCTAssertEqual(threads[1].recentFacts, ["O4.", "O3.", "O2."], "own 3 latest, newest first")
        XCTAssertEqual(threads[0].recentFacts, ["N1."])
    }

    func testZeroFactThreadStillListed() throws {
        _ = try store.commitCapture(CaptureInput(sourceApp: "Web", sourceKey: "https://empty.com",
                                                 sourceTitle: "E", content: "x"), nowMs: t0)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].recentFacts.isEmpty)
    }

    func testTotalFactCount() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("F1.", 1), ("F2.", 2)], at: t0)
        XCTAssertEqual(try store.totalFactCount(), 2)
    }
}
