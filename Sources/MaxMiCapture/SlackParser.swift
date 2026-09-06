import Foundation
import MaxMiCore

/// Dedicated parser for the native Slack app. Window reached by the caller via
/// AXReader's locator (Slack leaves AXWindows empty). Content = AXRow messages
/// in visual order, sender-attributed; key from the window title.
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    static let sidebarMaxX: CGFloat = 240   // rows left of this are sidebar/nav chrome, not messages
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        let messages = messages(in: window, windowX: window.frame?.origin.x ?? 0)
        guard !messages.isEmpty else { return nil }
        let conversation = Conversation(
            channel: channel(fromTitle: app.windowTitle),
            isGroup: isGroup(fromTitle: app.windowTitle),
            messages: messages
        )
        // Newest-anchored cap on the STRUCTURED value: the rendered text is derived from it, so
        // capping the string afterwards would be undone by CaptureEnvelope.
        return Self.hardCapped(
            CaptureAccumulator.bound(.conversation(conversation), to: Self.contentCap),
            to: Self.contentCap
        )
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: "Slack",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: structured
        )
    }

    /// "<view> - <workspace> - Slack" -> "<view>"; else the whole title.
    func channel(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last == "Slack" { return parts[0] }
        return title
    }

    /// A "<view> - <workspace> - Slack" title is a channel view and therefore multi-party. That
    /// is the only group signal this AX walk exposes; Phase D's anchored parser reads the
    /// member list instead.
    func isGroup(fromTitle title: String?) -> Bool {
        guard let title else { return false }
        let parts = title.components(separatedBy: " - ")
        return parts.count >= 3 && parts.last == "Slack"
    }

    /// `CaptureAccumulator.bound` is a SOFT cap: one message longer than the cap is kept whole
    /// rather than rendering an empty conversation. Slack's pre-existing guard is harder — a
    /// single pathological message must not bloat a version unboundedly — so that lone message
    /// keeps only the tail of its text. Applied to the STRUCTURED value, so
    /// `content == ContentRenderer.render(structured, .full)` still holds.
    static func hardCapped(_ content: CapturedContent, to cap: Int) -> CapturedContent {
        guard case .conversation(let conversation) = content,
              conversation.messages.count == 1, let message = conversation.messages.first
        else { return content }
        let overflow = ContentRenderer.renderMessage(message).count - cap
        guard overflow > 0 else { return content }
        let text = String(message.text.dropFirst(min(overflow, message.text.count)))
        return .conversation(Conversation(
            channel: conversation.channel,
            isGroup: conversation.isGroup,
            messages: [Message(
                id: Message.makeID(sender: message.sender, timeString: message.timeString, text: text),
                sender: message.sender, text: text, timestamp: message.timestamp,
                timeString: message.timeString, isUser: message.isUser, isDraft: message.isDraft
            )]
        ))
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

    /// Collect AXRow messages in visual order. Within a row, the first static text is the
    /// sender and the rest is the body.
    func messages(in root: AXNode, windowX: CGFloat) -> [Message] {
        var rows: [(y: CGFloat, texts: [String])] = []
        collectRows(root, into: &rows, windowX: windowX)
        return rows.sorted { $0.y < $1.y }.compactMap { row in
            let texts = row.texts.filter { !$0.isEmpty }
            guard !texts.isEmpty else { return nil }
            let sender = texts.count >= 2 ? texts[0] : "unknown"
            let text = texts.count >= 2 ? texts.dropFirst().joined(separator: " ") : texts[0]
            return Message(
                id: Message.makeID(sender: sender, timeString: nil, text: text),
                sender: sender, text: text, timestamp: nil, timeString: nil,
                // Slack's AX rows carry no "sent by me" marker (no bubble side, no
                // self-authored role), so every message defaults to a peer message.
                isUser: false, isDraft: false
            )
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
