import XCTest
@testable import MaxMiMCP
@testable import MaxMiStore
import MaxMiCore

final class MeetingMemoryTests: XCTestCase {
    func makeQueries() throws -> MemoryQueries {
        let db = try MaxMiDatabase.inMemory()
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        let t0 = EpochMs(495_700) * 3_600_000
        _ = try store.commitMeeting(id: "mm-1", app: "Zoom", title: "Roadmap sync", transcript: "we decided to ship M5 next",
            startedAtMs: t0, endedAtMs: t0+600_000, captureMode: "system+mic", transcriptionStatus: "complete", nowMs: t0+600_000)
        return MemoryQueries(store: store, relay: MockRelay(.success([Float](repeating: 0.5, count: 1536))))
    }

    func testListReturnsMeetings() async throws {
        let r = await try makeQueries().meetingMemory(action: "list", query: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("Roadmap sync"))
        XCTAssertTrue(r.text.contains("Zoom"))
    }

    func testGetContextReturnsTranscript() async throws {
        let r = await try makeQueries().meetingMemory(action: "get_context", query: "mm-1")
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("ship M5 next"), "decrypted transcript in context")
    }

    func testUnknownActionErrors() async throws {
        let r = await try makeQueries().meetingMemory(action: "bogus", query: nil)
        XCTAssertTrue(r.isError)
    }
}
