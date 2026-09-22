import Foundation
import MaxMiCore

/// Dedicated parser for the native Discord app (Electron; needs AXManualAccessibility, set by AXReader).
/// Discord's virtualised-list frames are unreliable, so this parser anchors on the transcript list
/// and walks its groups in AX tree order without reading geometry.
public struct DiscordParser: SourceParser {
    static let contentCap = 8000
    // UI chrome strings that appear as AXStaticText but aren't message content.
    static let chrome: Set<String> = ["Add Reaction", "More", "Message", "Edited", "Reply",
                                      "Forward", "React", "Add a reaction", "Text Channel"]
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        return CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        let content = CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
        return ParsedCapture(
            sourceApp: "Discord",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: content,
            truncated: content != unbounded
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

}

extension DiscordParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Discord",
        bundleIDs: [ParserRegistry.discordBundleID],
        hosts: ["discord.com", "www.discord.com"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: true
    )

    static let messageListMarker = "Messages in"

    /// "#<channel> | <server> - Discord" -> "<channel>".
    static func channelName(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        var head = title
        if let range = head.range(of: " - Discord", options: .backwards) {
            head = String(head[..<range.lowerBound])
        }
        let channel = head.components(separatedBy: " | ").first ?? head
        return channel.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    /// The transcript list is the only stable Discord anchor. Geometry is intentionally unused.
    static func messageList(in snapshot: AXNode) -> AXNode? {
        let byLabel = AXQuery.findAll("//AXList[label*=\"\(messageListMarker)\"]", in: snapshot)
        if let list = byLabel.first { return list }
        return AXQuery.findAll(
            "//AXList[identifier*=\"\(messageListMarker)\"]",
            in: snapshot
        ).first
    }

    /// One message per body line, attributed to the group's heading. Groups without a heading
    /// continue the preceding sender, matching Discord's grouped-message presentation.
    static func messages(in list: AXNode) -> [Message] {
        var result: [Message] = []
        var lastSender: String?
        for group in list.children {
            let heading = AXQuery.findAll("//AXHeading", in: group)
                .compactMap { ($0.value ?? $0.title)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let heading { lastSender = heading }
            let sender = heading ?? lastSender ?? "unknown"
            let bodies = staticTextsInTreeOrder(group)
                .filter { $0 != heading && !Self.chrome.contains($0) && $0.count > 1 }
            for body in bodies {
                result.append(Message(
                    id: Message.makeID(sender: sender, timeString: nil, text: body),
                    sender: sender,
                    text: body,
                    timestamp: nil,
                    timeString: nil,
                    isUser: false,
                    isDraft: false
                ))
            }
        }
        return result
    }

    static func staticTextsInTreeOrder(_ node: AXNode) -> [String] {
        var result: [String] = []
        func visit(_ current: AXNode) {
            guard current.subrole != GenericPageExtractor.secureSubrole,
                  current.role != "AXSecureTextField"
            else { return }
            if current.role == "AXStaticText",
               let value = current.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                result.append(value)
            }
            for child in current.children { visit(child) }
        }
        visit(node)
        return result
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        // The list anchor structurally excludes Discord's channel sidebar. Keep the legacy
        // whole-tree fallback in this same v2 path for older AX snapshots that exposed only
        // message static text; it preserves existing native capture behaviour.
        let messages = if let list = Self.messageList(in: snapshot) {
            Self.messages(in: list)
        } else {
            Self.messages(in: snapshot)
        }
        guard !messages.isEmpty else { return nil }
        return .conversation(Conversation(
            channel: Self.channelName(fromTitle: context.windowTitle),
            isGroup: true,
            messages: messages
        ))
    }
}
