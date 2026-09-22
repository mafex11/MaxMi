import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class SlackStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, domClassList: [String]? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 20), focused: false,
               children: children, identifier: nil, label: nil, subrole: nil,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// A DOM-classed Slack window: message list, two virtual-list items, and a composer.
    func domWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: x + 260, y: y, width: 900, height: 700), children: [
                node("AXGroup", domClassList: ["c-virtual_list__item"],
                     frame: CGRect(x: x + 260, y: y + 100, width: 900, height: 40), children: [
                    text("Ada", ["c-message__sender"], y: y + 100, x: x + 260),
                    text("10:14 AM", ["c-timestamp"], y: y + 100, x: x + 700),
                    text("index rebuilt", nil, y: y + 118, x: x + 260),
                ]),
                node("AXGroup", domClassList: ["c-virtual_list__item"],
                     frame: CGRect(x: x + 260, y: y + 160, width: 900, height: 40), children: [
                    text("Grace", ["c-message__sender"], y: y + 160, x: x + 260),
                    text("10:16 AM", ["c-timestamp"], y: y + 160, x: x + 700),
                    text("deploy looks green", nil, y: y + 178, x: x + 260),
                ]),
            ]),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft, domClassList: ["ql-editor"],
                                 frame: CGRect(x: x + 260, y: y + 640, width: 900, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: children)
    }

    /// The pre-DOM shape SlackParserTests already covers: AXRow message rows in an x band.
    func geometryWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXRow", frame: CGRect(x: x + 10, y: y + 90, width: 200, height: 24),
                 children: [text("random-channel", nil, y: y + 90, x: x + 10)]),
            node("AXRow", frame: CGRect(x: x + 240, y: y + 100, width: 900, height: 40),
                 children: [text("Ada", nil, y: y + 100, x: x + 240),
                            text("index rebuilt", nil, y: y + 118, x: x + 240)]),
        ])
    }

    func context(_ title: String?, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigClaimsTheAppAndTheWebHostsAndForcesTheDOMClassList() {
        XCTAssertEqual(SlackParser.config.bundleIDs, [ParserRegistry.slackBundleID])
        XCTAssertEqual(SlackParser.config.hosts, ["app.slack.com", ".slack.com"])
        XCTAssertEqual(SlackParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(SlackParser.config.preferOverNative,
                      "a Slack tab must not fall to the generic web page")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.slackBundleID) is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SlackParser)
    }

    func testChannelNameIsTheFirstTitleComponent() {
        // The EXISTING helpers, reused rather than duplicated (there is no `channelName`).
        XCTAssertEqual(SlackParser().channel(fromTitle: "general - Acme - Slack"), "general")
        XCTAssertEqual(SlackParser().channel(fromTitle: "Huddle"), "Huddle")
        XCTAssertEqual(SlackParser().channel(fromTitle: nil), "unknown")
        XCTAssertTrue(SlackParser().isGroup(fromTitle: "general - Acme - Slack"))
        XCTAssertFalse(SlackParser().isGroup(fromTitle: "Huddle"))
    }

    func testDOMAnchorsProduceSenderAttributedTimestampedMessages() throws {
        let c = try conversation(SlackParser().parse(domWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, false],
                       "Slack's DOM exposes no self marker, so isUser is false for real messages")
        XCTAssertEqual(c.messages.map(\.isDraft), [false, false])
        XCTAssertEqual(c.messages[0].id,
                       Message.makeID(sender: "Ada", timeString: "10:14 AM", text: "index rebuilt"))
    }

    func testComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(SlackParser().parse(domWindow(draft: "shipping in five"),
                                                    context: context("general - Acme - Slack")))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "shipping in five")
        XCTAssertEqual(c.messages.count, 3, "the draft is appended, never replacing a message")
    }

    func testAnEmptyComposerProducesNoDraft() throws {
        let c = try conversation(SlackParser().parse(domWindow(draft: "   "),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.count, 2)
        XCTAssertFalse(c.messages.contains { $0.isDraft })
    }

    func testFallsBackToTheXBandHeuristicWhenNoDOMClassesAreExposed() throws {
        let c = try conversation(SlackParser().parse(geometryWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
        XCTAssertFalse(c.messages.contains { $0.text.contains("random-channel") },
                       "the sidebar band is excluded in the fallback too")
    }

    func testTheXBandFallbackIsWindowRelative() throws {
        let c = try conversation(SlackParser().parse(
            geometryWindow(origin: CGPoint(x: 600, y: 120)),
            context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"],
                       "a floated window must not turn every row into a sidebar row")
    }

    func testDOMResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try SlackParser().parse(domWindow(), context: context("general - Acme - Slack")),
                       try SlackParser().parse(domWindow(origin: CGPoint(x: 1440, y: 220)),
                                           context: context("general - Acme - Slack")))
    }

    func testAWindowWithNeitherAnchorIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(try SlackParser().parse(bare, context: context("x - y - Slack")))
    }

    func testRenderedConversationUsesYouForTheDraftAndNeverTheInternalUserMarker() throws {
        let content = try XCTUnwrap(SlackParser().parse(domWindow(draft: "shipping in five"),
                                                       context: context("general - Acme - Slack")))
        let rendered = ContentRenderer.render(content, style: .full)
        XCTAssertTrue(rendered.contains("(From: You (draft)): shipping in five"))
        XCTAssertFalse(rendered.contains("[user]"))
    }

    func testDOMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-dom-messages"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-dom-messages-golden")
    }

    func testOffsetNoDOMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-offset-no-dom"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-offset-no-dom-golden")
    }
}
