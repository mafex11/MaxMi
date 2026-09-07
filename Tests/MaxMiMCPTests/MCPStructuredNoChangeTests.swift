import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class MCPStructuredNoChangeTests: XCTestCase {
    func makeTools(seed: (Store) throws -> Void = { _ in }) throws -> MaxMiTools {
        let store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
        try seed(store)
        let queries = MemoryQueries(store: store, relay: MockRelay(.failure(RelayError.notConfigured)))
        return MaxMiTools(queries: queries)
    }

    func conversationEnvelope() -> CaptureEnvelope {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#maxmi-dev", isGroup: true, messages: [
                Message(id: "1", sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                        isUser: false, isDraft: false),
                Message(id: "2", sender: "Sudhanshu", text: "on it", timestamp: nil, timeString: nil,
                        isUser: true, isDraft: false),
            ]))
        return CaptureEnvelope(
            sourceApp: "Slack", sourceKey: "slack:acme/dev", sourceTitle: "dev",
            content: "IGNORED", contentKind: .conversation, parserID: "SlackParser",
            parserVersion: 2, accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            trigger: .conversationChanged, truncated: false, structured: structured)
    }

    // Controller ruling (pre-flight F22): back-date the commit by 60s so `get_latest_context`'s
    // `captured_at <= endAtMs` filter cannot race with the query's later as-of time.
    func pastNowMs() -> EpochMs {
        EpochMs(Date().timeIntervalSince1970 * 1_000) - 60_000
    }

    private func expectedSearchMemoryDefinition() -> [String: Any] {
        let retrieval: [String: Any] = [
            "source_apps": ["type": "array", "items": ["type": "string"],
                            "description": "Exact source-app names, for example Web, Slack, Cursor, Calendar, Meeting, or Voice Note"],
            "lookback_minutes": ["type": "integer", "minimum": 1,
                                 "description": "Relative lookback from the fixed as_of time; cannot be combined with start_time/end_time"],
            "start_time": ["type": "string", "description": "Inclusive ISO-8601/RFC3339 timestamp with timezone"],
            "end_time": ["type": "string", "description": "Inclusive ISO-8601/RFC3339 timestamp with timezone"],
            "timezone": ["type": "string", "description": "IANA timezone for rendered metadata, for example Asia/Kolkata"],
            "cursor": ["type": "string", "description": "Opaque next cursor from a previous response; repeat the same query and filters"],
        ]
        return [
            "name": "search_memory",
            "description": "Semantic search over captured memory facts. Supports exact app/time filters and deterministic cursor pagination.",
            "inputSchema": [
                "type": "object",
                "properties": retrieval.merging([
                    "query": ["type": "string", "description": "What to search for"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                              "description": "Max results (default 10, max 20)"],
                ]) { _, new in new },
                "required": ["query"],
            ],
        ]
    }

    func testSearchMemoryRequestShapeIsUnchangedWhileContextSectionIsResponseOnly() throws {
        let definition = try XCTUnwrap(
            MaxMiToolsDefinitions.all.first { $0["name"] as? String == "search_memory" }
        )
        let actual = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        let expected = try JSONSerialization.data(
            withJSONObject: expectedSearchMemoryDefinition(), options: [.sortedKeys]
        )
        XCTAssertEqual(
            String(decoding: actual, as: UTF8.self),
            String(decoding: expected, as: UTF8.self)
        )
    }

    func testContextHitsDoNotChangeFactPageCountOrCursorAndAreAbsentWhenNoneMatch() async throws {
        let withContext = await toolsWithFactAndContextHit().call(
            name: "search_memory", arguments: ["query": "release gate", "limit": 1]
        )
        let withoutContext = await toolsWithFactOnlyHit().call(
            name: "search_memory", arguments: ["query": "release gate", "limit": 1]
        )

        XCTAssertTrue(withContext.text.contains("### Matching context"))
        XCTAssertFalse(withoutContext.text.contains("### Matching context"))
        XCTAssertTrue(withContext.text.contains("_1 results in this page_"))
        XCTAssertTrue(withContext.text.contains("**Next cursor:**"))
        XCTAssertEqual(
            factFooter(in: withContext.text),
            factFooter(in: withoutContext.text)
        )
    }

    func testToolNamesAndRequiredArgumentsAreUnchanged() throws {
        let definitions = try makeTools().toolDefinitions
        XCTAssertEqual(definitions.map { $0["name"] as? String },
                       ["search_memory", "list_active_threads", "get_latest_context", "meeting_memory"])
        let getLatest = try XCTUnwrap(definitions[2]["inputSchema"] as? [String: Any])
        XCTAssertEqual(getLatest["required"] as? [String], [])
        let properties = try XCTUnwrap(getLatest["properties"] as? [String: Any])
        XCTAssertNil(properties["structured"], "structured is never exposed over MCP")
        let kinds = try XCTUnwrap(
            (properties["content_kinds"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(kinds["enum"] as? [String],
                       ["webpage", "conversation", "document", "terminal", "email",
                        "calendar", "task", "meeting", "voiceNote", "generic"])
    }

    func testGetLatestContextReturnsRenderedTextAndNeverTheStructuredPayload() async throws {
        let tools = try makeTools { store in
            _ = try store.commitCapture(self.conversationEnvelope(), nowMs: self.pastNowMs())
        }
        let result = await tools.call(name: "get_latest_context", arguments: [:])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("(From: Ana)(sent 09:20): ping"),
                      "the rendered .full text is what MCP serves")
        XCTAssertTrue(result.text.contains("(From: You): on it"))
        XCTAssertFalse(result.text.contains("enc:v1:"), "no ciphertext leaks")
        XCTAssertFalse(result.text.contains("\"regions\""), "no structured JSON leaks")
        XCTAssertFalse(result.text.contains("\"isDraft\""))
        XCTAssertFalse(result.text.contains("[user]"))
    }

    func testListActiveThreadsStillAnswersAfterAStructuredCommit() async throws {
        let tools = try makeTools { store in
            _ = try store.commitCapture(self.conversationEnvelope(), nowMs: self.pastNowMs())
        }
        let result = await tools.call(name: "list_active_threads", arguments: [:])
        XCTAssertFalse(result.isError, result.text)
    }

    private func toolsWithFactAndContextHit() -> MaxMiTools {
        searchTools(includeContext: true)
    }

    private func toolsWithFactOnlyHit() -> MaxMiTools {
        searchTools(includeContext: false)
    }

    private func searchTools(includeContext: Bool) -> MaxMiTools {
        let nowMs = EpochMs(1_788_000_000_000)
        let store = try! Store(db: MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
        _ = try! seedFact(
            store: store,
            sourceKey: "https://release-gate-fact.example",
            content: "Release gate fact context.",
            fact: "Release gate fact.",
            committedAt: nowMs - 2_000
        )
        _ = try! seedFact(
            store: store,
            sourceKey: "https://release-gate-more.example",
            content: "Second release gate fact context.",
            fact: "Second release gate fact.",
            committedAt: nowMs - 1_000
        )
        if includeContext {
            guard case .committed(let contextVersionID, _, _) = try! store.commitCapture(
                CaptureInput(
                    sourceApp: "Web",
                    sourceKey: "https://release-gate-context.example",
                    sourceTitle: "Release gate context",
                    content: "Release gate raw context."
                ),
                nowMs: nowMs - 500
            ) else {
                fatalError()
            }
            try! store.insertContextEmbedding(versionID: contextVersionID, vector: unit(11))
        }
        return MaxMiTools(queries: MemoryQueries(
            store: store,
            relay: MockRelay(.success(unit(11))),
            now: { Date(timeIntervalSince1970: Double(nowMs) / 1_000) }
        ))
    }

    @discardableResult
    private func seedFact(
        store: Store,
        sourceKey: String,
        content: String,
        fact: String,
        committedAt: EpochMs
    ) throws -> String {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: "Web",
                sourceKey: sourceKey,
                sourceTitle: "Release gate",
                content: content
            ),
            nowMs: committedAt
        ) else {
            fatalError()
        }
        let threadID = try store.threadID(forKey: sourceKey)
        let derivative = try store.insertDerivatives(
            versionID: versionID,
            threadID: threadID,
            facts: [fact],
            nowMs: committedAt + 1
        )
        try store.insertEmbedding(derivativeID: derivative[0].id, vector: unit(11))
        return versionID
    }

    private func unit(_ hot: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 1_536)
        vector[hot] = 1
        return vector
    }

    private func factFooter(in text: String) -> String {
        guard let start = text.range(of: "_1 results in this page_") else {
            return ""
        }
        let footer = text[start.lowerBound...]
        guard let context = footer.range(of: "\n\n### Matching context") else {
            return cursorPrefix(in: footer)
        }
        return cursorPrefix(in: footer[..<context.lowerBound])
    }

    private func cursorPrefix(in footer: Substring) -> String {
        guard let cursor = footer.range(of: "`") else {
            return String(footer)
        }
        return String(footer[..<cursor.upperBound])
    }
}
