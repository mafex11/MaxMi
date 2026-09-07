import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class AgentPromptsTests: XCTestCase {
    func testCaptureActionPromptHasMetadataAndOmitsEmptySections() {
        let prompt = AgentPrompts.summarizeCaptureForDisplay(.init(
            variant: .action, appLabel: "Cursor", sourceTitle: "Plan.swift",
            url: "file:///Plan.swift", kind: .document,
            capturedAtISO8601: "2026-09-03T08:05:00Z", trigger: .periodic,
            onScreenMain: "Implement context embeddings.", renderedDelta: "",
            typedText: "", channel: nil, isGroup: nil, hasMeaningfulContent: true
        ))

        XCTAssertTrue(prompt.contains("app: Cursor"))
        XCTAssertTrue(prompt.contains("window: Plan.swift"))
        XCTAssertTrue(prompt.contains("ON SCREEN (main):"))
        XCTAssertFalse(prompt.contains("NEW SINCE LAST CAPTURE:\n\n"))
        XCTAssertFalse(prompt.contains("USER TYPED:\n\n"))
        XCTAssertTrue(prompt.contains("at most 24 words"))
        XCTAssertTrue(prompt.contains("BEGIN_UNTRUSTED_DATA_"))
    }

    func testConversationPromptHasOnlyNewMessagesAndUsesConversationRules() {
        let prompt = AgentPrompts.summarizeCaptureForDisplay(.init(
            variant: .conversation, appLabel: "Slack", sourceTitle: "project-chat",
            url: nil, kind: .conversation, capturedAtISO8601: "2026-09-03T08:05:00Z",
            trigger: .conversationChanged, onScreenMain: "",
            renderedDelta: "(From: You): I will review it.", typedText: "",
            channel: "#project-chat", isGroup: true, hasMeaningfulContent: true
        ))

        XCTAssertTrue(prompt.contains("channel: #project-chat"))
        XCTAssertTrue(prompt.contains("isGroup: true"))
        XCTAssertTrue(prompt.contains("at most 45 words"))
        XCTAssertFalse(prompt.contains("ON SCREEN (main):"))
        XCTAssertTrue(prompt.contains("(From: You): I will review it."))
    }

    func testSessionPromptUsesTimelineInsteadOfEvidenceLanguage() {
        let prompt = AgentPrompts.summarizeForDisplay(
            appLabel: "Warp",
            timelineText: "09:02–09:14 Warp (terminal ~/scratch/demo-project): ran swift test ×3",
            maxChars: 6_000
        )
        XCTAssertTrue(prompt.contains("timeline's chronological order"))
        XCTAssertTrue(prompt.contains("ran swift test"))
        XCTAssertFalse(prompt.contains("captured content"))
    }

    func testCaptureActionAppLineIsInsideUntrustedDataFence() {
        let prompt = AgentPrompts.summarizeCaptureForDisplay(.init(
            variant: .action, appLabel: "Cursor", sourceTitle: "Plan.swift",
            url: "file:///Plan.swift", kind: .document,
            capturedAtISO8601: "2026-09-03T08:05:00Z", trigger: .periodic,
            onScreenMain: "Implement context embeddings.", renderedDelta: "",
            typedText: "", channel: nil, isGroup: nil, hasMeaningfulContent: true
        ))

        assertLine("app: Cursor", isInsideUntrustedDataFenceIn: prompt)
    }

    func testCaptureConversationAppLineIsInsideUntrustedDataFence() {
        let prompt = AgentPrompts.summarizeCaptureForDisplay(.init(
            variant: .conversation, appLabel: "Slack", sourceTitle: "project-chat",
            url: nil, kind: .conversation, capturedAtISO8601: "2026-09-03T08:05:00Z",
            trigger: .conversationChanged, onScreenMain: "",
            renderedDelta: "(From: You): I will review it.", typedText: "",
            channel: "#project-chat", isGroup: true, hasMeaningfulContent: true
        ))

        assertLine("app: Slack", isInsideUntrustedDataFenceIn: prompt)
    }

    func testSessionAppLineIsInsideUntrustedDataFence() {
        let prompt = AgentPrompts.summarizeForDisplay(
            appLabel: "Warp",
            timelineText: "09:02–09:14 Warp (terminal ~/scratch/demo-project): ran swift test ×3",
            maxChars: 6_000
        )

        assertLine("App: Warp", isInsideUntrustedDataFenceIn: prompt)
    }

    func testHourlyReviewCapsSourceMetadataFields() {
        let sourceApp = String(repeating: "a", count: 5_000)
        let sourceTitle = String(repeating: "b", count: 5_000)
        let sourceKey = String(repeating: "c", count: 5_000)
        let input = AgentReviewInput(
            runID: "run-1",
            versions: [
                ReviewVersion(
                    versionID: "version-1",
                    threadID: "thread-1",
                    sourceApp: sourceApp,
                    sourceTitle: sourceTitle,
                    sourceKey: sourceKey,
                    kind: .generic,
                    wordCount: 0,
                    committedAt: 0,
                    compactContent: "",
                    deltaSummary: nil,
                    deltaChars: 0
                )
            ],
            timelineText: "",
            openItems: [],
            localTimeISO: "2026-09-08T00:00:00Z",
            timeRange: (0, 0)
        )

        let prompt = AgentPrompts.hourlyReview(input: input)

        XCTAssertLessThanOrEqual(renderedValue(after: "app: ", in: prompt).count, 120)
        XCTAssertLessThanOrEqual(renderedValue(after: "title: ", in: prompt).count, 200)
        XCTAssertLessThanOrEqual(renderedValue(after: "sourceKey: ", in: prompt).count, 200)
    }

    private func assertLine(_ line: String, isInsideUntrustedDataFenceIn prompt: String, file: StaticString = #filePath, line testLine: UInt = #line) {
        let appLineIndex = try! XCTUnwrap(
            prompt.range(of: line)?.lowerBound,
            "Expected app line to be present.",
            file: file,
            line: testLine
        )
        let beginFenceIndex = try! XCTUnwrap(
            prompt.ranges(of: "===BEGIN_UNTRUSTED_DATA_").last?.lowerBound,
            "Expected begin fence to be present.",
            file: file,
            line: testLine
        )
        let endFenceIndex = try! XCTUnwrap(
            prompt.ranges(of: "===END_UNTRUSTED_DATA_").last?.lowerBound,
            "Expected end fence to be present.",
            file: file,
            line: testLine
        )

        XCTAssertGreaterThan(appLineIndex, beginFenceIndex, file: file, line: testLine)
        XCTAssertLessThan(appLineIndex, endFenceIndex, file: file, line: testLine)
    }

    private func renderedValue(after prefix: String, in prompt: String) -> String {
        let line = try! XCTUnwrap(prompt.split(separator: "\n").first {
            $0.hasPrefix(prefix)
        })
        return String(line.dropFirst(prefix.count))
    }
}
