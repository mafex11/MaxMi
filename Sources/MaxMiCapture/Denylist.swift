import Foundation

public enum Denylist {
    // Seeded from the host list pulled out of Minimi's binary (spec §5).
    static let blockedHostSuffixes: [String] = [
        "accounts.google.com", "bitwarden.com", "1password.com", "okta.com",
        "lastpass.com", "dashlane.com", "authy.com",
        "netbanking.hdfcbank.com", "onlinesbi.sbi", "icicibank.com", "axisbank.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com",
        "paypal.com", "stripe.com/login",
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
    ]
    static let blockedPathFragments: [String] = [
        "/reset-password", "/forgot-password", "/change-password", "/2fa", "/mfa", "/otp",
    ]

    /// Strict web-URL denylist for browsers: only http(s) schemes allowed, plus banking/meeting/auth hosts.
    /// Blocks data:, blob:, chrome-untrusted://, chrome-search://, resource://, moz-extension://, javascript:, etc.
    public static func isBlockedWebURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        // Only http/https pass for browsers; all other schemes blocked (M1 behavior restored).
        if scheme != "http" && scheme != "https" { return true }
        // Apply banking/meeting/auth denylist.
        guard let host = url.host?.lowercased() else { return false }
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return blockedPathFragments.contains { path.contains($0) }
    }

    public static func isBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // Block browser-internal pages, not native-app source keys (slack:, whatsapp:, bundleid:title).
        let browserInternalSchemes: Set<String> = ["chrome", "about", "edge", "arc", "brave", "vivaldi", "file", "view-source", "devtools", "chrome-extension"]
        if let scheme = url.scheme?.lowercased(), browserInternalSchemes.contains(scheme) { return true }
        guard let host = url.host?.lowercased() else { return false }
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return blockedPathFragments.contains { path.contains($0) }
    }
}
