import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageBudgetTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil, selectedText: String? = nil,
              frame: CGRect? = nil, focused: Bool = false, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: focused,
               children: children, identifier: identifier, label: label, subrole: subrole,
               selectedText: selectedText)
    }

    func text(_ value: String, y: CGFloat = 320) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: 520, y: y, width: 400, height: 16))
    }

    static let windowFrame = CGRect(x: 500, y: 300, width: 1000, height: 800)

    func extract(_ children: [AXNode], focusedElement: AXNode? = nil,
                 options: GenericPageExtractor.Options = GenericPageExtractor.Options())
        -> GenericPageExtractor.Result {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: Self.windowFrame, children: children),
            focusedElement: focusedElement, url: nil, options: options
        )
    }

    func blocks(_ result: GenericPageExtractor.Result, _ kind: RegionKind) -> [Block] {
        result.page.regions.first(where: { $0.kind == kind })?.blocks ?? []
    }

    func testDeepestFocusedNodeInTheTreeWins() {
        let deep = node("AXGroup", frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                        focused: true, children: [
            node("AXTextField", value: "vec0 knn", identifier: "search",
                 selectedText: "vec0", frame: CGRect(x: 520, y: 340, width: 400, height: 24),
                 focused: true),
        ])
        let focused = extract([deep]).page.focused
        XCTAssertEqual(focused?.role, "AXTextField", "the deepest focused node wins")
        XCTAssertEqual(focused?.identifier, "search")
        XCTAssertEqual(focused?.value, "vec0 knn")
        XCTAssertEqual(focused?.selectedText, "vec0")
        XCTAssertEqual(focused?.isSecure, false)
    }

    func testFallbackSnapshotIsUsedWhenTheTreeHasNoFocusedNode() {
        let fallback = node("AXTextArea", value: "composer draft", identifier: "composer",
                            frame: CGRect(x: 520, y: 700, width: 400, height: 60), focused: true)
        let focused = extract([text("body")], focusedElement: fallback).page.focused
        XCTAssertEqual(focused?.role, "AXTextArea")
        XCTAssertEqual(focused?.value, "composer draft")
    }

    func testNoFocusAnywhereYieldsNilFocusedElement() {
        XCTAssertNil(extract([text("body")]).page.focused)
    }

    func testSecureFocusedFieldNeverCarriesItsValue() {
        let secure = node("AXTextField", value: "hunter2", identifier: "password",
                          subrole: "AXSecureTextField",
                          frame: CGRect(x: 520, y: 340, width: 400, height: 24), focused: true)
        let focused = extract([secure]).page.focused
        XCTAssertEqual(focused?.isSecure, true)
        XCTAssertNil(focused?.value)
    }

    func testSecureFocusedFieldNeverCarriesItsSelectedText() throws {
        let secure = node("AXTextField", value: "hunter2", identifier: "password",
                          subrole: "AXSecureTextField", selectedText: "hunter2",
                          frame: CGRect(x: 520, y: 340, width: 400, height: 24), focused: true)
        let page = extract([secure]).page
        XCTAssertNil(page.focused?.value)
        XCTAssertNil(page.focused?.selectedText)
        let encoded = try CapturedContentEnvelope.encode(.generic(page))
        XCTAssertFalse(encoded.contains("hunter2"),
                       "the secret must not reach the stored envelope by any field")
    }

    func testNothingIsTrimmedWhenEverythingFits() {
        let result = extract([text("alpha", y: 320), text("bravo", y: 340)])
        XCTAssertEqual(blocks(result, .main).map(\.text), ["alpha", "bravo"])
        XCTAssertFalse(result.truncated)
    }

    func testUnusedDialogAndRestSharesRollIntoMain() {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 40   // mainShare alone would be 28 and would drop the third block
        let result = extract([
            text("aaaaaaaaaa", y: 320), text("bbbbbbbbbb", y: 340), text("cccccccccc", y: 360),
        ], options: options)
        XCTAssertEqual(blocks(result, .main).count, 3, "the unused 15% + 15% roll into main")
        XCTAssertFalse(result.truncated)
    }

    func testRestRegionsShareTheirBudgetProportionallyAndNeverSplitABlock() {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 100   // restAllowance = 15 for a 34-char unbounded rest
        let sidebar = node("AXGroup", identifier: "sidebar",
                           frame: CGRect(x: 500, y: 400, width: 300, height: 300), children: [
            node("AXOutline", frame: CGRect(x: 500, y: 400, width: 300, height: 300), children: [
                node("AXListItem", frame: CGRect(x: 510, y: 410, width: 280, height: 20),
                     children: [text("Alpha", y: 410)]),
                node("AXListItem", frame: CGRect(x: 510, y: 430, width: 280, height: 20),
                     children: [text("Bravo", y: 430)]),
                node("AXListItem", frame: CGRect(x: 510, y: 450, width: 280, height: 20),
                     children: [text("Charlie", y: 450)]),
            ]),
        ])
        let toolbar = node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 40),
                           children: [text("Uploading", y: 310)])
        let result = extract([toolbar, sidebar, text("Main", y: 500)], options: options)

        XCTAssertEqual(blocks(result, .sidebar).map(\.text), ["Alpha"],
                       "sidebar's proportional share fits one item")
        XCTAssertEqual(blocks(result, .toolbar).map(\.text), ["Uploading"],
                       "a single block larger than its share is kept whole, never split")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["Main"])
        XCTAssertTrue(result.truncated)
    }

    func testDialogIsNeverTrimmedAndTakesItsOverflowFromMain() throws {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 100
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil, options: options
        )
        XCTAssertEqual(blocks(result, .dialog).map(\.text),
                       ["Quit Cloudflare WARP?", "Open tunnels will disconnect.", "Quit", "Cancel"],
                       "a dialog is never trimmed")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["Main body line one", "Main body line two"],
                       "main pays for the dialog's overflow")
        XCTAssertTrue(result.truncated)
    }

    /// An alert window: the root itself claims `.dialog`, so there is no `.main` region and no
    /// rest region to pay. Both unused shares roll into the dialog, which therefore gets the
    /// whole budget — 63 rendered chars survive a 100-char budget whose dialog share is 15.
    func testDialogOnlyWindowGetsTheFullBudget() {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 100
        let alert = node("AXWindow", subrole: "AXSystemDialog", frame: Self.windowFrame, children: [
            text("Quit Cloudflare WARP?", y: 320),
            text("Open tunnels will disconnect.", y: 340),
            node("AXButton", title: "Quit", frame: CGRect(x: 520, y: 400, width: 80, height: 24)),
            node("AXButton", title: "Cancel", frame: CGRect(x: 620, y: 400, width: 80, height: 24)),
        ])
        let result = GenericPageExtractor.extract(
            window: alert, focusedElement: nil, url: nil, options: options
        )
        XCTAssertEqual(result.page.regions.map(\.kind), [.dialog])
        XCTAssertEqual(blocks(result, .dialog).map(\.text),
                       ["Quit Cloudflare WARP?", "Open tunnels will disconnect.", "Quit", "Cancel"],
                       "the unused main and rest shares roll into the dialog")
        XCTAssertFalse(result.truncated)
    }

    func testDefaultBudgetLeavesTheDialogFixtureIntact() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(blocks(result, .main).count, 6)
        XCTAssertEqual(blocks(result, .dialog).count, 4)
        XCTAssertFalse(result.truncated)
    }

    func testTrimDropsWholeBlocksFromTheEnd() {
        let input = [
            Block(type: .paragraph, text: "0123456789"),
            Block(type: .paragraph, text: "abcdefghij"),
            Block(type: .paragraph, text: "klmnopqrst"),
        ]
        let trimmed = GenericPageExtractor.trim(input, to: 21)
        XCTAssertEqual(trimmed.blocks.map(\.text), ["0123456789", "abcdefghij"])
        XCTAssertTrue(trimmed.truncated)
        XCTAssertFalse(GenericPageExtractor.trim(input, to: 1_000).truncated)
    }

    func testMenuSubtreeIsNeverConsultedForFocus() {
        let menu = node("AXMenu", frame: CGRect(x: 520, y: 320, width: 200, height: 200), children: [
            node("AXMenuItem", title: "Copy", frame: CGRect(x: 520, y: 340, width: 200, height: 20),
                 focused: true),
        ])
        XCTAssertNil(extract([menu, text("body", y: 500)]).page.focused)
    }
}
