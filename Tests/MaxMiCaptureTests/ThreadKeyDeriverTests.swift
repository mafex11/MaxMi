import XCTest
@testable import MaxMiCapture

final class ThreadKeyDeriverTests: XCTestCase {
    func cap(_ app: String, _ key: String, _ title: String? = nil, _ content: String = "x") -> ParsedCapture {
        ParsedCapture(sourceApp: app, sourceKey: key, sourceTitle: title, content: content)
    }

    // ── Universal hygiene ──
    func testStripsTrailingPunctuationAndBrackets() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/maxmi.app).", appFallback: "terminal:warp"),
                       "terminal:warp")   // ".app).": file-ext token -> coarsen to parent
    }
    func testStripsEllipsisTruncation() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/layer…)", appFallback: "terminal:warp"),
                       "terminal:warp/layer")
    }
    func testCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/My  Project", appFallback: "terminal:warp"),
                       "terminal:warp/my-project")
    }
    func testFileExtensionSegmentCoarsensToParent() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/inspect2.mjs", appFallback: "terminal:warp"),
                       "terminal:warp")
    }
    func testDegenerateKeyCoarsensToAppFallback() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:", appFallback: "terminal:warp"), "terminal:warp")
        XCTAssertEqual(ThreadKeyDeriver.hygiene("   ", appFallback: "web:unknown"), "web:unknown")
    }
    func testLengthBounded() {
        let long = "web:example.com/" + String(repeating: "a", count: 500)
        XCTAssertLessThanOrEqual(ThreadKeyDeriver.hygiene(long, appFallback: "web:example.com").count, 200)
    }

    // ── Web via URLKeyNormalizer (real dirty corpus) ──
    func testMapsCoordsCollapse() {
        let a = ThreadKeyDeriver.derive(cap("Web", "https://www.google.com/maps/@13.0001,77.71,2550m/data=!3?entry=ttu"))
        let b = ThreadKeyDeriver.derive(cap("Web", "https://www.google.com/maps/@12.999,77.71,2070m/data=!3?entry=ttu"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "https://www.google.com/maps")
    }
    func testDocsTabFractureCollapses() {
        let id = "1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg"
        let a = ThreadKeyDeriver.derive(cap("Web", "https://docs.google.com/document/d/\(id)/edit?tab=t.6xoj"))
        let b = ThreadKeyDeriver.derive(cap("Web", "https://docs.google.com/document/d/\(id)/edit?tab=t.p2vx"))
        XCTAssertEqual(a, b)
    }

    // ── Per-app: non-web keys pass through hygiene but keep their scheme ──
    func testSlackKeyPreserved() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Slack", "slack:acme/general")), "slack:acme/general")
    }
    func testTerminalGarbageKeyCleaned() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Warp", "terminal:warp/maxmi.app).")), "terminal:warp")
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Warp", "terminal:warp/inspect2.mjs")), "terminal:warp")
    }
    func testMailKeyPreserved() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Mail", "mail:inbox")), "mail:inbox")
    }

    func testDocTitleWithDotNotCoarsened() {
        // Notion/Notes/Obsidian slug arbitrary titles; a dot in the title must NOT collapse the key.
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Notion", "notion:plan-v1.2")), "notion:plan-v1.2")
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Notes", "notes:node.js")), "notes:node.js")
        // and two different such docs stay DISTINCT
        XCTAssertNotEqual(ThreadKeyDeriver.derive(cap("Notion", "notion:plan-v1.2")),
                          ThreadKeyDeriver.derive(cap("Notion", "notion:budget-2.5")))
        // terminal garbage still coarsens (parent segment exists)
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Warp", "terminal:warp/inspect2.mjs")), "terminal:warp")
    }
}
