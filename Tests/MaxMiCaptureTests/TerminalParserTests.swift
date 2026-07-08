import XCTest
@testable import MaxMiCapture

final class TerminalParserTests: XCTestCase {
    func n(_ role: String, _ value: String? = nil, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false, children: kids)
    }
    func app(_ title: String?) -> AppInfo {
        AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: title)
    }

    // ── Blob extraction: terminal is one big AXTextArea ──
    func testGrabsLargestTextArea() throws {
        let win = n("AXWindow", nil, [
            n("AXTextArea", "short"),
            n("AXTextArea", "the much longer scrollback buffer content here"),
        ])
        let cap = try XCTUnwrap(try TerminalParser().parse(window: win, app: app(nil)))
        XCTAssertEqual(cap.sourceApp, "Warp")
        XCTAssertTrue(cap.content.contains("longer scrollback"))
    }
    func testEmptyTerminalReturnsNil() throws {
        XCTAssertNil(try TerminalParser().parse(window: n("AXWindow", nil, [n("AXButton")]), app: app(nil)))
    }

    // ── Option B: key groups by working directory ──
    func testKeyFromCwdInContent() {
        let p = TerminalParser()
        // a shell prompt line carrying the cwd
        let content = "some output\nsudhanshu@mac ~/code/personal/MaxMi % git status\n"
        XCTAssertEqual(p.terminalKey(app: app(nil), content: content), "terminal:warp/maxmi")
    }
    func testKeyUsesMostRecentCwd() {
        let p = TerminalParser()
        // two prompts; the LAST (most recent) wins
        let content = "u ~/code/ProjectA % ls\nu ~/code/ProjectB % vim\n"
        XCTAssertEqual(p.terminalKey(app: app(nil), content: content), "terminal:warp/projectb")
    }
    func testKeyFallsBackToTitleCwd() {
        let p = TerminalParser()
        // no path in content, but the title carries one
        XCTAssertEqual(p.terminalKey(app: app("~/code/MyRepo"), content: "just output, no path"),
                       "terminal:warp/myrepo")
    }
    func testKeyFallsBackToAppWhenNoPath() {
        let p = TerminalParser()
        XCTAssertEqual(p.terminalKey(app: app("✳ Review voice audit document"), content: "no paths here at all"),
                       "terminal:warp")
    }
    func testAbsoluteUsersPath() {
        let p = TerminalParser()
        XCTAssertEqual(p.terminalKey(app: app(nil), content: "x\n/Users/sudhanshu/code/Yuki $ npm test\n"),
                       "terminal:warp/yuki")
    }
}
