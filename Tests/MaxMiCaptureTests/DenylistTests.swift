import XCTest
@testable import MaxMiCapture

final class DenylistTests: XCTestCase {
    func testBlockedHostsAndPatterns() {
        XCTAssertTrue(Denylist.isBlocked("https://accounts.google.com/signin"))
        XCTAssertTrue(Denylist.isBlocked("https://vault.bitwarden.com/#/vault"))
        XCTAssertTrue(Denylist.isBlocked("https://my.1password.com/home"))
        XCTAssertTrue(Denylist.isBlocked("https://foo.okta.com/app"))
        XCTAssertTrue(Denylist.isBlocked("https://example.com/reset-password?token=x"))
        XCTAssertTrue(Denylist.isBlocked("https://netbanking.hdfcbank.com/netbanking"))
    }
    func testAllowedHosts() {
        XCTAssertFalse(Denylist.isBlocked("https://google.com/search?q=x"))
        XCTAssertFalse(Denylist.isBlocked("https://news.ycombinator.com"))
        XCTAssertFalse(Denylist.isBlocked("not a url"))  // unparseable -> allow, capture layer already has the URL
    }
    func testMeetingHostsBlocked() {
        // Live finding: a Meet code was extracted into a stored fact — meetings are sensitive.
        XCTAssertTrue(Denylist.isBlocked("https://meet.google.com/rtz-tyqq-nzr"))
        XCTAssertTrue(Denylist.isBlocked("https://us02web.zoom.us/j/1234567890"))
        XCTAssertTrue(Denylist.isBlocked("https://teams.microsoft.com/l/meetup-join/x"))
    }
    func testNonWebSchemesBlocked() {
        // Live finding: chrome:// pages were captured — browser-internal pages have no memory value.
        XCTAssertTrue(Denylist.isBlocked("chrome://extensions/"))
        XCTAssertTrue(Denylist.isBlocked("chrome://new-tab-page/"))
        XCTAssertTrue(Denylist.isBlocked("about:blank"))
        XCTAssertTrue(Denylist.isBlocked("file:///Users/me/doc.pdf"))
        XCTAssertFalse(Denylist.isBlocked("https://example.com"))  // plain https stays allowed
    }
}
