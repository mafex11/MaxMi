import XCTest
@testable import MaxMiCapture

final class GenericAXParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false, children: children)
    }
    func app(_ title: String? = "My Note") -> AppInfo {
        AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: title)
    }

    func testCollectsVisualOrderTextWithBundleTitleKey() throws {
        let win = node("AXWindow", children: [
            node("AXStaticText", value: "Second line", frame: CGRect(x: 0, y: 100, width: 10, height: 10)),
            node("AXStaticText", value: "First line", frame: CGRect(x: 0, y: 10, width: 10, height: 10)),
        ])
        let cap = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app()))
        XCTAssertEqual(cap.sourceApp, "Notes")
        XCTAssertEqual(cap.sourceKey, "com.apple.Notes:My Note")
        XCTAssertEqual(cap.content, "First line\nSecond line")
        XCTAssertEqual(cap.sourceTitle, "My Note")
    }
    func testNilWindowTitleFallsBackToWindowLiteral() throws {
        let win = node("AXWindow", children: [node("AXStaticText", value: "x", frame: CGRect(x: 0, y: 0, width: 1, height: 1))])
        let cap = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app(nil)))
        XCTAssertEqual(cap.sourceKey, "com.apple.Notes:window")
    }
    func testEmptyContentReturnsNil() throws {
        let win = node("AXWindow", children: [node("AXButton")])  // no static text
        XCTAssertNil(try GenericAXParser().parse(window: win, app: app()))
    }
}
