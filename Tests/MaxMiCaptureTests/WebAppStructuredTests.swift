import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebAppStructuredTests: XCTestCase {
    func testSlackWebWithoutAHostParserProducesAGenericPage() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "app.zen-browser.zen"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("gecko-slack-chat"),
            windowTitle: "Slack", browser: browser
        )
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.url,
                       "https://app.slack.com/fixture/workspace-alpha/channel-general/thread-placeholder?source=fixture")
        XCTAssertFalse(page.regions.isEmpty)
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.content, ContentRenderer.render(.generic(page), style: .full))
        XCTAssertTrue(result.parserID.contains("gecko/slack/webArea/quality-high"))
    }

    func testGenericPageProducesATypedGenericPageCarryingItsURL() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.apple.Safari"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("safari-domain-only"),
            windowTitle: "Example Article", browser: browser
        )
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.url, "https://example.com")
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["Article body text."])
        XCTAssertEqual(result.capture.contentKind, .webpage)
        XCTAssertEqual(result.capture.content, "URL: https://example.com\nArticle body text.")
    }

    func testGmailKeepsEmailKindWithAGenericShape() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("chromium-gmail-thread"),
            windowTitle: "Project update - Gmail", browser: browser
        )
        XCTAssertEqual(result.webApp, .gmail)
        XCTAssertEqual(result.capture.contentKind, .email,
                       "kind is not derived from the shape")
        XCTAssertEqual(result.capture.accumulationPolicy, .replace,
                       "a typed page is the tab's whole current state")
        XCTAssertEqual(try XCTUnwrap(result.capture.structured).kind, .generic)
        XCTAssertEqual(result.capture.content, ContentRenderer.render(
            try XCTUnwrap(result.capture.structured), style: .full))
    }

    func testPrimaryWebAreaIsFoundForTheGenericPath() throws {
        let webArea = BrowserTabExtractor.primaryWebArea(
            in: try fixture("chrome-article"), windowTitle: "How SQLite Works", engine: .chromium)
        XCTAssertEqual(webArea?.role, "AXWebArea")
        XCTAssertEqual(webArea?.url, "https://docs.invalid/architecture")
    }

    func testPrimaryWebAreaIsNilWhenTheWindowExposesNone() throws {
        XCTAssertNil(BrowserTabExtractor.primaryWebArea(
            in: try fixture("safari-domain-only"), windowTitle: "Example Article", engine: .webkit))
    }

    func testWebAreaAbsentFallsBackToTheWindowWithoutBrowserChrome() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "No web area", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXStaticText", value: "chrome only", title: nil, url: nil,
                   frame: CGRect(x: 10, y: 10, width: 200, height: 16), focused: false, children: []),
        ])
        let tab = TabCapture(url: "https://example.com/x", title: "x", content: "chrome only",
                             urlSource: .addressBar, quality: .fallback, truncated: false)
        guard case .generic(let page) = WebPageParser.parse(window: window, tab: tab) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["chrome only"])
        XCTAssertEqual(page.url, "https://example.com/x")
    }

    /// A page can be far under the raw cap and still lose blocks to the region budgets. That is a
    /// bounded capture and the pipeline has to say so, or the MCP disclosure goes silent.
    func testBudgetedAwayPageBlocksReportTruncationEndToEnd() throws {
        func paragraph(_ value: String, y: CGFloat) -> AXNode {
            AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
                   frame: CGRect(x: 10, y: y, width: 400, height: 16), focused: false, children: [])
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "Long page", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXWebArea", value: nil, title: "Long page",
                   url: "https://example.com/long",
                   frame: CGRect(x: 0, y: 40, width: 800, height: 560), focused: false, children: [
                paragraph("Paragraph one.", y: 60),
                paragraph("Paragraph two.", y: 80),
                paragraph("Paragraph three.", y: 100),
                paragraph("Paragraph four.", y: 120),
                paragraph("Paragraph five.", y: 140),
            ]),
        ])
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.apple.Safari"))
        let result = try BrowserCapturePipeline.parse(
            window: window, windowTitle: "Long page", browser: browser, contentBudget: 60
        )
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertLessThan(page.regions[0].blocks.count, 5, "the budget must have dropped blocks")
        XCTAssertLessThan(result.capture.content.count, WebAppCaptureParser.contentCap,
                          "the raw page is far under the 16k cap, so only the budget signal can fire")
        XCTAssertTrue(result.truncated)
    }

    func testWebAppMetadataKeepsConversationIdentityWithoutSelectingItsShape() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
                            focused: false, children: [])
        let tab = TabCapture(url: "https://app.slack.com/client/T/C", title: "general",
                             content: "first\nsecond", urlSource: .webArea, quality: .high,
                             truncated: false)

        let result = try WebAppCaptureParser.parse(tab: tab, window: window)
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.accumulationPolicy, .appendItems)
        XCTAssertNil(result.capture.structured)
    }

}
