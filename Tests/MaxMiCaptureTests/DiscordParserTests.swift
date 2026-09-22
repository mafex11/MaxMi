import XCTest
import MaxMiCore
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

    // ── Message extraction: a transcript list is the only anchor; Discord frames are unreliable. ──
    func testExtractsMessagesFiltersChrome() throws {
        let win = node("AXWindow", nil, x: 230, [
            AXNode(
                role: "AXList", value: nil, title: nil, url: nil,
                frame: CGRect(x: 460, y: 0, width: 10, height: 10), focused: false,
                children: [
                    node("AXGroup", nil, x: 460, [
                        AXNode(role: "AXHeading", value: "Afton", title: nil, url: nil,
                               frame: nil, focused: false, children: []),
                        node("AXStaticText", "Shukudai given by Afton senpai is completed.", x: 462),
                        node("AXStaticText", "Add Reaction", x: 462),   // chrome -> dropped
                        node("AXStaticText", "Great work everyone!", x: 462),
                        node("AXStaticText", "Message", x: 462),         // chrome -> dropped
                    ]),
                ],
                label: "Messages in 宿題"
            ),
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
        // Frames are unreliable in Discord; an anchored frameless text node must still be captured.
        let win = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [
            AXNode(role: "AXList", value: nil, title: nil, url: nil, frame: nil, focused: false,
                   children: [
                    AXNode(role: "AXGroup", value: nil, title: nil, url: nil, frame: nil,
                           focused: false, children: [
                            AXNode(role: "AXStaticText", value: "message with no frame",
                                   title: nil, url: nil, frame: nil, focused: false, children: []),
                           ]),
                   ], identifier: nil, label: "Messages in c")
        ])
        let cap = try XCTUnwrap(try DiscordParser().parse(window: win, app: app("#c | s - Discord")))
        XCTAssertTrue(cap.content.contains("message with no frame"))
    }

    func testV2ParseHardBoundsOversizeContent() throws {
        func conversationWindow(_ messages: [String]) -> AXNode {
            node("AXWindow", nil, x: 230, [
                AXNode(
                    role: "AXList", value: nil, title: nil, url: nil,
                    frame: nil, focused: false,
                    children: messages.enumerated().map { index, message in
                        AXNode(
                            role: "AXGroup", value: nil, title: nil, url: nil,
                            frame: nil, focused: false,
                            children: [
                                AXNode(
                                    role: "AXHeading", value: "Mira", title: nil, url: nil,
                                    frame: nil, focused: false, children: []
                                ),
                                node("AXStaticText", message, x: 460),
                            ]
                        )
                    },
                    identifier: nil, label: "Messages in general"
                ),
            ])
        }

        let parser = DiscordParser()
        let small = try XCTUnwrap(try parser.parse(
            window: conversationWindow(["A short message"]), app: app("#general | Acme - Discord")))
        XCTAssertFalse(small.truncated)

        let oversizedWindow = conversationWindow((0..<120).map {
            "message \($0) " + String(repeating: "discord body ", count: 10)
        })
        let direct = try XCTUnwrap(try parser.parse(
            oversizedWindow, context: ParseContext(app: app("#general | Acme - Discord"))
        ))
        XCTAssertLessThanOrEqual(
            ContentRenderer.render(direct, style: .full).count,
            DiscordParser.contentCap
        )

        let oversize = try XCTUnwrap(try parser.parse(
            window: oversizedWindow, app: app("#general | Acme - Discord")
        ))
        XCTAssertTrue(oversize.truncated)
        XCTAssertLessThanOrEqual(oversize.content.count, DiscordParser.contentCap)
    }
}
