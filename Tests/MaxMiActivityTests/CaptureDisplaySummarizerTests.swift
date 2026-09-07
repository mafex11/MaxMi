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
    var requests: [CaptureSummaryPromptInput] = []
    func setResult(_ value: Result<String, Error>) { result = value }
    func summarizeCapture(_ input: CaptureSummaryPromptInput) async throws -> String {
        requests.append(input)
        return try result.get()
    }
}

final class CaptureDisplaySummarizerTests: XCTestCase {
    func testGeneratesAndSavesCleanSummary() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        await repo.setPending([meaningfulCaptureCandidate()])
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
            threadID: "t2", appLabel: "Zen", sourceTitle: nil, url: nil,
            contentKind: .generic, capturedAt: 1, trigger: .periodic,
            structured: .generic(.init(
                regions: [.init(kind: .main, blocks: [.init(type: .paragraph, text: "article")])],
                focused: nil,
                url: nil
            )),
            delta: .empty,
            typedText: nil,
            expectedSourceHash: "h2"
        )])
        await relay.setResult(.failure(NSError(domain: "test", code: 1)))

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_000)

        let failed = await repo.failed
        let saved = await repo.saved
        XCTAssertEqual(failed, ["t2"])
        XCTAssertTrue(saved.isEmpty)
    }

    func testEmptyStructuredInputSavesLocalViewingFallbackWithoutCallingRelay() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        await repo.setPending([CaptureSummaryCandidate(
            threadID: "t1", appLabel: "Finder", sourceTitle: "Downloads", url: nil,
            contentKind: .generic, capturedAt: 1_800_000_000_000, trigger: .periodic,
            structured: .generic(.init(regions: [], focused: nil, url: nil)),
            delta: .empty, typedText: nil, expectedSourceHash: "h1",
            promptVersion: CaptureDisplaySummaryFormat.standard
        )])

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_800_000_010_000)

        let requestCount = await relay.requests.count
        let saved = await repo.saved
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(saved.first?.1, "Viewing Finder: Downloads")
    }

    func testConversationCandidatePassesOnlyAddedMessagesToRelay() async throws {
        let request = try await summarizedConversationRequest()
        XCTAssertEqual(request.variant, .conversation)
        XCTAssertFalse(request.renderedDelta.contains("old transcript"))
        XCTAssertTrue(request.renderedDelta.contains("new message"))
    }

    func testRefusedSummarySavesViewingFallbackWithoutRecordingFailure() async {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        await repo.setPending([meaningfulCaptureCandidate()])
        await relay.setResult(.success("I cannot summarize that content."))

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1)

        let requestCount = await relay.requests.count
        let saved = await repo.saved
        let failures = await repo.failed
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(saved.first?.1, "Viewing Cursor: Plan.swift")
        XCTAssertTrue(failures.isEmpty)
    }

    func testRefusalPredicateCoversEveryLocalFallbackCase() {
        let refused = [
            "",
            "12345 !!!",
            String(repeating: "a", count: 281),
            "first paragraph\n\nsecond paragraph",
            "I can't summarize this.",
            "I CANNOT summarize this.",
            "I'm unable to summarize this.",
            "I am unable to summarize this.",
            "I am not able to summarize this.",
            "As an AI, I cannot summarize this.",
            "I'm sorry, but I cannot summarize this.",
            "I am sorry, but I cannot summarize this.",
        ]
        XCTAssertTrue(refused.allSatisfy(CaptureDisplaySummarizer.isRefused))
        XCTAssertFalse(CaptureDisplaySummarizer.isRefused("You reviewed the migration plan."))
    }

    func testEveryRefusalPhraseSavesViewingFallback() async {
        let phrases = [
            "I can't summarize this.",
            "I cannot summarize this.",
            "I'm unable to summarize this.",
            "I am unable to summarize this.",
            "I am not able to summarize this.",
            "As an AI, I cannot summarize this.",
            "I'm sorry, but I cannot summarize this.",
            "I am sorry, but I cannot summarize this.",
        ]
        let expected = CaptureDisplaySummaryFormat.fallback(app: "Cursor", title: "Plan.swift")

        for phrase in phrases {
            let repo = CaptureSummaryRepoMock()
            let relay = CaptureSummaryRelayMock()
            await repo.setPending([meaningfulCaptureCandidate()])
            await relay.setResult(.success(phrase))

            await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1)

            let saved = await repo.saved
            XCTAssertEqual(saved.first?.1, expected, phrase)
        }
    }

    private func meaningfulCaptureCandidate() -> CaptureSummaryCandidate {
        CaptureSummaryCandidate(
            threadID: "t1", appLabel: "Cursor", sourceTitle: "Plan.swift", url: nil,
            contentKind: .document, capturedAt: 1, trigger: .periodic,
            structured: .document(.init(
                title: "Plan.swift",
                blocks: [.init(type: .paragraph, text: "Review the migration plan.")],
                author: .unknown,
                url: nil
            )),
            delta: .empty,
            typedText: nil,
            expectedSourceHash: "h1"
        )
    }

    private func summarizedConversationRequest() async throws -> CaptureSummaryPromptInput {
        let repo = CaptureSummaryRepoMock()
        let relay = CaptureSummaryRelayMock()
        let old = Message(
            id: "old", sender: "Teammate", text: "old transcript",
            timestamp: nil, timeString: nil, isUser: false, isDraft: false
        )
        let new = Message(
            id: "new", sender: "Teammate", text: "new message",
            timestamp: nil, timeString: nil, isUser: false, isDraft: false
        )
        await repo.setPending([CaptureSummaryCandidate(
            threadID: "chat", appLabel: "Chat", sourceTitle: "Project",
            url: nil, contentKind: .conversation, capturedAt: 1,
            trigger: .conversationChanged,
            structured: .conversation(.init(
                channel: "Project", isGroup: true, messages: [old, new]
            )),
            delta: .init(addedMessages: [new]),
            typedText: nil,
            expectedSourceHash: "h-chat",
            promptVersion: CaptureDisplaySummaryFormat.recentConversation
        )])

        await CaptureDisplaySummarizer(repo: repo, relay: relay).summarizeDue(nowMs: 1_000)

        let requests = await relay.requests
        return try XCTUnwrap(requests.first)
    }
}
