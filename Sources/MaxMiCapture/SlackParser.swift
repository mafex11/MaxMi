import Foundation
import MaxMiCore

/// Dedicated parser for the native Slack app. Window reached by the caller via
/// AXReader's locator (Slack leaves AXWindows empty). Verified DOM anchors are
/// `c-message_list`, `c-virtual_list__item`, `c-message__sender`, `c-timestamp`, and `ql-editor`.
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parseStructured(window: window, app: app) else { return nil }
        let content = CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
        return ParsedCapture(
            sourceApp: "Slack",
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

    /// "<view> - <workspace> - Slack" -> "<view>"; else the whole title.
    func channel(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last == "Slack" {
            return parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
        return title
    }

    /// Slack's title distinguishes a channel from a DM by the `#` prefix on its view component.
    func isGroup(fromTitle title: String?) -> Bool {
        guard let title else { return false }
        let parts = title.components(separatedBy: " - ")
        return parts.count >= 3 && parts.last == "Slack"
            && parts[0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    /// "<view> - <workspace> - Slack" -> "slack:<workspace>/<view>"; else "slack:<title>".
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "slack:unknown" }
        let parts = title.components(separatedBy: " - ")
        func slug(_ s: String) -> String {
            s.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                .replacingOccurrences(of: " ", with: "-")
        }
        if parts.count >= 3, parts.last == "Slack" {
            let view = slug(parts[0]); let workspace = slug(parts[parts.count - 2])
            return "slack:\(workspace)/\(view)"
        }
        return "slack:\(slug(title))"
    }
}

extension SlackParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Slack",
        bundleIDs: [ParserRegistry.slackBundleID],
        // Slack in a browser tab gets the same anchors as the native app, and must beat the
        // generic web page (spec §7b).
        hosts: ["app.slack.com", ".slack.com"],
        // Slack's Electron tree does not always sit under an AXWebArea, so the DOM class list is
        // forced rather than gated (spec §7b, reconciliation 2).
        attributeSet: ["AXDOMClassList"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: true
    )

    static let messageListClass = "c-message_list"
    static let messageItemClass = "c-virtual_list__item"
    static let senderClass = "c-message__sender"
    static let timestampClass = "c-timestamp"
    static let composerClass = "ql-editor"

    private struct TextNode {
        let path: [Int]
        let node: AXNode
        let value: String
    }

    /// The path distinguishes two otherwise-equal AX nodes, such as a sender named "Mira"
    /// whose body is also "Mira".
    private static func staticTextNodes(in root: AXNode) -> [TextNode] {
        var found: [TextNode] = []
        func visit(_ node: AXNode, path: [Int]) {
            if AXQuery.menuRoles.contains(node.role) || node.hidden
                || node.subrole == GenericPageExtractor.secureSubrole {
                return
            }
            if node.role == "AXStaticText",
               let value = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                found.append(TextNode(path: path, node: node, value: value))
            }
            for (index, child) in node.children.enumerated() {
                visit(child, path: path + [index])
            }
        }
        visit(root, path: [])
        return found.enumerated().sorted { lhs, rhs in
            let left = lhs.element.node.frame
            let right = rhs.element.node.frame
            let leftY = (left?.minY ?? root.frame?.minY ?? 0) - (root.frame?.minY ?? 0)
            let rightY = (right?.minY ?? root.frame?.minY ?? 0) - (root.frame?.minY ?? 0)
            if leftY != rightY { return leftY < rightY }
            let leftX = (left?.minX ?? root.frame?.minX ?? 0) - (root.frame?.minX ?? 0)
            let rightX = (right?.minX ?? root.frame?.minX ?? 0) - (root.frame?.minX ?? 0)
            if leftX != rightX { return leftX < rightX }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func domMessages(in snapshot: AXNode) -> [Message] {
        guard let list = AXQuery.find("//*[domClass*=\"\(messageListClass)\"]", in: snapshot)
        else { return [] }
        let items = AXQuery.findAll("//*[domClass*=\"\(messageItemClass)\"]", in: list)
        return AXQuery.sortedByVisualOrder(items, relativeTo: list.frame).compactMap { item in
            let texts = staticTextNodes(in: item)
            let senderNode = texts.first {
                ($0.node.domClassList ?? []).contains {
                    $0.caseInsensitiveCompare(senderClass) == .orderedSame
                }
            }
            let timestampNode = texts.first {
                ($0.node.domClassList ?? []).contains {
                    $0.caseInsensitiveCompare(timestampClass) == .orderedSame
                }
            }
            let excluded = Set([senderNode?.path, timestampNode?.path].compactMap { $0 })
            let body = texts.filter { !excluded.contains($0.path) }
                .map(\.value)
                .joined(separator: " ")
            guard !body.isEmpty else { return nil }
            let resolvedSender = senderNode.flatMap {
                NativeConversationExtraction.senderLabel([$0.value, body])
            } ?? "unknown"
            let timeString = timestampNode?.value
            return Message(
                id: Message.makeID(sender: resolvedSender, timeString: timeString, text: body),
                sender: resolvedSender, text: body, timestamp: nil,
                timeString: timeString?.isEmpty == false ? timeString : nil,
                isUser: false, isDraft: false
            )
        }
    }

    /// The composer's live text. A draft is the one message Slack's tree marks as the user's.
    static func draftMessage(in snapshot: AXNode) -> Message? {
        if let composer = AXQuery.find("//*[domClass*=\"\(composerClass)\"]", in: snapshot) {
            guard composer.subrole != GenericPageExtractor.secureSubrole else { return nil }
            let text = (composer.value ?? AXQuery.collectStaticTexts(in: composer).joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Message(id: Message.makeID(sender: "You", timeString: nil, text: text),
                           sender: "You", text: text, timestamp: nil, timeString: nil,
                           isUser: true, isDraft: true)
        }
        // Preserve the established native composer predicate when Slack has not exposed DOM
        // attributes yet. This is reached through the same v2 path, not a separate extraction.
        return ComposerDraft.draft(window: snapshot)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        guard !messages.isEmpty else { return nil }
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        return .conversation(Conversation(
            channel: channel(fromTitle: context.windowTitle),
            isGroup: isGroup(fromTitle: context.windowTitle),
            messages: messages
        ))
    }
}
