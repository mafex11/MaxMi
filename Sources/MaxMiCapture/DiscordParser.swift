import Foundation
import MaxMiCore

/// Dedicated parser for the native Discord app (Electron; needs AXManualAccessibility, set by AXReader).
/// Live-probed shape: title is "#<channel> | <server> - Discord"; messages are AXStaticText in the
/// content area. NOTE: Discord's AXFrame values are UNRELIABLE — live probe showed message text and
/// sidebar text at contradictory/overlapping x, and many nodes collapse to one y (virtualized list).
/// So unlike Slack/Mail, we do NOT use an x-band sidebar split (it would wrongly drop real messages);
/// instead we collect all AXStaticText in tree order, filter known UI chrome, and rely on the
/// title-derived server/channel KEY for stable identity. Content may carry some channel-list noise —
/// acceptable best-effort (the ThreadKeyDeriver + fingerprint dedup keep threads clean regardless).
public struct DiscordParser: SourceParser {
    static let contentCap = 8000
    // UI chrome strings that appear as AXStaticText but aren't message content.
    static let chrome: Set<String> = ["Add Reaction", "More", "Message", "Edited", "Reply",
                                      "Forward", "React", "Add a reaction", "Text Channel"]
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let lines = messageLines(in: window)
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            let add = line.count + 1
            if total + add > Self.contentCap && !kept.isEmpty { break }
            kept.insert(line, at: 0)
            total += add
        }
        let content = String(kept.joined(separator: "\n").suffix(Self.contentCap))
        return ParsedCapture(
            sourceApp: "Discord",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: content,
            contentKind: .conversation,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3)
        )
    }

    /// "#<channel> | <server> - Discord" -> "discord:<server>/<channel>"; else "discord:<title>".
    /// The deriver applies final hygiene, so this only needs the semantic split.
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "discord:unknown" }
        // Drop the trailing " - Discord".
        var head = title
        if let r = head.range(of: " - Discord", options: .backwards) { head = String(head[..<r.lowerBound]) }
        func slug(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        }
        // "#channel | server"
        let parts = head.components(separatedBy: " | ")
        if parts.count >= 2 {
            let channel = slug(parts[0]); let server = slug(parts[1])
            return "discord:\(server)/\(channel)"
        }
        return "discord:\(slug(head))"
    }

    /// Collect AXStaticText in tree order (Discord frames unreliable — no x-band), filtering UI chrome.
    private func messageLines(in root: AXNode) -> [String] {
        var out: [String] = []
        collect(root, into: &out)
        return out
    }

    private func collect(_ node: AXNode, into out: inout [String]) {
        if node.role == "AXStaticText", let v = node.value {
            let text = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !Self.chrome.contains(text), text.count > 1 {
                out.append(text)
            }
        }
        for c in node.children { collect(c, into: &out) }
    }
}
