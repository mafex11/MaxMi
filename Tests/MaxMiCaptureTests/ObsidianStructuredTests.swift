import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class ObsidianStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, domClassList: [String]? = nil,
              headingLevel: Int? = nil, subrole: String? = nil, selectedText: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: nil, label: nil, subrole: subrole,
               headingLevel: headingLevel, selected: false, placeholder: nil,
               selectedText: selectedText,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func window(paneClass: String, origin: CGPoint = .zero,
                paneChildren: [AXNode] = []) -> AXNode {
        let x = origin.x
        let y = origin.y
        let pane = [
            node("AXHeading", value: "Index rebuild", headingLevel: 2,
                 frame: CGRect(x: x + 320, y: y + 80, width: 400, height: 28)),
            node("AXStaticText", value: "vec0 uses L2, not cosine.",
                 frame: CGRect(x: x + 320, y: y + 120, width: 600, height: 20)),
        ] + paneChildren
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1300, height: 850)),
                    children: [
            node("AXGroup", domClassList: ["nav-files-container"],
                 frame: CGRect(x: x, y: y, width: 260, height: 850), children: [
                node("AXStaticText", value: "Daily notes",
                     frame: CGRect(x: x + 10, y: y + 20, width: 200, height: 16)),
            ]),
            node("AXGroup", domClassList: [paneClass],
                 frame: CGRect(x: x + 300, y: y + 40, width: 1000, height: 810),
                 children: pane),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                  windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            XCTFail("expected .document, got \(String(describing: content))")
            throw NSError(domain: "ObsidianStructuredTests", code: 1)
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

    func testSecureFieldsInsideThePaneAreNeverCaptured() throws {
        let secrets = ["role secret", "subrole secret", "selected secret"]
        let content = try XCTUnwrap(ObsidianParser().parse(
            window(paneClass: "cm-editor", paneChildren: [
                node("AXSecureTextField", value: secrets[0],
                     frame: CGRect(x: 320, y: 180, width: 300, height: 24)),
                node("AXStaticText", value: secrets[1],
                     subrole: "AXSecureTextField", selectedText: secrets[2],
                     frame: CGRect(x: 320, y: 220, width: 300, height: 24)),
            ]),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        let doc = try document(content)
        let rendered = ContentRenderer.render(content, style: .full)
        for secret in secrets {
            XCTAssertFalse(doc.title.contains(secret))
            XCTAssertFalse(doc.blocks.contains { $0.text.contains(secret) })
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testStructuredPathBoundsOversizeDocumentsAndV1MarksThemTruncated() throws {
        let paneChildren = (0..<40).map { index in
            node("AXStaticText", value: "line \(index) " + String(repeating: "x", count: 1_000),
                 frame: CGRect(x: 320, y: CGFloat(200 + index * 20), width: 600, height: 20))
        }
        let snapshot = window(paneClass: "cm-editor", paneChildren: paneChildren)
        let title = "Index rebuild - Research - Obsidian v1.5.3"
        let v2 = try XCTUnwrap(ObsidianParser().parse(snapshot, context: context(title)))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(v2, style: .full).count,
            StructuredEntityExtraction.pageBudget
        )

        let app = AppInfo(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                          windowTitle: title)
        let v1 = try XCTUnwrap(ObsidianParser().parse(window: snapshot, app: app))
        XCTAssertTrue(v1.truncated)
        XCTAssertEqual(v1.structured, v2)
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
