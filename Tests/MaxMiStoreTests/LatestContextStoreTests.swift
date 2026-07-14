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
