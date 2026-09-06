import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageRegionTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: label, subrole: subrole)
    }

    /// Every synthetic window in this file sits at a nonzero screen origin, because that is
    /// exactly the case a global-coordinate comparison gets wrong.
    static let origin = CGRect(x: 500, y: 300, width: 1000, height: 800)

    func regions(_ children: [AXNode], window: CGRect = GenericPageRegionTests.origin) -> [Region] {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: window, children: children),
            focusedElement: nil, url: nil
        ).page.regions
    }

    func blocks(_ regions: [Region], _ kind: RegionKind) -> [Block] {
        regions.first(where: { $0.kind == kind })?.blocks ?? []
    }

    func body(_ text: String, y: CGFloat) -> AXNode {
        node("AXStaticText", value: text, frame: CGRect(x: 520, y: y, width: 400, height: 16))
    }

    func testRule1SheetDialogAndPopoverBecomeDialog() {
        for role in ["AXSheet", "AXDialog", "AXPopover"] {
            let result = regions([
                body("main text", y: 320),
                node(role, frame: CGRect(x: 700, y: 500, width: 300, height: 200),
                     children: [body("dialog text", y: 520)]),
            ])
            XCTAssertEqual(blocks(result, .dialog).map(\.text), ["dialog text"], role)
            XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"], role)
        }
        for subrole in ["AXDialog", "AXSystemDialog"] {
            let result = regions([
                node("AXGroup", subrole: subrole, frame: CGRect(x: 700, y: 500, width: 300, height: 200),
                     children: [body("dialog text", y: 520)]),
            ])
            XCTAssertEqual(blocks(result, .dialog).map(\.text), ["dialog text"], subrole)
        }
    }

    func testRule2ToolbarBecomesToolbar() {
        let result = regions([
            node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 52),
                 children: [body("Uploading 34 items", y: 310)]),
            body("main text", y: 400),
        ])
        XCTAssertEqual(blocks(result, .toolbar).map(\.text), ["Uploading 34 items"])
        XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"])
    }

    func testRule3LandmarkSubrolesMapToRegions() {
        let expected: [(String, RegionKind)] = [
            ("AXLandmarkMain", .main),
            ("AXLandmarkNavigation", .navigation),
            ("AXLandmarkComplementary", .sidebar),
            ("AXLandmarkBanner", .banner),
            ("AXLandmarkContentInfo", .footer),
        ]
        for (subrole, kind) in expected {
            let result = regions([
                node("AXGroup", subrole: subrole, frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                     children: [body("landmark text", y: 330)]),
            ])
            XCTAssertEqual(blocks(result, kind).map(\.text), ["landmark text"], subrole)
        }
    }

    func testRule4SidebarNamingIsCaseInsensitiveOnIdentifierAndLabel() {
        let byIdentifier = regions([
            node("AXGroup", identifier: "MainSideBar", frame: CGRect(x: 500, y: 320, width: 400, height: 200),
                 children: [body("sidebar text", y: 330)]),
        ])
        XCTAssertEqual(blocks(byIdentifier, .sidebar).map(\.text), ["sidebar text"])

        let byLabel = regions([
            node("AXGroup", label: "Source List", frame: CGRect(x: 500, y: 320, width: 400, height: 200),
                 children: [body("source list text", y: 330)]),
        ])
        XCTAssertEqual(blocks(byLabel, .sidebar).map(\.text), ["source list text"])
    }

    func testRule4SidebarNamingChecksIdentifierAndLabelIndependently() {
        // Concatenating the two names invents a hint that neither carries: "dataSource" +
        // "List of items" contains "source list" only across the join.
        let result = regions([
            node("AXGroup", label: "List of items", identifier: "dataSource",
                 frame: CGRect(x: 500, y: 320, width: 400, height: 200),
                 children: [body("row text", y: 330)]),
        ])
        XCTAssertTrue(blocks(result, .sidebar).isEmpty)
        XCTAssertEqual(blocks(result, .main).map(\.text), ["row text"])
    }

    func testRule5SplitGroupHeuristicUsesWindowRelativeCoordinates() {
        // Narrow (200 < 350), flush left in WINDOW coordinates (500 - 500 = 0 <= 50), holds an outline.
        let sidebar = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
            node("AXOutline", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
                node("AXTreeItem", frame: CGRect(x: 510, y: 350, width: 180, height: 20),
                     children: [body("Favorites", y: 350)]),
            ]),
        ])
        let main = node("AXGroup", frame: CGRect(x: 700, y: 340, width: 800, height: 700),
                        children: [body("main text", y: 350)])
        let result = regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                   children: [sidebar, main])])
        XCTAssertEqual(blocks(result, .sidebar).map(\.text), ["Favorites"],
                       "window-relative minX must be used; a global comparison would call this main")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"])
    }

    func testRule5RejectsWidePanesAndPanesAwayFromTheLeftEdge() {
        let wide = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 900, height: 700), children: [
            node("AXList", frame: CGRect(x: 500, y: 340, width: 900, height: 700),
                 children: [body("wide list", y: 350)]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [wide])]), .sidebar).isEmpty)

        let offset = node("AXGroup", frame: CGRect(x: 900, y: 340, width: 200, height: 700), children: [
            node("AXList", frame: CGRect(x: 900, y: 340, width: 200, height: 700),
                 children: [body("right list", y: 350)]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [offset])]), .sidebar).isEmpty)

        let noList = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700),
                          children: [body("just text", y: 350)])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [noList])]), .sidebar).isEmpty)
    }

    func testRule5OnlyAppliesToDirectChildrenOfASplitGroup() {
        let nested = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 900, height: 700), children: [
            node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
                node("AXList", frame: CGRect(x: 500, y: 340, width: 200, height: 700),
                     children: [body("grandchild list", y: 350)]),
            ]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [nested])]), .sidebar).isEmpty,
                      "the heuristic is scoped to direct children of the split group")
    }

    func testRule6EverythingElseIsMainAndUnknownIsNeverEmitted() {
        let result = regions([
            node("AXGroup", frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                 children: [body("plain body", y: 330)]),
        ])
        XCTAssertEqual(result.map(\.kind), [.main])
        XCTAssertFalse(result.contains { $0.kind == .unknown },
                       "the extractor never emits .unknown")
    }

    func testSameKindRegionsConcatenateInVisualOrder() {
        let lower = node("AXToolbar", frame: CGRect(x: 500, y: 900, width: 1000, height: 40),
                         children: [body("bottom bar", y: 910)])
        let upper = node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 40),
                         children: [body("top bar", y: 310)])
        XCTAssertEqual(blocks(regions([lower, upper]), .toolbar).map(\.text), ["top bar", "bottom bar"])
    }

    func testFinderFixtureAtNonzeroOriginSplitsSidebarMainAndToolbar() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("finder-offset-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .sidebar, .toolbar])
        XCTAssertEqual(blocks(result.page.regions, .sidebar).map(\.text), ["Favorites", "Projects"])
        XCTAssertEqual(blocks(result.page.regions, .sidebar).map(\.type),
                       [.listItem(depth: 0), .listItem(depth: 0)])
        XCTAssertEqual(blocks(result.page.regions, .main).map(\.type), [
            .tableRow(cells: ["Name", "Size"], selected: false),
            .tableRow(cells: ["Report.pdf", "12 KB"], selected: true),
            .tableRow(cells: ["Notes.txt", "4 KB"], selected: false),
        ])
        XCTAssertEqual(blocks(result.page.regions, .toolbar).map(\.text), ["Uploading 34 items"])
    }

    func testFinderFixtureRendersJoinedRows() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("finder-offset-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(ContentRenderer.render(.generic(result.page), style: .full), """
        Name | Size
        * Report.pdf | 12 KB
        Notes.txt | 4 KB
        ## Sidebar
        - Favorites
        - Projects
        ## Toolbar
        Uploading 34 items
        """)
    }

    func testWebTableColumnsDoNotRepublishTheirCells() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("web-table-with-columns"), focusedElement: nil, url: nil
        )
        let main = blocks(result.page.regions, .main)
        XCTAssertEqual(main.count, 2, "one block per row, not one per row plus one per column")
        XCTAssertEqual(main.map(\.type), [
            .tableRow(cells: ["Widget", "17 in stock"], selected: false),
            .tableRow(cells: ["Sprocket", "4 in stock"], selected: false),
        ])
        XCTAssertFalse(main.contains { $0.type == .paragraph },
                       "a column's cells must not fall through to loose paragraphs")
    }

    func testDialogOverWindowFixturePutsSheetContentInDialog() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .dialog])
        XCTAssertEqual(blocks(result.page.regions, .dialog).map(\.text),
                       ["Quit Cloudflare WARP?", "Open tunnels will disconnect.", "Quit", "Cancel"])
        XCTAssertEqual(blocks(result.page.regions, .main).count, 6)
    }
}
