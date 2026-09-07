import XCTest
@testable import MaxMiActivity
import MaxMiCore

actor MockRepo: ActivitySummaryRepository {
    private var pendingSessions: [PendingSession] = []
    private var savedSummaries: [(sessionID: String, summary: String, expectedHash: String)] = []
    private var failedSessions: [(sessionID: String, error: String)] = []

    func setPending(_ sessions: [PendingSession]) {
        pendingSessions = sessions
    }

    func getSaved() -> [(sessionID: String, summary: String, expectedHash: String)] {
        return savedSummaries
    }

    func getFailed() -> [(sessionID: String, error: String)] {
        return failedSessions
    }

    func sessionsNeedingSummary(nowMs: EpochMs) async -> [PendingSession] {
        return pendingSessions
    }

    func saveSummary(sessionID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async {
        savedSummaries.append((sessionID, summary, expectedSourceHash))
    }

    func markFailed(sessionID: String, error: String, nowMs: EpochMs) async {
        failedSessions.append((sessionID, error))
    }
}

actor MockRelay: ActivityGenerationRelay {
    private var shouldThrow = false
    private var returnedSummary = "Worked on X"
    var timelineRequests: [String] = []

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func setReturnedSummary(_ value: String) {
        returnedSummary = value
    }

    func summarizeSession(appLabel: String, timelineText: String) async throws -> String {
        timelineRequests.append(timelineText)
        if shouldThrow {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test error"])
        }
        return returnedSummary
    }
}

final class DisplaySummarizerTests: XCTestCase {
    func testSummarizeDueCallsRepoWithSummary() async throws {
        let repo = MockRepo()
        let relay = MockRelay()
        await repo.setPending([PendingSession(
            id: "sess1",
            appLabel: "TestApp",
            timelineText: "09:02–09:14 TestApp: did work",
            expectedSourceHash: "hash123"
        )])
        await relay.setReturnedSummary("Worked on X")

        let summarizer = DisplaySummarizer(repo: repo, relay: relay)
        await summarizer.summarizeDue(nowMs: 1000)

        let saved = await repo.getSaved()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.sessionID, "sess1")
        XCTAssertEqual(saved.first?.summary, "Worked on X")
        XCTAssertEqual(saved.first?.expectedHash, "hash123")
    }

    func testRelayThrowsMarksSessionFailed() async throws {
        let repo = MockRepo()
        let relay = MockRelay()
        await repo.setPending([PendingSession(
            id: "sess2",
            appLabel: "TestApp",
            timelineText: "09:02–09:14 TestApp: did work",
            expectedSourceHash: "hash456"
        )])
        await relay.setShouldThrow(true)

        let summarizer = DisplaySummarizer(repo: repo, relay: relay)
        await summarizer.summarizeDue(nowMs: 1000)

        let failed = await repo.getFailed()
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.sessionID, "sess2")
        XCTAssertTrue(failed.first?.error.contains("test error") ?? false)

        let saved = await repo.getSaved()
        XCTAssertEqual(saved.count, 0, "should not save summary when relay throws")
    }

    func testSummarizeDueSendsTimelineTextNeverEvidenceArray() async {
        let repo = MockRepo()
        let relay = MockRelay()
        await repo.setPending([PendingSession(
            id: "s1", appLabel: "Warp",
            timelineText: "09:02–09:14 Warp: ran swift test",
            expectedSourceHash: "h1"
        )])

        await DisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1)

        let requests = await relay.timelineRequests
        XCTAssertEqual(requests, ["09:02–09:14 Warp: ran swift test"])
    }
}
