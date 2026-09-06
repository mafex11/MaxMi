import XCTest
@testable import MaxMiCapture

final class AXNodeDOMAttributeTests: XCTestCase {
    // TODO(Task 6): shared loader
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    /// Every fixture on disk, enumerated rather than listed by hand — a hand-maintained list
    /// silently stops covering fixtures that later tasks add.
    func everyFixtureName() throws -> [String] {
        let urls = try XCTUnwrap(Bundle.module.urls(forResourcesWithExtension: "json",
                                                    subdirectory: "Fixtures"))
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func testDOMAttributesDecode() throws {
        let window = try fixture("dom-attributes")
        let webArea = window.children[0]
        XCTAssertEqual(webArea.domIdentifier, "root")
        XCTAssertNil(webArea.domClassList)
        let list = webArea.children[0]
        XCTAssertEqual(list.domClassList, ["c-message_list", "p-workspace__primary"])
        let item = list.children[0]
        XCTAssertEqual(item.domIdentifier, "msg-1")
        XCTAssertEqual(item.children[0].domClassList, ["c-message__sender"])
    }

    func testEveryFixtureOnDiskStillDecodesAndOnlyDomAttributesFixtureCarriesTheNewFields() throws {
        let names = try everyFixtureName()
        XCTAssertTrue(names.contains("dom-attributes"))
        for name in names {
            // Goldens are CapturedContentEnvelope JSON, not AXNode JSON; skip them by suffix.
            if name.hasSuffix("-golden") { continue }
            let node = try fixture(name)
            if name == "dom-attributes" {
                XCTAssertNotNil(node.children.first?.domIdentifier)
                continue
            }
            XCTAssertNil(node.domClassList, "\(name) has no domClassList and must decode as nil")
            XCTAssertNil(node.domIdentifier, "\(name) has no domIdentifier and must decode as nil")
        }
    }

    func testEncodeDecodeRoundTripPreservesDOMAttributes() throws {
        let original = try fixture("dom-attributes")
        let decoded = try JSONDecoder().decode(AXNode.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.children[0].children[0].domClassList,
                       ["c-message_list", "p-workspace__primary"])
        XCTAssertEqual(decoded.children[0].domIdentifier, "root")
    }

    func testMemberwiseInitDefaultsKeepOldCallSitesValid() {
        let node = AXNode(role: "AXStaticText", value: "x", title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                          focused: false, children: [])
        XCTAssertNil(node.domClassList)
        XCTAssertNil(node.domIdentifier)
    }

    func testDOMReadGateIsWebAreaScoped() {
        XCTAssertTrue(AXReader.readsDOMAttributes(role: "AXWebArea", inWebArea: false, forced: []),
                      "the web area itself is inside the web")
        XCTAssertTrue(AXReader.readsDOMAttributes(role: "AXGroup", inWebArea: true, forced: []))
        XCTAssertFalse(AXReader.readsDOMAttributes(role: "AXGroup", inWebArea: false, forced: []),
                       "native subtrees pay nothing for DOM attributes")
    }

    func testForcedAttributeSetBypassesTheWebAreaGate() {
        XCTAssertTrue(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXDOMClassList"]))
        XCTAssertTrue(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXDOMIdentifier"]))
        XCTAssertFalse(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXHeadingLevel"]),
            "only the two DOM attribute names are honoured")
    }
}
