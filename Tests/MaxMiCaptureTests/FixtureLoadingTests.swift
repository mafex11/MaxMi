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
}
