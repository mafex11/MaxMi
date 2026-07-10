import XCTest
@testable import MaxMiCapture

final class MessagesParserTests: XCTestCase {
    func node(_ role: String, _ value: String? = nil, y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func app(_ title: String?) -> AppInfo { AppInfo(bundleID: "com.apple.MobileSMS", name: "Messages", windowTitle: title) }

    func testKeyFromContactName() {
        XCTAssertEqual(MessagesParser().key(fromTitle: "Harnish"), "imessage:harnish")
        XCTAssertEqual(MessagesParser().key(fromTitle: "Mom and Dad"), "imessage:mom-and-dad")
    }
    func testKeyNilTitle() {
        XCTAssertEqual(MessagesParser().key(fromTitle: nil), "imessage:unknown")
    }

    func testExtractsConversationInVerticalOrder() throws {
        let win = node("AXWindow", nil, y: 0, [
            node("AXTextArea", "hey are you free", y: 234),
            node("AXTextArea", "yes what's up", y: 297),
            node("AXTextArea", "call me", y: 361),
        ])
        let cap = try XCTUnwrap(try MessagesParser().parse(window: win, app: app("Harnish")))
        XCTAssertEqual(cap.sourceApp, "Messages")
        XCTAssertEqual(cap.sourceKey, "imessage:harnish")
        XCTAssertEqual(cap.content, "hey are you free\nyes what's up\ncall me")
    }

    func testEmptyConversationReturnsNil() throws {
        XCTAssertNil(try MessagesParser().parse(window: node("AXWindow", nil, y: 0, [node("AXButton")]), app: app("Harnish")))
    }

    func testSortsByYNotTreeOrder() throws {
        // out-of-order children must still read top-to-bottom
        let win = node("AXWindow", nil, y: 0, [
            node("AXTextArea", "third", y: 300),
            node("AXTextArea", "first", y: 100),
            node("AXTextArea", "second", y: 200),
        ])
        let cap = try XCTUnwrap(try MessagesParser().parse(window: win, app: app("x")))
        XCTAssertEqual(cap.content, "first\nsecond\nthird")
    }
}
