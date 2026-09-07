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
            variant: .conversation, appLabel: "Slack", sourceTitle: "maxmi-dev",
            url: nil, kind: .conversation, capturedAtISO8601: "2026-09-03T08:05:00Z",
            trigger: .conversationChanged, onScreenMain: "",
            renderedDelta: "(From: You): I will review it.", typedText: "",
            channel: "#maxmi-dev", isGroup: true, hasMeaningfulContent: true
        ))

        XCTAssertTrue(prompt.contains("channel: #maxmi-dev"))
        XCTAssertTrue(prompt.contains("isGroup: true"))
        XCTAssertTrue(prompt.contains("at most 45 words"))
        XCTAssertFalse(prompt.contains("ON SCREEN (main):"))
        XCTAssertTrue(prompt.contains("(From: You): I will review it."))
    }

    func testSessionPromptUsesTimelineInsteadOfEvidenceLanguage() {
        let prompt = AgentPrompts.summarizeForDisplay(
            appLabel: "Warp",
            timelineText: "09:02–09:14 Warp (terminal ~/code/MaxMi): ran swift test ×3",
            maxChars: 6_000
        )
        XCTAssertTrue(prompt.contains("timeline's chronological order"))
        XCTAssertTrue(prompt.contains("ran swift test"))
        XCTAssertFalse(prompt.contains("captured content"))
    }
}
