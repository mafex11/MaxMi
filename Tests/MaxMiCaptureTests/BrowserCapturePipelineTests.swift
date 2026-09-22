import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class BrowserCapturePipelineTests: XCTestCase {
    func testSlackWebFallsBackToAGenericPageAndKeepsURLIdentity() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "app.zen-browser.zen"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("gecko-slack-chat"), windowTitle: "general - Workspace", browser: browser
        )
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertEqual(result.capture.sourceKey, "https://app.slack.com/client/T123/C456")
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.accumulationPolicy, .appendItems)
        guard case .generic = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("an unclaimed host must fall through to the generic web page")
        }
        XCTAssertEqual(result.capture.content, ContentRenderer.render(
            try XCTUnwrap(result.capture.structured), style: .full))
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
        XCTAssertEqual(result.capture.accumulationPolicy, .replace)
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertTrue(result.capture.sourceKey.hasPrefix("https://mail.google.com/"))
    }

    func testRegisteredHostFallbackPageIsBoundedToTheGenericPageBudget() throws {
        func paragraph(_ value: String, y: CGFloat) -> AXNode {
            AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
                   frame: CGRect(x: 20, y: y, width: 600, height: 16), focused: false,
                   children: [])
        }
        let url = "https://mail.google.com/mail/u/0/#inbox/oversized"
        let webArea = AXNode(
            role: "AXWebArea", value: nil, title: "Gmail", url: url,
            frame: CGRect(x: 0, y: 40, width: 1200, height: 760), focused: false,
            children: [
                paragraph("Paragraph one is visible.", y: 80),
                paragraph("Paragraph two is visible.", y: 110),
                paragraph("Paragraph three is visible.", y: 140),
                paragraph("Paragraph four is visible.", y: 170),
                paragraph("Paragraph five is visible.", y: 200),
            ]
        )
        let window = AXNode(
            role: "AXWindow", value: nil, title: "Gmail", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800), focused: false,
            children: [webArea]
        )
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: window, windowTitle: "Gmail", browser: browser, contentBudget: 120
        )

        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("a host parser without anchors must fall through to its generic page")
        }
        XCTAssertTrue(result.parserID.contains("fallback/GmailParser"))
        XCTAssertLessThan(page.regions[0].blocks.count, 5)
        XCTAssertLessThanOrEqual(ContentRenderer.render(.generic(page), style: .full).count, 120)
        XCTAssertTrue(result.truncated)
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

}
