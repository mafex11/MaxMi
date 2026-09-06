import XCTest
@testable import MaxMiCapture

final class AXQueryPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AXQuery.resetPathCache()
        // An invalid path is a programmer error and traps in debug builds. These tests assert the
        // release behaviour (nil / []), so the trap is switched off for the duration. The property
        // exists in release too, so this file compiles under `swift test -c release`.
        AXQuery.trapsOnInvalidPath = false
    }

    override func tearDown() {
        #if DEBUG
        AXQuery.trapsOnInvalidPath = true
        #endif
        AXQuery.resetPathCache()
        super.tearDown()
    }

    func step(_ axis: AXQuery.Axis, _ role: String?,
              _ predicates: [AXQuery.Predicate] = [], _ index: Int? = nil) -> AXQuery.Step {
        AXQuery.Step(axis: axis, role: role, predicates: predicates, index: index)
    }

    func predicate(_ attribute: AXQuery.Attribute, _ op: AXQuery.Operator,
                   _ expected: String) -> AXQuery.Predicate {
        AXQuery.Predicate(attribute: attribute, op: op, expected: expected)
    }

    func testValidPaths() {
        let cases: [(path: String, expected: [AXQuery.Step])] = [
            ("/AXRow", [step(.child, "AXRow")]),
            ("//AXRow", [step(.descendant, "AXRow")]),
            ("/AXTable/AXRow", [step(.child, "AXTable"), step(.child, "AXRow")]),
            ("/AXTable//AXRow", [step(.child, "AXTable"), step(.descendant, "AXRow")]),
            ("//AXOutline//AXRow", [step(.descendant, "AXOutline"), step(.descendant, "AXRow")]),
            ("/*", [step(.child, nil)]),
            ("//*", [step(.descendant, nil)]),
            ("//AXGroup[identifier=\"editor\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .equals, "editor")])]),
            ("//AXGroup[identifier^=\"workbench.\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .prefix, "workbench.")])]),
            ("//AXGroup[identifier*=\"editor\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .contains, "editor")])]),
            ("//*[domClass*=\"c-virtual_list__item\"]",
             [step(.descendant, nil, [predicate(.domClass, .contains, "c-virtual_list__item")])]),
            ("//*[domId=\"msg-1\"]", [step(.descendant, nil, [predicate(.domId, .equals, "msg-1")])]),
            ("//AXStaticText[description*=\"message from\"]",
             [step(.descendant, "AXStaticText", [predicate(.description, .contains, "message from")])]),
            ("//AXRow[label^=\"Row \"]",
             [step(.descendant, "AXRow", [predicate(.label, .prefix, "Row ")])]),
            ("//AXRow[0]", [step(.descendant, "AXRow", [], 0)]),
            ("//AXRow[3]", [step(.descendant, "AXRow", [], 3)]),
            ("//AXRow[subrole=\"AXTabButton\"][title*=\"Inbox\"]",
             [step(.descendant, "AXRow",
                   [predicate(.subrole, .equals, "AXTabButton"),
                    predicate(.title, .contains, "Inbox")])]),
            ("//AXRow[value=\"1\"][2]",
             [step(.descendant, "AXRow", [predicate(.value, .equals, "1")], 2)]),
            ("//AXWebArea//AXGroup[domClass*=\"notion-frame\"]//AXStaticText",
             [step(.descendant, "AXWebArea"),
              step(.descendant, "AXGroup", [predicate(.domClass, .contains, "notion-frame")]),
              step(.descendant, "AXStaticText")]),
        ]

        for c in cases {
            XCTAssertEqual(AXQuery.parsePath(c.path), c.expected, "path \(c.path)")
        }
    }

    func testInvalidPathsReturnNil() {
        let invalid = [
            "",                                 // empty
            "AXRow",                            // no leading slash
            "/",                                // empty role token
            "//",                               // empty role token
            "/AXRow/",                          // trailing slash
            "///AXRow",                         // three slashes
            "/AXRow[",                          // unterminated bracket
            "/AXRow]",                          // stray close
            "/AXRow[identifier]",               // predicate without operator
            "/AXRow[identifier=editor]",        // unquoted value
            "/AXRow[identifier=\"editor]",      // unterminated quote
            "/AXRow[bogus=\"x\"]",              // unknown attribute
            "/AXRow[identifier~=\"x\"]",        // unknown operator
            "/AXRow[-1]",                       // negative index
            "/AXRow[0][1]",                     // two indexes on one step
            "/AXRow trailing",                  // trailing junk
            "/AX-Row",                          // illegal character in a role token
        ]
        for path in invalid {
            XCTAssertNil(AXQuery.parsePath(path), "path \(path) must not parse")
        }
    }

    func testWildcardRoleIsRepresentedAsNil() throws {
        XCTAssertNil(try XCTUnwrap(AXQuery.parsePath("//*")).first?.role)
        XCTAssertEqual(try XCTUnwrap(AXQuery.parsePath("//AXRow")).first?.role, "AXRow")
    }

    func testCachedStepsEqualUncachedStepsAndAreReused() {
        let path = "//AXTable//AXRow[value=\"1\"][0]"
        XCTAssertEqual(AXQuery.cachedPathCount(), 0)
        let first = AXQuery.steps(for: path)
        XCTAssertEqual(AXQuery.cachedPathCount(), 1)
        let second = AXQuery.steps(for: path)
        XCTAssertEqual(AXQuery.cachedPathCount(), 1, "a hit must not add an entry")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, AXQuery.parsePath(path), "the cache must not change the result")
    }

    func testInvalidPathsAreNotCached() {
        XCTAssertNil(AXQuery.steps(for: "/AXRow["))
        XCTAssertEqual(AXQuery.cachedPathCount(), 0)
    }

    func testCacheEvictsBeyondCapacityAndKeepsTheNewestEntries() {
        for i in 0..<(AXQuery.pathCacheCapacity + 10) {
            XCTAssertNotNil(AXQuery.steps(for: "//AXRow\(i)"))
        }
        XCTAssertEqual(AXQuery.cachedPathCount(), AXQuery.pathCacheCapacity)
    }
}
