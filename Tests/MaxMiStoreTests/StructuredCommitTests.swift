import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class StructuredCommitTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let cipher = AESGCMFieldCipher.testCipher
    let h10 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: cipher)
    }

    func message(_ sender: String, _ text: String) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: nil, text: text),
                sender: sender, text: text, timestamp: nil, timeString: nil,
                isUser: false, isDraft: false)
    }

    func envelope(_ structured: CapturedContent, key: String = "slack:acme/dev") -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: "Slack", sourceKey: key, sourceTitle: "dev", content: "IGNORED",
            contentKind: .conversation, parserID: "SlackParser", parserVersion: 2,
            accumulationPolicy: .appendItems, offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            trigger: .conversationChanged, truncated: false, structured: structured
        )
    }

    func storedStructured(table: String) throws -> CapturedContent? {
        try db.dbQueue.read { d in
            guard let raw = try String.fetchOne(d, sql: "SELECT structured_ciphertext FROM \(table)")
            else { return nil }
            return CapturedContentEnvelope.decode(try cipher.decrypt(raw))
        }
    }

    func testCommitWritesStructuredToBothTablesEncrypted() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "ping")]))
        guard case .committed = try store.commitCapture(envelope(structured), nowMs: h10)
        else { return XCTFail("expected a commit") }

        XCTAssertEqual(try storedStructured(table: "latest_contexts"), structured)
        XCTAssertEqual(try storedStructured(table: "versions"), structured)
        let raw = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT structured_ciphertext FROM versions")
        }
        XCTAssertEqual(raw?.hasPrefix("enc:v1:"), true, "structured payload is encrypted at rest")
    }

    func testCommittedContentIsTheRenderedStructuredValue() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "ping")]))
        _ = try store.commitCapture(envelope(structured), nowMs: h10)
        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "(From: Ana): ping")
        XCTAssertEqual(record.structured, structured)
    }

    func testConversationAccumulatesAcrossCapturesAndReturnsTheDelta() throws {
        _ = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one")]))),
            nowMs: h10)
        let result = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one"), message("Bo", "two")]))),
            nowMs: h10 + 60_000)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertEqual(delta.addedMessages.map(\.text), ["two"])
        XCTAssertFalse(delta.isFirstCapture)

        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "(From: Ana): one\n(From: Bo): two")
    }

    func testFirstCaptureDeltaIsMarkedFirst() throws {
        let result = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one")]))),
            nowMs: h10)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertTrue(delta.isFirstCapture)
        XCTAssertEqual(delta.addedMessages.count, 1)
    }

    func testUnchangedTreeStillDeduplicates() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "one")]))
        _ = try store.commitCapture(envelope(structured), nowMs: h10)
        XCTAssertEqual(try store.commitCapture(envelope(structured), nowMs: h10 + 1_000), .deduplicated)
    }

    func testLegacyCaptureInputStillCommitsAndStoresGenericStructure() throws {
        let result = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                         content: "note body"),
            nowMs: h10)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertTrue(delta.isFirstCapture)
        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "note body")
        XCTAssertEqual(record.structured.kind, .generic)
    }
}
