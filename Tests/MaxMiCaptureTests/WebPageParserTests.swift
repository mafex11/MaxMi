import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebPageParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, url: String? = nil,
              subrole: String? = nil, identifier: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 20), focused: false,
               children: children, identifier: identifier, label: nil, subrole: subrole)
    }

    /// A landmarked page inside a browser chrome window, optionally at a nonzero origin.
    func browserWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", title: "How SQLite Works",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: [
            node("AXToolbar", frame: CGRect(x: x, y: y, width: 1440, height: 42), children: [
                node("AXTextField", value: "sqlite.org/arch.html", title: "Address and search bar",
                     frame: CGRect(x: x + 250, y: y + 6, width: 700, height: 30)),
            ]),
            node("AXWebArea", url: "https://sqlite.org/arch.html",
                 frame: CGRect(x: x, y: y + 42, width: 1440, height: 858), children: [
                node("AXGroup", subrole: "AXLandmarkMain",
                     frame: CGRect(x: x + 300, y: y + 80, width: 900, height: 700), children: [
                    node("AXHeading", value: "Architecture",
                         frame: CGRect(x: x + 300, y: y + 80, width: 400, height: 28)),
                    node("AXStaticText", value: "SQLite is a library.",
                         frame: CGRect(x: x + 300, y: y + 120, width: 600, height: 20)),
                ]),
                node("AXGroup", subrole: "AXLandmarkComplementary",
                     frame: CGRect(x: x + 40, y: y + 80, width: 220, height: 700), children: [
                    node("AXStaticText", value: "On this page",
                         frame: CGRect(x: x + 40, y: y + 80, width: 200, height: 20)),
                ]),
                node("AXGroup", subrole: "AXLandmarkNavigation",
                     frame: CGRect(x: x + 300, y: y + 60, width: 900, height: 18), children: [
                    node("AXLink", title: "Docs",
                         frame: CGRect(x: x + 300, y: y + 60, width: 60, height: 18)),
                ]),
            ]),
        ])
    }

    func page(_ content: CapturedContent) throws -> GenericPage {
        guard case .generic(let page) = content else {
            throw XCTSkip("expected .generic, got \(content)")
        }
        return page
    }

    func testPrimaryWebAreaIsTheScoredWebArea() throws {
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: browserWindow(), windowTitle: "How SQLite Works", engine: .chromium))
        XCTAssertEqual(area.role, "AXWebArea")
        XCTAssertEqual(area.url, "https://sqlite.org/arch.html")
    }

    func testNoWebAreaYieldsNil() {
        XCTAssertNil(BrowserTabExtractor.primaryWebArea(
            in: node("AXWindow", children: [node("AXToolbar")]),
            windowTitle: nil, engine: .webkit))
    }

    func testLandmarksBecomeRegionsAndTheUrlIsCarried() throws {
        let window = browserWindow()
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: "How SQLite Works", engine: .chromium))
        let result = WebPageParser.extract(window: window, webArea: area,
                                          url: "https://sqlite.org/arch.html",
                                          options: GenericPageExtractor.Options())
        XCTAssertEqual(result.page.url, "https://sqlite.org/arch.html")
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .sidebar, .navigation])
        XCTAssertEqual(result.page.regions[0].blocks.map(\.text),
                       ["Architecture", "SQLite is a library."])
        XCTAssertEqual(result.page.regions[1].blocks.map(\.text), ["On this page"])
        XCTAssertEqual(result.page.regions[2].blocks.map(\.text), ["Docs"])
    }

    func testBrowserChromeOutsideTheWebAreaIsNeverCaptured() throws {
        let window = browserWindow()
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: nil, engine: .chromium))
        let rendered = ContentRenderer.render(
            .generic(WebPageParser.extract(window: window, webArea: area, url: nil,
                                           options: GenericPageExtractor.Options()).page),
            style: .full)
        XCTAssertFalse(rendered.contains("Address and search bar"))
        XCTAssertFalse(rendered.contains("sqlite.org/arch.html"),
                       "the address field's value is chrome, not page content")
    }

    func testRegionsAreIdenticalAtANonzeroWindowOrigin() throws {
        func regions(_ origin: CGPoint) throws -> [Region] {
            let window = browserWindow(origin: origin)
            let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
                in: window, windowTitle: nil, engine: .chromium))
            return WebPageParser.extract(window: window, webArea: area, url: nil,
                                        options: GenericPageExtractor.Options()).page.regions
        }
        XCTAssertEqual(try regions(.zero), try regions(CGPoint(x: 1440, y: 220)),
                       "region detection is window-relative, so the origin must not matter")
    }

    func testParseFromATabCaptureUsesTheTabUrl() throws {
        let tab = TabCapture(url: "https://sqlite.org/arch.html", title: "How SQLite Works",
                             content: "ignored", urlSource: .webArea, quality: .high,
                             truncated: false)
        let content = WebPageParser.parse(window: browserWindow(), tab: tab)
        XCTAssertEqual(try page(content).url, "https://sqlite.org/arch.html")
    }

    func testAWindowWithNoWebAreaFallsBackToTheWholeWindow() throws {
        // A browser can be showing a native error sheet with no web area at all. The parser must
        // still produce a page rather than nothing.
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        children: [
                            node("AXToolbar", children: [
                                node("AXStaticText", value: "Reload page"),
                            ]),
                            node("AXStaticText", value: "You are offline",
                                        frame: CGRect(x: 0, y: 0, width: 200, height: 20))])
        let tab = TabCapture(url: "https://example.com/", title: nil, content: "")
        XCTAssertEqual(try page(WebPageParser.parse(window: bare, tab: tab))
                        .regions.first?.blocks.map(\.text), ["You are offline"])
    }

    func testPipelineCarriesTheStructuredValueAndKeepsTheParserID() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(window: browserWindow(),
                                                     windowTitle: "How SQLite Works",
                                                     browser: browser)
        XCTAssertEqual(result.url, "https://sqlite.org/arch.html")
        XCTAssertEqual(result.webApp, .generic)
        XCTAssertTrue(result.parserID.hasPrefix("BrowserWeb.v2/chromium/generic/"))
        XCTAssertFalse(result.parserID.contains("fallback"),
                       "no host parser claimed this tab, so there is nothing to degrade from")
        XCTAssertEqual(result.capture.contentKind, .webpage, "spec §12 Q3: browsers keep .webpage")
        let structured = try XCTUnwrap(result.capture.structured,
                                       "the browser path always attaches a typed shape")
        XCTAssertEqual(result.capture.content, ContentRenderer.render(structured, style: .full))
        XCTAssertEqual(try page(structured).regions.map(\.kind), [.main, .sidebar, .navigation])
    }

    func testChromeLandmarksFixtureMatchesItsGolden() throws {
        let window = try fixture("chrome-landmarks")
        let tab = TabCapture(url: "https://example.com/docs/architecture", title: "Architecture",
                             content: "")
        assertGolden(WebPageParser.parse(window: window, tab: tab),
                     matches: "chrome-landmarks-golden")
    }

    func testOffsetSafariArticleFixtureMatchesItsGolden() throws {
        let window = try fixture("safari-offset-article")
        let tab = TabCapture(url: "https://example.com/posts/one", title: "One", content: "")
        assertGolden(WebPageParser.parse(window: window, tab: tab),
                     matches: "safari-offset-article-golden")
    }
}
