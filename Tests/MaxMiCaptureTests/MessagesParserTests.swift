import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class MessagesParserTests: XCTestCase {
    func node(_ role: String, _ value: String? = nil, y: CGFloat = 0, _ kids: [AXNode] = [],
              identifier: String? = nil) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: y, width: 10, height: 10), focused: false, children: kids,
               identifier: identifier)
    }
    func app(_ title: String?) -> AppInfo { AppInfo(bundleID: "com.apple.MobileSMS", name: "Messages", windowTitle: title) }
    func transcript(_ rows: [AXNode]) -> AXNode {
        node("AXList", y: 80, rows, identifier: "message-list")
    }

    func testKeyFromContactName() {
        XCTAssertEqual(MessagesParser().key(fromTitle: "Harnish"), "imessage:harnish")
        XCTAssertEqual(MessagesParser().key(fromTitle: "Mom and Dad"), "imessage:mom-and-dad")
    }
    func testKeyNilTitle() {
        XCTAssertEqual(MessagesParser().key(fromTitle: nil), "imessage:unknown")
    }

    func testExtractsConversationInVerticalOrder() throws {
        let win = node("AXWindow", nil, y: 0, [
            transcript([
                node("AXRow", y: 234, [node("AXTextArea", "hey are you free", y: 234)]),
                node("AXRow", y: 297, [node("AXTextArea", "yes what's up", y: 297)]),
                node("AXRow", y: 361, [node("AXTextArea", "call me", y: 361)]),
            ]),
        ])
        let cap = try XCTUnwrap(try MessagesParser().parse(window: win, app: app("Harnish")))
        XCTAssertEqual(cap.sourceApp, "Messages")
        XCTAssertEqual(cap.sourceKey, "imessage:harnish")
        XCTAssertEqual(cap.content,
                       ContentRenderer.render(try XCTUnwrap(cap.structured), style: .full))
    }

    func testSelfBoundingCaptureReportsTruncation() throws {
        func conversationWindow(_ messages: [String]) -> AXNode {
            node("AXWindow", nil, y: 0, [
                transcript(messages.enumerated().map { index, message in
                    node("AXRow", y: CGFloat(index * 20), [
                        node("AXTextArea", message, y: CGFloat(index * 20)),
                    ])
                }),
            ])
        }

        let small = try XCTUnwrap(try MessagesParser().parse(
            window: conversationWindow(["A short message"]), app: app("Harnish")))
        XCTAssertFalse(small.truncated)

        let oversize = try XCTUnwrap(try MessagesParser().parse(
            window: conversationWindow((0..<120).map {
                "message \($0) " + String(repeating: "bubble body ", count: 10)
            }),
            app: app("Harnish")
        ))
        XCTAssertTrue(oversize.truncated)
    }

    func testEmptyConversationReturnsNil() throws {
        XCTAssertNil(try MessagesParser().parse(window: node("AXWindow", nil, y: 0, [node("AXButton")]), app: app("Harnish")))
    }

    func testSortsByYNotTreeOrder() throws {
        // out-of-order children must still read top-to-bottom
        let win = node("AXWindow", nil, y: 0, [
            transcript([
                node("AXRow", y: 300, [node("AXTextArea", "third", y: 300)]),
                node("AXRow", y: 100, [node("AXTextArea", "first", y: 100)]),
                node("AXRow", y: 200, [node("AXTextArea", "second", y: 200)]),
            ]),
        ])
        let cap = try XCTUnwrap(try MessagesParser().parse(window: win, app: app("x")))
        XCTAssertEqual(cap.content,
                       ContentRenderer.render(try XCTUnwrap(cap.structured), style: .full))
    }
}
