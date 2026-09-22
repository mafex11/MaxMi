import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WhatsAppStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              identifier: String? = nil, frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: label)
    }

    func bubble(_ body: String? = nil, time: String?, x: CGFloat, y: CGFloat,
                label: String? = nil) -> AXNode {
        var kids: [AXNode] = []
        if let body {
            kids.append(node("AXStaticText", value: body,
                             frame: CGRect(x: x, y: y, width: 260, height: 18)))
        }
        if let time {
            kids.append(node("AXStaticText", value: time,
                             frame: CGRect(x: x + 220, y: y + 20, width: 40, height: 12)))
        }
        return node("AXCell", label: label, identifier: "WAMessageBubbleTableViewCell",
                    frame: CGRect(x: x, y: y, width: 300, height: 40), children: kids)
    }

    /// Window 1000 wide: incoming bubble left of centre, outgoing right of centre.
    func window(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                              size: CGSize(width: 1000, height: 700)),
                    children: [
            node("AXGroup", label: "Chats", frame: CGRect(x: x, y: y, width: 300, height: 700),
                 children: [node("AXStaticText", value: "Archived",
                                 frame: CGRect(x: x + 10, y: y + 20, width: 100, height: 16))]),
            node("AXHeading", value: "Priya Vantar", label: "conversation title",
                 frame: CGRect(x: x + 340, y: y + 20, width: 200, height: 22)),
            bubble("are we still on for 4", time: "16:02", x: x + 340, y: y + 100),
            bubble("yes, see you then", time: "16:04", x: x + 660, y: y + 160),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation, got \(String(describing: content))")
            throw NSError(domain: "ExpectedContentShape", code: 1)
        }
        return c
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(WhatsAppParser.config.bundleIDs, ParserRegistry.whatsAppBundleIDs)
        XCTAssertEqual(WhatsAppParser.config.hosts, ["web.whatsapp.com"])
        XCTAssertTrue(WhatsAppParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: "net.whatsapp.WhatsApp") is WhatsAppParser)
        XCTAssertTrue(registry.structuredParser(forHost: "web.whatsapp.com") is WhatsAppParser)
    }

    func testBubbleCellsAreTheOnlyMessageAnchor() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.text), ["are we still on for 4", "yes, see you then"])
        XCTAssertFalse(c.messages.contains { $0.text == "Archived" },
                       "the chat list is not a bubble cell, so it is structurally excluded")
    }

    func testTimeStringIsSplitOutOfTheBubbleBody() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.timeString), ["16:02", "16:04"])
        XCTAssertFalse(c.messages[0].text.contains("16:02"))
    }

    func testSplitBubbleTextsRecognisesBothTimeFormats() {
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "16:02"]).timeString, "16:02")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "4:02 PM"]).timeString, "4:02 PM")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "16:02"]).body, "hello")
        XCTAssertNil(WhatsAppParser.splitBubbleTexts(["hello", "there"]).timeString)
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "there"]).body, "hello there")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts([]).body, "")
    }

    func testBubbleSideDecidesIsUser() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.isUser), [false, true])
        XCTAssertEqual(c.messages.map(\.sender), ["Priya Vantar", "You"])
    }

    func testChannelComesFromTheConversationHeaderNotTheWindowTitle() throws {
        // WhatsApp's window title is just "WhatsApp"; the header carries the identity.
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.channel, "Priya Vantar")
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try WhatsAppParser().parse(window(), context: context("WhatsApp")),
                       try WhatsAppParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                              context: context("WhatsApp")))
    }

    func testCombinedGroupCellLabelsProduceNamedSenders() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700), children: [
            node("AXHeading", value: "Weekend Plans", label: "conversation title",
                 frame: CGRect(x: 340, y: 20, width: 200, height: 22)),
            bubble(nil, time: nil, x: 340, y: 100, label: "Mira: bringing snacks"),
            bubble(nil, time: nil, x: 340, y: 150, label: "Niko: arranging rides"),
            bubble(nil, time: nil, x: 660, y: 200, label: "You: I will bring drinks"),
        ])
        let c = try conversation(WhatsAppParser().parse(win, context: context("WhatsApp")))
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Mira", "Niko", "You"])
        XCTAssertEqual(c.messages.map(\.text),
                       ["bringing snacks", "arranging rides", "I will bring drinks"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, true],
                       "outgoing status comes from the bubble side, not the label text")
    }

    func testNoBubbleCellsAreNotHandledSoTheRegistryCanFallThrough() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                        children: [node("AXStaticText", value: "Use WhatsApp on your phone",
                                        frame: CGRect(x: 400, y: 300, width: 200, height: 16))])
        XCTAssertNil(try WhatsAppParser().parse(bare, context: context("WhatsApp")))
    }

    func testBubblesWithNoConfirmedChatHeaderAreRefusedRatherThanStored() {
        let headerless = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              children: [
            node("AXGroup", label: "Chats", frame: CGRect(x: 0, y: 0, width: 300, height: 700),
                 children: [node("AXStaticText", value: "Archived",
                                 frame: CGRect(x: 10, y: 20, width: 100, height: 16))]),
            bubble("are we still on for 4", time: "16:02", x: 340, y: 100),
        ])
        // Bubbles but no confirmed header: there is no thread to attribute them to, so refuse
        // rather than key them under the window title "WhatsApp" (ruling F13).
        XCTAssertThrowsError(try WhatsAppParser().parse(headerless,
                                                        context: context("WhatsApp"))) { error in
            XCTAssertEqual(error as? ParserRefusal,
                           ParserRefusal(reason: "unconfirmed-conversation-identity"))
        }
    }

    func testV2PathHardBoundsAnOversizeConversationToEightThousandCharacters() throws {
        let oversized = node(
            "AXWindow",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            children: [
                node("AXHeading", value: "Priya Vantar", label: "conversation title",
                     frame: CGRect(x: 340, y: 20, width: 200, height: 22)),
                bubble(String(repeating: "whatsapp body ", count: 1_000),
                       time: "16:02", x: 340, y: 100),
            ]
        )
        let parser = WhatsAppParser()
        let structured = try XCTUnwrap(parser.parse(oversized, context: context("WhatsApp")))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(structured, style: .full).count,
            NativeConversationExtraction.contentCap
        )

        let capture = try XCTUnwrap(parser.parse(
            window: oversized,
            app: AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        ))
        XCTAssertLessThanOrEqual(capture.content.count, NativeConversationExtraction.contentCap)
        XCTAssertTrue(capture.truncated)
    }

    func testWhatsAppFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(WhatsAppParser().parse(try fixture("whatsapp-bubbles"),
                                                        context: context("WhatsApp"))),
                     matches: "whatsapp-bubbles-golden")
    }

    func testOffsetWhatsAppFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(WhatsAppParser().parse(try fixture("whatsapp-offset-bubbles"),
                                                        context: context("WhatsApp"))),
                     matches: "whatsapp-offset-bubbles-golden")
    }

    func testGroupSenderFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(WhatsAppParser().parse(try fixture("whatsapp-group-senders"),
                                                        context: context("WhatsApp"))),
                     matches: "whatsapp-group-senders-golden")
    }

    func testDirectSenderFixtureUsesBubbleSideForTheUser() throws {
        let content = try XCTUnwrap(WhatsAppParser().parse(
            try fixture("whatsapp-direct-senders"), context: context("WhatsApp")
        ))
        assertGolden(content, matches: "whatsapp-direct-senders-golden")
        guard case .conversation(let conversation) = content else {
            return XCTFail("expected .conversation")
        }
        XCTAssertFalse(conversation.isGroup)
        XCTAssertEqual(conversation.messages.map(\.isUser), [false, true])
    }
}
