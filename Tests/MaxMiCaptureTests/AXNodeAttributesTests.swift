import XCTest
@testable import MaxMiCapture

final class AXNodeAttributesTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testNewAttributesDecode() throws {
        let window = try fixture("ax-attributes")
        XCTAssertEqual(window.children[0].headingLevel, 3)
        XCTAssertEqual(window.children[1].placeholder, "Search")
        XCTAssertEqual(window.children[1].selectedText, "typed")
        XCTAssertEqual(window.children[2].subrole, "AXSecureTextField")
        XCTAssertTrue(window.children[3].selected)
        XCTAssertTrue(window.children[4].hidden)
    }

    func testAbsentAttributesDefaultAndDoNotBreakOldFixtures() throws {
        for name in ["calendar-event", "chrome-article", "chromium-gmail-thread", "cursor-editor",
                     "gecko-slack-chat", "pages-document", "reminder-task", "safari-domain-only",
                     "slack-window", "whatsapp-conversation", "zen-meet"] {
            let node = try fixture(name)
            XCTAssertNil(node.subrole, "\(name) has no subrole and must decode as nil")
            XCTAssertNil(node.headingLevel, "\(name)")
            XCTAssertNil(node.placeholder, "\(name)")
            XCTAssertNil(node.selectedText, "\(name)")
            XCTAssertFalse(node.selected, "\(name) defaults selected to false")
            XCTAssertFalse(node.hidden, "\(name) defaults hidden to false")
        }
    }

    func testEncodeDecodeRoundTripPreservesNewAttributes() throws {
        let original = try fixture("ax-attributes")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AXNode.self, from: data)
        XCTAssertEqual(decoded.children[0].headingLevel, 3)
        XCTAssertEqual(decoded.children[2].subrole, "AXSecureTextField")
        XCTAssertTrue(decoded.children[3].selected)
        XCTAssertTrue(decoded.children[4].hidden)
        XCTAssertEqual(decoded.children[1].selectedText, "typed")
    }

    func testMemberwiseInitDefaultsKeepOldCallSitesValid() {
        let node = AXNode(role: "AXStaticText", value: "x", title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                          focused: false, children: [])
        XCTAssertNil(node.subrole)
        XCTAssertFalse(node.selected)
        XCTAssertFalse(node.hidden)
    }
}
