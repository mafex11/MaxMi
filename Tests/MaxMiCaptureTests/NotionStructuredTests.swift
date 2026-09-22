import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NotionStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, url: String? = nil,
              domClassList: [String]? = nil, headingLevel: Int? = nil,
              subrole: String? = nil, selectedText: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: url, frame: frame, focused: false,
               children: children, identifier: nil, label: nil, subrole: subrole,
               headingLevel: headingLevel, selected: false, placeholder: nil,
               selectedText: selectedText,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat, classes: [String]? = nil) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 400, height: 20))
    }

    /// A Notion window: topbar, page frame with two blocks, a right margin and a property group.
    func window(frameClass: String = "notion-frame", origin: CGPoint = .zero,
                pageChildren: [AXNode] = []) -> AXNode {
        let x = origin.x
        let y = origin.y
        let page = [
            node("AXHeading", value: "Q3 plan", headingLevel: 1,
                 frame: CGRect(x: x + 300, y: y + 100, width: 400, height: 30)),
            text("Ship the index rebuild.", y: y + 150, x: x + 300),
            node("AXGroup", domClassList: ["notion-page-properties"],
                 frame: CGRect(x: x + 300, y: y + 60, width: 400, height: 30), children: [
                text("Status: In progress", y: y + 60, x: x + 300),
            ]),
            node("AXGroup", domClassList: ["layout-margin-right"],
                 frame: CGRect(x: x + 1100, y: y + 100, width: 280, height: 700),
                 children: [text("Comments", y: y + 100, x: x + 1100)]),
        ] + pageChildren
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1400, height: 900)),
                    children: [
            node("AXWebArea", url: "https://www.notion.so/acme/Roadmap-1",
                 frame: CGRect(x: x, y: y, width: 1400, height: 900), children: [
                node("AXGroup", domClassList: ["notion-topbar"],
                     frame: CGRect(x: x, y: y, width: 1400, height: 44), children: [
                    text("Roadmap", y: y + 12, x: x + 20),
                ]),
                node("AXGroup", domClassList: [frameClass],
                     frame: CGRect(x: x, y: y + 44, width: 1400, height: 856),
                     children: page),
            ]),
        ])
    }

    func context(_ title: String?, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                                  windowTitle: title), url: url)
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            XCTFail("expected .document, got \(String(describing: content))")
            throw NSError(domain: "NotionStructuredTests", code: 1)
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(NotionParser.config.bundleIDs, [ParserRegistry.notionBundleID])
        XCTAssertEqual(NotionParser.config.hosts, ["www.notion.so", "notion.so", ".notion.site"])
        XCTAssertEqual(NotionParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(NotionParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.notionBundleID) is NotionParser)
        XCTAssertTrue(registry.structuredParser(forHost: "www.notion.so") is NotionParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.notion.site") is NotionParser)
    }

    func testPageRootIsTheNotionFrame() throws {
        let root = try XCTUnwrap(NotionParser.pageRoot(in: window()))
        XCTAssertEqual(root.domClassList, ["notion-frame"])
    }

    func testPeekRendererIsAlsoAValidPageRoot() throws {
        let root = try XCTUnwrap(NotionParser.pageRoot(in: window(frameClass: "notion-peek-renderer")))
        XCTAssertEqual(root.domClassList, ["notion-peek-renderer"])
    }

    func testTitleComesFromTheTopbar() {
        XCTAssertEqual(NotionParser.pageTitle(in: window(), windowTitle: "Roadmap — Notion"),
                       "Roadmap")
    }

    func testTitleFallsBackToTheWindowTitleWithoutATopbar() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(NotionParser.pageTitle(in: bare, windowTitle: "Roadmap"), "Roadmap")
        XCTAssertEqual(NotionParser.pageTitle(in: bare, windowTitle: nil), "untitled")
    }

    func testHeadingsKeepTheirLevelAndBodyBecomesParagraphs() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertEqual(doc.title, "Roadmap")
        XCTAssertEqual(doc.blocks.map(\.type), [.heading(level: 1), .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["Q3 plan", "Ship the index rebuild."])
        XCTAssertEqual(doc.author, .user)
    }

    func testRightMarginAndPropertyGroupsAreSkipped() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Comments" },
                       "layout-margin-right is chrome")
        XCTAssertFalse(doc.blocks.contains { $0.text.hasPrefix("Status:") },
                       "page properties are metadata, not page body")
    }

    func testTopbarTextIsNotDuplicatedIntoTheBody() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Roadmap" })
    }

    func testSecureFieldsInsideThePageAreNeverCaptured() throws {
        let secrets = ["role secret", "subrole secret", "selected secret"]
        let content = try XCTUnwrap(NotionParser().parse(
            window(pageChildren: [
                node("AXSecureTextField", value: secrets[0],
                     frame: CGRect(x: 300, y: 200, width: 400, height: 24)),
                node("AXStaticText", value: secrets[1],
                     subrole: GenericPageExtractor.secureSubrole, selectedText: secrets[2],
                     frame: CGRect(x: 300, y: 240, width: 400, height: 24)),
            ]),
            context: context("Roadmap — Notion")))
        let doc = try document(content)
        let rendered = ContentRenderer.render(content, style: .full)
        for secret in secrets {
            XCTAssertFalse(doc.title.contains(secret))
            XCTAssertFalse(doc.blocks.contains { $0.text.contains(secret) })
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testStructuredPathBoundsOversizeDocumentsAndV1MarksThemTruncated() throws {
        let pageChildren = (0..<40).map { index in
            text("line \(index) " + String(repeating: "x", count: 1_000),
                 y: CGFloat(200 + index * 20), x: 300)
        }
        let snapshot = window(pageChildren: pageChildren)
        let v2 = try XCTUnwrap(NotionParser().parse(
            snapshot, context: context("Roadmap — Notion")))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(v2, style: .full).count,
            StructuredEntityExtraction.pageBudget
        )

        let app = AppInfo(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                          windowTitle: "Roadmap — Notion")
        let v1 = try XCTUnwrap(NotionParser().parse(window: snapshot, app: app))
        XCTAssertTrue(v1.truncated)
        XCTAssertEqual(v1.structured, v2)
    }

    func testUrlComesFromTheContextWhenPresent() throws {
        let doc = try document(NotionParser().parse(
            window(), context: context("Roadmap — Notion", url: "https://www.notion.so/acme/R-1")))
        XCTAssertEqual(doc.url, "https://www.notion.so/acme/R-1")
    }

    func testNoNotionFrameIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [text("loading", y: 0, x: 0)])
        XCTAssertNil(try NotionParser().parse(bare, context: context("Notion")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try NotionParser().parse(window(), context: context("Roadmap — Notion")),
                       try NotionParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                            context: context("Roadmap — Notion")))
    }

    func testNotionFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotionParser().parse(try fixture("notion-page"),
                                                       context: context("Roadmap — Notion"))),
                     matches: "notion-page-golden")
    }

    func testOffsetNotionPeekFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotionParser().parse(try fixture("notion-offset-peek"),
                                                       context: context("Roadmap — Notion"))),
                     matches: "notion-offset-peek-golden")
    }
}
