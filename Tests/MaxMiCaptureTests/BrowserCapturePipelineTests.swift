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
        XCTAssertEqual(result.capture.content, "Alex: Morning update\nSam: Reviewing the browser parser")
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
}
