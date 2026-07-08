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

    func testSingleOversizeMessageStillHardCapped() throws {
        // One message far larger than the cap must still be bounded (resource-bound guard).
        let huge = String(repeating: "x", count: 20_000)
        let win = AXNode(role: "AXWindow", value: nil, title: "c - w - Slack", url: nil, frame: nil, focused: false,
            children: [AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                              frame: CGRect(x: 240, y: 0, width: 10, height: 10), focused: false,
                children: [AXNode(role: "AXStaticText", value: huge, title: nil, url: nil,
                                  frame: CGRect(x: 240, y: 0, width: 10, height: 10), focused: false, children: [])])])
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("c - w - Slack")))
        XCTAssertLessThanOrEqual(cap.content.count, 8000, "single oversize message must not bypass the cap")
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
    func testSidebarRowsExcludedFromContent() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("general - Acme - Slack")))
        // message-area rows (x>=240) present
        XCTAssertTrue(cap.content.contains("Alice: shipped the build"))
        XCTAssertTrue(cap.content.contains("Bob: deploy looks green"))
        // sidebar row (x<240) excluded
        XCTAssertFalse(cap.content.contains("random-channel"), "sidebar chrome must not appear in message content")
    }
    func testContentCapAtWholeMessageBoundaries() throws {
        // Build 400 rows, each ~50 chars, totaling >8000 chars
        var rows: [AXNode] = []
        var allMessages: [String] = []
        for i in 0..<400 {
            let msg = "User\(i): message body number \(i) with some padding text"
            allMessages.append(msg)
            let textNode = AXNode(role: "AXStaticText", value: msg, title: nil, url: nil,
                                  frame: CGRect(x: 240, y: CGFloat(i * 20), width: 400, height: 18),
                                  focused: false, children: [])
            let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                            frame: CGRect(x: 240, y: CGFloat(i * 20), width: 500, height: 20),
                            focused: false, children: [textNode])
            rows.append(row)
        }
        let window = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
                           focused: false, children: rows)
        let cap = try XCTUnwrap(try SlackParser().parse(window: window, app: app("test - ws - Slack")))

        // 1. content.count <= 8000 (approximately — within one line)
        XCTAssertLessThanOrEqual(cap.content.count, 8000 + 100, "Content should be capped near 8000")

        // 2. The NEWEST message (last row by y) IS present
        let newestMsg = allMessages.last!
        XCTAssertTrue(cap.content.contains(newestMsg), "Newest message should be present")

        // 3. The OLDEST message (first row) is NOT present (it was dropped)
        let oldestMsg = allMessages.first!
        XCTAssertFalse(cap.content.contains(oldestMsg), "Oldest message should be dropped")

        // 4. Content does not start or end mid-word — all kept lines are complete
        let keptLines = cap.content.components(separatedBy: "\n")
        for line in keptLines {
            XCTAssertTrue(allMessages.contains(line), "Each kept line should be a complete original message")
        }
    }
}
