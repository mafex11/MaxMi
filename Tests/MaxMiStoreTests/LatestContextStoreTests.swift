import XCTest
@testable import MaxMiStore
import MaxMiCore

final class LatestContextStoreTests: XCTestCase {
    private var store: Store!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }

    func testConversationContextAccumulatesAcrossVisibleWindows() throws {
        _ = try store.commitCapture(envelope("Alice: one\nBob: two"), nowMs: t0)
        _ = try store.commitCapture(envelope("Bob: two\nCarol: three"), nowMs: t0 + 1_000)

        let context = try XCTUnwrap(store.latestContexts(limit: 1).first)
        XCTAssertEqual(context.content, "Alice: one\nBob: two\nCarol: three")
        XCTAssertEqual(context.contentKind, .conversation)
        XCTAssertEqual(context.parserID, "TestChatParser")
        XCTAssertEqual(context.parserVersion, 2)
        XCTAssertEqual(context.trigger, .accessibilityChanged)
    }

    func testContainedWindowRefreshesContextWithoutCreatingVersion() throws {
        _ = try store.commitCapture(envelope("one\ntwo\nthree"), nowMs: t0)
        let result = try store.commitCapture(envelope("two"), nowMs: t0 + 1_000)

        XCTAssertEqual(result, .deduplicated)
        XCTAssertEqual(try store.latestContexts(limit: 1).first?.content, "one\ntwo\nthree")
    }

    func testLatestContextsAreFreshnessRankedAndFilterable() throws {
        _ = try store.commitCapture(envelope("old", key: "chat:old", title: "Team Alpha"), nowMs: t0)
        _ = try store.commitCapture(envelope("new", key: "chat:new", title: "Team Beta"), nowMs: t0 + 1_000)

        XCTAssertEqual(try store.latestContexts(limit: 2).map(\.sourceTitle), ["Team Beta", "Team Alpha"])
        XCTAssertEqual(try store.latestContexts(limit: 2, source: "alpha").map(\.sourceTitle), ["Team Alpha"])
    }

    func testRawContextIsEncryptedAtRest() throws {
        let secret = "private raw context"
        _ = try store.commitCapture(envelope(secret), nowMs: t0)
        let raw = try store.db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT content_ciphertext FROM latest_contexts")
        }
        XCTAssertNotEqual(raw, secret)
        XCTAssertEqual(try store.latestContexts(limit: 1).first?.content, secret)
    }

    func testLatestContextRecordsByThreadIDReturnsOnlyTheRequestedThreads() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "One",
                         content: "one"),
            nowMs: t0)
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:two", sourceTitle: "Two",
                         content: "two"),
            nowMs: t0 + 1_000)
        let one = try store.threadID(forKey: "note:one")
        let two = try store.threadID(forKey: "note:two")

        let records = try store.latestContextRecords(threadIDs: [one, "absent"])
        XCTAssertEqual(Set(records.keys), [one])
        XCTAssertEqual(records[one]?.sourceTitle, "One")

        XCTAssertEqual(try store.latestContextRecords(threadIDs: [one, two]).count, 2)
        XCTAssertTrue(try store.latestContextRecords(threadIDs: []).isEmpty)
    }

    func testLatestContextRecordsResolveTheStructuredShape() throws {
        let page = GenericPage(
            regions: [Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")])],
            focused: nil, url: "https://example.invalid/page")
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Web", sourceKey: "example.invalid/page", sourceTitle: "A page",
                content: "", contentKind: .webpage, parserID: "test", parserVersion: 2,
                accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .browserNavigation, truncated: false, structured: .generic(page)),
            nowMs: t0)
        let threadID = try store.threadID(forKey: "example.invalid/page")
        let record = try XCTUnwrap(store.latestContextRecords(threadIDs: [threadID])[threadID])
        guard case .generic(let stored) = record.structured else { return XCTFail("expected generic") }
        XCTAssertEqual(stored.url, "https://example.invalid/page")
        XCTAssertEqual(record.contentKind, .webpage)
    }

    private func envelope(
        _ content: String,
        key: String = "chat:test",
        title: String = "Test Chat"
    ) -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: "TestChat",
            sourceKey: key,
            sourceTitle: title,
            content: content,
            contentKind: .conversation,
            parserID: "TestChatParser",
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            trigger: .accessibilityChanged,
            truncated: false
        )
    }
}
