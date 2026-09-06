import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebAppStructuredTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testSlackWebProducesTypedConversationMessages() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "app.zen-browser.zen"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("gecko-slack-chat"),
            windowTitle: "Slack", browser: browser
        )
        guard case .conversation(let conversation) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Slack")
        XCTAssertFalse(conversation.isGroup, "no group signal survives the web walk")
        XCTAssertEqual(conversation.messages.map(\.sender), ["Alex", "Sam"])
        XCTAssertEqual(conversation.messages.map(\.text),
                       ["Morning update", "Reviewing the browser parser"])
        XCTAssertEqual(conversation.messages.map(\.isUser), [false, false])
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.content,
                       "(From: Alex): Morning update\n(From: Sam): Reviewing the browser parser")
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
        XCTAssertEqual(result.capture.accumulationPolicy, .rollingText)
        XCTAssertEqual(try XCTUnwrap(result.capture.structured).kind, .generic)
        XCTAssertEqual(result.capture.content, ContentRenderer.render(
            try XCTUnwrap(result.capture.structured), style: .full))
    }

    func testPrimaryWebAreaIsFoundForTheGenericPath() throws {
        let webArea = BrowserTabExtractor.primaryWebArea(
            in: try fixture("chrome-article"), windowTitle: "How SQLite Works", engine: .chromium)
        XCTAssertEqual(webArea?.role, "AXWebArea")
        XCTAssertEqual(webArea?.url, "https://sqlite.org/arch.html")
    }

    func testPrimaryWebAreaIsNilWhenTheWindowExposesNone() throws {
        XCTAssertNil(BrowserTabExtractor.primaryWebArea(
            in: try fixture("safari-domain-only"), windowTitle: "Example Article", engine: .webkit))
    }

    func testWebAreaAbsentFallsBackToTheWholeWindow() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "No web area", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXStaticText", value: "chrome only", title: nil, url: nil,
                   frame: CGRect(x: 10, y: 10, width: 200, height: 16), focused: false, children: []),
        ])
        let tab = TabCapture(url: "https://example.com/x", title: "x", content: "chrome only",
                             urlSource: .addressBar, quality: .fallback, truncated: false)
        let result = WebAppCaptureParser.parse(tab: tab, window: window)
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["chrome only"])
        XCTAssertEqual(page.url, "https://example.com/x")
    }

    func testMessageLinesHelperIsUnchanged() {
        func text(_ value: String, y: CGFloat) -> AXNode {
            AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
                   frame: CGRect(x: 0, y: y, width: 100, height: 16), focused: false, children: [])
        }
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 100, width: 400, height: 30), focused: false,
                         children: [text("Alex", y: 100), text("yes", y: 101)])
        let root = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
                          focused: false, children: [row])
        XCTAssertEqual(WebAppCaptureParser.messageLines(in: root), ["Alex: yes"])
        XCTAssertEqual(WebAppCaptureParser.messages(in: root).map(\.sender), ["Alex"])
        XCTAssertEqual(WebAppCaptureParser.messages(in: root).map(\.text), ["yes"])
    }

    /// A one-label bubble is never re-split on ": ": that fabricates a sender.
    func testSingleLabelContainerKeepsItsWholeTextAsAnUnattributedMessage() {
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 100, width: 400, height: 30), focused: false,
                         children: [
            AXNode(role: "AXStaticText", value: "Note: check the doc", title: nil, url: nil,
                   frame: CGRect(x: 0, y: 100, width: 300, height: 16), focused: false, children: []),
        ])
        let root = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
                          focused: false, children: [row])
        let messages = WebAppCaptureParser.messages(in: root)
        XCTAssertEqual(messages.map(\.sender), ["unknown"])
        XCTAssertEqual(messages.map(\.text), ["Note: check the doc"])
    }
}
