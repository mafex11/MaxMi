import Foundation
import MaxMiCore

/// Dedicated parser for the native Slack app. Window reached by the caller via
/// AXReader's locator (Slack leaves AXWindows empty). Content = AXRow messages
/// in visual order, sender-attributed; key from the window title.
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    static let sidebarMaxX: CGFloat = 240   // rows left of this are sidebar/nav chrome, not messages
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let winX = window.frame?.origin.x ?? 0
        let lines = messageLines(in: window, windowX: winX)
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            let add = line.count + 1  // +1 for the joining newline
            if total + add > Self.contentCap && !kept.isEmpty { break }
            kept.insert(line, at: 0)
            total += add
        }
        // Hard cap: a single newest message longer than the cap is kept but bounded
        // (its tail), so one pathological line can't bloat a version unboundedly.
        let content = String(kept.joined(separator: "\n").suffix(Self.contentCap))
        return ParsedCapture(
            sourceApp: "Slack",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: content,
            contentKind: .conversation,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3)
        )
    }

    /// "<view> - <workspace> - Slack" -> "slack:<workspace>/<view>"; else "slack:<title>".
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "slack:unknown" }
        let parts = title.components(separatedBy: " - ")
        func slug(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        }
        if parts.count >= 3, parts.last == "Slack" {
            let view = slug(parts[0]); let workspace = slug(parts[parts.count - 2])
            return "slack:\(workspace)/\(view)"
        }
        return "slack:\(slug(title))"
    }

    /// Collect AXRow message text in visual order. Within a row, first static text
    /// is treated as sender, the rest as the message body.
    private func messageLines(in root: AXNode, windowX: CGFloat) -> [String] {
        var rows: [(y: CGFloat, texts: [String])] = []
        collectRows(root, into: &rows, windowX: windowX)
        return rows.sorted { $0.y < $1.y }.compactMap { row in
            let ts = row.texts.filter { !$0.isEmpty }
            guard !ts.isEmpty else { return nil }
            if ts.count >= 2 { return "\(ts[0]): \(ts.dropFirst().joined(separator: " "))" }
            return ts[0]
        }
    }

    private func collectRows(_ node: AXNode, into out: inout [(y: CGFloat, texts: [String])], windowX: CGFloat) {
        if node.role == "AXRow" {
            // Sidebar/nav rows sit in the narrow left column (window-relative x < sidebarMaxX);
            // messages are in the main content area to their right. Exclude sidebar chrome (spec §4).
            // AXFrame is in global screen coordinates, so subtract window origin to get window-relative x.
            let x = node.frame?.origin.x ?? .greatestFiniteMagnitude
            if x != .greatestFiniteMagnitude && (x - windowX) < Self.sidebarMaxX { return }
            var texts: [(CGFloat, CGFloat, String)] = []
            collectStaticText(node, into: &texts)
            let ordered = texts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
            out.append((node.frame?.origin.y ?? 0, ordered))
            return   // don't descend into nested rows twice
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
