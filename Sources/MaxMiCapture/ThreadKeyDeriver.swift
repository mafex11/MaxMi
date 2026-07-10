import Foundation

/// The single keying chokepoint. Parsers propose a key (ParsedCapture.sourceKey is a HINT);
/// this turns it into a clean, STABLE thread key. Pure and total — always returns a non-empty
/// key, coarsening to an app-level fallback rather than ever dropping a capture.
/// Principle: coarse-but-stable beats fine-but-volatile (spec §3a).
public enum ThreadKeyDeriver {
    static let maxLen = 200

    public static func derive(_ capture: ParsedCapture) -> String {
        let fallback = appFallback(for: capture)
        // Web: identity comes from the normalized URL, not the raw hint.
        if capture.sourceApp == "Web" {
            let normalized = URLKeyNormalizer.normalize(capture.sourceKey)
            return hygiene(normalized, appFallback: fallback, isURL: true)
        }
        // Native apps: the parser's hint already carries the scheme (slack:/terminal:/mail:...).
        return hygiene(capture.sourceKey, appFallback: fallback)
    }

    /// App-level coarse key used when a specific key degenerates.
    static func appFallback(for capture: ParsedCapture) -> String {
        switch capture.sourceApp {
        case "Web":
            // host-level fallback
            if let host = URLComponents(string: capture.sourceKey)?.host { return "https://\(host)" }
            return "web:unknown"
        case "Warp", "Terminal", "iTerm2": return "terminal:\(capture.sourceApp.lowercased())"
        default:
            // scheme prefix of the hint if present (e.g. "slack:x" -> "slack:"), else app name
            if let scheme = capture.sourceKey.split(separator: ":").first, capture.sourceKey.contains(":") {
                return "\(scheme):\(capture.sourceApp.lowercased())"
            }
            return "\(capture.sourceApp.lowercased()):unknown"
        }
    }

    /// Universal hygiene. `isURL` keeps URL structure intact (only trims junk); non-URL keys
    /// get scheme-preserving slug cleanup + file-extension coarsening.
    static func hygiene(_ raw: String, appFallback: String, isURL: Bool = false) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        key = key.replacingOccurrences(of: "\n", with: " ")
        // strip trailing junk: whitespace, brackets, punctuation, ellipsis
        let trailingJunk = CharacterSet(charactersIn: " \t.,;:)]}>…")
        while let last = key.unicodeScalars.last, trailingJunk.contains(last) { key.unicodeScalars.removeLast() }
        if key.isEmpty { return appFallback }
        if isURL {
            return String(key.prefix(maxLen))
        }
        // Non-URL: split scheme:path, clean the path segments.
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            // no scheme -> degenerate
            return appFallback
        }
        let scheme = parts[0].lowercased()
        var path = parts[1]
        // collapse whitespace runs to single dash, lowercase
        path = path.lowercased().replacingOccurrences(of: " ", with: "-")
        while path.contains("--") { path = path.replacingOccurrences(of: "--", with: "-") }
        // last segment file-extension coarsening: "warp/inspect2.mjs" -> "warp"
        // but only if a parent segment remains (don't coarsen single-segment doc keys like "plan-v1.2")
        var segs = path.split(separator: "/").map(String.init)
        if segs.count >= 2, let last = segs.last, let dot = last.lastIndex(of: "."), dot != last.startIndex {
            let ext = last[last.index(after: dot)...]
            if ext.count <= 5 && !ext.isEmpty && ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                segs.removeLast()
            }
        }
        let cleanedPath = segs.joined(separator: "/")
        if cleanedPath.isEmpty { return appFallback }
        return String("\(scheme):\(cleanedPath)".prefix(maxLen))
    }
}
