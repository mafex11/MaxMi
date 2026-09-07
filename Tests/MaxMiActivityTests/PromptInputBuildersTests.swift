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
            typedText: String(repeating: "T", count: 600)
        )

        XCTAssertEqual(input.variant, .action)
        XCTAssertLessThanOrEqual(input.onScreenMain.count, 3_000)
        XCTAssertLessThanOrEqual(input.renderedDelta.count, 1_500)
        XCTAssertLessThanOrEqual(input.typedText.count, 500)
        XCTAssertEqual(input.url, "https://example.test/plan")
        XCTAssertTrue(input.hasMeaningfulContent)
        XCTAssertFalse(input.capturedAtISO8601.isEmpty)
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
            delta: CaptureDelta(addedMessages: [new]), typedText: nil
        )

        XCTAssertEqual(input.variant, .conversation)
        XCTAssertEqual(input.onScreenMain, "")
        XCTAssertTrue(input.renderedDelta.contains("(From: You)(sent 09:05): I will ship it"))
        XCTAssertFalse(input.renderedDelta.contains("old transcript"))
        XCTAssertEqual(input.channel, "#maxmi-dev")
        XCTAssertEqual(input.isGroup, true)
    }
}
