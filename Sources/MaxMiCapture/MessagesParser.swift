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
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let outcome = parseOutcome(
            window, context: ParseContext(app: app)
        ) else { return nil }
        let content = outcome.content
        return ParsedCapture(
            sourceApp: "Messages",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: content,
            truncated: outcome.truncated
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
    static let transcriptRole = "AXList"
    static let transcriptIdentifier = "message-list"

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

    /// The transcript is the common container of the bubble rows. Do not search the whole
    /// window: Messages exposes contact names and search text in adjacent sidebar chrome.
    static func transcript(in snapshot: AXNode) -> AXNode? {
        AXQuery.find(
            "//\(transcriptRole)[identifier=\"\(transcriptIdentifier)\"]",
            in: snapshot
        )
    }

    static func bubbles(in transcript: AXNode) -> [AXNode] {
        let found = AXQuery.all(in: transcript) {
            bubbleRoles.contains($0.role)
                && !$0.isSecureField
                && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return AXQuery.sortedByVisualOrder(found, relativeTo: transcript.frame)
    }

    private static func unboundedContent(
        _ snapshot: AXNode,
        context: ParseContext
    ) -> CapturedContent? {
        guard let transcript = Self.transcript(in: snapshot) else { return nil }
        let chat = Self.chatName(fromTitle: context.windowTitle)
        let messages = Self.bubbles(in: transcript).compactMap { bubble -> Message? in
            guard let text = bubble.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let isUser = Self.isUserBubble(bubble, window: snapshot)
            // A group chat exposes the sender as the bubble's accessibility description; a 1:1
            // chat exposes nothing, so the chat name IS the other party.
            let sender = isUser
                ? "You"
                : bubble.label
                    .map { [$0, text] }
                    .flatMap(NativeConversationExtraction.senderLabel)
                    ?? chat
            return Message(id: Message.makeID(sender: sender, timeString: nil, text: text),
                           sender: sender, text: text, timestamp: nil, timeString: nil,
                           isUser: isUser, isDraft: false)
        }
        guard !messages.isEmpty else { return nil }
        // A 1:1 chat is titled with one name; a group chat's messages carry per-bubble senders.
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        return .conversation(Conversation(channel: chat, isGroup: isGroup, messages: messages))
    }

    func parseOutcome(
        _ snapshot: AXNode,
        context: ParseContext
    ) -> StructuredContentOutcome? {
        guard let unbounded = Self.unboundedContent(snapshot, context: context) else { return nil }
        let content = CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
        return StructuredContentOutcome(content: content, truncated: content != unbounded)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        parseOutcome(snapshot, context: context)?.content
    }
}

extension MessagesParser: TruncationReportingStructuredParser {}
