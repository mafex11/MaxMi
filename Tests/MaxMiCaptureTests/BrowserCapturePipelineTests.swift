import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class BrowserCapturePipelineTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testSlackWebPreservesMessageBoundariesAndURLIdentity() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "app.zen-browser.zen"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("gecko-slack-chat"), windowTitle: "general - Workspace", browser: browser
        )
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertEqual(result.capture.sourceKey, "https://app.slack.com/client/T123/C456")
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(result.capture.content,
                       "(From: Alex): Morning update\n(From: Sam): Reviewing the browser parser")
        XCTAssertEqual(result.quality, .high)
        XCTAssertTrue(result.parserID.contains("gecko/slack/webArea/quality-high"))
    }

    func testGmailWebUsesEmailProfile() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("chromium-gmail-thread"), windowTitle: "Project update - Gmail", browser: browser
        )
        XCTAssertEqual(result.webApp, .gmail)
        XCTAssertEqual(result.capture.contentKind, .email)
        XCTAssertEqual(result.capture.accumulationPolicy, .rollingText)
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertTrue(result.capture.sourceKey.hasPrefix("https://mail.google.com/"))
    }

    func testAllDedicatedWebAppsClassify() {
        let cases: [(String, WebAppKind)] = [
            ("https://mail.google.com/mail/u/0/#inbox", .gmail),
            ("https://app.slack.com/client/T/C", .slack),
            ("https://discord.com/channels/G/C", .discord),
            ("https://web.whatsapp.com/", .whatsapp),
            ("https://teams.microsoft.com/v2/", .teams),
            ("https://outlook.office.com/mail/", .outlook),
            ("https://www.linkedin.com/messaging/", .linkedin),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(WebAppCaptureParser.classify(url: url), expected, url)
        }
    }

    func testAWebAreaThatRendersNoRegionsIsRefused() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        // Text is present but the web area has collapsed to zero size, so nothing on the page is
        // on screen: the tab text still reads, the typed page comes out with no regions at all.
        let text = AXNode(role: "AXStaticText", value: "Loading", title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 200, height: 16),
                          focused: false, children: [])
        let webArea = AXNode(role: "AXWebArea", value: nil, title: "Docs",
                             url: "https://example.com/docs", frame: .zero,
                             focused: false, children: [text])
        let window = AXNode(role: "AXWindow", value: nil, title: "Docs", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                            focused: false, children: [webArea])
        XCTAssertThrowsError(try BrowserCapturePipeline.parse(
            window: window, windowTitle: "Docs", browser: browser
        )) { XCTAssertEqual($0 as? ExtractionError, .emptyContent) }
    }

    func testConversationKeepsRepeatedMessagesAtDifferentPositions() {
        func text(_ value: String, y: CGFloat) -> AXNode {
            AXNode(
                role: "AXStaticText", value: value, title: nil, url: nil,
                frame: CGRect(x: 0, y: y, width: 100, height: 16),
                focused: false, children: []
            )
        }
        func row(_ y: CGFloat) -> AXNode {
            AXNode(
                role: "AXRow", value: nil, title: nil, url: nil,
                frame: CGRect(x: 0, y: y, width: 400, height: 30),
                focused: false, children: [text("Alex", y: y), text("yes", y: y + 1)]
            )
        }
        let root = AXNode(
            role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
            focused: false, children: [row(100), row(200)]
        )

        XCTAssertEqual(
            WebAppCaptureParser.messageLines(in: root),
            ["Alex: yes", "Alex: yes"]
        )
    }
}
