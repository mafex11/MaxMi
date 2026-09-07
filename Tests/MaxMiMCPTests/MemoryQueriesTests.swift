import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var embedResult: Result<[Float], Error>
    var embedCalls = 0
    init(_ r: Result<[Float], Error>) { embedResult = r }
    func extract(
        newContent: String,
        previousContent: String?,
        metadata: ExtractMetadata
    ) async throws -> [String] { [] }
    func embed(text: String) async throws -> [Float] {
        embedCalls += 1
        return try embedResult.get()
    }
}

final class MemoryQueriesTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(495_442) * 3_600_000

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    func seed(_ facts: [(String, Int)], url: String = "https://gintama.example", title: String = "Gin Tama",
              sourceApp: String = "Web", at: EpochMs? = nil) throws {
        let capturedAt = at ?? t0
        guard case .committed(let vid, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: sourceApp, sourceKey: url, sourceTitle: title, content: "c\(url)"),
            nowMs: capturedAt) else { fatalError() }
        let realTid = try store.threadID(forKey: url)
        var when = capturedAt
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

    func testSearchAppendsMatchingContextForRawOnlyPhrase() async throws {
        let versionID = try seedVersionOnlyContext(
            "The raw phrase is nebula-anchor and no derivative contains it."
        )
        try store.insertContextEmbedding(versionID: versionID, vector: unit(7))

        let result = await queries(MockRelay(.success(unit(7)))).searchMemory(
            query: "nebula-anchor", limit: 10
        )

        XCTAssertTrue(result.text.contains("### Matching context"))
        XCTAssertTrue(result.text.contains("nebula-anchor"))
        XCTAssertTrue(result.text.contains("thread `"))
        XCTAssertFalse(result.text.contains("enc:v1:"))
        XCTAssertFalse(result.text.contains("\"schemaVersion\""))
    }

    func testSearchOmitsMatchingContextWhenNoContextHitPassesFloor() async {
        let result = await queries(MockRelay(.success(unit(9)))).searchMemory(query: "none", limit: 10)
        XCTAssertFalse(result.text.contains("### Matching context"))
    }

    func testSearchDoesNotDuplicateContextForVersionRepresentedByFact() async throws {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: "Web",
                sourceKey: "https://deduplicated-context.example",
                sourceTitle: "Deduplicated context",
                content: "The shared raw context is aurora-anchor."
            ),
            nowMs: t0
        ) else {
            fatalError()
        }
        let threadID = try store.threadID(forKey: "https://deduplicated-context.example")
        let derivative = try store.insertDerivatives(
            versionID: versionID,
            threadID: threadID,
            facts: ["The shared fact is aurora-anchor."],
            nowMs: t0 + 1
        )
        try store.insertEmbedding(derivativeID: derivative[0].id, vector: unit(8))
        try store.insertContextEmbedding(versionID: versionID, vector: unit(8))

        let result = await queries(MockRelay(.success(unit(8)))).searchMemory(
            query: "aurora-anchor", limit: 10
        )

        XCTAssertTrue(result.text.contains("The shared fact is aurora-anchor."))
        XCTAssertFalse(result.text.contains("### Matching context"))
    }

    func testSearchRetainsFactResponseWhenContextIndexIsUnavailable() async throws {
        try seed([("Fact remains available.", 9)])
        try await db.dbQueue.write { database in
            try database.execute(sql: "DROP TABLE context_embeddings")
        }

        let result = await queries(MockRelay(.success(unit(9)))).searchMemory(
            query: "available", limit: 10
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Fact remains available."))
        XCTAssertFalse(result.text.contains("### Matching context"))
    }

    func testSearchTruncatesMatchingContextSnippet() async throws {
        let rawPrefix = String(repeating: "x", count: 300)
        let versionID = try seedVersionOnlyContext("\(rawPrefix)TRUNCATED-CONTEXT-TAIL")
        try store.insertContextEmbedding(versionID: versionID, vector: unit(10))

        let result = await queries(MockRelay(.success(unit(10)))).searchMemory(
            query: "context", limit: 10
        )

        XCTAssertTrue(result.text.contains(rawPrefix))
        XCTAssertFalse(result.text.contains("TRUNCATED-CONTEXT-TAIL"))
    }

    func testListActiveThreadsMarkdownAndOrder() async throws {
        try seed([("Old fact 1.", 1), ("Old fact 2.", 2), ("Old fact 3.", 3), ("Old fact 4.", 4)],
                 url: "https://old.example", title: "Old Page")
        try seed([("New fact.", 10)], url: "https://new.example", title: "New Page")
        // make new.example more recent:
        _ = try store.commitCapture(CaptureInput(sourceApp: "Web", sourceKey: "https://new.example",
                                                 sourceTitle: "New Page", content: "changed"),
                                    nowMs: t0 + 600_000)
        let q = queries(MockRelay(.success(unit(1))))
        let r = q.listActiveThreads(limit: nil)
        XCTAssertFalse(r.isError)
        let newIdx = r.text.range(of: "New Page")!.lowerBound
        let oldIdx = r.text.range(of: "Old Page")!.lowerBound
        XCTAssertLessThan(newIdx, oldIdx, "recency order")
        XCTAssertTrue(r.text.contains("Old fact 4."))
        XCTAssertFalse(r.text.contains("Old fact 1."), "only own 3 latest facts")
    }

    func testListEmptyDBFriendly() {
        let q = queries(MockRelay(.success(unit(1))))
        let r = q.listActiveThreads(limit: nil)
        XCTAssertTrue(r.text.contains("hasn't captured anything yet"))
    }

    func testGetLatestContextReturnsRawMaterialWithoutEmbedding() throws {
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Slack",
                sourceKey: "slack:workspace/general",
                sourceTitle: "general",
                content: "Alice: ship the parser",
                contentKind: .conversation,
                parserID: "SlackParser",
                parserVersion: 2,
                accumulationPolicy: .appendItems,
                offscreenPolicy: .accessibilityScroll(maxSteps: 3),
                trigger: .appActivated,
                truncated: false
            ),
            nowMs: t0
        )
        let relay = MockRelay(.failure(RelayError.notConfigured))
        let result = queries(relay).getLatestContext(source: "Slack", limit: nil)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Alice: ship the parser"))
        XCTAssertTrue(result.text.contains("SlackParser v2"))
        XCTAssertEqual(relay.embedCalls, 0)
    }

    func testGetLatestContextEmptyIsFriendly() {
        let result = queries(MockRelay(.failure(RelayError.notConfigured)))
            .getLatestContext(source: nil, limit: nil)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("No raw context matched"))
    }

    func testMeetingMemoryEmptyListReturnsStub() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.meetingMemory(action: "list", query: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("No meetings captured yet"))
    }

    func testMeetingMemoryGetContextRequiresQuery() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.meetingMemory(action: "get_context", query: nil)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("requires a meeting ID"))
    }

    func testMeetingMemorySearchRequiresQuery() async {
        let q = queries(MockRelay(.success(unit(1))))
        let r = await q.meetingMemory(action: "search", query: nil)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("requires a query"))
    }

    func testListFiltersExactAppAndTimeRange() throws {
        try seed([("Web fact.", 1)], url: "web:one", title: "Web One", sourceApp: "Web", at: t0)
        try seed([("Slack fact.", 2)], url: "slack:one", title: "Slack One", sourceApp: "Slack", at: t0 + 60_000)
        let result = queries(MockRelay(.success(unit(1)))).listActiveThreads(
            limit: 10,
            options: RetrievalOptions(sourceApps: ["Slack"], lookbackMinutes: 180)
        )
        XCTAssertTrue(result.text.contains("Slack One"))
        XCTAssertFalse(result.text.contains("Web One"))
        XCTAssertTrue(result.text.contains("As of:"))
        XCTAssertTrue(result.text.contains("Timezone:"))
    }

    func testListCursorIsDeterministicAndScopeChecked() throws {
        try seed([("One.", 1)], url: "thread:one", title: "One", at: t0)
        try seed([("Two.", 2)], url: "thread:two", title: "Two", at: t0 + 60_000)
        try seed([("Three.", 3)], url: "thread:three", title: "Three", at: t0 + 120_000)
        let q = queries(MockRelay(.success(unit(1))))
        let first = q.listActiveThreads(limit: 1, options: RetrievalOptions(sourceApps: ["Web"]))
        XCTAssertTrue(first.text.contains("Three"))
        let cursor = try XCTUnwrap(nextCursor(in: first.text))
        let second = q.listActiveThreads(limit: 1, options: RetrievalOptions(sourceApps: ["Web"], cursor: cursor))
        XCTAssertTrue(second.text.contains("Two"))
        XCTAssertFalse(second.text.contains("Three"))
        let wrongScope = q.listActiveThreads(limit: 1, options: RetrievalOptions(sourceApps: ["Slack"], cursor: cursor))
        XCTAssertTrue(wrongScope.isError)
        XCTAssertTrue(wrongScope.text.contains("does not belong"))
    }

    func testLatestContextFiltersStructuredKindsAndThread() throws {
        _ = try store.commitCapture(CaptureEnvelope(
            sourceApp: "Calendar", sourceKey: "calendar:event", sourceTitle: "Planning",
            content: "Planning at 3 PM", contentKind: .calendar, parserID: "CalendarParser",
            parserVersion: 1, accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
            trigger: .appActivated, truncated: false
        ), nowMs: t0)
        _ = try store.commitCapture(CaptureEnvelope(
            sourceApp: "Reminders", sourceKey: "task:item", sourceTitle: "Ship parser",
            content: "Ship parser tomorrow", contentKind: .task, parserID: "RemindersParser",
            parserVersion: 1, accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
            trigger: .appActivated, truncated: false
        ), nowMs: t0 + 1_000)
        let relay = MockRelay(.failure(RelayError.notConfigured))
        let q = queries(relay)
        let tasks = q.getLatestContext(limit: 10, options: RetrievalOptions(contentKinds: [.task]))
        XCTAssertTrue(tasks.text.contains("Ship parser tomorrow"))
        XCTAssertFalse(tasks.text.contains("Planning at 3 PM"))
        XCTAssertEqual(relay.embedCalls, 0)
        XCTAssertTrue(tasks.text.contains("thread `"))
    }

    func testSearchHonorsSourceAppFilter() async throws {
        try seed([("Web memory.", 5)], url: "web:memory", title: "Web Memory", sourceApp: "Web")
        try seed([("Slack memory.", 5)], url: "slack:memory", title: "Slack Memory", sourceApp: "Slack")
        let webContextVersionID = try seedVersionOnlyContext(
            "Web raw filter context.",
            sourceApp: "Web",
            sourceKey: "web:raw-filter",
            title: "Web raw filter"
        )
        let slackContextVersionID = try seedVersionOnlyContext(
            "Slack raw filter context.",
            sourceApp: "Slack",
            sourceKey: "slack:raw-filter",
            title: "Slack raw filter"
        )
        try store.insertContextEmbedding(versionID: webContextVersionID, vector: unit(5))
        try store.insertContextEmbedding(versionID: slackContextVersionID, vector: unit(5))
        let result = await queries(MockRelay(.success(unit(5)))).searchMemory(
            query: "memory", limit: 10,
            options: RetrievalOptions(sourceApps: ["Slack"])
        )
        XCTAssertTrue(result.text.contains("Slack memory."))
        XCTAssertFalse(result.text.contains("Web memory."))
        XCTAssertTrue(result.text.contains("Slack raw filter context."))
        XCTAssertFalse(result.text.contains("Web raw filter context."))
    }

    func testMCPReadersExcludeLocalOnlyPausedAndBlockedSourcesAcrossFactsThreadsAndContexts() async throws {
        try seed(
            [("Ordinary MCP fact.", 14)],
            url: "https://ordinary-mcp.example",
            title: "Ordinary MCP",
            sourceApp: "Web"
        )
        try seed(
            [("Local MCP fact.", 14)],
            url: "local:mcp",
            title: "Local MCP",
            sourceApp: "Local"
        )
        try seed(
            [("Paused MCP fact.", 14)],
            url: "https://paused-mcp.example",
            title: "Paused MCP",
            sourceApp: "Web",
            at: t0 + 1
        )
        try seed(
            [("Blocked MCP fact.", 14)],
            url: "https://blocked-mcp.example",
            title: "Blocked MCP",
            sourceApp: "Web",
            at: t0 + 2
        )
        try store.setCloudProcessing("Local", allowed: false, nowMs: t0 + 3)
        try store.setThreadPaused("https://paused-mcp.example", paused: true, nowMs: t0 + 3)
        _ = try store.setDomain("blocked-mcp.example", blocked: true, nowMs: t0 + 3)

        let queries = queries(MockRelay(.success(unit(14))))
        let search = await queries.searchMemory(query: "privacy", limit: 10)
        let threads = queries.listActiveThreads(limit: 10)
        let contexts = queries.getLatestContext(source: nil, limit: 10)

        for result in [search, threads, contexts] {
            XCTAssertTrue(result.text.contains("Ordinary MCP"))
            XCTAssertFalse(result.text.contains("Local MCP"))
            XCTAssertFalse(result.text.contains("Paused MCP"))
            XCTAssertFalse(result.text.contains("Blocked MCP"))
        }
        XCTAssertTrue(search.text.contains("Ordinary MCP fact."))
        XCTAssertFalse(search.text.contains("Local MCP fact."))
        XCTAssertFalse(search.text.contains("Paused MCP fact."))
        XCTAssertFalse(search.text.contains("Blocked MCP fact."))
    }

    private func seedVersionOnlyContext(
        _ content: String,
        sourceApp: String = "Web",
        sourceKey: String = "https://raw-context.example",
        title: String = "Raw context"
    ) throws -> String {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: sourceApp,
                sourceKey: sourceKey,
                sourceTitle: title,
                content: content
            ),
            nowMs: t0
        ) else {
            fatalError()
        }
        return versionID
    }

    private func nextCursor(in text: String) -> String? {
        guard let marker = text.range(of: "**Next cursor:** `") else { return nil }
        let tail = text[marker.upperBound...]
        guard let end = tail.firstIndex(of: "`") else { return nil }
        return String(tail[..<end])
    }
}
