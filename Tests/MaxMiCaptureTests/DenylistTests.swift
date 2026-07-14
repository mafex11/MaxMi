import XCTest
@testable import MaxMiCapture

final class DenylistTests: XCTestCase {
    func testUserBlockedDomainsMatchExactHostAndSubdomains() {
        let blocked: Set<String> = ["example.com", "private.test"]
        XCTAssertTrue(Denylist.isBlockedByUser("https://example.com/page", blockedDomains: blocked))
        XCTAssertTrue(Denylist.isBlockedByUser("https://docs.example.com/page", blockedDomains: blocked))
        XCTAssertFalse(Denylist.isBlockedByUser("https://notexample.com", blockedDomains: blocked))
        XCTAssertFalse(Denylist.isBlockedByUser("https://example.org", blockedDomains: blocked))
        XCTAssertTrue(Denylist.isBlockedByUser("not a url", blockedDomains: blocked), "malformed browser values fail closed")
    }
    func testBlockedHostsAndPatterns() {
        XCTAssertTrue(Denylist.isBlocked("https://accounts.google.com/signin"))
        XCTAssertTrue(Denylist.isBlocked("https://vault.bitwarden.com/#/vault"))
        XCTAssertTrue(Denylist.isBlocked("https://my.1password.com/home"))
        XCTAssertTrue(Denylist.isBlocked("https://foo.okta.com/app"))
        XCTAssertTrue(Denylist.isBlocked("https://example.com/reset-password?token=x"))
        XCTAssertTrue(Denylist.isBlocked("https://netbanking.hdfcbank.com/netbanking"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https://dashboard.stripe.com/login"))
        XCTAssertFalse(Denylist.isBlockedWebURL("https://stripe.com/docs"))
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
        XCTAssertFalse(Denylist.isBlockedWebURL("https://teams.microsoft.com/v2/"))
    }
    func testNonWebSchemesBlocked() {
        // Live finding: chrome:// pages were captured — browser-internal pages have no memory value.
        XCTAssertTrue(Denylist.isBlocked("chrome://extensions/"))
        XCTAssertTrue(Denylist.isBlocked("chrome://new-tab-page/"))
        XCTAssertTrue(Denylist.isBlocked("about:blank"))
        XCTAssertTrue(Denylist.isBlocked("file:///Users/me/doc.pdf"))
        XCTAssertFalse(Denylist.isBlocked("https://example.com"))  // plain https stays allowed
    }
    func testNativeSchemeKeysAreNotBlocked() {
        // native-app source_keys must pass (they are not chrome://-style internal pages)
        XCTAssertFalse(Denylist.isBlocked("slack:acme/general"))
        XCTAssertFalse(Denylist.isBlocked("whatsapp:Mom"))
        XCTAssertFalse(Denylist.isBlocked("com.apple.Notes:Groceries"))
    }
    func testBrowserInternalSchemesStillBlocked() {
        XCTAssertTrue(Denylist.isBlocked("chrome://settings"))
        XCTAssertTrue(Denylist.isBlocked("about:blank"))
    }
    func testSensitiveAppsBlockedFromCapture() {
        // System secrets / credentials — never captured, even by generic fallback.
        XCTAssertTrue(Denylist.isSensitiveApp("com.apple.systempreferences"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.apple.keychainaccess"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.agilebits.onepassword7"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.bitwarden.desktop"))
        XCTAssertTrue(Denylist.isSensitiveApp("dev.mafex.maxmi"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.apple.loginwindow"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.apple.UserNotificationCenter"))
        // password-manager name substrings still match
        XCTAssertTrue(Denylist.isSensitiveApp("io.LastPass.helper"))
        XCTAssertTrue(Denylist.isSensitiveApp("com.example.1password-helper"))
    }
    func testNormalAppsAreCapturable() {
        // The apps the user named + common ones must NOT be sensitive (capture-by-default).
        XCTAssertFalse(Denylist.isSensitiveApp("com.todesktop.230313mzl4w4u92"))  // Cursor
        XCTAssertFalse(Denylist.isSensitiveApp("com.spotify.client"))
        XCTAssertFalse(Denylist.isSensitiveApp("com.apple.finder"))
        XCTAssertFalse(Denylist.isSensitiveApp("com.microsoft.VSCode"))
        XCTAssertFalse(Denylist.isSensitiveApp("com.hnc.Discord"))
        // Bank/wallet/crypto apps ARE captured now — substring over-match removed (user's call).
        XCTAssertFalse(Denylist.isSensitiveApp("com.example.MyBankApp"))
        XCTAssertFalse(Denylist.isSensitiveApp("com.coinbase.wallet"))
        XCTAssertFalse(Denylist.isSensitiveApp("com.bankless.podcast"))
    }
    func testAdultSearchQueryBlocked() {
        // The gap found in live data: google.com/search?q=jaav+porn slipped through (host is google).
        XCTAssertTrue(Denylist.isBlockedWebURL("https://www.google.com/search?q=jaav+porn&rlz=1C5"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https://www.bing.com/search?q=hentai+videos"))
        // innocent searches still pass
        XCTAssertFalse(Denylist.isBlockedWebURL("https://www.google.com/search?q=swift+regex"))
        XCTAssertFalse(Denylist.isBlockedWebURL("https://www.google.com/search?q=expensive+dinner"))
    }
    func testAdultContentBlocked() {
        // Specific hosts seen in the wild + long-tail substring net; blocked on BOTH entry points.
        for u in ["https://www.pornhub.org/view_video.php?id=1", "https://jav.guru/992152/x",
                  "https://hanime.tv/videos/hentai/x", "https://www.xvideos.com/v",
                  "https://onlyfans.com/someone", "https://sub.somepornsite.net/x"] {
            XCTAssertTrue(Denylist.isBlockedWebURL(u), "web denylist should block \(u)")
            XCTAssertTrue(Denylist.isBlocked(u), "shared denylist should block \(u)")
        }
    }
    func testNonAdultNotOverBlocked() {
        // Innocent hosts pass; the substring net only matches the HOST, not the path.
        XCTAssertFalse(Denylist.isBlockedWebURL("https://news.ycombinator.com"))
        XCTAssertFalse(Denylist.isBlockedWebURL("https://github.com/someone/xhamster-mirror-tool"))  // "xhamster" in path, not host
        XCTAssertFalse(Denylist.isBlockedWebURL("https://en.wikipedia.org/wiki/Pornography"))         // "porn" in path, not host
    }
    // NOTE: the substring net intentionally over-blocks any HOST containing "porn"/"hentai"/etc.
    // (e.g. a hypothetical pornfree-support.org). Accepted: over-blocking adult-adjacent hosts is
    // the safe direction for this control; the specific-suffix list handles the common real sites.
    func testBlockedWebURL_rejectsNonHTTPSchemes() {
        // M1 strict rule restored: only http(s) pass for browsers
        XCTAssertTrue(Denylist.isBlockedWebURL("data:text/html,<h1>x</h1>"))
        XCTAssertTrue(Denylist.isBlockedWebURL("blob:https://example.com/uuid"))
        XCTAssertTrue(Denylist.isBlockedWebURL("chrome-untrusted://new-tab-page"))
        XCTAssertTrue(Denylist.isBlockedWebURL("chrome-search://local-ntp"))
        XCTAssertTrue(Denylist.isBlockedWebURL("resource://gre/modules/foo.jsm"))
        XCTAssertTrue(Denylist.isBlockedWebURL("moz-extension://uuid/page.html"))
        XCTAssertTrue(Denylist.isBlockedWebURL("javascript:alert(1)"))
    }
    func testBlockedWebURL_allowsHTTPS() {
        XCTAssertFalse(Denylist.isBlockedWebURL("https://example.com"))
        XCTAssertFalse(Denylist.isBlockedWebURL("http://example.com"))
    }
    func testBlockedWebURLFailsClosedAndProtectsAuthRoutes() {
        XCTAssertTrue(Denylist.isBlockedWebURL("not a url"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https:///missing-host"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https://user:secret@example.com/page"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https://example.com/signin"))
        XCTAssertTrue(Denylist.isBlockedWebURL("https://example.com/oauth/authorize"))
    }
    func testIsBlocked_nativeKeysStillPass() {
        // Native keys still use isBlocked (not isBlockedWebURL), so they remain allowed
        XCTAssertFalse(Denylist.isBlocked("slack:acme/general"))
    }
}
