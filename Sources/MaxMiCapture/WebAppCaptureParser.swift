import Foundation
import MaxMiCore

public enum WebAppKind: String, Sendable, CaseIterable {
    case generic
    case gmail
    case slack
    case discord
    case whatsapp
    case teams
    case outlook
    case linkedin
}

public struct WebAppParseResult: Sendable, Equatable {
    public let capture: ParsedCapture
    public let app: WebAppKind
    public let preservedBoundaries: Bool
    /// True when bounding the typed shape dropped content — budgeted-away page blocks, or
    /// messages shed off the front of a conversation. Independent of `TabCapture.truncated`,
    /// which reports the tab TEXT hitting `BrowserTabExtractor`'s own cap.
    public let truncated: Bool
}

/// Routes known web applications to semantic capture profiles while retaining a
/// URL-keyed `Web` thread. No network or DOM injection is used; content remains the
/// visible Accessibility tree and is bounded before it reaches storage or Gemini.
public enum WebAppCaptureParser {
    /// The browser content cap. Public because it is the default of a public parameter.
    public static let contentCap = 16_000
    static let messageRoles: Set<String> = ["AXRow", "AXListItem"]
    static let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXLink"]

    public static func classify(url: String) -> WebAppKind {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased() else { return .generic }
        if host == "mail.google.com" { return .gmail }
        if host == "app.slack.com" || host.hasSuffix(".slack.com") { return .slack }
        if host == "discord.com" || host == "www.discord.com" { return .discord }
        if host == "web.whatsapp.com" { return .whatsapp }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return .teams }
        if host == "outlook.office.com" || host == "outlook.live.com"
            || host == "outlook.office365.com" { return .outlook }
        if host == "linkedin.com" || host == "www.linkedin.com" { return .linkedin }
        return .generic
    }

    /// `contentBudget` is the cap both shapes are bounded to. It is a parameter only so a test can
    /// drive the budget without a 16k fixture; production always uses `contentCap`.
    public static func parse(
        tab: TabCapture,
        window: AXNode,
        contentBudget: Int = contentCap
    ) throws -> WebAppParseResult {
        let app = classify(url: tab.url)
        let isLinkedInMessaging = app == .linkedin
            && (URLComponents(string: tab.url)?.path.hasPrefix("/messaging") == true)
        let isConversation = [.slack, .discord, .whatsapp, .teams].contains(app)
            || isLinkedInMessaging
        let isEmail = app == .gmail || app == .outlook

        let typedMessages = isConversation ? messages(in: window) : []
        let structured: CapturedContent
        let preservedBoundaries: Bool
        // Whether BOUNDING dropped content, which is a separate fact from the tab text having hit
        // the extractor's own cap. Both feed `BrowserCaptureResult.truncated`, which is what the
        // MCP layer discloses as "context was bounded".
        var truncated = false
        if !typedMessages.isEmpty {
            structured = CaptureAccumulator.bound(
                .conversation(Conversation(
                    channel: tab.title ?? URLComponents(string: tab.url)?.host ?? tab.url,
                    // No group marker survives the web walk; Phase D's anchored parsers read
                    // the participant list.
                    isGroup: false,
                    messages: typedMessages
                )),
                to: contentBudget
            )
            // `bound` sheds whole messages off the front, so a shorter list IS the truncation.
            if case .conversation(let bounded) = structured {
                truncated = bounded.messages.count < typedMessages.count
            }
            preservedBoundaries = true
        } else {
            // Generic path: the v2 extractor over the page subtree, with the URL attached.
            var options = GenericPageExtractor.Options()
            options.totalBudget = contentBudget
            options.offscreenPolicy = .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000)
            let extracted = GenericPageExtractor.extract(
                window: pageSubtree(in: window, title: tab.title),
                focusedElement: nil,
                url: tab.url,
                options: options
            )
            // A page with no regions renders to nothing but its URL, which would overwrite a
            // real capture of this thread with an empty one. Same rule as
            // `GenericV2Content.page` returning nil for a native window.
            guard !extracted.page.regions.isEmpty else { throw ExtractionError.emptyContent }
            structured = .generic(extracted.page)
            truncated = extracted.truncated
            preservedBoundaries = false
        }

        // Kind is NOT derived from the shape: Gmail/Outlook stay .email and every other page
        // stays .webpage (spec 12 Q3).
        let kind: CaptureContentKind = isConversation ? .conversation : (isEmail ? .email : .webpage)
        let accumulation: CaptureAccumulationPolicy = isConversation ? .appendItems : .rollingText
        let capture = ParsedCapture(
            sourceApp: "Web",
            sourceKey: URLKeyNormalizer.normalize(tab.url),
            sourceTitle: tab.title,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: kind,
            parserVersion: 2,
            accumulationPolicy: accumulation,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000),
            structured: structured
        )
        return WebAppParseResult(
            capture: capture, app: app,
            preservedBoundaries: preservedBoundaries, truncated: truncated
        )
    }

    /// The subtree the generic path walks: the primary web area, or — when the window exposes
    /// none — the window with its browser chrome removed. Toolbars are dropped structurally
    /// rather than filtered out of the finished page, so the page's budget is never spent on the
    /// address bar; this is the same exclusion `BrowserTabExtractor.visualOrderText` applies on
    /// its own no-web-area fallback.
    static func pageSubtree(in window: AXNode, title: String?) -> AXNode {
        BrowserTabExtractor.primaryWebArea(in: window, windowTitle: title)
            ?? withoutToolbars(window)
    }

    private static func withoutToolbars(_ node: AXNode) -> AXNode {
        AXNode(
            role: node.role, value: node.value, title: node.title, url: node.url,
            frame: node.frame, focused: node.focused,
            children: node.children.filter { $0.role != "AXToolbar" }.map(withoutToolbars),
            identifier: node.identifier, label: node.label, subrole: node.subrole,
            headingLevel: node.headingLevel, selected: node.selected,
            placeholder: node.placeholder, selectedText: node.selectedText, hidden: node.hidden
        )
    }

    /// One line per visible message container: `sender: body`. Containers without a
    /// distinct sender still remain one atomic line, which keeps append dedup stable.
    static func messageLines(in root: AXNode) -> [String] {
        messageValues(in: root).compactMap(messageLine)
    }

    /// One `Message` per visible message container, built from that container's OWN text values:
    /// the first value becomes the sender only when it looks like a sender label
    /// (`NativeConversationExtraction.senderLabel`, shared with the native chat parsers), and
    /// otherwise the container is one unattributed message keeping its full text. A joined line is
    /// never re-split on `": "` — "Note: check the doc" is a message, not a message from "Note".
    static func messages(in root: AXNode) -> [Message] {
        messageValues(in: root).compactMap(message(from:))
    }

    /// The atomic text values of each visible message container, in visual order, with
    /// accidental adjacent duplicate containers collapsed. `messageLines` joins them and
    /// `messages` attributes them, so both see exactly one entry per rendered message.
    static func messageValues(in root: AXNode) -> [[String]] {
        var rows: [(y: CGFloat, values: [String])] = []
        collectMessageContainers(root, into: &rows)
        var result: [[String]] = []
        // Repeated messages such as "yes" are real, distinct events. Only collapse
        // accidental adjacent duplicate AX nodes from the same rendered message.
        var previous: String?
        for values in rows.sorted(by: { $0.y < $1.y }).map(\.values) {
            guard let line = messageLine(values) else { continue }
            if previous?.caseInsensitiveCompare(line) == .orderedSame { continue }
            result.append(values)
            previous = line
        }
        return result
    }

    static func message(from values: [String]) -> Message? {
        let sender = NativeConversationExtraction.senderLabel(values)
        let text = (sender == nil ? values : Array(values.dropFirst())).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let name = sender ?? "unknown"
        return Message(
            id: Message.makeID(sender: name, timeString: nil, text: text),
            sender: name, text: text, timestamp: nil, timeString: nil,
            // No outgoing signal survives this walk: a web chat's own bubbles are marked by
            // ALIGNMENT and by DOM classes, neither of which reaches the AX values read here.
            // Phase D's anchored per-app parsers read it.
            isUser: false,
            isDraft: false
        )
    }

    private static func collectMessageContainers(
        _ node: AXNode,
        into out: inout [(y: CGFloat, values: [String])]
    ) {
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let singularMessageHint = metadata.contains("message") && !metadata.contains("messages")
        let candidate = messageRoles.contains(node.role) || singularMessageHint
        if candidate {
            var text: [(y: CGFloat, x: CGFloat, value: String)] = []
            collectText(node, into: &text)
            let values = text.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
                .map(\.value)
                .reduce(into: [String]()) { result, value in
                    if result.last != value { result.append(value) }
                }
            if let line = messageLine(values), !line.isEmpty {
                out.append((node.frame?.origin.y ?? 0, values))
                return
            }
        }
        for child in node.children { collectMessageContainers(child, into: &out) }
    }

    private static func messageLine(_ values: [String]) -> String? {
        let values = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = values.first else { return nil }
        if values.count == 1 { return first }
        return "\(first): \(values.dropFirst().joined(separator: " "))"
    }

    private static func collectText(
        _ node: AXNode,
        into out: inout [(y: CGFloat, x: CGFloat, value: String)]
    ) {
        if textRoles.contains(node.role), let raw = node.value ?? node.title {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                out.append((node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0, value))
            }
        }
        for child in node.children { collectText(child, into: &out) }
    }
}
