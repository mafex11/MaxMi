import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NotesStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func window(body: String?, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            node("AXOutline", frame: CGRect(x: x, y: y, width: 260, height: 700), children: [
                node("AXStaticText", value: "All iCloud",
                     frame: CGRect(x: x + 10, y: y + 20, width: 200, height: 16)),
            ]),
        ]
        if let body {
            children.append(node("AXTextArea", value: body, identifier: "Note Body Text View",
                                 frame: CGRect(x: x + 300, y: y + 60, width: 700, height: 620)))
        }
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1100, height: 760)),
                    children: children)
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                                  windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(NotesParser.config.bundleIDs, [ParserRegistry.notesBundleID])
        XCTAssertEqual(NotesParser.config.app, "Notes")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.notesBundleID)
                        is NotesParser)
    }

    func testTitleIsTheBodysFirstLineAndTheRestBecomesParagraphs() throws {
        let doc = try document(NotesParser().parse(
            window(body: "Grocery list\nmilk\noats"), context: context("Grocery list")))
        XCTAssertEqual(doc.title, "Grocery list")
        XCTAssertEqual(doc.blocks.map(\.text), ["milk", "oats"])
        XCTAssertEqual(doc.blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testTitleFallsBackToTheWindowTitleWhenTheBodyStartsBlank() throws {
        let doc = try document(NotesParser().parse(window(body: "\n\nmilk"),
                                                  context: context("Grocery list")))
        XCTAssertEqual(doc.title, "Grocery list")
        XCTAssertEqual(doc.blocks.map(\.text), ["milk"])
    }

    func testTitleFallsBackToUntitledWithNeitherSource() throws {
        let doc = try document(NotesParser().parse(window(body: "\nmilk"), context: context(nil)))
        XCTAssertEqual(doc.title, "untitled")
    }

    func testASharedHeaderLineMarksTheAuthorAsOther() throws {
        let doc = try document(NotesParser().parse(
            window(body: "Trip plan\nAda Lovelace — Shared\nflights booked"),
            context: context("Trip plan")))
        XCTAssertEqual(doc.author, .other("Ada Lovelace"))
        XCTAssertEqual(doc.blocks.map(\.text), ["flights booked"],
                       "the shared header is metadata, not note content")
    }

    func testASharedHeaderWithNoNameStillMarksTheNoteAsShared() throws {
        let doc = try document(NotesParser().parse(window(body: "Trip plan\n— Shared\nnotes"),
                                                  context: context("Trip plan")))
        XCTAssertEqual(doc.author, .unknown)
    }

    func testTheSidebarIsStructurallyExcluded() throws {
        let doc = try document(NotesParser().parse(window(body: "Grocery list\nmilk"),
                                                  context: context("Grocery list")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "All iCloud" })
    }

    func testWithoutTheBodyAnchorTheNoteIsNotHandled() throws {
        XCTAssertNil(try NotesParser().parse(window(body: nil), context: context("Grocery list")),
                     "nil routes to GenericPageExtractor")
    }

    func testAnEmptyBodyIsNotHandled() throws {
        XCTAssertNil(try NotesParser().parse(window(body: "   \n  "), context: context("x")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(
            try NotesParser().parse(window(body: "Grocery list\nmilk"), context: context("Grocery list")),
            try NotesParser().parse(window(body: "Grocery list\nmilk", origin: CGPoint(x: 1440, y: 220)),
                                context: context("Grocery list")))
    }

    func testNotesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotesParser().parse(try fixture("notes-body"),
                                                      context: context("Grocery list"))),
                     matches: "notes-body-golden")
    }

    func testOffsetSharedNotesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotesParser().parse(try fixture("notes-offset-shared"),
                                                      context: context("Trip plan"))),
                     matches: "notes-offset-shared-golden")
    }
}
