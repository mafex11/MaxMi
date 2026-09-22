import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NotesStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              subrole: String? = nil, selectedText: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil, subrole: subrole,
               selectedText: selectedText)
    }

    func window(body: String?, origin: CGPoint = .zero,
                bodyChildren: [AXNode] = []) -> AXNode {
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
                                 frame: CGRect(x: x + 300, y: y + 60, width: 700, height: 620),
                                 children: bodyChildren))
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
            XCTFail("expected .document, got \(String(describing: content))")
            throw NSError(domain: "NotesStructuredTests", code: 1)
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

    func testOnlyTheExactTrailingSharedWindowTitleSuffixIsStripped() throws {
        let doc = try document(NotesParser().parse(
            window(body: "\nbody"),
            context: context("Shared planning — Shared")))
        XCTAssertEqual(doc.title, "Shared planning")

        let midTitle = try document(NotesParser().parse(
            window(body: "\nbody"),
            context: context("Planning Shared — notes")))
        XCTAssertEqual(midTitle.title, "Planning Shared — notes")
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

    func testSecureFieldsInsideTheBodyAreNeverCaptured() throws {
        let secrets = ["role secret", "subrole secret", "selected secret"]
        let content = try XCTUnwrap(NotesParser().parse(
            window(body: "Private note\nvisible text", bodyChildren: [
                node("AXSecureTextField", value: secrets[0],
                     frame: CGRect(x: 320, y: 180, width: 300, height: 24)),
                node("AXTextField", value: secrets[1],
                     subrole: GenericPageExtractor.secureSubrole, selectedText: secrets[2],
                     frame: CGRect(x: 320, y: 220, width: 300, height: 24)),
            ]),
            context: context("Private note")))
        let doc = try document(content)
        let rendered = ContentRenderer.render(content, style: .full)
        for secret in secrets {
            XCTAssertFalse(doc.title.contains(secret))
            XCTAssertFalse(doc.blocks.contains { $0.text.contains(secret) })
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testStructuredPathBoundsOversizeDocumentsAndV1MarksThemTruncated() throws {
        let body = (["Oversized note"] + (0..<40).map {
            "line \($0) " + String(repeating: "x", count: 1_000)
        }).joined(separator: "\n")
        let snapshot = window(body: body)
        let v2 = try XCTUnwrap(NotesParser().parse(snapshot, context: context("Oversized note")))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(v2, style: .full).count,
            StructuredEntityExtraction.pageBudget
        )

        let app = AppInfo(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                          windowTitle: "Oversized note")
        let v1 = try XCTUnwrap(NotesParser().parse(window: snapshot, app: app))
        XCTAssertTrue(v1.truncated)
        XCTAssertEqual(v1.structured, v2)
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
