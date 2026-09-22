import XCTest
@testable import MaxMiCapture

final class AXQueryEvaluationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AXQuery.resetPathCache()
        AXQuery.trapsOnInvalidPath = false
    }

    override func tearDown() {
        #if DEBUG
        AXQuery.trapsOnInvalidPath = true
        #endif
        AXQuery.resetPathCache()
        super.tearDown()
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil,
              domClassList: [String]? = nil, domIdentifier: String? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
               children: children, identifier: identifier, label: label, subrole: subrole,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: domIdentifier)
    }

    /// AXWindow > AXTable > (AXRow "one", AXRow "two"), plus AXGroup > AXRow "three".
    func tree() -> AXNode {
        node("AXWindow", children: [
            node("AXTable", identifier: "files", children: [
                node("AXRow", value: "one", children: [node("AXStaticText", value: "one-cell")]),
                node("AXRow", value: "two", children: [node("AXStaticText", value: "two-cell")]),
            ]),
            node("AXGroup", identifier: "editor-main", children: [
                node("AXRow", value: "three"),
            ]),
        ])
    }

    func testChildAxisMatchesDirectChildrenOnly() {
        XCTAssertEqual(AXQuery.findAll("/AXRow", in: tree()).count, 0,
                       "rows are grandchildren, not children")
        XCTAssertEqual(AXQuery.findAll("/AXTable/AXRow", in: tree()).map(\.value), ["one", "two"])
    }

    func testDescendantAxisMatchesAtAnyDepthAndExcludesSelf() {
        XCTAssertEqual(AXQuery.findAll("//AXRow", in: tree()).map(\.value), ["one", "two", "three"])
        let row = node("AXRow", value: "self", children: [node("AXRow", value: "nested")])
        XCTAssertEqual(AXQuery.findAll("//AXRow", in: row).map(\.value), ["nested"],
                       "// never matches the node it is evaluated against")
    }

    func testWildcardMatchesAnyRole() {
        XCTAssertEqual(AXQuery.findAll("/*", in: tree()).map(\.role), ["AXTable", "AXGroup"])
        XCTAssertEqual(AXQuery.findAll("//*[domId=\"nope\"]", in: tree()), [])
    }

    func testFindReturnsTheFirstMatchAndNilWhenThereIsNone() {
        XCTAssertEqual(AXQuery.find("//AXRow", in: tree())?.value, "one")
        XCTAssertNil(AXQuery.find("//AXButton", in: tree()))
    }

    func testEqualsPrefixAndContainsOperators() {
        let root = node("AXWindow", children: [
            node("AXGroup", identifier: "workbench.editor.main"),
            node("AXGroup", identifier: "workbench.panel.terminal"),
            node("AXGroup", identifier: "sidebar"),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier=\"sidebar\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier^=\"workbench.\"]", in: root).count, 2)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier*=\"terminal\"]", in: root)
                        .map(\.identifier), ["workbench.panel.terminal"])
    }

    func testPredicatesOnOneStepAreAnded() {
        let root = node("AXWindow", children: [
            node("AXRow", title: "Inbox", subrole: "AXTabButton"),
            node("AXRow", title: "Inbox", subrole: "AXOther"),
            node("AXRow", title: "Sent", subrole: "AXTabButton"),
        ])
        let matches = AXQuery.findAll("/AXRow[subrole=\"AXTabButton\"][title*=\"Inbox\"]", in: root)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].title, "Inbox")
        XCTAssertEqual(matches[0].subrole, "AXTabButton")
    }

    func testIndexSelectsOneMatchAndIsZeroBased() {
        XCTAssertEqual(AXQuery.findAll("//AXRow[0]", in: tree()).map(\.value), ["one"])
        XCTAssertEqual(AXQuery.findAll("//AXRow[2]", in: tree()).map(\.value), ["three"])
        XCTAssertEqual(AXQuery.findAll("//AXRow[9]", in: tree()), [],
                       "an out-of-range index yields no match, never a crash")
    }

    func testIndexAppliesAfterThePredicatesOnTheSameStep() {
        let root = node("AXWindow", children: [
            node("AXRow", value: "a", identifier: "keep"),
            node("AXRow", value: "b", identifier: "drop"),
            node("AXRow", value: "c", identifier: "keep"),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXRow[identifier=\"keep\"][1]", in: root).map(\.value), ["c"])
    }

    func testDescriptionIsAnAliasOfLabel() {
        let root = node("AXWindow", children: [node("AXStaticText", label: "message from Ada")])
        XCTAssertEqual(AXQuery.findAll("/AXStaticText[description*=\"message from\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXStaticText[label*=\"message from\"]", in: root).count, 1)
    }

    func testRoleSubroleTitleValueAndIdentifierAttributesResolve() {
        let root = node("AXWindow", children: [
            node("AXRow", value: "v", title: "t", identifier: "i", subrole: "s"),
        ])
        for path in ["/AXRow[role=\"AXRow\"]", "/AXRow[value=\"v\"]", "/AXRow[title=\"t\"]",
                     "/AXRow[identifier=\"i\"]", "/AXRow[subrole=\"s\"]"] {
            XCTAssertEqual(AXQuery.findAll(path, in: root).count, 1, path)
        }
    }

    func testDomIdMatchesDomIdentifier() {
        let root = node("AXWindow", children: [node("AXGroup", domIdentifier: "msg-1")])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domId=\"msg-1\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domId=\"MSG-1\"]", in: root).count, 0,
                       "domId is case-sensitive")
    }

    func testDomClassMatchesAnyEntryAndIsCaseInsensitive() {
        let root = node("AXWindow", children: [
            node("AXGroup", domClassList: ["p-workspace__primary", "c-virtual_list__item"]),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"c-virtual_list\"]", in: root).count, 1,
                       "any entry of the class list may satisfy the predicate")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"C-VIRTUAL_LIST\"]", in: root).count, 1,
                       "domClass is the one case-insensitive attribute")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass=\"c-virtual_list__item\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass^=\"p-workspace\"]", in: root).count, 1)
    }

    func testMissingAttributeNeverMatches() {
        let root = node("AXWindow", children: [node("AXGroup")])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier*=\"\"]", in: root).count, 0,
                       "a node with no identifier matches nothing, not the empty substring")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"x\"]", in: root).count, 0)
    }

    func testMultiStepDescendantChainsResolveInDocumentOrder()  {
        let root = node("AXWindow", children: [
            node("AXWebArea", children: [
                node("AXGroup", domClassList: ["notion-frame"], children: [
                    node("AXStaticText", value: "first"),
                    node("AXGroup", children: [node("AXStaticText", value: "second")]),
                ]),
            ]),
        ])
        XCTAssertEqual(
            AXQuery.findAll("//AXWebArea//AXGroup[domClass*=\"notion-frame\"]//AXStaticText", in: root)
                .map(\.value),
            ["first", "second"])
    }

    func testNestedDescendantSourcesReturnOneMatchingDescendant() {
        let root = node("AXWindow", children: [
            node("AXGroup", children: [
                node("AXGroup", children: [
                    node("AXStaticText", value: "only"),
                ]),
            ]),
        ])

        XCTAssertEqual(AXQuery.findAll("//AXGroup//AXStaticText", in: root).map(\.value), ["only"])
    }

    func testNestedDescendantSourcesProduceUniqueResultsInDocumentOrder() {
        let root = node("AXWindow", children: [
            node("AXGroup", children: [
                node("AXStaticText", value: "before"),
                node("AXGroup", children: [
                    node("AXStaticText", value: "nested"),
                ]),
                node("AXStaticText", value: "after"),
            ]),
        ])

        XCTAssertEqual(
            AXQuery.findAll("//AXGroup//AXStaticText", in: root).map(\.value),
            ["before", "nested", "after"])
    }

    #if DEBUG
    func testNestedDescendantSourcesEvaluateLinearly() {
        var root = node("AXStaticText", value: "only")
        for _ in 0..<2_000 {
            root = node("AXGroup", children: [root])
        }

        let clock = ContinuousClock()
        let start = clock.now
        let matches = AXQuery.findAll("//AXGroup//AXStaticText", in: root)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(matches.map(\.value), ["only"])
        XCTAssertLessThan(elapsed, .milliseconds(150))
    }
    #endif

    func testInvalidPathYieldsNoMatchesInsteadOfCrashing() {
        XCTAssertEqual(AXQuery.findAll("/AXRow[", in: tree()), [])
        XCTAssertNil(AXQuery.find("bogus", in: tree()))
    }
}
