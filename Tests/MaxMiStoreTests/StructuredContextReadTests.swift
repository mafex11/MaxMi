import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class StructuredContextReadTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let cipher = AESGCMFieldCipher.testCipher
    let t0 = EpochMs(1_757_000_000_000)

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: cipher)
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                         content: "note body\nsecond line"),
            nowMs: t0
        )
    }

    func setStructured(_ value: String?) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE latest_contexts SET structured_ciphertext=?", arguments: [value])
        }
    }

    func read() throws -> LatestContextRecord {
        try XCTUnwrap(try store.latestContexts(limit: 1).first)
    }

    func testNullStructuredFallsBackToLegacyAdapter() throws {
        try setStructured(nil)
        let record = try read()
        XCTAssertEqual(record.structured,
                       LegacyContentAdapter.adapt(renderedContent: record.content, kind: record.contentKind))
        XCTAssertEqual(ContentRenderer.render(record.structured, style: .full), record.content)
    }

    func testRealEnvelopeIsDecodedVerbatim() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true,
            messages: [Message(id: "1", sender: "Ana", text: "ping", timestamp: nil,
                               timeString: "09:20", isUser: false, isDraft: false)]
        ))
        try setStructured(try cipher.encrypt(try CapturedContentEnvelope.encode(structured)))
        XCTAssertEqual(try read().structured, structured)
    }

    func testUndecryptableCiphertextFallsBackInsteadOfThrowing() throws {
        try setStructured("enc:v1:not-base64!!")
        let record = try read()
        XCTAssertEqual(record.structured.kind, .generic)
        XCTAssertEqual(ContentRenderer.render(record.structured, style: .full), record.content)
    }

    func testUndecodableJSONFallsBack() throws {
        try setStructured(try cipher.encrypt("{\"nope\":true}"))
        XCTAssertEqual(try read().structured.kind, .generic)
    }

    func testFutureSchemaVersionIsTreatedExactlyLikeNull() throws {
        let future = "{\"v\":99,\"content\":{\"generic\":{\"_0\":{\"regions\":[]}}}}"
        try setStructured(try cipher.encrypt(future))
        let record = try read()
        XCTAssertEqual(record.structured,
                       LegacyContentAdapter.adapt(renderedContent: record.content, kind: record.contentKind))
    }

    func testFilteredPageReadAlsoResolvesStructured() throws {
        let structured = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        try setStructured(try cipher.encrypt(try CapturedContentEnvelope.encode(structured)))
        let page = try store.latestContexts(
            filter: RetrievalFilter(sourceApps: [], startAtMs: nil, endAtMs: t0 + 1_000, contentKinds: []),
            source: nil, threadID: nil, offset: 0, limit: 5
        )
        XCTAssertEqual(page.records.first?.structured, structured)
    }
}
