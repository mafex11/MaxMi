import XCTest
@testable import MaxMiActivity
import MaxMiCore

private actor CaptureSummaryRepoMock: CaptureDisplaySummaryRepository {
    var pending: [CaptureSummaryCandidate] = []
    var saved: [(String, String, String)] = []
    var failed: [String] = []

    func setPending(_ value: [CaptureSummaryCandidate]) { pending = value }
    func capturesNeedingSummary(nowMs: EpochMs) async -> [CaptureSummaryCandidate] { pending }
    func saveCaptureSummary(threadID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async {
        saved.append((threadID, summary, expectedSourceHash))
    }
    func markCaptureSummaryFailed(threadID: String, expectedSourceHash: String, nowMs: EpochMs) async {
        failed.append(threadID)
    }
}

private actor CaptureSummaryRelayMock: CaptureDisplayGenerationRelay {
    var result: Result<String, Error> = .success("You're working on capture summaries.")
    func setResult(_ value: Result<String, Error>) { result = value }
    func summarizeCapture(appLabel: String, content: String) async throws -> String { try result.get() }
}

final class CaptureDisplaySummarizerTests: XCTestCase {
    func testGeneratesAndSavesCleanSummary() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        await repo.setPending([CaptureSummaryCandidate(
            threadID: "t1", appLabel: "Cursor", content: "code", expectedSourceHash: "h1"
        )])
        await relay.setResult(.success("  \"You're fixing MaxMi's capture menu.\"  "))

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_000)

        let saved = await repo.saved
        XCTAssertEqual(saved.first?.0, "t1")
        XCTAssertEqual(saved.first?.1, "You're fixing MaxMi's capture menu.")
        XCTAssertEqual(saved.first?.2, "h1")
    }

    func testFailureIsRecordedWithoutSaving() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        await repo.setPending([CaptureSummaryCandidate(
            threadID: "t2", appLabel: "Zen", content: "article", expectedSourceHash: "h2"
        )])
        await relay.setResult(.failure(NSError(domain: "test", code: 1)))

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_000)

        let failed = await repo.failed
        let saved = await repo.saved
        XCTAssertEqual(failed, ["t2"])
        XCTAssertTrue(saved.isEmpty)
    }
}
