import XCTest
@testable import MaxMiCapture

final class MailParserTests: XCTestCase {
    // Build a node at a given screen x (message rows probed at x≈568, sidebar rows at x≈0).
    func node(_ role: String, _ value: String? = nil, x: CGFloat = 0, y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func app(_ title: String?) -> AppInfo { AppInfo(bundleID: "com.apple.mail", name: "Mail", windowTitle: title) }

    /// A message row: sender|date|subject|preview static texts, in the content area (x=568).
    func msgRow(_ sender: String, _ date: String, _ subject: String, _ preview: String, y: CGFloat) -> AXNode {
        node("AXRow", x: 568, y: y, [
            node("AXCell", x: 568, y: y, [
                node("AXStaticText", sender, x: 570, y: y),
                node("AXStaticText", date, x: 900, y: y),
                node("AXStaticText", subject, x: 570, y: y + 2),
                node("AXStaticText", preview, x: 570, y: y + 4),
            ])
        ])
    }

    func testExtractsMessageRowsFromContentArea() throws {
        let win = node("AXWindow", x: 0, y: 0, [
            // sidebar mailbox rows (x≈0) — must be excluded
            node("AXRow", x: 10, y: 40, [node("AXStaticText", "All Inboxes", x: 12, y: 40)]),
            node("AXRow", x: 10, y: 70, [node("AXStaticText", "Flagged", x: 12, y: 70)]),
            // message rows (from the live probe)
            msgRow("Pegasystems", "Yesterday", "Pega named a Leader in AI Decisioning", "Discover why Forrester", y: 100),
            msgRow("Naukri Campus Jobs", "07/07/26", "Sudhanshu, recruiters can’t see you!!", "Upload your resume", y: 130),
        ])
        let cap = try XCTUnwrap(try MailParser().parse(window: win, app: app("All Inboxes – 218 messages")))
        XCTAssertEqual(cap.sourceApp, "Mail")
        // message content present
        XCTAssertTrue(cap.content.contains("Pegasystems"))
        XCTAssertTrue(cap.content.contains("Pega named a Leader"))
        XCTAssertTrue(cap.content.contains("Naukri Campus Jobs"))
        // sidebar mailbox names excluded
        XCTAssertFalse(cap.content.contains("Flagged"), "sidebar chrome must not leak into content")
    }

    func testKeyStripsVolatileCount() {
        let p = MailParser()
        // "218 messages" changes constantly; the mailbox is the stable identity
        XCTAssertEqual(p.key(fromTitle: "All Inboxes – 218 messages"), "mail:all-inboxes")
        XCTAssertEqual(p.key(fromTitle: "All Inboxes – 221 messages"), "mail:all-inboxes")
    }
    func testKeyPlainMailbox() {
        XCTAssertEqual(MailParser().key(fromTitle: "Work"), "mail:work")
    }
    func testKeyNilTitle() {
        XCTAssertEqual(MailParser().key(fromTitle: nil), "mail:inbox")
    }

    func testEmptyMailboxReturnsNil() throws {
        // only sidebar chrome, no message rows in the content area
        let win = node("AXWindow", x: 0, y: 0, [
            node("AXRow", x: 10, y: 40, [node("AXStaticText", "All Inboxes", x: 12, y: 40)]),
        ])
        XCTAssertNil(try MailParser().parse(window: win, app: app("All Inboxes")))
    }

    func testSidebarExclusionIsWindowRelative() throws {
        // window floated at screen x=500: sidebar row at 510, message row at 1080 (winX+580)
        let win = node("AXWindow", x: 500, y: 0, [
            node("AXRow", x: 510, y: 40, [node("AXStaticText", "Sidebar Mailbox", x: 512, y: 40)]),
            node("AXRow", x: 1080, y: 100, [node("AXCell", x: 1080, y: 100, [
                node("AXStaticText", "RealSender", x: 1082, y: 100),
                node("AXStaticText", "Today", x: 1400, y: 100),
            ])]),
        ])
        let cap = try XCTUnwrap(try MailParser().parse(window: win, app: app("Work")))
        XCTAssertTrue(cap.content.contains("RealSender"))
        XCTAssertFalse(cap.content.contains("Sidebar Mailbox"))
    }
}
