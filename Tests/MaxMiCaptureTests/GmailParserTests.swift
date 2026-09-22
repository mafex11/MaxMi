import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GmailParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              selected: Bool = false, domClassList: [String]? = nil, url: String? = nil,
              subrole: String? = nil, frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: subrole,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    func heading(_ value: String, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXHeading", value: value, frame: CGRect(x: x, y: y, width: 400, height: 24))
    }

    func composeEditor(_ draft: String?, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXTextArea", value: draft, label: "Message Body",
             frame: CGRect(x: x, y: y, width: 500, height: 120))
    }

    /// One EXPANDED message (has an `a3s` body), one COLLAPSED message (no body node at all),
    /// plus the thread subject as a heading and Gmail's own chrome heading above it.
    func threadWindow(origin: CGPoint = .zero, draft: String? = nil,
                      sender: String = "Ada Lovelace") -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            heading("Main menu", y: y + 10, x: x + 20),
            heading("Quarterly index rebuild", y: y + 60, x: x + 300),
            node("AXGroup", domClassList: ["adn", "ads"],
                 frame: CGRect(x: x + 300, y: y + 100, width: 900, height: 120), children: [
                text(sender, ["gD"], y: y + 100, x: x + 300),
                text("ada@example.com", ["go"], y: y + 100, x: x + 460),
                text("10:14 AM", ["g3"], y: y + 100, x: x + 1100),
                node("AXGroup", domClassList: ["a3s"],
                     frame: CGRect(x: x + 300, y: y + 130, width: 900, height: 80), children: [
                    text("Rebuild finished overnight.", nil, y: y + 130, x: x + 300),
                    text("No downtime.", nil, y: y + 150, x: x + 300),
                ]),
            ]),
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: x + 300, y: y + 240, width: 900, height: 24), children: [
                text("Grace Hopper", ["gD"], y: y + 240, x: x + 300),
                text("10:41 AM", ["g3"], y: y + 240, x: x + 1100),
            ]),
        ]
        if let draft { children.append(composeEditor(draft, y: y + 500, x: x + 300)) }
        return node("AXWindow", title: "Quarterly index rebuild - me@example.com - Gmail",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    /// The inbox list: three `zA` rows, one of them selected.
    func inboxWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        func row(_ sender: String, _ subject: String, _ snippet: String, _ time: String,
                 y rowY: CGFloat, selected: Bool = false) -> AXNode {
            node("AXRow", selected: selected, domClassList: ["zA", "yO"],
                 frame: CGRect(x: x + 300, y: rowY, width: 1100, height: 28), children: [
                text(sender, nil, y: rowY, x: x + 320),
                text(subject, nil, y: rowY, x: x + 500),
                text(snippet, nil, y: rowY, x: x + 700),
                text(time, nil, y: rowY, x: x + 1300),
            ])
        }
        return node("AXWindow", title: "Inbox (3) - me@example.com - Gmail",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: [
            heading("Main menu", y: y + 10, x: x + 20),
            row("Ada Lovelace", "Quarterly index rebuild", "Rebuild finished overnight.",
                "10:14 AM", y: y + 100, selected: true),
            row("Grace Hopper", "Deploy window", "Green across the board.", "09:02 AM", y: y + 140),
            row("Alan Turing", "Machine time", "Booked the afternoon slot.", "Jul 3", y: y + 180),
        ])
    }

    /// A standalone compose window: a composer and nothing else.
    func composeOnlyWindow(_ draft: String?) -> AXNode {
        node("AXWindow", title: "New Message - me@example.com - Gmail",
             frame: CGRect(x: 0, y: 0, width: 700, height: 500),
             children: [composeEditor(draft, y: 80)])
    }

    /// A Gmail settings page: no thread, no rows, no composer.
    func settingsWindow() -> AXNode {
        node("AXWindow", title: "Settings - me@example.com - Gmail",
             frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
             children: [heading("Main menu", y: 10, x: 20),
                        text("Undo send", nil, y: 100)])
    }

    /// A browser window: chrome plus an `AXWebArea` wrapping the Gmail page.
    func browserWindow(_ page: AXNode, url: String) -> AXNode {
        let frame = page.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return node("AXWindow", title: page.title,
                    frame: frame, children: [
            node("AXToolbar", frame: CGRect(x: frame.minX, y: frame.minY,
                                            width: frame.width, height: 42), children: [
                node("AXTextField", value: url, title: "Address and search bar",
                     frame: CGRect(x: frame.minX + 250, y: frame.minY + 6, width: 700, height: 30)),
            ]),
            node("AXWebArea", url: url, frame: frame, children: page.children),
        ])
    }

    static let threadURL = "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWxyz"

    func context(_ title: String?, url: String = GmailParserTests.threadURL) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func page(_ content: CapturedContent?) throws -> GenericPage {
        guard case .generic(let p) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .generic, got \(String(describing: content))")
        }
        return p
    }

    // MARK: - Registration

    func testConfigClaimsTheGmailHostOnly() {
        XCTAssertEqual(GmailParser.config.hosts, ["mail.google.com"])
        XCTAssertEqual(GmailParser.config.bundleIDs, [])
        XCTAssertFalse(GmailParser.config.preferOverNative,
                       "no native app shares mail.google.com")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "mail.google.com") is GmailParser)
        XCTAssertNil(registry.structuredParser(forHost: "mail.google.com.evil.example"))
    }

    func testTheDeclaredAttributeSetIsInertForAHostsOnlyParser() {
        // Documented, not aspirational: forcedAttributes is keyed by BUNDLE id, and the bundle
        // here is the browser's. The AXWebArea gate (Task 1) is what supplies the DOM attributes.
        XCTAssertEqual(GmailParser.config.attributeSet, ["AXDOMClassList", "AXDOMIdentifier"])
        XCTAssertEqual(ParserRegistry().forcedAttributes(for: "com.google.Chrome"), [])
    }

    // MARK: - Thread

    func testExpandedThreadMessagesCarrySenderTimeAndBody() throws {
        let c = try conversation(GmailParser().parse(
            threadWindow(), context: context("Quarterly index rebuild - me@example.com - Gmail")))
        XCTAssertEqual(c.channel, "Quarterly index rebuild")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(c.messages.map(\.text), ["Rebuild finished overnight. No downtime."])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM"])
        XCTAssertEqual(c.messages[0].id, Message.makeID(sender: "Ada Lovelace",
                                                        timeString: "10:14 AM",
                                                        text: "Rebuild finished overnight. No downtime."))
    }

    func testACollapsedMessageIsSkippedRatherThanEmittedEmpty() throws {
        let c = try conversation(GmailParser().parse(threadWindow(), context: context(nil)))
        XCTAssertFalse(c.messages.contains { $0.sender == "Grace Hopper" },
                       "a collapsed row has no a3s body, so it is not a message yet")
        XCTAssertFalse(c.messages.contains { $0.text.isEmpty })
    }

    func testASubjectlessThreadFallsBackToTheWindowTitle() throws {
        let bare = node("AXWindow", title: "Some thread - me@example.com - Gmail",
                        frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: 0, y: 40, width: 800, height: 60), children: [
                text("Ada", ["gD"], y: 40),
                node("AXGroup", domClassList: ["a3s"], frame: CGRect(x: 0, y: 60, width: 800, height: 20),
                     children: [text("one line", nil, y: 60)]),
            ]),
        ])
        XCTAssertEqual(try conversation(GmailParser().parse(bare, context: context(
            "Some thread - me@example.com - Gmail"))).channel,
                       "Some thread - me@example.com - Gmail")
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: 0, y: 40, width: 800, height: 60), children: [
                node("AXGroup", domClassList: ["a3s"], frame: CGRect(x: 0, y: 60, width: 800, height: 20),
                     children: [text("Note: check the doc", nil, y: 60)]),
            ]),
        ])
        let message = try XCTUnwrap(try conversation(GmailParser().parse(win, context: context(nil)))
            .messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testUserMarkerBecomesAUserMessageWithoutLeakingTheMarker() throws {
        let c = try conversation(GmailParser().parse(threadWindow(sender: "[user]"),
                                                    context: context(nil)))
        let message = try XCTUnwrap(c.messages.first)
        XCTAssertEqual(message.sender, "You")
        XCTAssertTrue(message.isUser)
        XCTAssertFalse(ContentRenderer.render(.conversation(c), style: .full).contains("[user]"))
    }

    // MARK: - Draft

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(GmailParser().parse(threadWindow(draft: "Sending the summary now"),
                                                    context: context(nil)))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "Sending the summary now")
        XCTAssertEqual(c.messages.count, 2, "the draft is appended, never replacing a message")
        XCTAssertTrue(ContentRenderer.render(.conversation(c), style: .full)
            .contains("(From: You (draft)): Sending the summary now"))
    }

    func testSecureTextInAReadingBodyIsAbsentFromCapturedContentAndRendering() throws {
        let secret = "gmail secure body"
        let body = node("AXGroup", domClassList: ["a3s"],
                        frame: CGRect(x: 300, y: 130, width: 900, height: 80), children: [
            text("Visible body.", nil, y: 130),
            node("AXTextArea", value: secret, subrole: "CustomSecureField",
                 frame: CGRect(x: 300, y: 150, width: 500, height: 20), children: [
                    text(secret, nil, y: 150),
                 ]),
        ])
        let window = node("AXWindow", title: "Subject - Gmail",
                          frame: CGRect(x: 0, y: 0, width: 1440, height: 900), children: [
            heading("Subject", y: 60),
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: 300, y: 100, width: 900, height: 120), children: [
                text("Ada", ["gD"], y: 100),
                text("10:14 AM", ["g3"], y: 100, x: 1100),
                body,
            ]),
        ])

        let captured = try XCTUnwrap(GmailParser().parse(window, context: context("Subject - Gmail")))
        let conversation = try conversation(captured)
        XCTAssertFalse(conversation.messages.contains { $0.text.contains(secret) })
        XCTAssertFalse(ContentRenderer.render(captured, style: .full).contains(secret))
    }

    func testAStandaloneComposeWindowIsTheDraftAlone() throws {
        let c = try conversation(GmailParser().parse(composeOnlyWindow("draft body"),
                                                    context: context("New Message - me@example.com - Gmail")))
        XCTAssertEqual(c.messages.map(\.text), ["draft body"])
        XCTAssertEqual(c.messages.map(\.isDraft), [true])
    }

    // MARK: - List view

    func testTheInboxBecomesThreeCellTableRows() throws {
        let rows = try page(GmailParser().parse(inboxWindow(), context: context(
            "Inbox (3) - me@example.com - Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox"))).regions
        XCTAssertEqual(rows.map(\.kind), [.main])
        XCTAssertEqual(rows[0].blocks.map(\.type), [
            .tableRow(cells: ["Ada Lovelace", "Quarterly index rebuild Rebuild finished overnight.",
                              "10:14 AM"], selected: true),
            .tableRow(cells: ["Grace Hopper", "Deploy window Green across the board.",
                              "09:02 AM"], selected: false),
            .tableRow(cells: ["Alan Turing", "Machine time Booked the afternoon slot.",
                              "Jul 3"], selected: false),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(rows[0].blocks[0]),
                       "* Ada Lovelace | Quarterly index rebuild Rebuild finished overnight. | 10:14 AM")
    }

    func testTheListPageCarriesTheUrl() throws {
        let url = "https://mail.google.com/mail/u/0/#inbox"
        XCTAssertEqual(try page(GmailParser().parse(inboxWindow(), context: context(nil, url: url))).url,
                       url)
    }

    // MARK: - Not handled vs refusal

    func testAPageWithNoMessageContainerIsNotHandledRatherThanRefused() throws {
        let parser = GmailParser()
        XCTAssertNil(try parser.parse(settingsWindow(), context: context(nil)))
        XCTAssertFalse(parser.refusesEmptyCompose(settingsWindow(), context: context(nil)),
                       "no composer means no refusal — this window becomes generic v2")
    }

    func testAnEmptyComposeOnlyWindowRefuses() throws {
        let parser = GmailParser()
        let window = composeOnlyWindow("   ")
        XCTAssertTrue(parser.refusesEmptyCompose(window, context: context(nil)))
        // The refusal travels on `parse`'s `throws` — there is nothing to store and this must not
        // degrade to a generic capture of the compose chrome (ruling F13).
        XCTAssertThrowsError(try parser.parse(window, context: context(nil))) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    func testAnEmptyComposerOverAThreadDoesNotRefuse() throws {
        let parser = GmailParser()
        let window = threadWindow(draft: "")
        XCTAssertNotNil(try parser.parse(window, context: context(nil)))
        XCTAssertFalse(parser.refusesEmptyCompose(window, context: context(nil)))
    }

    // MARK: - Origin invariance

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = GmailParser()
        XCTAssertEqual(try parser.parse(threadWindow(), context: context(nil)),
                       try parser.parse(threadWindow(origin: CGPoint(x: 1440, y: 220)),
                                    context: context(nil)))
        XCTAssertEqual(try parser.parse(inboxWindow(), context: context(nil)),
                       try parser.parse(inboxWindow(origin: CGPoint(x: 1440, y: 220)),
                                    context: context(nil)))
    }

    // MARK: - Pipeline: kind, key and the refusal

    func testThePipelineKeepsEmailKindAndTheUrlNormalizedKey() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(threadWindow(), url: Self.threadURL),
            windowTitle: "Quarterly index rebuild - me@example.com - Gmail", browser: browser)
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.threadURL), .gmail)
        XCTAssertEqual(result.capture.contentKind, .email, "§12 Q3: Gmail stays .email")
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertEqual(result.capture.sourceKey, URLKeyNormalizer.normalize(Self.threadURL))
        XCTAssertEqual(result.capture.sourceKey, Self.threadURL, "the key scheme is unchanged")
        XCTAssertEqual(result.webApp, .gmail)
        guard case .conversation(let c) = result.capture.structured else {
            return XCTFail("expected the host parser's conversation, got \(String(describing: result.capture.structured))")
        }
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(result.capture.content,
                       ContentRenderer.render(.conversation(c), style: .full))
    }

    func testAnEmptyComposeOnlyTabRefusesThroughThePipeline() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        do {
            _ = try BrowserCapturePipeline.parse(
                window: browserWindow(composeOnlyWindow("  "),
                                      url: "https://mail.google.com/mail/u/0/#drafts?compose=new"),
                windowTitle: "New Message - me@example.com - Gmail", browser: browser)
            XCTFail("expected a ParserRefusal")
        } catch let refusal as ParserRefusal {
            XCTAssertEqual(refusal.reason, "empty-compose")
        }
    }

    func testHostContentIsBoundedToTheBrowserBudget() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(threadWindow(), url: Self.threadURL),
            windowTitle: nil, browser: browser, contentBudget: 40)
        XCTAssertLessThanOrEqual(result.capture.content.count, 40,
                                 "a host parser's content is bounded exactly like the web path's")
    }

    // MARK: - Goldens

    func testThreadFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(GmailParser().parse(try fixture("gmail-thread"),
                                                       context: context(nil))),
                     matches: "gmail-thread-golden")
    }

    func testOffsetInboxFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(GmailParser().parse(
            try fixture("gmail-offset-inbox"),
            context: context(nil, url: "https://mail.google.com/mail/u/0/#inbox"))),
                     matches: "gmail-offset-inbox-golden")
    }

}
