import Foundation

/// Dedicated parser for Apple Mail. Live-probed shape: the message list is a set of AXRows
/// in the content area (right of the sidebar), each row exposing a
/// `sender | date | subject | preview` tuple of AXStaticText. The left sidebar (x < band)
/// holds mailbox/account names and must be excluded — the same message-list-vs-sidebar
/// split we solved for Slack.
///
/// Thread identity = the current mailbox (from the window title, e.g. "All Inboxes"), so a
/// mailbox accumulates its message list over time rather than fracturing.
public struct MailParser: SourceParser {
    static let contentCap = 8000
    static let sidebarMaxX: CGFloat = 260   // rows left of this (window-relative) are mailbox chrome
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let winX = window.frame?.origin.x ?? 0
        let lines = messageLines(in: window, windowX: winX)
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
            sourceApp: "Mail",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: content
        )
    }

    /// "All Inboxes – 218 messages" -> "mail:all-inboxes"; strips a trailing count clause.
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "mail:inbox" }
        // Drop a trailing "– N messages" / "— N messages" count (volatile) before slugging.
        let mailbox = title.split(whereSeparator: { $0 == "–" || $0 == "—" }).first.map(String.init) ?? title
        let slug = mailbox.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        return "mail:\(slug.isEmpty ? "inbox" : slug)"
    }

    /// Collect content-area message rows (excluding the sidebar) as
    /// "sender — subject: preview" lines, in visual (top-to-bottom) order.
    private func messageLines(in root: AXNode, windowX: CGFloat) -> [String] {
        var rows: [(y: CGFloat, texts: [String])] = []
        collectRows(root, into: &rows, windowX: windowX)
        return rows.sorted { $0.y < $1.y }.compactMap { row in
            let ts = row.texts.filter { !$0.isEmpty }
            guard ts.count >= 2 else { return ts.first }
            // Probed tuple order: sender | date | subject | preview. Compose a readable line;
            // keep sender + subject + preview, fold the date in after the sender.
            let sender = ts[0]
            let rest = ts.dropFirst().joined(separator: " · ")
            return "\(sender): \(rest)"
        }
    }

    private func collectRows(_ node: AXNode, into out: inout [(y: CGFloat, texts: [String])], windowX: CGFloat) {
        if node.role == "AXRow" {
            // Window-relative x: sidebar mailbox rows sit in the left band; message rows are
            // to their right (probed at x≈568). AXFrame is global screen coords → subtract winX.
            let x = node.frame?.origin.x ?? .greatestFiniteMagnitude
            if x != .greatestFiniteMagnitude && (x - windowX) < Self.sidebarMaxX { return }
            var texts: [(CGFloat, CGFloat, String)] = []
            collectStaticText(node, into: &texts)
            let ordered = texts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
            out.append((node.frame?.origin.y ?? 0, ordered))
            return
        }
        for c in node.children { collectRows(c, into: &out, windowX: windowX) }
    }

    private func collectStaticText(_ node: AXNode, into out: inout [(CGFloat, CGFloat, String)]) {
        if node.role == "AXStaticText", let v = node.value, !v.isEmpty {
            out.append((node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0, v))
        }
        for c in node.children { collectStaticText(c, into: &out) }
    }
}
