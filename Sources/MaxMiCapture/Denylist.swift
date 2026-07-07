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

    public static func isBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // Only regular web pages carry memory value; browser-internal schemes
        // (chrome://, about:, edge://, arc://, file:// …) are never captured.
        if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" { return true }
        guard let host = url.host?.lowercased() else { return false }
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return blockedPathFragments.contains { path.contains($0) }
    }
}
