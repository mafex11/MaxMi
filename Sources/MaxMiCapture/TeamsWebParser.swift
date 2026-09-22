import Foundation
import MaxMiCore

/// Teams on the web (`teams.microsoft.com`, `teams.cloud.microsoft`) → `.conversation`, routed by
/// host (§7b, §14b). The native Teams app keeps `TeamsParser`; this parser never sees it.
///
/// `data-tid` is the least likely candidate to reach AX, so containers resolve in two tiers — DOM
/// class first, then an identifier prefix — and a container with no static texts at all falls back
/// to its `AXDescription` as the whole message text. A description is never parsed into sender and
/// time: that is format-guessing, and a joined line is never re-split (§14b).
///
/// `contentKind` comes from `WebAppCaptureParser.classify` (§12 Q3), which classifies both Teams
/// domains as `.teams`. `URLKeyNormalizer` is deliberately not changed: `teams.cloud.microsoft`
/// keeps its current generic query strip so existing thread keys remain stable.
///
/// ANCHORS. Per the privacy ruling, no live AX snapshot was inspected or recorded for this task.
/// The following candidates are verified only by hand-authored, scrubbed fixtures and parser
/// tests; a future live verification must retain this distinction:
///   data-tid "chat-pane-message"    message container   fixture-verified as identifier prefix
///   `fui-ChatMessage`               message container   fixture-verified
///   `message-author-name`           sender              fixture-verified
///   `message-timestamp`             time                fixture-verified
///   `fui-ChatMessage__body`         body                fixture-verified
///   data-tid "ckeditor"             composer            fixture-verified as dom identifier
///   `ck-editor__editable`           composer            fixture-verified
///   AXDescription on a text-free container              fixture-verified as whole message text
public struct TeamsWebParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Microsoft Teams Web",
        bundleIDs: [],
        hosts: ["teams.microsoft.com", "teams.cloud.microsoft"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`).
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let messageClass = "fui-ChatMessage"
    static let authorClass = "message-author-name"
    static let timestampClass = "message-timestamp"
    static let bodyClass = "fui-ChatMessage__body"
    static let messageIdentifierPrefix = "chat-pane-message"
    static let composerClass = "ck-editor__editable"
    static let composerIdentifier = "ckeditor"
    static let composerPlaceholderHint = "message"

    // MARK: - Anchors

    /// Tier A: the message DOM class. Tier B: a container whose `domIdentifier` or `identifier`
    /// starts with Teams' `data-tid` value, for the builds where the class list is absent. Never
    /// both tiers at once, so one message cannot be counted twice.
    static func messageContainers(in snapshot: AXNode) -> [AXNode] {
        var containers = AXQuery.findAll("//*[domClass=\"\(messageClass)\"]", in: snapshot)
        if containers.isEmpty {
            containers = AXQuery.findAll("//*[domId^=\"\(messageIdentifierPrefix)\"]", in: snapshot)
        }
        if containers.isEmpty {
            containers = AXQuery.all(in: snapshot) { node in
                (node.identifier ?? "").hasPrefix(messageIdentifierPrefix)
            }
        }
        return AXQuery.sortedByVisualOrder(containers, relativeTo: snapshot.frame)
    }

    static func composer(in snapshot: AXNode) -> AXNode? {
        if let classed = AXQuery.find("//*[domClass*=\"\(composerClass)\"]", in: snapshot) {
            return classed
        }
        if let identified = AXQuery.find("//*[domId=\"\(composerIdentifier)\"]", in: snapshot) {
            return identified
        }
        // Last resort: the text-entry field whose placeholder or description mentions a message.
        return AXQuery.first(in: snapshot) { node in
            guard AXReader.textEntryRoles.contains(node.role) else { return false }
            let hint = [node.placeholder, node.label].compactMap { $0 }
                .joined(separator: " ").lowercased()
            return hint.contains(composerPlaceholderHint)
        }
    }

    static func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.findAll("//AXHeading", in: snapshot)
            .compactMap(WebHostParsing.text(of:)).first {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    static func messages(in snapshot: AXNode) -> [Message] {
        messageContainers(in: snapshot).compactMap { container in
            let authorNode = AXQuery.find("//*[domClass=\"\(authorClass)\"]", in: container)
            let timeNode = AXQuery.find("//*[domClass=\"\(timestampClass)\"]", in: container)
            let sender = authorNode.flatMap(WebHostParsing.text(of:))
            let timeString = timeNode.flatMap(WebHostParsing.text(of:))
            let bodyNode = AXQuery.find("//*[domClass=\"\(bodyClass)\"]", in: container)
            let texts: [String]
            if let bodyNode {
                texts = AXQuery.collectStaticTexts(in: bodyNode)
            } else {
                // Tier B: everything the container says, minus the anchored sender/time subtrees.
                let excluded = Set((authorNode.map(AXQuery.collectStaticTexts(in:)) ?? [])
                    + (timeNode.map(AXQuery.collectStaticTexts(in:)) ?? []))
                texts = AXQuery.collectStaticTexts(in: container).filter { !excluded.contains($0) }
            }
            if texts.isEmpty {
                // AXDescription fallback: the whole description is the message, unattributed.
                guard let described = WebHostParsing.text(of: container) else { return nil }
                return WebHostParsing.message(sender: nil, timeString: timeString,
                                              texts: [described])
            }
            let isUser = sender?.caseInsensitiveCompare("[user]") == .orderedSame
            return WebHostParsing.message(sender: isUser ? "You" : sender, timeString: timeString,
                                          texts: texts, isUser: isUser)
        }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.messages(in: snapshot)
        if let draft = WebHostParsing.draft(in: Self.composer(in: snapshot)) {
            messages.append(draft)
        }
        guard !messages.isEmpty else {
            // The one refusal case (§14b): a compose-only chat whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise not handled: Teams' calendar, files and apps tabs share this host.
            return nil
        }
        return .conversation(Conversation(
            channel: Self.channel(in: snapshot, windowTitle: context.windowTitle),
            // Teams' anchors expose no channel-vs-chat marker; the renderer does not use isGroup.
            isGroup: false,
            messages: messages
        ))
    }

    /// True only for a compose-only window whose draft is empty. Every other empty read returns
    /// nil (not handled), so a generic extractor can capture a different Teams web surface.
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil && Self.messages(in: snapshot).isEmpty
    }
}
