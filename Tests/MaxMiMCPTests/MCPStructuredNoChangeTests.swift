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
}
