import XCTest
@testable import MaxMiMCP
@testable import MaxMiStore
import MaxMiCore

final class MeetingMemoryTests: XCTestCase {
    let t0 = EpochMs(495_700) * 3_600_000

    func makeFixture() throws -> (queries: MemoryQueries, threadID: String) {
        let db = try MaxMiDatabase.inMemory()
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        _ = try store.commitMeeting(id: "mm-1", app: "Zoom", title: "Roadmap sync", transcript: "we decided to ship M5 next",
            startedAtMs: t0, endedAtMs: t0+600_000, captureMode: "system+mic", transcriptionStatus: "complete", nowMs: t0+600_000)
        let queryNow = t0 + 3_600_000
        let queries = MemoryQueries(
            store: store,
            relay: MockRelay(.success([Float](repeating: 0.5, count: 1536))),
            now: { Date(timeIntervalSince1970: Double(queryNow) / 1000) }
        )
        return (queries, try XCTUnwrap(store.meeting(id: "mm-1")?.threadID))
    }

    func makeQueries() throws -> MemoryQueries {
        try makeFixture().queries
    }

    func testListReturnsMeetings() async throws {
        let r = try await makeQueries().meetingMemory(action: "list", query: nil)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("Roadmap sync"))
        XCTAssertTrue(r.text.contains("Zoom"))
    }

    func testGetContextReturnsTranscript() async throws {
        let r = try await makeQueries().meetingMemory(action: "get_context", query: "mm-1")
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("ship M5 next"), "decrypted transcript in context")
    }

    func testUnknownActionErrors() async throws {
        let r = try await makeQueries().meetingMemory(action: "bogus", query: nil)
        XCTAssertTrue(r.isError)
    }

    func testGetContextAcceptsExplicitThreadID() async throws {
        let fixture = try makeFixture()
        let result = await fixture.queries.meetingMemory(
            action: "get_context", query: nil, meetingID: nil, limit: nil,
            options: RetrievalOptions(threadID: fixture.threadID)
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("ship M5 next"))
        XCTAssertTrue(result.text.contains("**Thread ID:** `\(fixture.threadID)`"))
    }

    func testListHonorsAppAndLookbackFilters() async throws {
        let fixture = try makeFixture()
        let wrongApp = await fixture.queries.meetingMemory(
            action: "list", query: nil, meetingID: nil, limit: 10,
            options: RetrievalOptions(sourceApps: ["Teams"])
        )
        XCTAssertFalse(wrongApp.text.contains("Roadmap sync"))
        let tooRecent = await fixture.queries.meetingMemory(
            action: "list", query: nil, meetingID: nil, limit: 10,
            options: RetrievalOptions(lookbackMinutes: 30)
        )
        XCTAssertFalse(tooRecent.text.contains("Roadmap sync"))
        let included = await fixture.queries.meetingMemory(
            action: "list", query: nil, meetingID: nil, limit: 10,
            options: RetrievalOptions(sourceApps: ["Zoom"], lookbackMinutes: 120)
        )
        XCTAssertTrue(included.text.contains("Roadmap sync"))
    }
}
