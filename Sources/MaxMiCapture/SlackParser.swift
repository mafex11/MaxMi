import Foundation
import MaxMiCore

/// Slack's native and web parser. The native window reaches this parser through AXReader's
/// locator because Slack leaves AXWindows empty; browser tabs reach it through app.slack.com.
///
/// ANCHORS. The privacy rule forbids recording or inspecting live application windows. The
/// following web anchors are verified by hand-authored, scrubbed fixtures only:
/// `c-message_list`, `c-virtual_list__item`, `c-message_kit__background`,
/// `c-message__sender`, `c-timestamp` (readable time in AXDescription), `p-rich_text_section`,
/// `ql-editor`, and `p-view_header__channel_title`. The web fixtures match the native message
/// list class-for-class except for the message_kit wrapper, description-only timestamp, and
/// header title. No unanchored whole-tree or geometry fallback is used.
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
    static let messageBackgroundClass = "c-message_kit__background"
    static let senderClass = "c-message__sender"
    static let timestampClass = "c-timestamp"
    static let composerClass = "ql-editor"
    static let headerChannelClass = "p-view_header__channel_title"

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
                || GenericPageExtractor.isSecure(node) {
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

    private static func paths(ofDOMClass domClass: String, in root: AXNode) -> [[Int]] {
        var found: [[Int]] = []
        func visit(_ node: AXNode, path: [Int]) {
            if (node.domClassList ?? []).contains(where: {
                $0.caseInsensitiveCompare(domClass) == .orderedSame
            }) {
                found.append(path)
            }
            for (index, child) in node.children.enumerated() {
                visit(child, path: path + [index])
            }
        }
        visit(root, path: [])
        return found
    }

    /// The channel title from the view header, e.g. "#general" for a channel and a person's name
    /// for a DM. nil when the header is not exposed, which is Task 10's native fixture shape.
    static func headerChannel(in snapshot: AXNode) -> String? {
        AXQuery.find("//*[domClass=\"\(headerChannelClass)\"]", in: snapshot)
            .flatMap(WebHostParsing.text(of:))
    }

    /// The channel NAME, with the group marker removed: "#general" and native "general" must
    /// produce the same name so one thread does not read two ways across surfaces. With no header
    /// the existing title helper answers — this task adds a source, it does not replace one.
    func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        guard let header = Self.headerChannel(in: snapshot) else {
            return channel(fromTitle: windowTitle)
        }
        return header.hasPrefix("#") ? String(header.dropFirst()) : header
    }

    /// A leading "#" in the header title is the only group marker Slack exposes. Native fixtures
    /// have no header, so their title rule remains unchanged. The web message_kit anchor retains
    /// Task 10's legacy channel default when the header is temporarily absent.
    func isGroup(in snapshot: AXNode, windowTitle: String?) -> Bool {
        guard let header = Self.headerChannel(in: snapshot) else {
            if AXQuery.find("//*[domClass*=\"\(Self.messageBackgroundClass)\"]", in: snapshot) != nil {
                return true
            }
            return isGroup(fromTitle: windowTitle)
        }
        return header.hasPrefix("#")
    }

    /// Message items: the virtual-list rows when they are exposed, else the message_kit
    /// backgrounds directly. Never both, so one message cannot be counted twice.
    static func domItems(in list: AXNode) -> [AXNode] {
        let virtualItems = AXQuery.findAll("//*[domClass*=\"\(messageItemClass)\"]", in: list)
        let items = virtualItems.isEmpty
            ? AXQuery.findAll("//*[domClass*=\"\(messageBackgroundClass)\"]", in: list)
            : virtualItems
        return AXQuery.sortedByVisualOrder(items, relativeTo: list.frame)
    }

    static func domMessages(in snapshot: AXNode) -> [Message] {
        guard let list = AXQuery.find("//*[domClass*=\"\(messageListClass)\"]", in: snapshot)
        else { return [] }
        return domItems(in: list).compactMap { item in
            let senderNode = AXQuery.find("//*[domClass*=\"\(senderClass)\"]", in: item)
            let timeNode = AXQuery.find("//*[domClass*=\"\(timestampClass)\"]", in: item)
            let sender = senderNode.flatMap(WebHostParsing.text(of:))
            // Slack web folds the readable time into the timestamp's aria-label, which AXReader
            // exposes as `label`; native Slack puts it in the value. `text(of:)` reads both.
            let timeString = timeNode.flatMap(WebHostParsing.text(of:))
            let excludedRoots = paths(ofDOMClass: senderClass, in: item)
                + paths(ofDOMClass: timestampClass, in: item)
            let texts = staticTextNodes(in: item)
                .filter { text in
                    !excludedRoots.contains { text.path.starts(with: $0) }
                }
                .map(\.value)
            let isUser = sender?.caseInsensitiveCompare("[user]") == .orderedSame
            return WebHostParsing.message(sender: isUser ? "You" : sender, timeString: timeString,
                                          texts: texts, isUser: isUser)
        }
    }

    /// The composer's live text. A draft is the one message Slack's tree marks as the user's.
    static func draftMessage(in snapshot: AXNode) -> Message? {
        if let composer = AXQuery.find("//*[domClass*=\"\(composerClass)\"]", in: snapshot) {
            return WebHostParsing.draft(in: composer)
        }
        // Preserve the established native composer predicate when Slack has not exposed DOM
        // attributes yet. This is reached through the same v2 path, not a separate extraction.
        return ComposerDraft.draft(window: snapshot)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        guard !messages.isEmpty else {
            // The ONE refusal case: a visible, empty composer and nothing else readable.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            return nil
        }
        return .conversation(Conversation(
            channel: channel(in: snapshot, windowTitle: context.windowTitle),
            isGroup: isGroup(in: snapshot, windowTitle: context.windowTitle),
            messages: messages
        ))
    }

    /// True only for a compose-only Slack surface: a visible composer, an empty draft and no
    /// anchored message. `parse` turns that into `ParserRefusal`; every other empty read stays
    /// nil and degrades to generic v2.
    func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = AXQuery.find("//*[domClass*=\"\(Self.composerClass)\"]", in: snapshot)
        else { return false }
        return Self.draftMessage(in: snapshot) == nil
            && Self.domMessages(in: snapshot).isEmpty
            && composer.hidden == false
    }
}
