import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredConversationParserTests: XCTestCase {
    func messages(_ content: CapturedContent?) throws -> [Message] {
        guard case .conversation(let conversation) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation")
            return []
        }
        return conversation.messages
    }

    func testSlackFixtureProducesSenderAttributedMessages() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "#general - Acme - Slack")
        let structured = try SlackParser().parseStructured(
            window: try fixture("slack-dom-messages"), app: app
        )
        let messages = try messages(structured)
        XCTAssertEqual(messages.map(\.sender), ["Arin", "Bela", "You"])
        XCTAssertEqual(messages.map(\.text),
                       ["cache warmup finished", "queue is clear", "I will verify the report"])
        XCTAssertTrue(messages.last?.isUser == true)
        XCTAssertTrue(messages.last?.isDraft == true)
    }

    func testSlackChannelAndGroupComeFromTheWindowTitle() {
        let parser = SlackParser()
        XCTAssertEqual(parser.channel(fromTitle: "#general - Acme - Slack"), "general")
        XCTAssertTrue(parser.isGroup(fromTitle: "#general - Acme - Slack"))
        XCTAssertEqual(parser.channel(fromTitle: "Ana Ruiz"), "Ana Ruiz")
        XCTAssertFalse(parser.isGroup(fromTitle: "Ana Ruiz"))
        XCTAssertEqual(parser.channel(fromTitle: nil), "unknown")
        XCTAssertFalse(parser.isGroup(fromTitle: nil))
    }

    func testSlackCaptureContentIsTheRenderedConversation() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "#general - Acme - Slack")
        let capture = try XCTUnwrap(try SlackParser().parse(
            window: try fixture("slack-dom-messages"), app: app
        ))
        XCTAssertEqual(capture.content,
                       """
                       (From: Arin)(sent 09:12 AM): cache warmup finished
                       (From: Bela)(sent 09:14 AM): queue is clear
                       (From: You (draft)): I will verify the report
                       """)
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.sourceKey, "slack:acme/general")
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
    }

    func testSlackCaptureIsHardBoundedAfterTheStructuredParse() throws {
        var items: [AXNode] = []
        for index in 0..<400 {
            let y = CGFloat(index) * 20
            items.append(AXNode(
                role: "AXGroup", value: nil, title: nil, url: nil,
                frame: CGRect(x: 400, y: y, width: 800, height: 20), focused: false,
                children: [
                    AXNode(role: "AXStaticText", value: "Person\(index)", title: nil, url: nil,
                           frame: CGRect(x: 400, y: y, width: 100, height: 16), focused: false,
                           children: [], domClassList: ["c-message__sender"]),
                    AXNode(role: "AXStaticText", value: String(repeating: "x", count: 60),
                           title: nil, url: nil,
                           frame: CGRect(x: 520, y: y, width: 400, height: 16), focused: false,
                           children: []),
                ],
                domClassList: ["c-virtual_list__item"]))
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [
                                AXNode(role: "AXGroup", value: nil, title: nil, url: nil,
                                       frame: CGRect(x: 400, y: 0, width: 800, height: 800),
                                       focused: false, children: items,
                                       domClassList: ["c-message_list"]),
                            ])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "#general - Acme - Slack")
        let structured = try XCTUnwrap(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertGreaterThan(ContentRenderer.render(structured, style: .full).count, SlackParser.contentCap)
        let capture = try XCTUnwrap(try SlackParser().parse(window: window, app: app))
        XCTAssertLessThanOrEqual(capture.content.count, SlackParser.contentCap)
        XCTAssertTrue(capture.content.contains("Person399"), "newest survives")
        XCTAssertFalse(capture.content.contains("Person0"), "oldest is dropped")
        let messages = try messages(capture.structured)
        XCTAssertEqual(messages.last?.sender, "Person399")
    }

    func testWhatsAppFixtureProducesTypedMessagesAndKeepsItsKey() throws {
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                          windowTitle: "WhatsApp")
        let window = try fixture("whatsapp-direct-senders")
        let structured = try WhatsAppParser().parseStructured(window: window, app: app)
        guard case .conversation(let conversation) = try XCTUnwrap(structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Priya Vantar")
        XCTAssertFalse(conversation.isGroup)
        XCTAssertEqual(conversation.messages.map(\.sender), ["Priya Vantar", "You"])
        XCTAssertEqual(conversation.messages.map(\.text), ["are we still on for 4", "yes, see you then"])
        XCTAssertEqual(conversation.messages.map(\.isUser), [false, true],
                       "WhatsApp identifies outgoing messages by bubble side")

        let capture = try XCTUnwrap(try WhatsAppParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "whatsapp:priya-vantar")
        XCTAssertEqual(capture.sourceTitle, "Priya Vantar")
        XCTAssertEqual(capture.content,
                       """
                       (From: Priya Vantar)(sent 16:02): are we still on for 4
                       (From: You)(sent 16:04): yes, see you then
                       """)
        XCTAssertEqual(capture.contentKind, .conversation)
    }

    func testUnanchoredSlackRowsAreNotHandled() throws {
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 400, y: 10, width: 800, height: 20), focused: false,
                         children: [
            AXNode(role: "AXStaticText", value: "system joined the channel", title: nil, url: nil,
                   frame: CGRect(x: 400, y: 10, width: 400, height: 16), focused: false, children: []),
        ])
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [row])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        XCTAssertNil(try SlackParser().parseStructured(window: window, app: app))
    }

    /// Teams has no such label convention, so a single-label row is never split.
    func testTeamsNeverSplitsASingleLabelRow() throws {
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 400, y: 200, width: 500, height: 40), focused: false,
                         children: [
            AXNode(role: "AXStaticText", value: "Alex: hi", title: nil, url: nil,
                   frame: CGRect(x: 420, y: 200, width: 200, height: 20), focused: false,
                   children: []),
        ])
        let window = AXNode(role: "AXWindow", value: nil, title: "Microsoft Teams", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
                            children: [row])
        let app = AppInfo(bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
                          windowTitle: "Alex")
        let messages = try messages(try TeamsParser().parseStructured(window: window, app: app))
        XCTAssertEqual(messages.map(\.sender), ["unknown"])
        XCTAssertEqual(messages.map(\.text), ["Alex: hi"])
    }

    /// Teams exposes no "You" label, so the same sender name is not an outgoing signal there.
    func testTeamsDoesNotTreatASenderCalledYouAsTheUser() throws {
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 400, y: 200, width: 500, height: 40), focused: false,
                         children: [
            AXNode(role: "AXStaticText", value: "You", title: nil, url: nil,
                   frame: CGRect(x: 420, y: 200, width: 60, height: 20), focused: false, children: []),
            AXNode(role: "AXStaticText", value: "standup at ten", title: nil, url: nil,
                   frame: CGRect(x: 500, y: 200, width: 200, height: 20), focused: false, children: []),
        ])
        let window = AXNode(role: "AXWindow", value: nil, title: "Microsoft Teams", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
                            children: [row])
        let app = AppInfo(bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
                          windowTitle: "Platform Team")
        let messages = try messages(try TeamsParser().parseStructured(window: window, app: app))
        XCTAssertEqual(messages.map(\.sender), ["You"])
        XCTAssertEqual(messages.map(\.isUser), [false])
    }

    func testEmptyMessageAreaStillReturnsNilSoDispatchCanFallThrough() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "#general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "#general - Acme - Slack")
        XCTAssertNil(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertNil(try SlackParser().parse(window: window, app: app))
    }
}
