import Foundation
import MaxMiCore

public enum Denylist {
    // Seeded from the host list pulled out of Minimi's binary (spec §5).
    static let blockedHostSuffixes: [String] = [
        "accounts.google.com", "bitwarden.com", "1password.com", "okta.com",
        "lastpass.com", "dashlane.com", "authy.com",
        "netbanking.hdfcbank.com", "onlinesbi.sbi", "icicibank.com", "axisbank.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com",
        "paypal.com",
        "meet.google.com", "zoom.us",
    ]
    static let blockedPathFragments: [String] = [
        "/login", "/signin", "/sign-in", "/sign_in", "/auth/", "/oauth/",
        "/reset-password", "/forgot-password", "/change-password", "/2fa", "/mfa", "/otp",
    ]
    static let blockedHostPathRules: [String: [String]] = [
        "stripe.com": ["/login"],
        "teams.microsoft.com": ["/l/meetup-join", "/meetup-join/", "/meeting/"],
        "teams.live.com": ["/l/meetup-join", "/meetup-join/", "/meeting/"],
    ]

    // Sensitive NATIVE apps never captured by the generic fallback (capture-by-default gate).
    // These expose passwords, keys, financial data, or system secrets in their windows.
    // Matched by exact bundle id OR a bundle-id prefix/substring for families.
    static let sensitiveAppBundleIDs: Set<String> = [
        "com.apple.systempreferences",          // System Settings (passwords, wifi keys, accounts)
        "com.apple.SecurityAgent",              // auth prompts
        "com.apple.keychainaccess",             // Keychain Access
        "com.apple.Passwords",                  // Passwords app (macOS 15+)
        "com.agilebits.onepassword7", "com.1password.1password",   // 1Password
        "com.bitwarden.desktop",                // Bitwarden
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", // LastPass, Dashlane
        "org.keepassxc.keepassxc",              // KeePassXC
        "com.apple.Terminal.SecureKeyboardEntry",
    ]
    // Substring matches ONLY for password-manager families (safe, specific product names).
    // Deliberately NOT "bank"/"wallet"/"authenticator" — those over-match legit apps
    // (Bankless, DataBank, crypto wallets) the user wants captured. Capture-by-default wins.
    static let sensitiveAppSubstrings: [String] = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass",
    ]

    /// True if a native app should NEVER be captured (even by the generic fallback).
    /// The capture-by-default gate admits everything EXCEPT these.
    public static func isSensitiveApp(_ bundleID: String) -> Bool {
        if ApplicationRegistry.isExcludedByDefault(bundleID) { return true }
        if sensitiveAppBundleIDs.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        return sensitiveAppSubstrings.contains { lower.contains($0) }
    }
    // Adult content: never captured, never sent to Gemini (which refuses to extract it anyway).
    // Specific hosts seen in the wild plus a substring net for the long tail of adult domains.
    static let blockedHostSuffixes_adult: [String] = [
        "pornhub.com", "pornhub.org", "xvideos.com", "xnxx.com", "redtube.com",
        "youporn.com", "xhamster.com", "spankbang.com", "jav.guru", "hanime.tv",
        "onlyfans.com", "chaturbate.com", "stripchat.com",
    ]
    static let blockedHostSubstrings_adult: [String] = ["porn", "xvideos", "xhamster", "hentai", "javhd"]

    /// True if the host is adult content (specific suffix OR a substring match on the long tail).
    static func isAdultHost(_ host: String) -> Bool {
        if blockedHostSuffixes_adult.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        return blockedHostSubstrings_adult.contains { host.contains($0) }
    }

    /// Adult terms that, when present in a SEARCH QUERY, block the capture. The host denylist
    /// can't catch these (host is google.com); a search for adult content should not be stored.
    static let blockedQueryTerms: [String] = ["porn", "hentai", "xxx", "nsfw", "jav ", "sex video"]

    /// Shared host/path denylist (banking, auth, meetings, adult). Used by both entry points.
    static func isBlockedHostOrPath(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if isAdultHost(host) { return true }
        let path = url.path.lowercased()
        if blockedPathFragments.contains(where: { path.contains($0) }) { return true }
        for (ruleHost, fragments) in blockedHostPathRules
        where host == ruleHost || host.hasSuffix("." + ruleHost) {
            if fragments.contains(where: { path.contains($0) }) { return true }
        }
        // Adult search queries (e.g. google.com/search?q=...porn...) — host won't match, query will.
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value?.lowercased() {
            if blockedQueryTerms.contains(where: { q.contains($0) }) { return true }
        }
        return false
    }

    /// Strict web-URL denylist for browsers: only http(s) schemes allowed, plus banking/meeting/auth hosts.
    /// Blocks data:, blob:, chrome-untrusted://, chrome-search://, resource://, moz-extension://, javascript:, etc.
    public static func isBlockedWebURL(_ urlString: String) -> Bool {
        // Browser routing is a privacy boundary: malformed or hostless values fail closed.
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        // Only http/https pass for browsers; all other schemes blocked (M1 behavior restored).
        if scheme != "http" && scheme != "https" { return true }
        if url.user != nil || url.password != nil { return true }
        return isBlockedHostOrPath(url)
    }

    /// User policy layered on top of the non-editable safety denylist.
    public static func isBlockedByUser(_ urlString: String, blockedDomains: Set<String>) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return true }
        return blockedDomains.contains { domain in
            let normalized = domain.lowercased()
            return host == normalized || host.hasSuffix("." + normalized)
        }
    }

    public static func isBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // Block browser-internal pages, not native-app source keys (slack:, whatsapp:, bundleid:title).
        let browserInternalSchemes: Set<String> = ["chrome", "about", "edge", "arc", "brave", "vivaldi", "file", "view-source", "devtools", "chrome-extension"]
        if let scheme = url.scheme?.lowercased(), browserInternalSchemes.contains(scheme) { return true }
        return isBlockedHostOrPath(url)
    }
}
