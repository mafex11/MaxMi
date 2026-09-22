import Foundation
import MaxMiCore

/// Dedicated parser for the native Slack app. Window reached by the caller via
/// AXReader's locator (Slack leaves AXWindows empty). DOM-class anchors identify Slack's
/// virtual message list; AXRow geometry remains the fallback for older Electron trees.
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    static let sidebarMaxX: CGFloat = 240   // rows left of this are sidebar/nav chrome, not messages
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        return CaptureAccumulator.boundHard(unbounded, to: Self.contentCap)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
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

    static func domMessages(in snapshot: AXNode) -> [Message] {
        guard let list = AXQuery.find("//*[domClass*=\"\(messageListClass)\"]", in: snapshot)
        else { return [] }
        let items = AXQuery.findAll("//*[domClass*=\"\(messageItemClass)\"]", in: list)
        return AXQuery.sortedByVisualOrder(items, relativeTo: list.frame).compactMap { item in
            let sender = AXQuery.find("//*[domClass*=\"\(senderClass)\"]", in: item)?
                .value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let timeString = AXQuery.find("//*[domClass*=\"\(timestampClass)\"]", in: item)?
                .value?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The body is every static text that is not the sender line and not the timestamp.
            let body = AXQuery.collectStaticTexts(in: item)
                .filter { $0 != sender && $0 != timeString }
                .joined(separator: " ")
            guard !body.isEmpty else { return nil }
            let resolvedSender = sender?.isEmpty == false ? sender! : "unknown"
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

    /// Today's x-band row heuristic, retyped. Used when Slack exposes no DOM classes at all
    /// (older builds, and a tree captured before AXManualAccessibility fully woke).
    static func geometryMessages(in snapshot: AXNode) -> [Message] {
        let windowX = snapshot.frame?.minX ?? 0
        let rows = AXQuery.findAll("//AXRow", in: snapshot)
            .filter { row in
                // Window-relative: AXFrame is global screen coordinates.
                guard let x = row.frame?.minX else { return true }
                return (x - windowX) >= sidebarMaxX
            }
        // Oldest first, exactly as the Phase A row walk sorted by y — `.appendItems` accumulation
        // and the newest-anchored cap both depend on this order.
        return AXQuery.sortedByVisualOrder(rows, relativeTo: snapshot.frame)
            .compactMap { row -> Message? in
                let texts = AXQuery.collectStaticTexts(in: row)
                guard let first = texts.first else { return nil }
                let sender = texts.count >= 2 ? first : "unknown"
                let body = texts.count >= 2 ? texts.dropFirst().joined(separator: " ") : first
                return Message(id: Message.makeID(sender: sender, timeString: nil, text: body),
                               sender: sender, text: body, timestamp: nil, timeString: nil,
                               isUser: false, isDraft: false)
            }
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        if messages.isEmpty { messages = Self.geometryMessages(in: snapshot) }
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        guard !messages.isEmpty else { return nil }
        return .conversation(Conversation(
            // The existing title helpers, not new ones: they are asserted directly by
            // StructuredConversationParserTests and Task 25 refines `isGroup` from the header.
            channel: channel(fromTitle: context.windowTitle),
            isGroup: isGroup(fromTitle: context.windowTitle),
            messages: messages
        ))
    }
}
