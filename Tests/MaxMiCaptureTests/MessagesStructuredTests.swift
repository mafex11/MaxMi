import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class MessagesStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: label)
    }

    /// Window 900 wide: incoming bubbles on the left (midX < window midX), outgoing on the right.
    func window(origin: CGPoint = .zero, groupSenderLabels: Bool = false) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                              size: CGSize(width: 900, height: 700)),
                    children: [
            node("AXList", identifier: "message-list",
                 frame: CGRect(x: x + 20, y: y + 80, width: 860, height: 500), children: [
                node("AXRow", frame: CGRect(x: x + 40, y: y + 100, width: 300, height: 40),
                     children: [
                    node("AXTextArea", value: "are we still on for 4",
                         label: groupSenderLabels ? "Ada" : nil,
                         frame: CGRect(x: x + 40, y: y + 100, width: 300, height: 40)),
                ]),
                node("AXRow", frame: CGRect(x: x + 540, y: y + 160, width: 300, height: 40),
                     children: [
                    node("AXTextArea", value: "yes, see you then",
                         frame: CGRect(x: x + 540, y: y + 160, width: 300, height: 40)),
                ]),
                node("AXRow", frame: CGRect(x: x + 700, y: y + 205, width: 100, height: 14),
                     children: [
                    node("AXStaticText", value: "Delivered",
                         frame: CGRect(x: x + 700, y: y + 205, width: 100, height: 14)),
                ]),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(MessagesParser.config.bundleIDs, [ParserRegistry.messagesBundleID])
        XCTAssertEqual(MessagesParser.config.app, "Messages")
        XCTAssertTrue(MessagesParser.config.hosts.isEmpty, "Messages has no web client")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.messagesBundleID)
                        is MessagesParser)
    }

    func testChatNameComesFromTheWindowTitle() {
        XCTAssertEqual(MessagesParser.chatName(fromTitle: "Priya Vantar"), "Priya Vantar")
        XCTAssertEqual(MessagesParser.chatName(fromTitle: "  "), "unknown")
        XCTAssertEqual(MessagesParser.chatName(fromTitle: nil), "unknown")
    }

    func testBubbleSideDecidesIsUser() throws {
        let c = try conversation(MessagesParser().parse(window(), context: context("Priya Vantar")))
        XCTAssertEqual(c.channel, "Priya Vantar")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.map(\.text),
                       ["are we still on for 4", "yes, see you then", "Delivered"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, true, true])
        XCTAssertEqual(c.messages.map(\.sender), ["Priya Vantar", "You", "You"])
    }

    func testBubbleSideIsWindowRelativeSoANonzeroOriginChangesNothing() throws {
        let flush = try conversation(MessagesParser().parse(window(),
                                                          context: context("Priya Vantar")))
        let offset = try conversation(MessagesParser().parse(
            window(origin: CGPoint(x: 1440, y: 220)), context: context("Priya Vantar")))
        XCTAssertEqual(flush.messages.map(\.isUser), offset.messages.map(\.isUser),
                       "AXFrame is global, so midX must be compared against the window's midX")
        XCTAssertEqual(flush, offset)
    }

    func testIsUserBubbleComparesAgainstTheWindowMidpoint() {
        let win = node("AXWindow", frame: CGRect(x: 1000, y: 0, width: 900, height: 700))
        let left = node("AXTextArea", value: "a", frame: CGRect(x: 1040, y: 10, width: 300, height: 40))
        let right = node("AXTextArea", value: "b", frame: CGRect(x: 1540, y: 10, width: 300, height: 40))
        XCTAssertFalse(MessagesParser.isUserBubble(left, window: win))
        XCTAssertTrue(MessagesParser.isUserBubble(right, window: win))
    }

    func testBubbleWithNoFrameIsTreatedAsIncoming() {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let unpositioned = AXNode(role: "AXTextArea", value: "a", title: nil, url: nil,
                                  frame: nil, focused: false, children: [])
        XCTAssertFalse(MessagesParser.isUserBubble(unpositioned, window: win),
                       "an unknown side must never be claimed as the user's own message")
    }

    func testAGroupChatUsesTheBubbleLabelAsTheSender() throws {
        let c = try conversation(MessagesParser().parse(window(groupSenderLabels: true),
                                                      context: context("Weekend Plans")))
        XCTAssertEqual(c.messages[0].sender, "Ada",
                       "Messages puts a group sender in the bubble's accessibility description")
        XCTAssertEqual(c.messages[1].sender, "You")
    }

    func testMessagesAreOrderedTopToBottom() throws {
        let c = try conversation(MessagesParser().parse(window(), context: context("Priya Vantar")))
        XCTAssertEqual(c.messages.map(\.text).first, "are we still on for 4")
    }

    func testEmptyTranscriptIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                        children: [node("AXButton", frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertNil(try MessagesParser().parse(bare, context: context("Priya Vantar")))
    }

    func testUnanchoredBubblesAreNotHandled() throws {
        let unanchored = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                              children: [
            node("AXTextArea", value: "sidebar preview",
                 frame: CGRect(x: 40, y: 100, width: 300, height: 40)),
        ])
        XCTAssertNil(try MessagesParser().parse(unanchored, context: context("Priya Vantar")))
    }

    func testRenderedOutputUsesYouAndNeverTheInternalUserMarker() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(MessagesParser().parse(window(), context: context("Priya Vantar"))),
            style: .full)
        XCTAssertTrue(rendered.contains("(From: You): yes, see you then"))
        XCTAssertFalse(rendered.contains("[user]"))
    }

    func testMessagesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(MessagesParser().parse(try fixture("messages-thread"),
                                                        context: context("Priya Vantar"))),
                     matches: "messages-thread-golden")
    }

    func testMessagesFixtureExcludesSidebarAndSearchText() throws {
        let conversation = try conversation(MessagesParser().parse(
            try fixture("messages-thread"), context: context("Priya Vantar")
        ))
        XCTAssertFalse(conversation.messages.contains { $0.text.contains("Sidebar contact") })
        XCTAssertFalse(conversation.messages.contains { $0.text.contains("Search conversations") })
    }

    func testOffsetMessagesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(MessagesParser().parse(try fixture("messages-offset-thread"),
                                                        context: context("Priya Vantar"))),
                     matches: "messages-offset-thread-golden")
    }
}
