import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class OutlookWebParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              selected: Bool = false, domClassList: [String]? = nil, domIdentifier: String? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: nil,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: domIdentifier)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat = 500) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 400, height: 16))
    }

    /// A reading-pane card whose header carries the "From: …, Sent: …" description.
    func card(description: String?, headerTexts: [String], body: [String],
              y: CGFloat, x: CGFloat, role: String = "AXGroup",
              anchored: Bool = true) -> AXNode {
        node(role, label: description,
             domClassList: anchored ? ["outlook-message-card"] : nil,
             frame: CGRect(x: x, y: y, width: 800, height: 120), children: [
                node("AXGroup", label: description,
                     domClassList: anchored ? ["outlook-message-header"] : nil,
                     frame: CGRect(x: x, y: y, width: 800, height: 20),
                     children: headerTexts.enumerated().map { index, value in
                         text(value, y: y, x: x + CGFloat(index * 150))
                     }),
                node("AXGroup", domClassList: anchored ? ["outlook-message-body"] : nil,
                     frame: CGRect(x: x, y: y + 30, width: 800, height: 80),
                     children: body.enumerated().map { index, value in
                         text(value, y: y + 30 + CGFloat(index * 20), x: x)
                     }),
            ])
    }

    func readingWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            node("AXHeading", value: "Quarterly index rebuild", domClassList: ["outlook-subject"],
                 frame: CGRect(x: x + 500, y: y + 60, width: 500, height: 24)),
            card(description: "Message From: Nira Vale, Sent: Mon 10:14 AM",
                 headerTexts: ["Nira Vale", "Mon 10:14 AM"],
                 body: ["Rebuild finished overnight.", "No downtime."], y: y + 100, x: x + 500),
            // The second card's description does not carry the From/Sent shape, so the header's
            // static texts in visual order are the fallback.
            card(description: "Message", headerTexts: ["Sol Renn", "Mon 10:41 AM"],
                 body: ["Green across the board."], y: y + 260, x: x + 500),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft, label: "Message body",
                                 domIdentifier: "outlook-compose-body",
                                 frame: CGRect(x: x + 500, y: y + 500, width: 600, height: 120)))
        }
        return node("AXWindow", title: "Quarterly index rebuild - Outlook",
                    frame: CGRect(origin: origin, size: CGSize(width: 1600, height: 900)),
                    children: children)
    }

    func listWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        func row(_ cells: [String], y rowY: CGFloat, selected: Bool = false) -> AXNode {
            node("AXRow", selected: selected, domClassList: ["outlook-message-row"],
                 frame: CGRect(x: x + 300, y: rowY, width: 400, height: 40),
                 children: cells.enumerated().map { index, value in
                     node("AXCell", frame: CGRect(x: x + 300 + CGFloat(index * 120), y: rowY,
                                                   width: 110, height: 40),
                          children: [text(value, y: rowY, x: x + 300 + CGFloat(index * 120))])
                 })
        }
        return node("AXWindow", title: "Inbox - Outlook",
                    frame: CGRect(origin: origin, size: CGSize(width: 1600, height: 900)),
                    children: [
                        node("AXTable", frame: CGRect(x: x + 300, y: y + 80, width: 400, height: 700),
                             children: [
                                row(["Nira Vale", "Quarterly index rebuild", "10:14 AM"], y: y + 100,
                                    selected: true),
                                row(["Sol Renn", "Deploy window", "09:02 AM"], y: y + 150),
                             ]),
                    ])
    }

    func composeOnlyWindow(draft: String?) -> AXNode {
        node("AXWindow", title: "New mail - Outlook",
             frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
                node("AXTextArea", value: draft, label: "Message body",
                     domIdentifier: "outlook-compose-body",
                     frame: CGRect(x: 100, y: 120, width: 600, height: 300)),
             ])
    }

    static let readingURL =
        "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00&exvsurl=1"

    func context(_ title: String? = "Quarterly index rebuild - Outlook",
                 url: String = OutlookWebParserTests.readingURL) -> ParseContext {
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

    func testConfigClaimsTheTwoSpecifiedOutlookHostsOnly() {
        XCTAssertEqual(OutlookWebParser.config.hosts, ["outlook.office.com", "outlook.live.com"])
        XCTAssertFalse(OutlookWebParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "outlook.office.com") is OutlookWebParser)
        XCTAssertTrue(registry.structuredParser(forHost: "outlook.live.com") is OutlookWebParser)
        XCTAssertNil(registry.structuredParser(forHost: "outlook.office365.com"),
                     "left generic on purpose: its anchors have not been dumped (§14b)")
    }

    // MARK: - Description parsing

    func testHeaderFieldsParseTheFromSentDescription() {
        let fields = OutlookWebParser.headerFields(
            fromDescription: "Message From: Nira Vale, Sent: Mon 10:14 AM")
        XCTAssertEqual(fields.sender, "Nira Vale")
        XCTAssertEqual(fields.time, "Mon 10:14 AM")
    }

    func testHeaderFieldsYieldNilForADescriptionWithoutTheShape() {
        let fields = OutlookWebParser.headerFields(fromDescription: "Message")
        XCTAssertNil(fields.sender)
        XCTAssertNil(fields.time)
    }

    func testHeaderFieldsToleratesAMissingSentClause() {
        let fields = OutlookWebParser.headerFields(fromDescription: "From: Nira Vale")
        XCTAssertEqual(fields.sender, "Nira Vale")
        XCTAssertNil(fields.time)
    }

    // MARK: - Reading pane

    func testReadingPaneCardsBecomeMessagesFromTheDescriptionAndFromTheHeaderTexts() throws {
        let c = try conversation(OutlookWebParser().parse(readingWindow(), context: context()))
        XCTAssertEqual(c.channel, "Quarterly index rebuild")
        XCTAssertEqual(c.messages.map(\.sender), ["Nira Vale", "Sol Renn"])
        XCTAssertEqual(c.messages.map(\.timeString), ["Mon 10:14 AM", "Mon 10:41 AM"])
        XCTAssertEqual(c.messages.map(\.text),
                       ["Rebuild finished overnight. No downtime.", "Green across the board."])
        XCTAssertFalse(c.messages.contains { $0.text.contains("Nira Vale") },
                       "the header is not part of the body")
    }

    func testARoleDocumentCardIsFoundWhenTheDescriptionShapeDiffers() throws {
        let win = node("AXWindow", title: "Note - Outlook",
                       frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
                        card(description: nil, headerTexts: ["Aven Dorr", "Tue 08:00 AM"],
                             body: ["Booked the afternoon slot."], y: 100, x: 200, role: "AXDocument"),
                       ])
        let c = try conversation(OutlookWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.map(\.sender), ["Aven Dorr"])
        XCTAssertEqual(c.messages.map(\.timeString), ["Tue 08:00 AM"])
    }

    func testAnUnanchoredDescriptionCardIsNotHandled() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            card(description: "Message From: Nira Vale, Sent: Mon 10:14 AM",
                 headerTexts: ["Nira Vale", "Mon 10:14 AM"], body: ["private body"],
                 y: 100, x: 200, anchored: false),
        ])
        XCTAssertNil(try OutlookWebParser().parse(win, context: context()))
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            card(description: "Message", headerTexts: [],
                 body: ["Note: check the doc"], y: 100, x: 200),
        ])
        let message = try XCTUnwrap(try conversation(
            try OutlookWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testTheUserMarkerBecomesAUserMessage() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            card(description: "Message From: [user], Sent: Mon 10:14 AM", headerTexts: [],
                 body: ["I sent this."], y: 100, x: 200),
        ])
        let message = try XCTUnwrap(try conversation(
            try OutlookWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "You")
        XCTAssertTrue(message.isUser)
    }

    // MARK: - List and draft

    func testTheMessageListBecomesTableRows() throws {
        let regions = try page(OutlookWebParser().parse(
            listWindow(), context: context("Inbox - Outlook"))).regions
        XCTAssertEqual(regions.map(\.kind), [.main])
        XCTAssertEqual(regions[0].blocks.map(\.type), [
            .tableRow(cells: ["Nira Vale", "Quarterly index rebuild", "10:14 AM"],
                      selected: true),
            .tableRow(cells: ["Sol Renn", "Deploy window", "09:02 AM"], selected: false),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(regions[0].blocks[0]),
                       "* Nira Vale | Quarterly index rebuild | 10:14 AM")
    }

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(OutlookWebParser().parse(readingWindow(draft: "replying now"),
                                                         context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.text, "replying now")
        XCTAssertEqual(c.messages.count, 3)
    }

    func testAStandaloneComposeWindowIsTheDraftAlone() throws {
        let c = try conversation(OutlookWebParser().parse(composeOnlyWindow(draft: "new mail body"),
                                                         context: context("New mail - Outlook")))
        XCTAssertEqual(c.messages.map(\.text), ["new mail body"])
        XCTAssertEqual(c.messages.map(\.isDraft), [true])
    }

    // MARK: - Not handled vs refusal

    func testAPageWithNoCardAndNoRowIsNotHandled() throws {
        let bare = node("AXWindow", title: "Calendar - Outlook",
                        frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                        children: [text("September 2026", y: 60)])
        let parser = OutlookWebParser()
        XCTAssertNil(try parser.parse(bare, context: context("Calendar - Outlook")))
        XCTAssertFalse(parser.refusesEmptyCompose(bare, context: context("Calendar - Outlook")))
    }

    func testAnEmptyComposeOnlyWindowRefuses() throws {
        let parser = OutlookWebParser()
        let window = composeOnlyWindow(draft: "  ")
        XCTAssertTrue(parser.refusesEmptyCompose(window, context: context()))
        XCTAssertThrowsError(try parser.parse(window, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    // MARK: - Kind, key, origin, goldens

    func testTheHostKeepsEmailKindAndItsItemIdOnlyKey() {
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.readingURL), .outlook)
        // The key derivation is unchanged: everything but `itemid` is dropped, so the reading pane
        // keys on the message and `exvsurl` cannot fork it.
        let key = URLKeyNormalizer.normalize(Self.readingURL)
        XCTAssertTrue(key.contains("itemid=AAQkAD00"))
        XCTAssertFalse(key.contains("exvsurl"))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = OutlookWebParser()
        XCTAssertEqual(try parser.parse(readingWindow(), context: context()),
                       try parser.parse(readingWindow(origin: CGPoint(x: 1600, y: 300)),
                                        context: context()))
        XCTAssertEqual(try parser.parse(listWindow(), context: context()),
                       try parser.parse(listWindow(origin: CGPoint(x: 1600, y: 300)),
                                        context: context()))
    }

    func testReadingPaneFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(OutlookWebParser().parse(try fixture("outlook-web-reading"),
                                                           context: context())),
                     matches: "outlook-web-reading-golden")
    }

    func testOffsetListFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(OutlookWebParser().parse(try fixture("outlook-web-offset-list"),
                                                           context: context(
                                                               "Inbox - Outlook",
                                                               url: "https://outlook.invalid/mail/inbox?itemid=fixture-item"
                                                           ))),
                     matches: "outlook-web-offset-list-golden")
    }
}
