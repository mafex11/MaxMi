import XCTest
@testable import MaxMiActivity
import MaxMiCore

private actor CaptureSummaryRepoMock: CaptureDisplaySummaryRepository {
    var pending: [CaptureSummaryCandidate] = []
    var saved: [(String, String, String, String)] = []
    var failed: [String] = []

    func setPending(_ value: [CaptureSummaryCandidate]) { pending = value }
    func capturesNeedingSummary(nowMs: EpochMs) async -> [CaptureSummaryCandidate] { pending }
    func saveCaptureSummary(threadID: String, summary: String, expectedSourceHash: String, promptVersion: String, nowMs: EpochMs) async {
        saved.append((threadID, summary, expectedSourceHash, promptVersion))
    }
    func markCaptureSummaryFailed(threadID: String, expectedSourceHash: String, nowMs: EpochMs) async {
        failed.append(threadID)
    }
}

private actor CaptureSummaryRelayMock: CaptureDisplayGenerationRelay {
    var result: Result<String, Error> = .success("You're working on capture summaries.")
    var requests: [(String, String?, CaptureContentKind, String)] = []
    func setResult(_ value: Result<String, Error>) { result = value }
    func summarizeCapture(appLabel: String, sourceTitle: String?, contentKind: CaptureContentKind, content: String) async throws -> String {
        requests.append((appLabel, sourceTitle, contentKind, content))
        return try result.get()
    }
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
        XCTAssertEqual(saved.first?.3, CaptureDisplaySummaryFormat.standard)
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

    func testConversationSummaryUsesTrailingMessages() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        let old = String(repeating: "Old message that must not drive the summary.\n", count: 300)
        let recent = "Ava: Can you ship the capture fix today?\nYou: Yes, I will test it now."
        await repo.setPending([CaptureSummaryCandidate(
            threadID: "chat",
            appLabel: "WhatsApp",
            sourceTitle: "Ava",
            contentKind: .conversation,
            content: old + recent,
            expectedSourceHash: "h-chat",
            promptVersion: CaptureDisplaySummaryFormat.recentConversation
        )])

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_000)

        let request = await relay.requests.first
        XCTAssertEqual(request?.0, "WhatsApp")
        XCTAssertEqual(request?.1, "Ava")
        XCTAssertEqual(request?.2, .conversation)
        XCTAssertTrue(request?.3.contains("ship the capture fix") == true)
        XCTAssertFalse(request?.3.contains("Old message") == true)
    }
}
