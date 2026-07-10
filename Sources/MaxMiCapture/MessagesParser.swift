import Foundation

/// Dedicated parser for Apple Messages (iMessage/SMS), bundle `com.apple.MobileSMS`.
///
/// Modern macOS blocks reading message text via AppleScript, and chat.db needs Full Disk Access,
/// so we use the WINDOW AX tree (no extra permission). Live-probed shape: window title is the
/// current chat's contact/group name; the conversation is a column of AXTextArea nodes in vertical
/// (y) order — same "document body" shape as Notes/terminal, NOT a sidebar-split message list.
/// Keyed by the chat name so one conversation is one thread.
public struct MessagesParser: SourceParser {
    static let contentCap = 8000
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let lines = conversationLines(in: window)
        guard !lines.isEmpty else { return nil }
        let content = String(lines.joined(separator: "\n").suffix(Self.contentCap))
        return ParsedCapture(
            sourceApp: "Messages",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: content
        )
    }

    /// Window title is the chat name (contact or group). "Harnish" -> "imessage:harnish".
    func key(fromTitle title: String?) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "imessage:unknown" }
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "imessage:\(slug)"
    }

    /// Collect AXTextArea (message bubbles) + AXStaticText in vertical order.
    private func conversationLines(in root: AXNode) -> [String] {
        var items: [(y: CGFloat, v: String)] = []
        collect(root, into: &items)
        return items.sorted { $0.y < $1.y }
            .map { $0.v.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func collect(_ node: AXNode, into out: inout [(y: CGFloat, v: String)]) {
        if node.role == "AXTextArea" || node.role == "AXStaticText", let v = node.value, !v.isEmpty {
            out.append((node.frame?.origin.y ?? 0, v))
        }
        for c in node.children { collect(c, into: &out) }
    }
}
