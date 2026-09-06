import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NativeConversationParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testWhatsAppExtractsConversationAndAtomicMessages() throws {
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        let capture = try XCTUnwrap(try WhatsAppParser().parse(
            window: fixture("whatsapp-conversation"), app: app
        ))
        XCTAssertEqual(capture.sourceApp, "WhatsApp")
        XCTAssertEqual(capture.sourceKey, "whatsapp:project-group")
        XCTAssertEqual(capture.sourceTitle, "Project Group")
        XCTAssertEqual(capture.content,
                       "(From: Alex): Morning update\n(From: You): I am reviewing it")
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(capture.parserVersion, 2)
    }

    func testSidebarRowsAreExcluded() throws {
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: nil)
        let capture = try XCTUnwrap(try WhatsAppParser().parse(
            window: fixture("whatsapp-conversation"), app: app
        ))
        XCTAssertFalse(capture.content.contains("Other Chat"))
    }

    /// Refuses rather than returning nil: nil would let the generic extractor store the sidebar
    /// chat list instead (spec 4f rule 3, refusal case).
    func testEmptyConversationRefusesInsteadOfFallingThrough() throws {
        let empty = AXNode(role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
                           frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                           focused: false, children: [])
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        XCTAssertThrowsError(try WhatsAppParser().parse(window: empty, app: app)) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "no-conversation-content"))
        }
    }

    func testWhatsAppReadsElectronSemanticButtonAndHeadingLabels() throws {
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

        let capture = try XCTUnwrap(try WhatsAppParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "whatsapp:controlled-group")
        // Each bubble is ONE accessible label, so a label is split only on a KNOWN participant.
        // This window titles the conversation "Controlled Group", so "Alex" is not vouched for
        // and stays part of the text; "You" always is.
        XCTAssertEqual(
            capture.content,
            """
            (From: unknown): Alex: First controlled message
            (From: You): Second controlled message
            """
        )
    }

    func testWhatsAppRejectsMainPaneFallbackWithoutChatHeaderAndMessageSemantics() throws {
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

        XCTAssertThrowsError(try WhatsAppParser().parse(window: window, app: app)) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "no-conversation-content"))
        }
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
