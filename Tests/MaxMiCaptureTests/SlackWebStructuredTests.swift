import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class SlackWebStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              domClassList: [String]? = nil, url: String? = nil, frame: CGRect? = nil,
              subrole: String? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 300, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: subrole,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String?, _ classes: [String]? = nil, label: String? = nil,
              y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, label: label, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// The web tree: a message list of `c-message_kit__background` items whose timestamps carry
    /// the readable time in their AXDescription only, plus a header channel title.
    func webWindow(origin: CGPoint = .zero, headerTitle: String? = "#general",
                   draft: String? = nil, firstBody: String = "index rebuilt") -> AXNode {
        let x = origin.x
        let y = origin.y
        func item(_ sender: String, _ time: String, _ body: String, y itemY: CGFloat) -> AXNode {
            node("AXGroup", domClassList: ["c-virtual_list__item"],
                 frame: CGRect(x: x + 260, y: itemY, width: 900, height: 40), children: [
                node("AXGroup", domClassList: ["c-message_kit__background"],
                     frame: CGRect(x: x + 260, y: itemY, width: 900, height: 40), children: [
                    text(sender, ["c-message__sender"], y: itemY, x: x + 260),
                    // Slack web puts the readable time in the timestamp's aria-label.
                    text(nil, ["c-timestamp"], label: time, y: itemY, x: x + 700),
                    node("AXGroup", domClassList: ["p-rich_text_section"],
                         frame: CGRect(x: x + 260, y: itemY + 18, width: 900, height: 18),
                         children: [text(body, nil, y: itemY + 18, x: x + 260)]),
                ]),
            ])
        }
        var children: [AXNode] = []
        if let headerTitle {
            children.append(text(headerTitle, ["p-view_header__channel_title"],
                                 y: y + 40, x: x + 260))
        }
        children.append(node("AXGroup", domClassList: ["c-message_list"],
                             frame: CGRect(x: x + 260, y: y + 80, width: 900, height: 600),
                             children: [
            item("Ada", "10:14 AM", firstBody, y: y + 100),
            item("Grace", "10:16 AM", "deploy looks green", y: y + 160),
        ]))
        if let draft {
            children.append(node("AXTextArea", value: draft, domClassList: ["ql-editor"],
                                 frame: CGRect(x: x + 260, y: y + 700, width: 900, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: children)
    }

    /// The native tree for the SAME two messages: no header, time in the value, no message_kit
    /// wrapper. This is Task 10's shape.
    func nativeWindow() -> AXNode {
        func item(_ sender: String, _ time: String, _ body: String, y: CGFloat) -> AXNode {
            node("AXGroup", domClassList: ["c-virtual_list__item"],
                 frame: CGRect(x: 260, y: y, width: 900, height: 40), children: [
                text(sender, ["c-message__sender"], y: y, x: 260),
                text(time, ["c-timestamp"], y: y, x: 700),
                text(body, nil, y: y + 18, x: 260),
            ])
        }
        return node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 900, height: 600),
                 children: [item("Ada", "10:14 AM", "index rebuilt", y: 100),
                            item("Grace", "10:16 AM", "deploy looks green", y: 160)]),
        ])
    }

    func context(_ title: String?, url: String? = "https://app.slack.com/client/T01/C02")
        -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func browserWindow(_ page: AXNode, url: String) -> AXNode {
        let frame = page.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return node("AXWindow", frame: frame, children: [
            node("AXWebArea", url: url, frame: frame, children: page.children),
        ])
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    // MARK: - Anchors

    func testWebItemsProduceSenderTimeAndBodyWithTheTimeFromTheDescription() throws {
        let c = try conversation(SlackParser().parse(webWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"],
                       "the web timestamp carries its time in AXDescription, not in the value")
        XCTAssertFalse(c.messages.contains { $0.text.contains("Ada") },
                       "the sender node's text never leaks into the body")
    }

    func testAMessageKitOnlyTreeIsStillRead() throws {
        // Some Slack builds expose the message_kit background without a virtual_list wrapper.
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 900, height: 200), children: [
                node("AXGroup", domClassList: ["c-message_kit__background"],
                     frame: CGRect(x: 260, y: 100, width: 900, height: 40), children: [
                    text("Ada", ["c-message__sender"], y: 100, x: 260),
                    text(nil, ["c-timestamp"], label: "10:14 AM", y: 100, x: 700),
                    text("index rebuilt", nil, y: 118, x: 260),
                ]),
            ]),
        ])
        let c = try conversation(SlackParser().parse(win, context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
    }

    // MARK: - Channel and isGroup

    func testHeaderChannelDrivesTheChannelNameAndIsGroup() throws {
        let channel = try conversation(SlackParser().parse(
            webWindow(headerTitle: "#general"), context: context("general - Acme - Slack")))
        XCTAssertEqual(channel.channel, "general", "the leading # is the group marker, not the name")
        XCTAssertTrue(channel.isGroup)

        let dm = try conversation(SlackParser().parse(
            webWindow(headerTitle: "Ada Lovelace"), context: context("Ada Lovelace - Acme - Slack")))
        XCTAssertEqual(dm.channel, "Ada Lovelace")
        XCTAssertFalse(dm.isGroup, "a DM header has no leading #")
    }

    func testWithNoHeaderAnchorTheTitleNamesTheChannelAndIsGroupStaysTrue() throws {
        let c = try conversation(SlackParser().parse(webWindow(headerTitle: nil),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup, "unchanged from Task 10: no header means treat it as a channel")
    }

    // MARK: - Byte-identical rendering

    func testWebAndNativeRenderByteIdenticallyFromEquivalentTrees() throws {
        let web = try XCTUnwrap(SlackParser().parse(webWindow(),
                                                   context: context("general - Acme - Slack")))
        let native = try XCTUnwrap(SlackParser().parse(
            nativeWindow(),
            context: ParseContext(app: AppInfo(bundleID: ParserRegistry.slackBundleID,
                                               name: "Slack",
                                               windowTitle: "general - Acme - Slack"))))
        XCTAssertEqual(ContentRenderer.render(web, style: .full),
                       ContentRenderer.render(native, style: .full))
        XCTAssertEqual(ContentRenderer.render(web, style: .full),
                       "(From: Ada)(sent 10:14 AM): index rebuilt\n"
                       + "(From: Grace)(sent 10:16 AM): deploy looks green")
    }

    // MARK: - Draft, routing, refusal, origin

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(SlackParser().parse(webWindow(draft: "shipping in five"),
                                                    context: context("general - Acme - Slack")))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(c.messages.count, 3)
    }

    func testSecureTextInAReadingBodyIsAbsentFromCapturedContentAndRendering() throws {
        let secret = "slack secure body"
        let window = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                          children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 900, height: 600), children: [
                node("AXGroup", domClassList: ["c-virtual_list__item"],
                     frame: CGRect(x: 260, y: 100, width: 900, height: 80), children: [
                    node("AXGroup", domClassList: ["c-message_kit__background"],
                         frame: CGRect(x: 260, y: 100, width: 900, height: 80), children: [
                        text("Ada", ["c-message__sender"], y: 100, x: 260),
                        text(nil, ["c-timestamp"], label: "10:14 AM", y: 100, x: 700),
                        text("Visible body.", nil, y: 120, x: 260),
                        node("AXTextArea", value: secret,
                             frame: CGRect(x: 260, y: 140, width: 600, height: 20),
                             subrole: "CustomSecureField", children: [
                            text(secret, nil, y: 140, x: 260),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let captured = try XCTUnwrap(SlackParser().parse(
            window, context: context("general - Acme - Slack")
        ))
        let conversation = try conversation(captured)
        XCTAssertFalse(conversation.messages.contains { $0.text.contains(secret) })
        XCTAssertFalse(ContentRenderer.render(captured, style: .full).contains(secret))
    }

    func testTheSlackHostsStillRouteToSlackParser() {
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SlackParser)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://app.slack.com/client/T01/C02"),
                       .slack)
    }

    func testHostConversationIsHardBoundedToEightThousandCharacters() throws {
        let url = "https://app.slack.com/client/T01/C02"
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(
                webWindow(firstBody: String(repeating: "slack body ", count: 1_200)),
                url: url
            ),
            windowTitle: "general - Acme - Slack", browser: browser
        )
        XCTAssertTrue(result.parserID.contains("SlackParser"))
        XCTAssertLessThanOrEqual(result.capture.content.count,
                                 BrowserCapturePipeline.conversationContentCap)
        XCTAssertTrue(result.truncated)
    }

    func testAnUnrelatedHostNeverRoutesToSlackParser() {
        XCTAssertFalse(ParserRegistry().structuredParser(forHost: "example.com") is SlackParser)
    }

    func testAppSlackWithAnEmptyComposerAndNoMessagesRefuses() throws {
        let parser = SlackParser()
        let composeOnly = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                               children: [
            node("AXTextArea", value: "   ", domClassList: ["ql-editor"],
                 frame: CGRect(x: 260, y: 600, width: 900, height: 60)),
        ])
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context("Acme - Slack"))) {
            XCTAssertEqual($0 as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context("Acme - Slack")))
    }

    func testNativeSlackWithAnEmptyComposerAndMessagesReturnsAConversationWithoutRefusal() throws {
        let native = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                          children: nativeWindow().children + [
            node("AXTextArea", value: "   ", domClassList: ["ql-editor"],
                 frame: CGRect(x: 260, y: 700, width: 900, height: 60)),
        ])
        let nativeContext = ParseContext(
            app: AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                         windowTitle: "general - Acme - Slack")
        )
        let parser = SlackParser()

        XCTAssertNotNil(try parser.parse(native, context: nativeContext))
        XCTAssertFalse(parser.refusesEmptyCompose(native, context: nativeContext))
    }

    func testAMessageListWithNoMessagesIsNotHandledAndNotRefused() throws {
        let parser = SlackParser()
        let empty = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 600, height: 400)),
        ])
        XCTAssertNil(try parser.parse(empty, context: context("Acme - Slack")))
        XCTAssertFalse(parser.refusesEmptyCompose(empty, context: context("Acme - Slack")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try SlackParser().parse(webWindow(), context: context("general - Acme - Slack")),
                       try SlackParser().parse(webWindow(origin: CGPoint(x: 1440, y: 220)),
                                           context: context("general - Acme - Slack")))
    }

    // MARK: - Goldens

    func testWebChannelFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-web-channel"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-web-channel-golden")
    }

    func testOffsetWebDMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-web-offset-dm"),
                                                      context: context("Ada Lovelace - Acme - Slack"))),
                     matches: "slack-web-offset-dm-golden")
    }
}
