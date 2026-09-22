import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class ObsidianStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, domClassList: [String]? = nil,
              headingLevel: Int? = nil, frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: nil, label: nil, subrole: nil,
               headingLevel: headingLevel, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func window(paneClass: String, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1300, height: 850)),
                    children: [
            node("AXGroup", domClassList: ["nav-files-container"],
                 frame: CGRect(x: x, y: y, width: 260, height: 850), children: [
                node("AXStaticText", value: "Daily notes",
                     frame: CGRect(x: x + 10, y: y + 20, width: 200, height: 16)),
            ]),
            node("AXGroup", domClassList: [paneClass],
                 frame: CGRect(x: x + 300, y: y + 40, width: 1000, height: 810), children: [
                node("AXHeading", value: "Index rebuild", headingLevel: 2,
                     frame: CGRect(x: x + 320, y: y + 80, width: 400, height: 28)),
                node("AXStaticText", value: "vec0 uses L2, not cosine.",
                     frame: CGRect(x: x + 320, y: y + 120, width: 600, height: 20)),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                  windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(ObsidianParser.config.bundleIDs, [ParserRegistry.obsidianBundleID])
        XCTAssertEqual(ObsidianParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(ObsidianParser.config.hosts.isEmpty, "Obsidian has no web client")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.obsidianBundleID)
                        is ObsidianParser)
    }

    func testNoteNameStripsTheVaultAndVersionSuffixes() {
        XCTAssertEqual(
            ObsidianParser.noteName(fromTitle: "Index rebuild - Research - Obsidian v1.5.3"),
            "Index rebuild")
        XCTAssertEqual(
            ObsidianParser.noteName(fromTitle: "Weekly - review - Research - Obsidian v1.5.3"),
            "Weekly - review", "a note name may itself contain \" - \"")
        XCTAssertEqual(ObsidianParser.noteName(fromTitle: "Obsidian"), "Obsidian")
        XCTAssertEqual(ObsidianParser.noteName(fromTitle: nil), "untitled")
    }

    func testEditorPaneIsAnAnchor() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "cm-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertEqual(doc.title, "Index rebuild")
        XCTAssertEqual(doc.blocks.map(\.type), [.heading(level: 2), .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["Index rebuild", "vec0 uses L2, not cosine."])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testPreviewPaneIsAlsoAnAnchor() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "markdown-preview-view"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertEqual(doc.blocks.map(\.text), ["Index rebuild", "vec0 uses L2, not cosine."])
    }

    func testTheFileNavigatorIsStructurallyExcluded() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "cm-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Daily notes" })
    }

    func testTheEditorPaneWinsWhenBothPanesArePresent() throws {
        let both = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1300, height: 850), children: [
            node("AXGroup", domClassList: ["markdown-preview-view"],
                 frame: CGRect(x: 800, y: 40, width: 500, height: 810), children: [
                node("AXStaticText", value: "preview copy",
                     frame: CGRect(x: 820, y: 80, width: 400, height: 20)),
            ]),
            node("AXGroup", domClassList: ["cm-editor"],
                 frame: CGRect(x: 300, y: 40, width: 500, height: 810), children: [
                node("AXStaticText", value: "editor copy",
                     frame: CGRect(x: 320, y: 80, width: 400, height: 20)),
            ]),
        ])
        let doc = try document(ObsidianParser().parse(both, context: context("Note - V - Obsidian v1")))
        XCTAssertEqual(doc.blocks.map(\.text), ["editor copy"],
                       "in split view the editor is what the user is editing")
    }

    func testNeitherPaneIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [node("AXStaticText", value: "loading vault",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 16))])
        XCTAssertNil(try ObsidianParser().parse(bare, context: context("Obsidian")))
    }

    func testAnEmptyPaneIsNotHandled() throws {
        let empty = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                         children: [node("AXGroup", domClassList: ["cm-editor"],
                                         frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertNil(try ObsidianParser().parse(empty, context: context("Note - V - Obsidian v1")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let title = "Index rebuild - Research - Obsidian v1.5.3"
        XCTAssertEqual(
            try ObsidianParser().parse(window(paneClass: "cm-editor"), context: context(title)),
            try ObsidianParser().parse(window(paneClass: "cm-editor", origin: CGPoint(x: 1440, y: 220)),
                                   context: context(title)))
    }

    func testObsidianEditorFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(ObsidianParser().parse(
            try fixture("obsidian-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3"))),
                     matches: "obsidian-editor-golden")
    }

    func testOffsetObsidianPreviewFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(ObsidianParser().parse(
            try fixture("obsidian-offset-preview"),
            context: context("Index rebuild - Research - Obsidian v1.5.3"))),
                     matches: "obsidian-offset-preview-golden")
    }
}
