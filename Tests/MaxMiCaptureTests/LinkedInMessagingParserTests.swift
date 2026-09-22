import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class LinkedInMessagingParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              domClassList: [String]? = nil, url: String? = nil, frame: CGRect? = nil,
              subrole: String? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: subrole,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 400) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// One `li` per group, in LinkedIn's real shape: the first `li` of a group carries the name
    /// and timestamp, and a continuation `li` carries only a body.
    func event(name: String?, time: String?, bodies: [String], y: CGFloat, x: CGFloat) -> AXNode {
        var children: [AXNode] = []
        if let name { children.append(text(name, ["msg-s-message-group__name"], y: y, x: x)) }
        if let time {
            children.append(text(time, ["msg-s-message-group__timestamp"], y: y, x: x + 200))
        }
        for (index, body) in bodies.enumerated() {
            children.append(node("AXGroup", domClassList: ["msg-s-event-listitem__body"],
                                 frame: CGRect(x: x, y: y + 20 + CGFloat(index * 20),
                                               width: 400, height: 18),
                                 children: [text(body, nil, y: y + 20 + CGFloat(index * 20), x: x)]))
        }
        return node("AXGroup", domClassList: ["msg-s-message-list__event"],
                    frame: CGRect(x: x, y: y, width: 500, height: CGFloat(40 + bodies.count * 20)),
                    children: children)
    }

    /// The messaging thread: two groups from the contact, one from the signed-in user, plus a
    /// continuation `li` under the first group, an entity title and an optional composer.
    func messagingWindow(origin: CGPoint = .zero, draft: String? = nil,
                         selfName: String? = "Sam Rivers",
                         firstBody: String = "Sending the deck over.") -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            text("Ada Lovelace", ["msg-entity-lockup__entity-title"], y: y + 60, x: x + 400),
            event(name: "Ada Lovelace", time: "10:14 AM",
                  bodies: [firstBody], y: y + 100, x: x + 400),
            event(name: nil, time: nil, bodies: ["Ignore the first slide."],
                  y: y + 160, x: x + 400),
            event(name: "Sam Rivers", time: "10:22 AM", bodies: ["Got it, thanks."],
                  y: y + 220, x: x + 400),
        ]
        if let selfName {
            children.insert(node("AXImage", label: "Photo of \(selfName)",
                                 domClassList: ["global-nav__me-photo"],
                                 frame: CGRect(x: x + 1200, y: y + 10, width: 24, height: 24)),
                            at: 0)
        }
        if let draft {
            children.append(node("AXTextArea", value: draft,
                                 domClassList: ["msg-form__contenteditable"],
                                 frame: CGRect(x: x + 400, y: y + 500, width: 500, height: 60)))
        }
        return node("AXWindow", title: "Messaging | LinkedIn",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    /// The LinkedIn feed: no message events anywhere.
    func feedWindow() -> AXNode {
        node("AXWindow", title: "Feed | LinkedIn",
             frame: CGRect(x: 0, y: 0, width: 1440, height: 900), children: [
            text("Ada Lovelace posted a photo", nil, y: 100),
        ])
    }

    static let threadURL = "https://www.linkedin.com/messaging/thread/2-abc123def=="

    func context(_ title: String? = "Messaging | LinkedIn",
                 url: String = LinkedInMessagingParserTests.threadURL) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func browserWindow(_ page: AXNode, url: String) -> AXNode {
        let frame = page.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return node("AXWindow", title: page.title, frame: frame, children: [
            node("AXWebArea", url: url, frame: frame, children: page.children),
        ])
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    // MARK: - Registration and routing

    func testConfigClaimsBothLinkedInHosts() {
        XCTAssertEqual(LinkedInMessagingParser.config.hosts, ["www.linkedin.com", "linkedin.com"])
        XCTAssertEqual(LinkedInMessagingParser.config.bundleIDs, [])
        XCTAssertFalse(LinkedInMessagingParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "www.linkedin.com")
                        is LinkedInMessagingParser)
        XCTAssertTrue(registry.structuredParser(forHost: "linkedin.com")
                        is LinkedInMessagingParser)
    }

    func testEveryLinkedInPageThatIsNotMessagingIsNotHandled() throws {
        let parser = LinkedInMessagingParser()
        XCTAssertNil(try parser.parse(feedWindow(),
                                      context: context("Feed | LinkedIn",
                                                       url: "https://www.linkedin.com/feed/")))
        // Even a page that DOES expose message events stays generic off /messaging: the notification
        // rail on the feed renders the same classes.
        XCTAssertNil(try parser.parse(messagingWindow(),
                                      context: context(url: "https://www.linkedin.com/feed/")))
        XCTAssertFalse(parser.refusesEmptyCompose(
            feedWindow(), context: context(url: "https://www.linkedin.com/feed/")))
    }

    func testTheMessagingPathIsMatchedByPrefixSoASubPathStillParses() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(), context: context(url: "https://www.linkedin.com/messaging/")))
        XCTAssertFalse(c.messages.isEmpty)
    }

    // MARK: - Messages

    func testGroupsBecomeAttributedMessagesAndAContinuationInheritsItsGroup() throws {
        let c = try conversation(LinkedInMessagingParser().parse(messagingWindow(),
                                                                  context: context()))
        XCTAssertEqual(c.channel, "Ada Lovelace")
        XCTAssertEqual(c.messages.map(\.sender),
                       ["Ada Lovelace", "Ada Lovelace", "Sam Rivers"])
        XCTAssertEqual(c.messages.map(\.text),
                       ["Sending the deck over.", "Ignore the first slide.", "Got it, thanks."])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:14 AM", "10:22 AM"])
    }

    func testIsUserIsTrueOnlyForTheSignedInUsersOwnGroup() throws {
        let c = try conversation(LinkedInMessagingParser().parse(messagingWindow(),
                                                                  context: context()))
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, true])
        XCTAssertTrue(ContentRenderer.render(.conversation(c), style: .full)
            .contains("(From: You)(sent 10:22 AM): Got it, thanks."))
    }

    func testAnUnresolvableSelfNameMakesEveryMessageIsUserFalse() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(selfName: nil), context: context()))
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, false],
                       "isUser is never guessed from geometry (§14b)")
        XCTAssertEqual(c.messages.last?.sender, "Sam Rivers")
    }

    func testUserMarkerBecomesAUserMessageWithoutLeakingTheMarker() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            event(name: "[user]", time: "10:22 AM", bodies: ["Got it, thanks."], y: 100, x: 400),
        ])
        let c = try conversation(LinkedInMessagingParser().parse(win, context: context()))
        let message = try XCTUnwrap(c.messages.first)
        XCTAssertEqual(message.sender, "You")
        XCTAssertTrue(message.isUser)
        XCTAssertFalse(ContentRenderer.render(.conversation(c), style: .full).contains("[user]"))
    }

    func testSignedInNameStripsThePhotoOfPrefix() {
        XCTAssertEqual(LinkedInMessagingParser.signedInName(in: messagingWindow()), "Sam Rivers")
        XCTAssertNil(LinkedInMessagingParser.signedInName(in: messagingWindow(selfName: nil)))
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            event(name: nil, time: nil, bodies: ["Note: check the doc"], y: 100, x: 400),
        ])
        let message = try XCTUnwrap(try conversation(
            LinkedInMessagingParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testAChannelWithNoEntityTitleFallsBackToTheWindowTitle() throws {
        let win = node("AXWindow", title: "Messaging | LinkedIn",
                       frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            event(name: "Ada", time: nil, bodies: ["hi"], y: 100, x: 400),
        ])
        XCTAssertEqual(try conversation(LinkedInMessagingParser().parse(win, context: context()))
                        .channel, "Messaging | LinkedIn")
    }

    // MARK: - Draft, not-handled, refusal

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(draft: "on my way"), context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "on my way")
        XCTAssertEqual(c.messages.count, 4)
    }

    func testSecureTextInAReadingBodyIsAbsentFromCapturedContentAndRendering() throws {
        let secret = "linkedin secure body"
        let body = node("AXGroup", domClassList: ["msg-s-event-listitem__body"],
                        frame: CGRect(x: 400, y: 120, width: 500, height: 40), children: [
            text("Visible body.", nil, y: 120),
            node("AXTextArea", value: secret,
                 frame: CGRect(x: 400, y: 140, width: 500, height: 20),
                 subrole: "CustomSecureField", children: [
                    text(secret, nil, y: 140),
                 ]),
        ])
        let window = node("AXWindow", title: "Messaging | LinkedIn",
                          frame: CGRect(x: 0, y: 0, width: 1440, height: 900), children: [
            text("Ada", ["msg-entity-lockup__entity-title"], y: 60),
            node("AXGroup", domClassList: ["msg-s-message-list__event"],
                 frame: CGRect(x: 400, y: 100, width: 500, height: 80), children: [
                text("Ada", ["msg-s-message-group__name"], y: 100),
                text("10:14 AM", ["msg-s-message-group__timestamp"], y: 100, x: 600),
                body,
            ]),
        ])

        let captured = try XCTUnwrap(LinkedInMessagingParser().parse(window, context: context()))
        let conversation = try conversation(captured)
        XCTAssertFalse(conversation.messages.contains { $0.text.contains(secret) })
        XCTAssertFalse(ContentRenderer.render(captured, style: .full).contains(secret))
    }

    func testAMessagingPageWithNoEventsIsNotHandled() throws {
        let empty = node("AXWindow", title: "Messaging | LinkedIn",
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         children: [text("No conversations yet", nil, y: 100)])
        XCTAssertNil(try LinkedInMessagingParser().parse(empty, context: context()))
    }

    func testAnEmptyComposerWithNoEventsRefuses() throws {
        let parser = LinkedInMessagingParser()
        let composeOnly = node("AXWindow", title: "Messaging | LinkedIn",
                               frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXTextArea", value: "  ", domClassList: ["msg-form__contenteditable"],
                 frame: CGRect(x: 400, y: 500, width: 500, height: 60)),
        ])
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context()))
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    // MARK: - Kind, key, origin, goldens

    func testTheHostKeepsItsConversationKindAndItsExistingKey() {
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.threadURL), .linkedin)
        // §14b keeps the key derivation exactly as it is today: the thread path is truncated to
        // three components, so a scroll or a query param cannot fork the thread.
        XCTAssertEqual(URLKeyNormalizer.normalize(Self.threadURL),
                       URLKeyNormalizer.normalize(Self.threadURL + "?focus=true"))
        XCTAssertTrue(URLKeyNormalizer.normalize(Self.threadURL).hasPrefix(
            "https://www.linkedin.com/messaging/thread"))
    }

    func testHostConversationIsHardBoundedToEightThousandCharacters() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(
                messagingWindow(firstBody: String(repeating: "linkedin body ", count: 1_000)),
                url: Self.threadURL
            ),
            windowTitle: "Messaging | LinkedIn", browser: browser
        )
        XCTAssertTrue(result.parserID.contains("LinkedInMessagingParser"))
        XCTAssertLessThanOrEqual(result.capture.content.count,
                                 BrowserCapturePipeline.conversationContentCap)
        XCTAssertTrue(result.truncated)
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = LinkedInMessagingParser()
        XCTAssertEqual(try parser.parse(messagingWindow(), context: context()),
                       try parser.parse(messagingWindow(origin: CGPoint(x: 1440, y: 220)),
                                        context: context()))
    }

    func testMessagingFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(LinkedInMessagingParser().parse(
            try fixture("linkedin-messaging"), context: context())),
                     matches: "linkedin-messaging-golden")
    }

    func testOffsetMessagingFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(LinkedInMessagingParser().parse(
            try fixture("linkedin-offset-messaging"), context: context())),
                     matches: "linkedin-offset-messaging-golden")
    }
}
