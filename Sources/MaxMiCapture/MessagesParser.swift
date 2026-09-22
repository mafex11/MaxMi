import Foundation
import MaxMiCore

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

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        return CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        let content = CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
        return ParsedCapture(
            sourceApp: "Messages",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: Self.legacyTranscript(from: content),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: content,
            truncated: content != unbounded
        )
    }

    /// Window title is the chat name (contact or group). "Harnish" -> "imessage:harnish".
    func key(fromTitle title: String?) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "imessage:unknown" }
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "imessage:\(slug)"
    }
}

extension MessagesParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Messages",
        bundleIDs: [ParserRegistry.messagesBundleID],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3)
    )

    static let bubbleRoles: Set<String> = ["AXTextArea", "AXStaticText"]

    static func chatName(fromTitle title: String?) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    /// Outgoing bubbles sit right of the transcript's centre line. `AXFrame` is global screen
    /// coordinates, so the comparison is against the WINDOW's midX — a floated window would
    /// otherwise flip every message's authorship.
    static func isUserBubble(_ bubble: AXNode, window: AXNode) -> Bool {
        guard let bubbleFrame = bubble.frame, let windowFrame = window.frame,
              windowFrame.width > 0 else { return false }
        return bubbleFrame.midX > windowFrame.midX
    }

    static func bubbles(in snapshot: AXNode) -> [AXNode] {
        let found = AXQuery.all(in: snapshot) {
            bubbleRoles.contains($0.role)
                && $0.subrole != GenericPageExtractor.secureSubrole
                && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return AXQuery.sortedByVisualOrder(found, relativeTo: snapshot.frame)
    }

    /// Keep the v1 bridge's established plain-bubble text while `structured` carries sender
    /// attribution for Phase A consumers. This derives from the v2 result; it is not a second
    /// AX extraction path.
    static func legacyTranscript(from content: CapturedContent) -> String {
        guard case .conversation(let conversation) = content else {
            return ContentRenderer.render(content, style: .full)
        }
        return conversation.messages.map(\.text).joined(separator: "\n")
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let chat = Self.chatName(fromTitle: context.windowTitle)
        let messages = Self.bubbles(in: snapshot).compactMap { bubble -> Message? in
            guard let text = bubble.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let isUser = Self.isUserBubble(bubble, window: snapshot)
            // A group chat exposes the sender as the bubble's accessibility description; a 1:1
            // chat exposes nothing, so the chat name IS the other party.
            let sender = isUser
                ? "You"
                : (bubble.label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? chat
            return Message(id: Message.makeID(sender: sender, timeString: nil, text: text),
                           sender: sender, text: text, timestamp: nil, timeString: nil,
                           isUser: isUser, isDraft: false)
        }
        guard !messages.isEmpty else { return nil }
        // A 1:1 chat is titled with one name; a group chat's messages carry per-bubble senders.
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        return .conversation(Conversation(channel: chat, isGroup: isGroup, messages: messages))
    }
}
