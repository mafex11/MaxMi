import Foundation

/// Dedicated parser for terminal emulators (Warp, Apple Terminal, iTerm2).
///
/// Unlike document/chat apps, a terminal exposes its ENTIRE scrollback as a single
/// AXTextArea blob — no per-command structure, no message rows. So extraction is just
/// "grab the biggest text area", and the interesting decisions are (a) how to derive a
/// stable thread key from a volatile window title, and (b) how to keep an actively-used
/// terminal from creating a near-identical version on every capture tick (content-hash
/// dedup in commitCapture only catches EXACTLY-equal content; a terminal changes by one
/// line constantly).
public struct TerminalParser: SourceParser {
    static let contentCap = 8000
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let blob = largestTextArea(in: window)
        guard let blob, !blob.isEmpty else { return nil }
        // Newest-anchored hard cap: keep the tail (most recent output), bound the size.
        let content = String(blob.suffix(Self.contentCap))
        return ParsedCapture(
            sourceApp: app.name,                 // "Warp", "Terminal", "iTerm2"
            sourceKey: terminalKey(app: app, content: content),
            sourceTitle: app.windowTitle,
            content: content
        )
    }

    /// Terminal scrollback lives in one big AXTextArea. Return the LONGEST text-area value
    /// (Warp = one; some emulators expose a couple — take the richest).
    private func largestTextArea(in root: AXNode) -> String? {
        var best: String?
        func walk(_ n: AXNode) {
            if n.role == "AXTextArea", let v = n.value, !v.isEmpty {
                if best == nil || v.count > best!.count { best = v }
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return best
    }

    /// Option B: group terminal activity by working directory / project, so recall is
    /// "what was I doing in the MaxMi repo?" rather than one giant blob or a thread per command.
    /// Strategy: sniff the deepest cwd-looking path from the scrollback (most recent prompt),
    /// fall back to the window title, fall back to the app name. Heuristic by nature — a
    /// terminal has no structured "current directory" attribute, so we read it from the text.
    func terminalKey(app: AppInfo, content: String) -> String {
        let appSlug = slug(app.name)
        if let dir = workingDirectory(fromContent: content) ?? workingDirectory(fromTitle: app.windowTitle) {
            return "terminal:\(appSlug)/\(dir)"
        }
        return "terminal:\(appSlug)"
    }

    /// Find the LAST (most recent) home-or-absolute path in the scrollback and return its
    /// final component — the project/dir you're currently in. Prompts render cwd as "~/foo/bar"
    /// or "/Users/x/foo/bar"; we take "bar". Returns nil if no path is present.
    func workingDirectory(fromContent content: String) -> String? {
        // Scan lines newest-first; a shell prompt line usually contains the cwd.
        for line in content.split(separator: "\n").reversed() {
            if let dir = lastPathComponent(in: String(line)) { return dir }
        }
        return nil
    }

    /// Warp/iTerm often put the cwd in the title (e.g. "MaxMi — -zsh" or "~/code/MaxMi").
    func workingDirectory(fromTitle title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return lastPathComponent(in: title)
    }

    /// Extract the final component of a ~/... or /Users/... path token in a string, slugged.
    private func lastPathComponent(in s: String) -> String? {
        // Match a path starting with ~ or / containing at least one more segment.
        guard let range = s.range(of: "(~|/Users/[^/ ]+)(/[^ \t\n:]+)+", options: .regularExpression) else { return nil }
        let path = String(s[range])
        guard let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        return slug(String(last))
    }

    private func slug(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }
}
