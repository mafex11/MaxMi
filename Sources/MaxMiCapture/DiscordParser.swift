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
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parseStructured(window: window, app: app) else { return nil }
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

    private struct TextNode {
        let path: [Int]
        let role: String
        let value: String
    }

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
            let values = textNodesInTreeOrder(group)
            let heading = values.first { $0.role == "AXHeading" }
            let bodies = values.filter {
                $0.role == "AXStaticText"
                    && $0.path != heading?.path
                    && !Self.chrome.contains($0.value)
                    && $0.value.count > 1
            }
            let headingSender = heading.flatMap { heading in
                NativeConversationExtraction.senderLabel(
                    [heading.value] + bodies.prefix(1).map(\.value)
                )
            }
            if let headingSender { lastSender = headingSender }
            let sender = headingSender ?? lastSender ?? "unknown"
            for body in bodies.map(\.value) {
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

    private static func textNodesInTreeOrder(_ node: AXNode) -> [TextNode] {
        var result: [TextNode] = []
        func visit(_ current: AXNode, path: [Int]) {
            guard current.subrole != GenericPageExtractor.secureSubrole,
                  current.role != "AXSecureTextField"
            else { return }
            if ["AXStaticText", "AXHeading"].contains(current.role),
               let value = (current.value ?? current.title)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                result.append(TextNode(path: path, role: current.role, value: value))
            }
            for (index, child) in current.children.enumerated() {
                visit(child, path: path + [index])
            }
        }
        visit(node, path: [])
        return result
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let list = Self.messageList(in: snapshot) else { return nil }
        let messages = Self.messages(in: list)
        guard !messages.isEmpty else { return nil }
        return .conversation(Conversation(
            channel: Self.channelName(fromTitle: context.windowTitle),
            isGroup: true,
            messages: messages
        ))
    }
}
