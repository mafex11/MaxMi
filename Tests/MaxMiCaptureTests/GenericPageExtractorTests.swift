import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageExtractorTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil, headingLevel: Int? = nil,
              selected: Bool = false, placeholder: String? = nil, hidden: Bool = false,
              frame: CGRect? = nil, focused: Bool = false, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: focused,
               children: children, identifier: identifier, label: label, subrole: subrole,
               headingLevel: headingLevel, selected: selected, placeholder: placeholder,
               selectedText: nil, hidden: hidden)
    }

    func text(_ value: String, y: CGFloat = 0, x: CGFloat = 0) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 100, height: 16))
    }

    func extract(_ children: [AXNode], url: String? = nil) -> GenericPageExtractor.Result {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: nil, children: children),
            focusedElement: nil, url: url
        )
    }

    func mainBlocks(_ children: [AXNode]) -> [Block] {
        let regions = extract(children).page.regions
        return regions.first(where: { $0.kind == .main })?.blocks ?? []
    }

    func testHeadingUsesLevelAttributeAndDefaultsToTwo() {
        XCTAssertEqual(
            mainBlocks([node("AXHeading", value: "Explicit", headingLevel: 4)]).map(\.type),
            [.heading(level: 4)])
        XCTAssertEqual(
            mainBlocks([node("AXHeading", value: "Default")]).map(\.type),
            [.heading(level: 2)], "default heading level is 2")
    }

    func testHeadingLevelIsClampedToOneThroughSix() {
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "hi", headingLevel: 99)]).map(\.type),
                       [.heading(level: 6)])
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "lo", headingLevel: 0)]).map(\.type),
                       [.heading(level: 1)])
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "neg", headingLevel: -3)]).map(\.type),
                       [.heading(level: 1)])
    }

    func testStaticTextAndParagraphBecomeParagraphs() {
        let blocks = mainBlocks([text("static"), node("AXParagraph", value: "para")])
        XCTAssertEqual(blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["static", "para"])
    }

    func testTextEntryRolesBecomeInputsCarryingValueAndPlaceholder() {
        let blocks = mainBlocks([
            node("AXTextField", value: "vec0", placeholder: "Search"),
            node("AXTextArea", value: "body text"),
            node("AXSearchField", placeholder: "Filter"),
            node("AXComboBox", value: "Choice"),
        ])
        XCTAssertEqual(blocks.map(\.type), [
            .input(placeholder: "Search"), .input(placeholder: nil),
            .input(placeholder: "Filter"), .input(placeholder: nil),
        ])
        XCTAssertEqual(blocks.map(\.text), ["vec0", "body text", "", "Choice"])
    }

    func testEmptyUnnamedInputIsNotEmitted() {
        XCTAssertTrue(mainBlocks([node("AXTextField")]).isEmpty)
    }

    func testSecureFieldIsMaskedAndValueNeverAppears() {
        let blocks = mainBlocks([
            node("AXTextField", value: "hunter2", subrole: "AXSecureTextField", placeholder: "Password"),
        ])
        XCTAssertEqual(blocks.map(\.text), ["«secure field»"])
        XCTAssertEqual(blocks.map(\.type), [.input(placeholder: nil)])
        XCTAssertFalse(ContentRenderer.renderBlocks(blocks).contains("hunter2"))
    }

    func testListItemsCarryZeroBasedNestingDepth() {
        let tree = [
            node("AXList", children: [
                node("AXListItem", children: [text("top")]),
                node("AXList", children: [
                    node("AXListItem", children: [text("nested")]),
                ]),
            ]),
        ]
        let blocks = mainBlocks(tree)
        XCTAssertEqual(blocks.map(\.type), [.listItem(depth: 0), .listItem(depth: 1)])
        XCTAssertEqual(blocks.map(\.text), ["top", "nested"])
    }

    func testTreeItemInsideOutlineIsAListItem() {
        let blocks = mainBlocks([
            node("AXOutline", children: [node("AXTreeItem", children: [text("Downloads")])]),
        ])
        XCTAssertEqual(blocks.map(\.type), [.listItem(depth: 0)])
    }

    func testRowBecomesOneJoinedTableRow() {
        let row = node("AXRow", selected: true, frame: CGRect(x: 0, y: 40, width: 600, height: 20), children: [
            node("AXCell", frame: CGRect(x: 300, y: 40, width: 100, height: 20),
                 children: [text("12 KB", y: 40, x: 300)]),
            node("AXCell", frame: CGRect(x: 0, y: 40, width: 200, height: 20),
                 children: [text("Report.pdf", y: 40, x: 0)]),
        ])
        let blocks = mainBlocks([node("AXTable", children: [row])])
        XCTAssertEqual(blocks.count, 1, "one row is one block, not one per cell")
        XCTAssertEqual(blocks[0].type, .tableRow(cells: ["Report.pdf", "12 KB"], selected: true),
                       "cells in visual (y, x) order, selected from AXSelected")
        XCTAssertEqual(ContentRenderer.renderBlock(blocks[0]), "* Report.pdf | 12 KB")
    }

    func testTableRowDropsAdjacentDuplicateCellText() {
        let row = node("AXTableRow", frame: CGRect(x: 0, y: 10, width: 300, height: 20), children: [
            text("Report.pdf", y: 10, x: 0),
            text("Report.pdf", y: 10, x: 1),
            text("12 KB", y: 10, x: 100),
        ])
        XCTAssertEqual(mainBlocks([row]).map(\.type), [.tableRow(cells: ["Report.pdf", "12 KB"], selected: false)])
    }

    func testRowWithFramelessCellsKeepsCellsInEmissionOrder() {
        let row = node("AXTableRow", frame: CGRect(x: 0, y: 10, width: 300, height: 20), children: [
            node("AXCell", children: [node("AXStaticText", value: "a")]),
            node("AXCell", children: [node("AXStaticText", value: "b")]),
            node("AXCell", children: [node("AXStaticText", value: "c")]),
        ])
        XCTAssertEqual(mainBlocks([row]).map(\.type),
                       [.tableRow(cells: ["a", "b", "c"], selected: false)],
                       "frameless cells all sort at (0, 0), so emission order must break the tie")
    }

    func testDedupKeepsSameTextInDifferentBlockShapes() {
        let row = node("AXRow", frame: CGRect(x: 0, y: 20, width: 300, height: 20), children: [
            text("Report.pdf", y: 20, x: 0),
            text("12 KB", y: 20, x: 100),
        ])
        let blocks = mainBlocks([text("Report.pdf 12 KB", y: 10), row])
        XCTAssertEqual(blocks.map(\.type),
                       [.paragraph, .tableRow(cells: ["Report.pdf", "12 KB"], selected: false)],
                       "a paragraph does not dedup away a row whose joined text matches")
        XCTAssertEqual(blocks.map(\.text), ["Report.pdf 12 KB", "Report.pdf 12 KB"])
    }

    func testLabelRolesUseTitleThenLabelThenValue() {
        let blocks = mainBlocks([
            node("AXButton", title: "Send"),
            node("AXLink", label: "Open docs"),
            node("AXMenuItem", value: "Duplicate"),
            node("AXCheckBox", title: "Remember me"),
            node("AXRadioButton", title: "Messages", subrole: "AXTabButton"),
            node("AXImage", label: "Avatar"),
        ])
        XCTAssertEqual(blocks.map(\.type), Array(repeating: BlockType.label, count: 6))
        XCTAssertEqual(blocks.map(\.text),
                       ["Send", "Open docs", "Duplicate", "Remember me", "Messages", "Avatar"])
    }

    func testEmittingNodeStopsRecursionIntoItsOwnChildren() {
        let paragraph = node("AXStaticText", value: "whole paragraph",
                             frame: CGRect(x: 0, y: 0, width: 100, height: 16),
                             children: [text("run one"), text("run two")])
        XCTAssertEqual(mainBlocks([paragraph]).map(\.text), ["whole paragraph"],
                       "text runs beneath an emitting node are never emitted")
    }

    func testExactDuplicateTextIsDroppedWithinARegionKeepingFirstOccurrence() {
        let blocks = mainBlocks([text("alpha", y: 0), text("beta", y: 10), text("alpha", y: 20)])
        XCTAssertEqual(blocks.map(\.text), ["alpha", "beta"])
    }

    func testMenuSubtreesAreNeverTraversed() {
        for role in ["AXMenuBar", "AXMenuBarItem", "AXMenu"] {
            let tree = [node(role, children: [text("File"), text("Edit")]), text("real body")]
            XCTAssertEqual(mainBlocks(tree).map(\.text), ["real body"],
                           "\(role) content is structurally excluded")
        }
    }

    func testScrollBarSplitterAndGrowAreaSubtreesAreSkipped() {
        for role in ["AXScrollBar", "AXSplitter", "AXGrowArea"] {
            let tree = [node(role, children: [text("chrome")]), text("real body")]
            XCTAssertEqual(mainBlocks(tree).map(\.text), ["real body"], "\(role)")
        }
    }

    func testHiddenAndZeroSizedNodesAreSkipped() {
        let tree = [
            node("AXGroup", hidden: true, children: [text("hidden text")]),
            node("AXStaticText", value: "zero width", frame: CGRect(x: 0, y: 0, width: 0, height: 16)),
            node("AXStaticText", value: "zero height", frame: CGRect(x: 0, y: 0, width: 100, height: 0)),
            text("visible"),
        ]
        XCTAssertEqual(mainBlocks(tree).map(\.text), ["visible"])
    }

    func testNodeEntirelyOutsideTheWindowIsSkippedUnlessScrollPolicyIsSet() {
        let window = node("AXWindow", frame: CGRect(x: 100, y: 100, width: 800, height: 600), children: [
            text("inside", y: 200, x: 200),
            node("AXStaticText", value: "far below",
                 frame: CGRect(x: 200, y: 5_000, width: 100, height: 16)),
        ])
        let visibleOnly = GenericPageExtractor.extract(window: window, focusedElement: nil, url: nil)
        XCTAssertEqual(visibleOnly.page.regions.first?.blocks.map(\.text), ["inside"])

        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = .accessibilityScroll(maxSteps: 3)
        let withScroll = GenericPageExtractor.extract(window: window, focusedElement: nil,
                                                      url: nil, options: options)
        XCTAssertEqual(withScroll.page.regions.first?.blocks.map(\.text), ["inside", "far below"])
    }

    func testBlocksAreOrderedVisuallyNotInTreeOrder() {
        // Same ordering `DocumentExtraction.bodyText` applied: y, then x. The tree lists the
        // lower line first.
        let blocks = mainBlocks([
            text("Second line", y: 100),
            text("First line", y: 10),
            text("Second line right", y: 100, x: 500),
        ])
        XCTAssertEqual(blocks.map(\.text), ["First line", "Second line", "Second line right"])
    }

    func testBlocksWithoutFramesKeepEmissionOrder() {
        let blocks = mainBlocks([
            node("AXStaticText", value: "one"),
            node("AXStaticText", value: "two"),
            node("AXStaticText", value: "three"),
        ])
        XCTAssertEqual(blocks.map(\.text), ["one", "two", "three"])
    }

    func testUrlIsCarriedAndEmptyWindowYieldsNoRegions() {
        let empty = extract([node("AXButton")], url: "https://example.com/a")
        XCTAssertEqual(empty.page.regions, [])
        XCTAssertEqual(empty.page.url, "https://example.com/a")
        XCTAssertNil(empty.page.focused)
        XCTAssertFalse(empty.truncated)
    }

    func testDefaultOptionsMatchTheSpecBudgets() {
        let options = GenericPageExtractor.Options()
        XCTAssertEqual(options.totalBudget, 8_000)
        XCTAssertEqual(options.mainShare, 0.70)
        XCTAssertEqual(options.dialogShare, 0.15)
        XCTAssertEqual(options.restShare, 0.15)
        XCTAssertEqual(options.offscreenPolicy.mode, .visibleOnly)
    }
}
