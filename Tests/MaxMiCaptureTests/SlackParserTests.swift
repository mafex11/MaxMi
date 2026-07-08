import XCTest
@testable import MaxMiCapture

final class SlackParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
    func app(_ title: String?) -> AppInfo {
        AppInfo(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", windowTitle: title)
    }

    func testKeyFromTitleAndSenderAttributedMessages() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("general - Acme - Slack")))
        XCTAssertEqual(cap.sourceApp, "Slack")
        XCTAssertEqual(cap.sourceKey, "slack:acme/general")
        XCTAssertTrue(cap.content.contains("Alice: shipped the build"))
        XCTAssertTrue(cap.content.contains("Bob: deploy looks green"))
        // message ordering top->bottom
        XCTAssertLessThan(cap.content.range(of: "Alice")!.lowerBound, cap.content.range(of: "Bob")!.lowerBound)
    }
    func testUnexpectedTitleFallsBackToFullTitleKey() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("Huddle")))
        XCTAssertEqual(cap.sourceKey, "slack:huddle")
    }
    func testNilTitleStillParses() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app(nil)))
        XCTAssertTrue(cap.sourceKey.hasPrefix("slack:"))
    }
    func testEmptyMessageAreaReturnsNil() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [])
        XCTAssertNil(try SlackParser().parse(window: bare, app: app("x - y - Slack")))
    }
}
