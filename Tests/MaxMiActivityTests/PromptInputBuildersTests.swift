import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class PromptInputBuildersTests: XCTestCase {
    func testNonConversationInputUsesMainDeltaMetadataAndTypedCaps() {
        let page = CapturedContent.generic(GenericPage(
            regions: [.init(kind: .main, blocks: [
                .init(type: .paragraph, text: String(repeating: "A", count: 3_400)),
            ])],
            focused: nil,
            url: "https://example.test/plan"
        ))
        let input = CaptureSummaryInputBuilder.build(
            appLabel: "Notes",
            sourceTitle: "M8 plan",
            url: "https://example.test/plan",
            contentKind: .document,
            capturedAt: 1_800_000_000_000,
            trigger: .periodic,
            structured: page,
            delta: CaptureDelta(addedBlocks: [
                .init(type: .paragraph, text: String(repeating: "D", count: 1_700)),
            ]),
            typedText: String(repeating: "T", count: 600),
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(input.variant, .action)
        XCTAssertLessThanOrEqual(input.onScreenMain.count, 3_000)
        XCTAssertLessThanOrEqual(input.renderedDelta.count, 1_500)
        XCTAssertLessThanOrEqual(input.typedText.count, 500)
        XCTAssertEqual(input.url, "https://example.test/plan")
        XCTAssertTrue(input.hasMeaningfulContent)
        XCTAssertEqual(input.capturedAtISO8601, "2027-01-15T08:00:00Z")
    }

    func testConversationInputContainsOnlyAddedMessagesAndConversationMetadata() {
        let old = Message(id: "old", sender: "Ana", text: "old transcript", timestamp: nil,
                          timeString: "09:00", isUser: false, isDraft: false)
        let new = Message(id: "new", sender: "You", text: "I will ship it", timestamp: nil,
                          timeString: "09:05", isUser: true, isDraft: false)
        let input = CaptureSummaryInputBuilder.build(
            appLabel: "Slack", sourceTitle: "maxmi-dev", url: nil,
            contentKind: .conversation, capturedAt: 1_800_000_000_000,
            trigger: .conversationChanged,
            structured: .conversation(.init(channel: "#maxmi-dev", isGroup: true, messages: [old, new])),
            delta: CaptureDelta(addedMessages: [new]), typedText: nil,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(input.variant, .conversation)
        XCTAssertEqual(input.onScreenMain, "")
        XCTAssertTrue(input.renderedDelta.contains("(From: You)(sent 09:05): I will ship it"))
        XCTAssertFalse(input.renderedDelta.contains("old transcript"))
        XCTAssertEqual(input.channel, "#maxmi-dev")
        XCTAssertEqual(input.isGroup, true)
        XCTAssertEqual(input.capturedAtISO8601, "2027-01-15T08:00:00Z")
    }

    func testConversationInputIgnoresNonMessageDeltaParts() {
        let conversation = CapturedContent.conversation(
            .init(channel: "#maxmi-dev", isGroup: true, messages: [])
        )
        let emptyMessageInput = CaptureSummaryInputBuilder.build(
            appLabel: "Slack", sourceTitle: "maxmi-dev", url: nil,
            contentKind: .conversation, capturedAt: 1_800_000_000_000,
            trigger: .conversationChanged,
            structured: conversation,
            delta: CaptureDelta(addedBlocks: [.init(type: .paragraph, text: "block-only delta")]),
            typedText: nil,
            timeZone: TimeZone(identifier: "UTC")!
        )
        let message = Message(
            id: "new", sender: "You", text: "message-only delta", timestamp: nil,
            timeString: "09:05", isUser: true, isDraft: false
        )
        let mixedInput = CaptureSummaryInputBuilder.build(
            appLabel: "Slack", sourceTitle: "maxmi-dev", url: nil,
            contentKind: .conversation, capturedAt: 1_800_000_000_000,
            trigger: .conversationChanged,
            structured: conversation,
            delta: CaptureDelta(
                addedBlocks: [.init(type: .paragraph, text: "block portion must not render")],
                addedMessages: [message]
            ),
            typedText: nil,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertTrue(emptyMessageInput.renderedDelta.isEmpty)
        XCTAssertFalse(emptyMessageInput.hasMeaningfulContent)
        XCTAssertTrue(mixedInput.renderedDelta.contains("message-only delta"))
        XCTAssertFalse(mixedInput.renderedDelta.contains("block portion must not render"))
    }
}
