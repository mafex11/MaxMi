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
    func testMailAndTerminalRegistered() {
        let r = ParserRegistry()
        XCTAssertTrue(r.parser(for: "com.apple.mail") is MailParser)
        XCTAssertTrue(r.parser(for: "dev.warp.Warp-Stable") is TerminalParser)
        XCTAssertTrue(r.parser(for: "com.googlecode.iterm2") is TerminalParser)
    }
    func testDiscordRegistered() {
        XCTAssertTrue(ParserRegistry().parser(for: "com.hnc.Discord") is DiscordParser)
    }
}
