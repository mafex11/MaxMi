import XCTest
@testable import MaxMiCapture

final class DiscordParserTests: XCTestCase {
    // Discord frames: message content at x≈402 (winX 230), sidebar left of ~220 window-relative.
    func node(_ role: String, _ value: String? = nil, x: CGFloat = 400, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: 0, width: 10, height: 10), focused: false, children: kids)
    }
    func app(_ title: String?) -> AppInfo { AppInfo(bundleID: "com.hnc.Discord", name: "Discord", windowTitle: title) }

    // ── Key from "#channel | server - Discord" (real probe title) ──
    func testKeyServerChannel() {
        let p = DiscordParser()
        XCTAssertEqual(p.key(fromTitle: "#宿題 | にほん - Discord"), "discord:にほん/宿題")
        XCTAssertEqual(p.key(fromTitle: "#general | My Server - Discord"), "discord:my-server/general")
    }
    func testKeyDMFallback() {
        // DMs often lack the "| server" part
        XCTAssertEqual(DiscordParser().key(fromTitle: "@someuser - Discord"), "discord:@someuser")
    }
    func testKeyNilTitle() {
        XCTAssertEqual(DiscordParser().key(fromTitle: nil), "discord:unknown")
    }

    // ── Message extraction: real message text kept, UI chrome filtered (no x-band: Discord
    //    frames unreliable, so identity comes from the title key, not spatial filtering) ──
    func testExtractsMessagesFiltersChrome() throws {
        let win = node("AXWindow", nil, x: 230, [
            node("AXGroup", nil, x: 460, [
                node("AXStaticText", "Shukudai given by Afton senpai is completed.", x: 462),
                node("AXStaticText", "Add Reaction", x: 462),   // chrome -> dropped
                node("AXStaticText", "Great work everyone!", x: 462),
                node("AXStaticText", "Message", x: 462),         // chrome -> dropped
            ]),
        ])
        let cap = try XCTUnwrap(try DiscordParser().parse(window: win, app: app("#宿題 | にほん - Discord")))
        XCTAssertEqual(cap.sourceApp, "Discord")
        XCTAssertEqual(cap.sourceKey, "discord:にほん/宿題")
        XCTAssertTrue(cap.content.contains("Shukudai given by Afton senpai"))
        XCTAssertTrue(cap.content.contains("Great work everyone!"))
        XCTAssertFalse(cap.content.contains("Add Reaction"), "reaction chrome must be filtered")
        XCTAssertFalse(cap.content.contains("Message\n") || cap.content.hasSuffix("Message"), "Message chrome filtered")
    }

    func testEmptyChannelReturnsNil() throws {
        // no AXStaticText message content at all
        let win = node("AXWindow", nil, x: 230, [node("AXButton", nil, x: 235)])
        XCTAssertNil(try DiscordParser().parse(window: win, app: app("#empty | server - Discord")))
    }

    func testFramelessTextKept() throws {
        // frames are unreliable in Discord; a frameless text node must still be captured
        let win = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [
            AXNode(role: "AXStaticText", value: "message with no frame", title: nil, url: nil, frame: nil, focused: false, children: [])
        ])
        let cap = try XCTUnwrap(try DiscordParser().parse(window: win, app: app("#c | s - Discord")))
        XCTAssertTrue(cap.content.contains("message with no frame"))
    }
}
