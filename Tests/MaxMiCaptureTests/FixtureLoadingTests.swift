import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class FixtureLoadingTests: XCTestCase {
    func testLoadsAnAXFixture() throws {
        XCTAssertEqual(try fixture("slack-window").role, "AXWindow")
    }

    func testMissingFixtureFailsLoudly() throws {
        XCTAssertThrowsError(try fixture("definitely-not-a-fixture"))
    }

    func testGoldenRoundTripsThroughTheEnvelope() throws {
        let content = CapturedContent.document(
            Document(title: "Note", blocks: [Block(type: .paragraph, text: "line",
                                                   authoredByUser: false)],
                     author: .user, url: nil))
        let json = try goldenJSON(content)
        XCTAssertEqual(CapturedContentEnvelope.decode(json), content)
    }

    func testAssertGoldenPassesForAMatchingGolden() throws {
        // Fixtures/generic-empty-golden.json is the smallest possible golden: an empty page.
        assertGolden(.generic(GenericPage(regions: [], focused: nil, url: nil)),
                     matches: "generic-empty-golden")
    }

    func testRecorderEncodingRoundTripsThroughFixtureDecoder() throws {
        let snapshot = AXNode(
            role: "AXWindow", value: nil, title: "Sample terminal", url: nil,
            frame: nil, focused: true,
            children: [
                AXNode(
                    role: "AXTextArea", value: "sample output", title: nil, url: nil,
                    frame: CGRect(x: 120, y: 80, width: 640, height: 420), focused: false,
                    children: [], identifier: "terminal-output", label: "Output",
                    subrole: "AXTextArea", headingLevel: nil, selected: true,
                    placeholder: "Type here", selectedText: "output", hidden: false,
                    domClassList: ["terminal", "viewport"], domIdentifier: "scrollback"
                )
            ],
            identifier: "sample-window", label: "Terminal", subrole: nil,
            headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
            hidden: false, domClassList: ["window"], domIdentifier: "root"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(AXNode.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.frame)
        XCTAssertEqual(decoded.domClassList, ["window"])
        XCTAssertEqual(decoded.domIdentifier, "root")
        XCTAssertEqual(decoded.children[0].domClassList, ["terminal", "viewport"])
        XCTAssertEqual(decoded.children[0].domIdentifier, "scrollback")
    }
}
