import XCTest
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
        XCTAssertEqual(capture.content, "Alex: Morning update\nYou: I am reviewing it")
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

    func testEmptyConversationReturnsNil() throws {
        let empty = AXNode(role: "AXWindow", value: nil, title: "WhatsApp", url: nil,
                           frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                           focused: false, children: [])
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", windowTitle: "WhatsApp")
        XCTAssertNil(try WhatsAppParser().parse(window: empty, app: app))
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
        XCTAssertEqual(
            capture.content,
            "Alex: First controlled message\nYou: Second controlled message"
        )
    }
}
