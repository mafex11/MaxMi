import XCTest
@testable import MaxMiCapture

final class ExtractorTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
    func testWebAreaURLWinsOverAddressBar() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("zen-meet"), windowTitle: "Meet - Daily Sync")
        XCTAssertEqual(cap.url, "https://meet.google.com/abc-defg-hij", "AXURL, not the scheme-less combo box")
        XCTAssertEqual(cap.title, "Meet - Daily Sync")
    }
    func testVisualOrderTopToBottomThenLeft() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("zen-meet"), windowTitle: nil)
        XCTAssertEqual(cap.content.components(separatedBy: "\n"),
                       ["Daily Sync", "Right of title", "Participants joined", "Left column later row"])
    }
    func testSafariFallbackNormalizesSchemelessDomain() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("safari-domain-only"), windowTitle: "Example Article")
        XCTAssertEqual(cap.url, "https://example.com", "address-bar fallback gets https:// prefixed")
        XCTAssertEqual(cap.content, "Article body text.")
    }
    func testFocusedAddressFieldIgnoredWhenWebAreaPresent() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("chrome-article"), windowTitle: nil)
        XCTAssertEqual(cap.url, "https://sqlite.org/arch.html")
        XCTAssertFalse(cap.content.contains("how does sqli"), "toolbar text is not page content")
    }
    func testFocusedAddressFieldWithoutWebAreaThrows() throws {
        // simulate mid-typing: safari-domain-only fixture but with address field focused and partially typed
        let fx = AXNode(
            role: "AXWindow", value: nil, title: "Example Article", url: nil,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800), focused: false,
            children: [
                AXNode(
                    role: "AXToolbar", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 38), focused: false,
                    children: [
                        AXNode(
                            role: "AXTextField", value: "example.co", title: "Address and search", url: nil,
                            frame: CGRect(x: 300, y: 4, width: 500, height: 30), focused: true,
                            children: []
                        )
                    ]
                ),
                AXNode(
                    role: "AXGroup", value: nil, title: nil, url: nil,
                    frame: CGRect(x: 0, y: 38, width: 1200, height: 762), focused: false,
                    children: [
                        AXNode(
                            role: "AXStaticText", value: "Article body text.", title: nil, url: nil,
                            frame: CGRect(x: 20, y: 60, width: 600, height: 20), focused: false,
                            children: []
                        )
                    ]
                )
            ]
        )
        XCTAssertThrowsError(try BrowserTabExtractor.extract(window: fx, windowTitle: nil)) {
            XCTAssertEqual($0 as? ExtractionError, .addressFieldFocused)
        }
    }
    func testNoURLAnywhereThrows() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [])
        XCTAssertThrowsError(try BrowserTabExtractor.extract(window: bare, windowTitle: nil)) {
            XCTAssertEqual($0 as? ExtractionError, .noURL)
        }
    }
}
