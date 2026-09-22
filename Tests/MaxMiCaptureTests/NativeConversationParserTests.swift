import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NativeConversationParserTests: XCTestCase {
    func testWhatsAppDoesNotReadTheUnanchoredLegacyFixture() throws {
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        let window = try fixture("whatsapp-conversation")
        XCTAssertNil(try WhatsAppParser().parseStructured(window: window, app: app))
        XCTAssertNil(try WhatsAppParser().parse(window: window, app: app))
    }

    func testSelfBoundingCaptureReportsTruncation() throws {
        func conversationWindow(_ bodies: [String]) -> AXNode {
            AXNode(
                role: "AXWindow", value: nil, title: "Project chat", url: nil,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
                children: [
                    AXNode(
                        role: "AXList", value: nil, title: nil, url: nil,
                        frame: CGRect(x: 400, y: 100, width: 500, height: 500),
                        focused: false,
                        children: bodies.enumerated().map { index, body in
                            AXNode(
                                role: "AXRow", value: nil, title: nil, url: nil,
                                frame: CGRect(x: 400, y: 100 + CGFloat(index * 20),
                                              width: 500, height: 18),
                                focused: false,
                                children: [
                                    AXNode(
                                        role: "AXStaticText", value: body, title: nil, url: nil,
                                        frame: CGRect(x: 420, y: 100 + CGFloat(index * 20),
                                                      width: 460, height: 18),
                                        focused: false, children: []
                                    )
                                ]
                            )
                        },
                        identifier: "teams-message-list",
                        label: "Chat message transcript"
                    )
                ]
            )
        }
        let app = AppInfo(
            bundleID: "com.microsoft.teams2", name: "Microsoft Teams", windowTitle: "Project chat"
        )

        let small = try XCTUnwrap(try TeamsParser().parse(
            window: conversationWindow(["A short message"]), app: app))
        XCTAssertFalse(small.truncated)

        let oversize = try XCTUnwrap(try TeamsParser().parse(
            window: conversationWindow((0..<200).map {
                "message \($0) " + String(repeating: "conversation body ", count: 10)
            }),
            app: app
        ))
        XCTAssertTrue(oversize.truncated)
    }

    func testTeamsRequiresTranscriptAnchorAndReadsOnlyItsMessages() throws {
        let app = AppInfo(
            bundleID: "com.microsoft.teams2", name: "Microsoft Teams", windowTitle: "Project chat"
        )
        let parser = TeamsParser()

        let unanchored = try fixture("teams-native-no-transcript")
        XCTAssertNil(try parser.parseStructured(window: unanchored, app: app))
        XCTAssertNil(try parser.parse(window: unanchored, app: app))

        guard case .conversation(let conversation) = try XCTUnwrap(
            parser.parseStructured(window: try fixture("teams-native-transcript"), app: app)
        ) else {
            return XCTFail("expected an anchored Teams conversation")
        }
        XCTAssertEqual(conversation.messages.map(\.text), [
            "anchored release note",
            "anchored follow-up",
        ])
        XCTAssertFalse(ContentRenderer.render(.conversation(conversation), style: .full)
            .contains("outside message row"))
    }

    func testEmptyConversationIsNotHandled() throws {
        let empty = AXNode(role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
                           frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                           focused: false, children: [])
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        XCTAssertNil(try WhatsAppParser().parse(window: empty, app: app))
    }

    func testWhatsAppDoesNotReadUnanchoredSemanticButtons() throws {
        let window = AXNode(
            role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
            children: [
                AXNode(
                    role: "AXHeading", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 400, y: 20, width: 300, height: 30), focused: false,
                    children: [], identifier: "conversation-header", label: "Controlled Group"
                ),
                AXNode(
                    role: "AXButton", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 420, y: 200, width: 400, height: 50), focused: false,
                    children: [], identifier: "message-1", label: "Alex: First controlled message"
                ),
                AXNode(
                    role: "AXButton", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 420, y: 260, width: 400, height: 50), focused: false,
                    children: [], identifier: "message-2", label: "You: Second controlled message"
                ),
            ]
        )
        let app = AppInfo(
            bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp"
        )

        XCTAssertNil(try WhatsAppParser().parse(window: window, app: app))
    }

    func testWhatsAppDoesNotReadMainPaneTextWithoutBubbleCells() throws {
        let window = AXNode(
            role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
            children: [
                AXNode(
                    role: "AXStaticText", value: "Use WhatsApp on your phone to see older messages.",
                    title: nil, url: nil,
                    frame: CGRect(x: 400, y: 30, width: 400, height: 30), focused: false,
                    children: []
                ),
                AXNode(
                    role: "AXStaticText", value: "A stale pane must not be captured.",
                    title: nil, url: nil,
                    frame: CGRect(x: 400, y: 250, width: 400, height: 30), focused: false,
                    children: []
                ),
            ]
        )
        let app = AppInfo(
            bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp"
        )

        XCTAssertNil(try WhatsAppParser().parse(window: window, app: app))
    }

    func testWhatsAppRejectsPinnedHeadingWithoutExplicitChatHeaderSemantics() throws {
        let window = AXNode(
            role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), focused: false,
            children: [
                AXNode(
                    role: "AXHeading", value: "Pinned message", title: nil, url: nil,
                    frame: CGRect(x: 400, y: 30, width: 300, height: 30), focused: false,
                    children: []
                ),
                AXNode(
                    role: "AXButton", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 400, y: 220, width: 400, height: 50), focused: false,
                    children: [], identifier: "WAMessageBubbleTableViewCell",
                    label: "A message that belongs to the pane"
                ),
            ]
        )
        let app = AppInfo(
            bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp"
        )

        XCTAssertThrowsError(try WhatsAppParser().parse(window: window, app: app)) { error in
            XCTAssertEqual(error as? ParserRefusal,
                           ParserRefusal(reason: "unconfirmed-conversation-identity"))
        }
    }

    /// A refusal reason is written verbatim into the log line, so it must survive
    /// `SafeLogToken(validating:)` — otherwise the refusal is recorded without its reason.
    func testEveryRefusalReasonIsLogTokenSafe() {
        for reason in ["no-conversation-content", "unconfirmed-conversation-identity"] {
            XCTAssertEqual(SafeLogToken(validating: reason)?.value, reason)
        }
    }
}
