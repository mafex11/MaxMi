import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredConversationParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func messages(_ content: CapturedContent?) throws -> [Message] {
        guard case .conversation(let conversation) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation")
            return []
        }
        return conversation.messages
    }

    func testSlackFixtureProducesSenderAttributedMessages() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let structured = try SlackParser().parseStructured(window: try fixture("slack-window"), app: app)
        let messages = try messages(structured)
        XCTAssertEqual(messages.map(\.sender), ["Alice", "Bob"])
        XCTAssertEqual(messages.map(\.text), ["shipped the build", "deploy looks green"])
        XCTAssertFalse(messages.contains { $0.isUser || $0.isDraft })
        XCTAssertEqual(messages.map(\.id), messages.map {
            Message.makeID(sender: $0.sender, timeString: nil, text: $0.text)
        })
    }

    func testSlackChannelAndGroupComeFromTheWindowTitle() {
        let parser = SlackParser()
        XCTAssertEqual(parser.channel(fromTitle: "general - Acme - Slack"), "general")
        XCTAssertTrue(parser.isGroup(fromTitle: "general - Acme - Slack"))
        XCTAssertEqual(parser.channel(fromTitle: "Ana Ruiz"), "Ana Ruiz")
        XCTAssertFalse(parser.isGroup(fromTitle: "Ana Ruiz"))
        XCTAssertEqual(parser.channel(fromTitle: nil), "unknown")
        XCTAssertFalse(parser.isGroup(fromTitle: nil))
    }

    func testSlackCaptureContentIsTheRenderedConversation() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let capture = try XCTUnwrap(try SlackParser().parse(window: try fixture("slack-window"), app: app))
        XCTAssertEqual(capture.content,
                       "(From: Alice): shipped the build\n(From: Bob): deploy looks green")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.sourceKey, "slack:acme/general")
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
    }

    func testSlackStructuredOutputIsCappedByDroppingOldestMessages() throws {
        var rows: [AXNode] = []
        for index in 0..<400 {
            let y = CGFloat(index) * 20
            rows.append(AXNode(
                role: "AXRow", value: nil, title: nil, url: nil,
                frame: CGRect(x: 400, y: y, width: 800, height: 20), focused: false,
                children: [
                    AXNode(role: "AXStaticText", value: "Person\(index)", title: nil, url: nil,
                           frame: CGRect(x: 400, y: y, width: 100, height: 16), focused: false,
                           children: []),
                    AXNode(role: "AXStaticText", value: String(repeating: "x", count: 60),
                           title: nil, url: nil,
                           frame: CGRect(x: 520, y: y, width: 400, height: 16), focused: false,
                           children: []),
                ]))
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: rows)
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
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
        let window = try fixture("whatsapp-conversation")
        let structured = try WhatsAppParser().parseStructured(window: window, app: app)
        guard case .conversation(let conversation) = try XCTUnwrap(structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Project Group")
        XCTAssertFalse(conversation.isGroup, "no group marker is exposed by the AX walk yet")
        XCTAssertEqual(conversation.messages.map(\.sender), ["Alex", "You"])
        XCTAssertEqual(conversation.messages.map(\.text), ["Morning update", "I am reviewing it"])
        XCTAssertEqual(conversation.messages.map(\.isUser), [false, true],
                       "WhatsApp labels the user's own bubbles \"You\", which is a real signal")

        let capture = try XCTUnwrap(try WhatsAppParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "whatsapp:project-group")
        XCTAssertEqual(capture.sourceTitle, "Project Group")
        XCTAssertEqual(capture.content,
                       "(From: Alex): Morning update\n(From: You): I am reviewing it")
        XCTAssertEqual(capture.contentKind, .conversation)
    }

    func testSingleTextRowBecomesAnUnknownSenderMessage() throws {
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
        let messages = try messages(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertEqual(messages.map(\.sender), ["unknown"])
        XCTAssertEqual(messages.map(\.text), ["system joined the channel"])
    }

    /// A one-label bubble must not be split on ": ": "Note: check the doc" is a message, not a
    /// message from someone called "Note". Only a bubble that exposes a separate sender label
    /// gets an attributed sender.
    func testWhatsAppAttributesSendersOnlyWhereTheBubbleExposesOne() throws {
        func bubble(_ id: String, _ y: CGFloat, _ texts: [String]) -> AXNode {
            AXNode(role: "AXGroup", value: nil, title: nil, url: nil,
                   frame: CGRect(x: 400, y: y, width: 500, height: 40), focused: false,
                   children: texts.enumerated().map { offset, text in
                       AXNode(role: "AXStaticText", value: text, title: nil, url: nil,
                              frame: CGRect(x: 420 + CGFloat(offset) * 120, y: y,
                                            width: 100, height: 20),
                              focused: false, children: [])
                   },
                   identifier: id)
        }
        let window = AXNode(
            role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
            children: [
                AXNode(role: "AXHeading", value: "Project Group", title: nil, url: nil,
                       frame: CGRect(x: 400, y: 20, width: 300, height: 30), focused: false,
                       children: [], identifier: "conversation-header"),
                bubble("message-1", 200, ["Note: check the doc"]),
                bubble("message-2", 260, ["Alice", "hi"]),
                bubble("message-3", 320, ["You", "on it"]),
            ]
        )
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                          windowTitle: "WhatsApp")
        let messages = try messages(try WhatsAppParser().parseStructured(window: window, app: app))
        XCTAssertEqual(messages.map(\.sender), ["unknown", "Alice", "You"])
        XCTAssertEqual(messages.map(\.text), ["Note: check the doc", "hi", "on it"])
        XCTAssertEqual(messages.map(\.isUser), [false, false, true])
        let capture = try XCTUnwrap(try WhatsAppParser().parse(window: window, app: app))
        XCTAssertEqual(capture.content, """
            (From: unknown): Note: check the doc
            (From: Alice): hi
            (From: You): on it
            """)
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
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        XCTAssertNil(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertNil(try SlackParser().parse(window: window, app: app))
    }
}
