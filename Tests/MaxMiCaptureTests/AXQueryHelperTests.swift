import XCTest
@testable import MaxMiCapture

final class AXQueryHelperTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, selected: Bool = false, hidden: Bool = false,
              domClassList: [String]? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
               children: children, identifier: identifier, label: label, subrole: nil,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: hidden, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 80, height: 16))
    }

    // MARK: - Matchers

    func testHasRoleAndHasIdentifierPrefix() {
        let row = node("AXRow", identifier: "workbench.editor.main")
        XCTAssertTrue(AXQuery.Matchers.hasRole("AXRow")(row))
        XCTAssertFalse(AXQuery.Matchers.hasRole("AXTable")(row))
        XCTAssertTrue(AXQuery.Matchers.hasIdentifierPrefix("workbench.")(row))
        XCTAssertFalse(AXQuery.Matchers.hasIdentifierPrefix("sidebar")(row))
        XCTAssertFalse(AXQuery.Matchers.hasIdentifierPrefix("x")(node("AXRow")),
                       "a node with no identifier never matches a prefix")
    }

    func testHasClassMatchesAnyEntryCaseInsensitively() {
        let group = node("AXGroup", domClassList: ["c-message_list", "P-Workspace"])
        XCTAssertTrue(AXQuery.Matchers.hasClass("c-message_list")(group))
        XCTAssertTrue(AXQuery.Matchers.hasClass("p-workspace")(group))
        XCTAssertFalse(AXQuery.Matchers.hasClass("cm-editor")(group))
        XCTAssertFalse(AXQuery.Matchers.hasClass("x")(node("AXGroup")))
    }

    func testHasTitleContaining() {
        XCTAssertTrue(AXQuery.Matchers.hasTitleContaining("Messages in")(
            node("AXList", title: "Messages in general")))
        XCTAssertFalse(AXQuery.Matchers.hasTitleContaining("Messages in")(node("AXList")))
    }

    func testAndOrNotCompose() {
        let row = node("AXRow", title: "Inbox", identifier: "mail.row")
        let isRow = AXQuery.Matchers.hasRole("AXRow")
        let isInbox = AXQuery.Matchers.hasTitleContaining("Inbox")
        let isTable = AXQuery.Matchers.hasRole("AXTable")
        XCTAssertTrue(AXQuery.Matchers.and(isRow, isInbox)(row))
        XCTAssertFalse(AXQuery.Matchers.and(isRow, isTable)(row))
        XCTAssertTrue(AXQuery.Matchers.or(isTable, isInbox)(row))
        XCTAssertFalse(AXQuery.Matchers.or(isTable, AXQuery.Matchers.hasRole("AXCell"))(row))
        XCTAssertTrue(AXQuery.Matchers.not(isTable)(row))
        XCTAssertFalse(AXQuery.Matchers.not(isRow)(row))
    }

    func testAllAndFirstRunAMatcherOverATree() {
        let root = node("AXWindow", children: [
            node("AXGroup", children: [node("AXRow", value: "a"), node("AXRow", value: "b")]),
        ])
        let isRow = AXQuery.Matchers.hasRole("AXRow")
        XCTAssertEqual(AXQuery.all(in: root, where: isRow).map(\.value), ["a", "b"])
        XCTAssertEqual(AXQuery.first(in: root, where: isRow)?.value, "a")
        XCTAssertNil(AXQuery.first(in: root, where: AXQuery.Matchers.hasRole("AXCell")))
    }

    // MARK: - Visual order

    func testVisualOrderSortsByYThenX() {
        let nodes = [text("c", y: 40, x: 0), text("b", y: 10, x: 90), text("a", y: 10, x: 0)]
        XCTAssertEqual(AXQuery.sortedByVisualOrder(nodes, relativeTo: nil).map(\.value),
                       ["a", "b", "c"])
    }

    func testVisualOrderIsTranslationInvariant() {
        // Same layout, once flush at the origin and once on a second display at (1440, 220).
        // AXFrame is global screen coordinates, so the ORDER must not change with the origin.
        let flushWindow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let flush = [text("c", y: 40, x: 0), text("b", y: 10, x: 90), text("a", y: 10, x: 0)]
        let offsetWindow = CGRect(x: 1440, y: 220, width: 800, height: 600)
        let offset = [text("c", y: 260, x: 1440), text("b", y: 230, x: 1530),
                      text("a", y: 230, x: 1440)]
        XCTAssertEqual(AXQuery.sortedByVisualOrder(flush, relativeTo: flushWindow).map(\.value),
                       AXQuery.sortedByVisualOrder(offset, relativeTo: offsetWindow).map(\.value))
        XCTAssertEqual(AXQuery.sortedByVisualOrder(offset, relativeTo: offsetWindow).map(\.value),
                       ["a", "b", "c"])
    }

    func testAFramelessNodeSortsAtTheWindowOriginNotAtGlobalZero() {
        // The local `node(...)` helper substitutes a real frame when `frame:` is nil, so this
        // genuinely frameless node is built directly — otherwise the nil branch of
        // `sortedByVisualOrder` is never reached and the assertion degenerates to "0 < 10".
        let frameless = AXNode(role: "AXStaticText", value: "z", title: nil, url: nil,
                               frame: nil, focused: false, children: [])
        let window = CGRect(x: 1_440, y: 220, width: 800, height: 600)
        // 10pt ABOVE the window's top edge, i.e. window-relative y == -10. A frameless node
        // treated as the WINDOW origin (relative 0) sorts after it; a frameless node wrongly
        // treated as global (0, 0) would be relative -220 and sort before it.
        let above = text("above", y: 210, x: 1_440)
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([above, frameless], relativeTo: window).map(\.value),
            ["above", "z"])
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([frameless, above], relativeTo: window).map(\.value),
            ["above", "z"], "the order comes from the frames, not from the input order")
        // With no window frame the same node is the origin and sorts ahead of everything below it.
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([text("a", y: 10, x: 0), frameless], relativeTo: nil)
                .map(\.value),
            ["z", "a"])
    }

    // MARK: - collectStaticTexts

    func testCollectStaticTextsReturnsVisualOrderTrimmedNonEmptyValues() {
        let row = node("AXRow", children: [
            text("  second  ", y: 20, x: 0),
            text("first", y: 10, x: 0),
            text("   ", y: 30, x: 0),
            node("AXButton", title: "Send", frame: CGRect(x: 0, y: 40, width: 10, height: 10)),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: row), ["first", "second"],
                       "AXStaticText only, trimmed, empties dropped, buttons excluded")
    }

    func testCollectStaticTextsIncludesSelfAndSkipsHiddenAndMenuSubtrees() {
        XCTAssertEqual(AXQuery.collectStaticTexts(in: text("only", y: 0, x: 0)), ["only"])
        let root = node("AXGroup", children: [
            node("AXMenu", children: [text("File", y: 0, x: 0)]),
            node("AXGroup", hidden: true, children: [text("hidden", y: 10, x: 0)]),
            text("kept", y: 20, x: 0),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: root), ["kept"])
    }

    func testCollectStaticTextsDropsAdjacentDuplicates() {
        let row = node("AXRow", children: [
            text("Report.pdf", y: 10, x: 0),
            text("Report.pdf", y: 10, x: 1),
            text("12 KB", y: 10, x: 100),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: row), ["Report.pdf", "12 KB"])
    }

    // MARK: - Menu roles

    func testMenuRolesIsTheExtractorsSetAndNotASecondLiteral() {
        XCTAssertEqual(AXQuery.menuRoles, GenericPageExtractor.menuRoles,
                       "one menu-skip set for the whole capture layer")
    }
}
