import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageExtractorPerformanceTests: XCTestCase {
    /// >= 20_000 nodes — the AXReader node budget (`maxNodes: 20_000`) — mixing the roles a real
    /// table-heavy window actually has: a toolbar, a named sidebar (list of items), and a run of
    /// content groups each with a heading, table rows of cells, and a small footnote list. This
    /// exercises region classification (toolbar/sidebar claims) and dedup/list handling, not just
    /// a bare tree walk. Depth stays at 5 (window -> group -> row/list -> cell/item -> text),
    /// well under the 40 `AXReader` caps depth at.
    func makeLargeTree() -> (window: AXNode, nodeCount: Int) {
        var count = 1 // the window itself
        var topLevel: [AXNode] = []

        // Toolbar: a handful of buttons, claims the `.toolbar` region.
        var toolbarButtons: [AXNode] = []
        for i in 0..<6 {
            toolbarButtons.append(AXNode(
                role: "AXButton", value: nil, title: "Action \(i)", url: nil,
                frame: CGRect(x: CGFloat(i) * 60, y: 0, width: 50, height: 24),
                focused: false, children: []))
            count += 1
        }
        topLevel.append(AXNode(
            role: "AXToolbar", value: nil, title: nil, url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 24),
            focused: false, children: toolbarButtons))
        count += 1

        // Sidebar: named "sidebar" so `classifyRegion` claims it directly; holds an outline of
        // list items so `containsListLike`/list-depth handling is exercised too.
        var sidebarItems: [AXNode] = []
        for i in 0..<20 {
            let itemText = AXNode(
                role: "AXStaticText", value: "Item \(i)", title: nil, url: nil,
                frame: CGRect(x: 0, y: CGFloat(i) * 20, width: 150, height: 18),
                focused: false, children: [])
            count += 1
            sidebarItems.append(AXNode(
                role: "AXListItem", value: nil, title: nil, url: nil,
                frame: CGRect(x: 0, y: CGFloat(i) * 20, width: 160, height: 20),
                focused: false, children: [itemText]))
            count += 1
        }
        let sidebarList = AXNode(
            role: "AXOutline", value: nil, title: nil, url: nil,
            frame: CGRect(x: 0, y: 24, width: 160, height: 400),
            focused: false, children: sidebarItems)
        count += 1
        topLevel.append(AXNode(
            role: "AXGroup", value: nil, title: nil, url: nil,
            frame: CGRect(x: 0, y: 24, width: 160, height: 60_000),
            focused: false, children: [sidebarList], identifier: "sidebar"))
        count += 1

        // Content groups: each is a heading, 60 table rows of 6 cells, and a 6-item footnote list.
        var groups: [AXNode] = []
        for group in 0..<30 {
            var rows: [AXNode] = []
            let groupY = CGFloat(group) * 2_400
            for row in 0..<60 {
                let y = groupY + CGFloat(row) * 24
                var cells: [AXNode] = []
                for cell in 0..<6 {
                    let x = 160 + CGFloat(cell) * 160
                    cells.append(AXNode(
                        role: "AXCell", value: nil, title: nil, url: nil,
                        frame: CGRect(x: x, y: y, width: 160, height: 24), focused: false,
                        children: [AXNode(
                            role: "AXStaticText", value: "g\(group)r\(row)c\(cell)",
                            title: nil, url: nil,
                            frame: CGRect(x: x, y: y, width: 160, height: 16),
                            focused: false, children: [])]))
                    count += 2
                }
                rows.append(AXNode(
                    role: "AXRow", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 160, y: y, width: 960, height: 24),
                    focused: false, children: cells))
                count += 1
            }

            var listItems: [AXNode] = []
            let listY = groupY + 60 * 24
            for item in 0..<6 {
                let y = listY + CGFloat(item) * 20
                let itemText = AXNode(
                    role: "AXStaticText", value: "note \(group)-\(item)", title: nil, url: nil,
                    frame: CGRect(x: 160, y: y, width: 300, height: 18),
                    focused: false, children: [])
                count += 1
                listItems.append(AXNode(
                    role: "AXListItem", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 160, y: y, width: 320, height: 20),
                    focused: false, children: [itemText]))
                count += 1
            }
            rows.append(AXNode(
                role: "AXList", value: nil, title: nil, url: nil,
                frame: CGRect(x: 160, y: listY, width: 320, height: 140),
                focused: false, children: listItems))
            count += 1

            rows.append(AXNode(
                role: "AXHeading", value: "Group \(group)", title: nil, url: nil,
                frame: CGRect(x: 160, y: groupY, width: 400, height: 24),
                focused: false, children: [], headingLevel: 2))
            count += 1

            groups.append(AXNode(
                role: "AXGroup", value: nil, title: nil, url: nil,
                frame: CGRect(x: 160, y: groupY, width: 960, height: 1_600),
                focused: false, children: rows))
            count += 1
        }
        topLevel.append(contentsOf: groups)

        let window = AXNode(
            role: "AXWindow", value: nil, title: "Big", url: nil,
            frame: CGRect(x: 300, y: 200, width: 1_200, height: 80_000),
            focused: false, children: topLevel)
        return (window, count)
    }

    func testTwentyThousandNodeTreeStaysWithinTheBound() {
        let tree = makeLargeTree()
        XCTAssertGreaterThanOrEqual(tree.nodeCount, 20_000,
                                    "the fixture must actually reach the AXReader node budget")

        // Warm-up: excludes one-time costs (allocator warm-up, code paging) from the measurement.
        _ = GenericPageExtractor.extract(window: tree.window, focusedElement: nil, url: nil)

        let started = DispatchTime.now().uptimeNanoseconds
        let result = GenericPageExtractor.extract(window: tree.window, focusedElement: nil, url: nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertFalse(result.page.regions.isEmpty, "the walk actually produced blocks")

        #if DEBUG
        // Debug builds are roughly 10x slower. The spec's 150 ms bound is asserted in release:
        //   swift test -c release -Xswiftc -enable-testing --filter GenericPageExtractorPerformanceTests
        let bound = 1.500
        #else
        let bound = 0.150
        #endif
        XCTAssertLessThan(elapsed, bound,
                          "GenericPageExtractor took \(elapsed)s for \(tree.nodeCount) nodes")
    }
}
