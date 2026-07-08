import XCTest
@testable import MaxMiCapture

final class ParserRegistryTests: XCTestCase {
    func testSlackBundleReturnsSlackParser() {
        let p = ParserRegistry().parser(for: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(p is SlackParser)
    }
    func testUnregisteredBundleReturnsNil() {
        XCTAssertNil(ParserRegistry().parser(for: "com.example.fake"))
    }
    func testDocumentParsersRegistered() {
        let r = ParserRegistry()
        XCTAssertTrue(r.parser(for: "notion.id") is NotionParser)
        XCTAssertTrue(r.parser(for: "md.obsidian") is ObsidianParser)
        XCTAssertTrue(r.parser(for: "com.apple.Notes") is NotesParser)
    }
}
