import XCTest
@testable import MaxMiCapture

final class URLKeyNormalizerTests: XCTestCase {
    func norm(_ s: String) -> String { URLKeyNormalizer.normalize(s) }

    // ── Maps: every pan produced a distinct thread (18 in the live DB). Collapse to one. ──
    func testMapsCoordinatesCollapse() {
        let a = norm("https://www.google.com/maps/@13.0001195,77.7156015,2550m/data=!3m1!1e3?entry=ttu&g_ep=Eg")
        let b = norm("https://www.google.com/maps/@12.9993394,77.7161969,2070m/data=!3m1!1e3?entry=ttu&g_ep=Eg")
        XCTAssertEqual(a, b, "different map pans must share one thread key")
        XCTAssertEqual(a, "https://www.google.com/maps")
    }
    func testMapsNamedPlaceKept() {
        // a specific place is meaningful identity — keep it, drop the coord/zoom tail
        let a = norm("https://www.google.com/maps/place/Cubbon+Park/@12.976,77.59,17z/data=!x")
        let b = norm("https://www.google.com/maps/place/Cubbon+Park/@12.977,77.60,15z/data=!y")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "https://www.google.com/maps/place/Cubbon+Park")
    }

    // ── Search: q is identity; rlz/oq/gs_lcrp/etc are tracking noise. ──
    func testSearchKeepsOnlyQuery() {
        let a = norm("https://www.google.com/search?q=swift+regex&rlz=1C5&oq=swift&gs_lcrp=Eg&sourceid=chrome&ie=UTF-8&sei=xy")
        XCTAssertEqual(a, "https://www.google.com/search?q=swift+regex")
    }
    func testSameSearchDifferentTrackingCollapses() {
        let a = norm("https://www.google.com/search?q=maxmi&rlz=AAA&sei=111")
        let b = norm("https://www.google.com/search?q=maxmi&rlz=BBB&sei=222")
        XCTAssertEqual(a, b)
    }

    // ── Docs: same document, different tab, must be one thread. ──
    func testDocsSameDocDifferentTab() {
        let id = "1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg"
        let a = norm("https://docs.google.com/document/d/\(id)/edit?tab=t.6xojzimtfblx")
        let b = norm("https://docs.google.com/document/d/\(id)/edit?tab=t.p2vx04q83x25")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "https://docs.google.com/document/d/\(id)")
    }
    func testDifferentDocsStayDistinct() {
        let a = norm("https://docs.google.com/document/d/AAA/edit?tab=t.1")
        let b = norm("https://docs.google.com/document/d/BBB/edit?tab=t.1")
        XCTAssertNotEqual(a, b)
    }

    // ── Generic tracking strip on non-Google sites ──
    func testGenericUTMStripped() {
        let a = norm("https://example.com/article?utm_source=twitter&utm_campaign=x&id=42")
        XCTAssertEqual(a, "https://example.com/article?id=42", "keep real params, drop utm_*")
    }

    // ── Safety: don't mangle normal URLs or fragments that carry identity ──
    func testPlainURLUntouched() {
        XCTAssertEqual(norm("https://github.com/anthropics/claude-code"),
                       "https://github.com/anthropics/claude-code")
    }
    func testGmailFragmentKept() {
        // Gmail encodes the mailbox in the fragment; must not be dropped generically.
        XCTAssertEqual(norm("https://mail.google.com/mail/u/1/#inbox"),
                       "https://mail.google.com/mail/u/1/#inbox")
    }
    func testUnparseablePassesThrough() {
        XCTAssertEqual(norm("not a url"), "not a url")
    }
}
