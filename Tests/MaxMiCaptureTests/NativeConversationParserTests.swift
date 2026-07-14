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
}
