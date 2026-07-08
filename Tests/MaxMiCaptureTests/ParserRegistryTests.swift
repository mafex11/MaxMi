import XCTest
@testable import MaxMiCapture

final class ParserRegistryTests: XCTestCase {
    func testSlackBundleReturnsSlackParser() {
        let p = ParserRegistry().parser(for: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(p is SlackParser)
    }
    func testUnregisteredBundleReturnsNil() {
        XCTAssertNil(ParserRegistry().parser(for: "com.apple.Notes"))
    }
}
