import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var embedResult: Result<[Float], Error>
    var embedCalls = 0
    init(_ r: Result<[Float], Error>) { embedResult = r }
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] { [] }
    func embed(text: String) async throws -> [Float] {
        embedCalls += 1
        return try embedResult.get()
    }
}

final class MemoryQueriesTests: XCTestCase {
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory())
    }

    func seed(_ facts: [(String, Int)], url: String = "https://gintama.example", title: String = "Gin Tama") throws {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: title, content: "c\(url)"),
            nowMs: t0) else { fatalError() }
        let realTid = try store.threadID(forKey: url)
        var when = t0
        for (f, hot) in facts {
            when += 1000
            let ins = try store.insertDerivatives(versionID: vid, threadID: realTid, facts: [f], nowMs: when)
            try store.insertEmbedding(derivativeID: ins[0].id, vector: unit(hot))
        }
    }

    func queries(_ relay: MockRelay) -> MemoryQueries {
        let t0 = self.t0
        return MemoryQueries(store: store, relay: relay,
                             now: { Date(timeIntervalSince1970: Double(t0 + 1000) / 1000 + 7200) }) // "2 hours ago"
    }

    func testSearchReturnsMarkdownWithSourceAndRelativeTime() async throws {
        try seed([("The user watched episode 18 of Gin Tama.", 3)])
        let q = queries(MockRelay(.success(unit(3))))
        let r = await q.searchMemory(query: "anime", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("The user watched episode 18 of Gin Tama."))
        XCTAssertTrue(r.text.contains("Gin Tama"))
        XCTAssertTrue(r.text.contains("https://gintama.example"))
        XCTAssertTrue(r.text.contains("2 hours ago"))
        XCTAssertTrue(r.text.contains(#"## Memory search: "anime""#))
    }

    func testSimilarityFloorFiltersOrthogonalResults() async throws {
        try seed([("Unrelated fact.", 900)])
        let q = queries(MockRelay(.success(unit(3))))    // orthogonal to stored -> distance 1.0 > 0.75
        let r = await q.searchMemory(query: "anime", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("Nothing sufficiently similar"))
        XCTAssertFalse(r.text.contains("Unrelated fact."))
    }

    func testLimitDefaultsTo10AndCapsAt20() async throws {
        try seed((0..<25).map { ("Fact \($0).", 100 + $0) })
        // query along an axis close to all? use one stored axis so at least ordering exists:
        let q = queries(MockRelay(.success(unit(100))))
        let def = await q.searchMemory(query: "x", limit: nil)
        XCTAssertLessThanOrEqual(def.text.components(separatedBy: "\n- ").count - 1, 10)
        let capped = await q.searchMemory(query: "x", limit: 50)
        XCTAssertLessThanOrEqual(capped.text.components(separatedBy: "\n- ").count - 1, 20)
    }

    func testOfflineReturnsExactErrorText() async throws {
        try seed([("F.", 1)])
        let q = queries(MockRelay(.failure(RelayError.notConfigured)))
        let r = await q.searchMemory(query: "x", limit: nil)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.text, "Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected.")
    }

    func testEmptyQueryRejected() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.searchMemory(query: "   ", limit: nil)
        XCTAssertTrue(r.isError)
    }

    func testLRUCacheSkipsSecondEmbed() async throws {
        try seed([("F.", 1)])
        let relay = MockRelay(.success(unit(1)))
        let q = queries(relay)
        _ = await q.searchMemory(query: "same query", limit: nil)
        _ = await q.searchMemory(query: "same query", limit: nil)
        XCTAssertEqual(relay.embedCalls, 1, "second identical query served from LRU")
    }

    func testEmptyDBGivesFriendlyMessage() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.searchMemory(query: "x", limit: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("No memories matched"))
    }
}
