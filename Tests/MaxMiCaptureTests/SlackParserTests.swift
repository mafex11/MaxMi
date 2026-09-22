import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class SlackParserTests: XCTestCase {
    func app(_ title: String?) -> AppInfo {
        AppInfo(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", windowTitle: title)
    }

    func domWindow(_ bodies: [String]) -> AXNode {
        AXNode(
            role: "AXWindow", value: nil, title: nil, url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
            children: [
                AXNode(
                    role: "AXGroup", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 240, y: 0, width: 900, height: 700), focused: false,
                    children: bodies.enumerated().map { index, body in
                        let y = CGFloat(index * 30)
                        return AXNode(
                            role: "AXGroup", value: nil, title: nil, url: nil,
                            frame: CGRect(x: 240, y: y, width: 900, height: 28), focused: false,
                            children: [
                                AXNode(
                                    role: "AXStaticText", value: "Mira", title: nil, url: nil,
                                    frame: CGRect(x: 240, y: y, width: 100, height: 16),
                                    focused: false, children: [], domClassList: ["c-message__sender"]
                                ),
                                AXNode(
                                    role: "AXStaticText", value: body, title: nil, url: nil,
                                    frame: CGRect(x: 240, y: y + 16, width: 600, height: 16),
                                    focused: false, children: []
                                ),
                            ],
                            domClassList: ["c-virtual_list__item"]
                        )
                    },
                    domClassList: ["c-message_list"]
                ),
            ]
        )
    }

    func testV2CaptureHardBoundsOversizeStructuredContent() throws {
        let parser = SlackParser()
        let small = try XCTUnwrap(try parser.parse(
            window: domWindow(["A short message"]), app: app("#general - Acme - Slack")))
        XCTAssertFalse(small.truncated)

        let oversizedWindow = domWindow([String(repeating: "x", count: SlackParser.contentCap * 2)])
        let direct = try XCTUnwrap(try parser.parse(
            oversizedWindow, context: ParseContext(app: app("#general - Acme - Slack"))
        ))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(direct, style: .full).count,
            SlackParser.contentCap
        )

        let oversize = try XCTUnwrap(try parser.parse(
            window: oversizedWindow, app: app("#general - Acme - Slack")
        ))
        XCTAssertTrue(oversize.truncated)
        XCTAssertLessThanOrEqual(oversize.content.count, SlackParser.contentCap)
        XCTAssertEqual(oversize.content,
                       ContentRenderer.render(try XCTUnwrap(oversize.structured), style: .full))
    }

    func testKeyFromTitleAndSenderAttributedMessages() throws {
        let win = try fixture("slack-dom-messages")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("#general - Acme - Slack")))
        XCTAssertEqual(cap.sourceApp, "Slack")
        XCTAssertEqual(cap.sourceKey, "slack:acme/general")
        XCTAssertTrue(cap.content.contains("(From: Arin)(sent 09:12 AM): cache warmup finished"))
        XCTAssertTrue(cap.content.contains("(From: Bela)(sent 09:14 AM): queue is clear"))
        // message ordering top->bottom
        XCTAssertLessThan(cap.content.range(of: "Arin")!.lowerBound, cap.content.range(of: "Bela")!.lowerBound)
    }
    func testUnexpectedTitleFallsBackToFullTitleKey() throws {
        let win = try fixture("slack-dom-messages")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("Huddle")))
        XCTAssertEqual(cap.sourceKey, "slack:huddle")
    }
    func testNilTitleStillParses() throws {
        let win = try fixture("slack-dom-messages")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app(nil)))
        XCTAssertTrue(cap.sourceKey.hasPrefix("slack:"))
    }
    func testEmptyMessageAreaReturnsNil() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [])
        XCTAssertNil(try SlackParser().parse(window: bare, app: app("x - y - Slack")))
    }
    func testUnanchoredRowsReturnNilForGenericFallThrough() throws {
        let win = AXNode(
            role: "AXWindow", value: nil, title: nil, url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
            children: [
                AXNode(
                    role: "AXRow", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 240, y: 100, width: 500, height: 20), focused: false,
                    children: [
                        AXNode(
                            role: "AXStaticText", value: "sidebar-like row", title: nil, url: nil,
                            frame: CGRect(x: 240, y: 100, width: 400, height: 18),
                            focused: false, children: []
                        ),
                    ]
                ),
            ]
        )
        XCTAssertNil(try SlackParser().parse(window: win, app: app("#general - Acme - Slack")))
    }
}
