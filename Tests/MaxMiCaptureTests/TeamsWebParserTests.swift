import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TeamsWebParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, domClassList: [String]? = nil,
              domIdentifier: String? = nil, placeholder: String? = nil,
              subrole: String? = nil, url: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: identifier, label: label, subrole: subrole,
               headingLevel: nil, selected: false, placeholder: placeholder, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: domIdentifier)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 400) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// Tier A: DOM-class anchors for container, author, timestamp and body.
    func classedMessage(_ sender: String, _ time: String, _ body: String,
                        y: CGFloat, x: CGFloat) -> AXNode {
        node("AXGroup", domClassList: ["fui-ChatMessage"],
             frame: CGRect(x: x, y: y, width: 700, height: 50), children: [
            text(sender, ["message-author-name"], y: y, x: x),
            text(time, ["message-timestamp"], y: y, x: x + 300),
            node("AXGroup", domClassList: ["fui-ChatMessage__body"],
                 frame: CGRect(x: x, y: y + 20, width: 700, height: 20),
                 children: [text(body, nil, y: y + 20, x: x)]),
        ])
    }

    /// Tier B: no DOM classes; the container is found by identifier prefix and its texts are read
    /// in visual order, so the shared sender heuristic decides the speaker.
    func identifiedMessage(_ texts: [String], y: CGFloat, x: CGFloat,
                           description: String? = nil) -> AXNode {
        node("AXGroup", label: description, identifier: "chat-pane-message-42",
             frame: CGRect(x: x, y: y, width: 700, height: 50),
             children: texts.enumerated().map { index, value in
                 text(value, nil, y: y + CGFloat(index * 18), x: x)
             })
    }

    func chatWindow(origin: CGPoint = .zero, draft: String? = nil,
                    firstBody: String = "index rebuilt") -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            node("AXHeading", value: "Platform team",
                 frame: CGRect(x: x + 400, y: y + 40, width: 400, height: 24)),
            classedMessage("Ada Lovelace", "10:14 AM", firstBody, y: y + 100, x: x + 400),
            classedMessage("Grace Hopper", "10:16 AM", "deploy looks green", y: y + 180, x: x + 400),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft,
                                 domClassList: ["ck-editor__editable"],
                                 frame: CGRect(x: x + 400, y: y + 600, width: 700, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1500, height: 900)),
                    children: children)
    }

    func context(_ title: String? = "Chat | Microsoft Teams",
                 url: String = "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat")
        -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func browserWindow(_ page: AXNode? = nil, url: String) -> AXNode {
        let frame = page?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return node("AXWindow", title: "Browser tab",
                    frame: frame, children: [
            node("AXWebArea", title: "Fallback page", url: url,
                 frame: frame,
                 children: page?.children ?? [text("Readable fallback page.", nil, y: 80, x: 20)]),
        ])
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation, got \(String(describing: content))")
            throw NSError(domain: "ExpectedContentShape", code: 1)
        }
        return c
    }

    // MARK: - Registration and classification

    func testConfigClaimsBothTeamsHosts() {
        XCTAssertEqual(TeamsWebParser.config.hosts,
                       ["teams.microsoft.com", "teams.cloud.microsoft"])
        XCTAssertFalse(TeamsWebParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "teams.microsoft.com") is TeamsWebParser)
        XCTAssertTrue(registry.structuredParser(forHost: "teams.cloud.microsoft") is TeamsWebParser)
    }

    func testClassifyNowRecognizesTheCloudMicrosoftTeamsDomain() {
        XCTAssertEqual(WebAppCaptureParser.classify(
            url: "https://teams.cloud.microsoft/v2/#/conversations/19:abc"), .teams)
        // The three pre-existing cases are unchanged.
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://teams.microsoft.com/v2/"), .teams)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://teams.live.com/v2/"), .teams)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://example.com/"), .generic)
    }

    func testKeyDerivationIsUnchangedForEveryWebHostInThisPhase() throws {
        // §14b keeps every existing thread key stable. `BrowserCapturePipeline` is where a
        // registered host parser's capture gets its source key, so drive each registered parser
        // through its host route and compare that key to the explicitly recorded pre-Phase-D key.
        let cases: [(host: String, parser: String, url: String, prePhaseDKey: String)] = [
            ("mail.google.com", "GmailParser",
             "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWxyz",
             "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWxyz"),
            ("www.linkedin.com", "LinkedInMessagingParser",
             "https://www.linkedin.com/messaging/thread/2-abc123def==",
             "https://www.linkedin.com/messaging/thread/2-abc123def=="),
            ("outlook.office.com", "OutlookWebParser",
             "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00&exvsurl=1",
             "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00"),
            ("app.slack.com", "SlackParser",
             "https://app.slack.com/client/T01/C02/thread/C02-1234",
             "https://app.slack.com/client/T01/C02"),
            ("teams.microsoft.com", "TeamsWebParser",
             "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat",
             "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat"),
        ]
        let registry = ParserRegistry()
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))

        for item in cases {
            XCTAssertNotNil(registry.structuredParser(forHost: item.host), item.host)
            let result = try BrowserCapturePipeline.parse(
                window: browserWindow(url: item.url), windowTitle: "Fallback page", browser: browser
            )
            let keyFromRegisteredParser = result.capture.sourceKey
            let prePhaseDKey = item.prePhaseDKey
            XCTAssertTrue(result.parserID.contains("fallback/\(item.parser)"), item.host)
            XCTAssertEqual(keyFromRegisteredParser, prePhaseDKey, item.host)
        }
    }

    func testTeamsCloudMicrosoftKeepsItsExistingGenericKeyDerivation() {
        XCTAssertEqual(URLKeyNormalizer.normalize("https://teams.microsoft.com/v2/#/x?ctx=chat"),
                       "https://teams.microsoft.com/v2/#/x?ctx=chat",
                       "teams.microsoft.com preserves fragment content unchanged")
        XCTAssertEqual(URLKeyNormalizer.normalize("https://teams.cloud.microsoft/v2/#/x?ctx=chat"),
                       "https://teams.cloud.microsoft/v2/#/x?ctx=chat",
                       "teams.cloud.microsoft keeps today's generic strip: changing it would "
                       + "fork every existing thread on that domain")
    }

    func testHostConversationIsHardBoundedToEightThousandCharacters() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(
                chatWindow(firstBody: String(repeating: "teams body ", count: 1_200)),
                url: context().url!
            ),
            windowTitle: "Chat | Microsoft Teams", browser: browser
        )
        XCTAssertTrue(result.parserID.contains("TeamsWebParser"))
        XCTAssertLessThanOrEqual(result.capture.content.count,
                                 BrowserCapturePipeline.conversationContentCap)
        XCTAssertTrue(result.truncated)
    }

    // MARK: - Messages

    func testClassAnchoredMessagesCarrySenderTimeAndBody() throws {
        let c = try conversation(TeamsWebParser().parse(chatWindow(), context: context()))
        XCTAssertEqual(c.channel, "Platform team")
        XCTAssertFalse(c.isGroup, "Teams exposes no group marker in these anchors")
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace", "Grace Hopper"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
    }

    func testTheUserMarkerBecomesAUserMessageWithoutLeakingTheMarker() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            classedMessage("[user]", "10:18 AM", "joining now", y: 100, x: 400),
        ])
        let c = try conversation(TeamsWebParser().parse(win, context: context()))
        let message = try XCTUnwrap(c.messages.first)
        XCTAssertEqual(message.sender, "You")
        XCTAssertTrue(message.isUser)
        XCTAssertFalse(ContentRenderer.render(.conversation(c), style: .full).contains("[user]"))
    }

    func testIdentifierPrefixContainersAreTheFallbackTier() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage(["Ada Lovelace", "index rebuilt"], y: 100, x: 400),
        ])
        let c = try conversation(TeamsWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
        XCTAssertNil(c.messages[0].timeString, "no timestamp anchor in this tier")
    }

    func testADescriptionOnlyContainerBecomesOneUnattributedMessage() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage([], y: 100, x: 400,
                              description: "Ada Lovelace, 10:14 AM, index rebuilt"),
        ])
        let message = try XCTUnwrap(try conversation(
            try TeamsWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown",
                       "an AXDescription is never parsed into sender and time")
        XCTAssertEqual(message.text, "Ada Lovelace, 10:14 AM, index rebuilt")
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage(["Note: check the doc"], y: 100, x: 400),
        ])
        let message = try XCTUnwrap(try conversation(
            try TeamsWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testAChannelWithNoHeadingFallsBackToTheWindowTitle() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            classedMessage("Ada", "10:14 AM", "hi", y: 100, x: 400),
        ])
        XCTAssertEqual(try conversation(TeamsWebParser().parse(win, context: context())).channel,
                       "Chat | Microsoft Teams")
    }

    // MARK: - Draft, not handled, refusal, origin

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(TeamsWebParser().parse(chatWindow(draft: "joining now"),
                                                       context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.text, "joining now")
        XCTAssertEqual(c.messages.count, 3)
    }

    func testSecureTextInAReadingBodyIsAbsentFromCapturedContentAndRendering() throws {
        let secret = "teams secure body"
        let window = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
                          children: [
            node("AXHeading", value: "Platform team",
                 frame: CGRect(x: 400, y: 40, width: 400, height: 24)),
            node("AXGroup", domClassList: ["fui-ChatMessage"],
                 frame: CGRect(x: 400, y: 100, width: 700, height: 80), children: [
                text("Ada", ["message-author-name"], y: 100),
                text("10:14 AM", ["message-timestamp"], y: 100, x: 700),
                node("AXGroup", domClassList: ["fui-ChatMessage__body"],
                     frame: CGRect(x: 400, y: 120, width: 700, height: 40), children: [
                    text("Visible body.", nil, y: 120),
                    node("AXTextArea", value: secret, subrole: "CustomSecureField",
                         frame: CGRect(x: 400, y: 140, width: 500, height: 20), children: [
                        text(secret, nil, y: 140),
                    ]),
                ]),
            ]),
        ])

        let captured = try XCTUnwrap(TeamsWebParser().parse(window, context: context()))
        let conversation = try conversation(captured)
        XCTAssertFalse(conversation.messages.contains { $0.text.contains(secret) })
        XCTAssertFalse(ContentRenderer.render(captured, style: .full).contains(secret))
    }

    func testATeamsPageWithNoMessageContainerIsNotHandled() throws {
        let calendar = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
                            children: [text("September 2026", nil, y: 60)])
        let parser = TeamsWebParser()
        XCTAssertNil(try parser.parse(calendar, context: context()))
        XCTAssertFalse(parser.refusesEmptyCompose(calendar, context: context()))
    }

    func testAnEmptyComposerWithNoMessagesRefuses() throws {
        let parser = TeamsWebParser()
        let composeOnly = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                               children: [
            node("AXTextArea", value: "   ", domClassList: ["ck-editor__editable"],
                 frame: CGRect(x: 400, y: 600, width: 700, height: 60)),
        ])
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context()))
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    func testAComposerFoundOnlyByItsPlaceholderStillCounts() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            classedMessage("Ada", "10:14 AM", "hi", y: 100, x: 400),
            node("AXTextArea", value: "typing", placeholder: "Type a message",
                 frame: CGRect(x: 400, y: 600, width: 700, height: 60)),
        ])
        let c = try conversation(TeamsWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.last?.text, "typing")
        XCTAssertTrue(c.messages.last?.isDraft == true)
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try TeamsWebParser().parse(chatWindow(), context: context()),
                       try TeamsWebParser().parse(chatWindow(origin: CGPoint(x: 1500, y: 260)),
                                              context: context()))
    }

    // MARK: - Goldens

    func testChatFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(TeamsWebParser().parse(try fixture("teams-web-chat"),
                                                         context: context())),
                     matches: "teams-web-chat-golden")
    }

    func testOffsetChatFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(TeamsWebParser().parse(try fixture("teams-web-offset-chat"),
                                                         context: context())),
                     matches: "teams-web-offset-chat-golden")
    }
}
