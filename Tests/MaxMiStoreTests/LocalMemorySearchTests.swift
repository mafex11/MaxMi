import XCTest
@testable import MaxMiStore
import MaxMiCore

final class LocalMemorySearchTests: XCTestCase {
    private var store: Store!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }

    func testSearchMatchesEncryptedContextWithoutRelay() throws {
        _ = try store.commitCapture(envelope(key: "doc:one", title: "Design", content: "The launch codename is moonlight."), nowMs: t0)
        let hits = try store.searchLocalMemory(query: "moonlight")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sourceTitle, "Design")
        XCTAssertTrue(hits.first?.snippet.contains("moonlight") == true)
        XCTAssertEqual(hits.first?.matchKind, "context")
    }

    func testSearchMatchesFactAndDeduplicatesThread() throws {
        guard case .committed(let versionID, _) = try store.commitCapture(
            envelope(key: "doc:two", title: "Roadmap", content: "General roadmap notes"), nowMs: t0
        ) else { return XCTFail("expected commit") }
        let threadID = try store.threadID(forKey: "doc:two")
        _ = try store.insertDerivatives(
            versionID: versionID, threadID: threadID,
            facts: ["The user chose Project Firefly.", "Firefly launches Friday."], nowMs: t0 + 1_000
        )
        let hits = try store.searchLocalMemory(query: "firefly")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.threadID, threadID)
        XCTAssertEqual(hits.first?.matchKind, "fact")
    }

    func testEmptyAndUnknownQueriesReturnNoHits() throws {
        _ = try store.commitCapture(envelope(key: "doc:three", title: "Notes", content: "private content"), nowMs: t0)
        XCTAssertTrue(try store.searchLocalMemory(query: "   ").isEmpty)
        XCTAssertTrue(try store.searchLocalMemory(query: "not-present").isEmpty)
    }

    private func envelope(key: String, title: String, content: String) -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: "Notes", sourceKey: key, sourceTitle: title, content: content,
            contentKind: .document, parserID: "TestParser", parserVersion: 1,
            accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
            trigger: .appActivated, truncated: false
        )
    }
}

