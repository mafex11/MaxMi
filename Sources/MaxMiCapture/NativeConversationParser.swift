import Foundation
import MaxMiCore

public struct WhatsAppParser: SourceParser {
    private struct BoundedContent {
        let content: CapturedContent
        let truncated: Bool
    }

    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let bounded = try Self.boundedContent(
            window, context: ParseContext(app: app)
        ) else { return nil }
        let content = bounded.content
        guard case .conversation(let conversation) = content else { return nil }
        return ParsedCapture(
            sourceApp: "WhatsApp",
            sourceKey: "whatsapp:\(NativeConversationExtraction.slug(conversation.channel))",
            sourceTitle: conversation.channel,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: content,
            truncated: bounded.truncated
        )
    }
}

public struct TeamsParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try NativeConversationExtraction.extract(
            window: window,
            app: app,
            sourceApp: "Microsoft Teams",
            keyPrefix: "teams"
        ).content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        try NativeConversationExtraction.capture(
            window: window,
            app: app,
            sourceApp: "Microsoft Teams",
            keyPrefix: "teams"
        )
    }
}

enum NativeConversationExtraction {
    static let contentCap = 8_000
    static let messageRoles: Set<String> = ["AXRow", "AXListItem"]
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXHeading"]
    static let semanticLabelRoles: Set<String> = ["AXButton", "AXLink"]
    static let chrome: Set<String> = [
        "chats", "calls", "updates", "communities", "settings", "search",
        "new chat", "more", "reply", "react", "forward", "edited",
        "activity", "chat", "teams", "calendar", "apps", "copilot",
    ]

    struct Extracted {
        let content: CapturedContent
        let sourceKey: String
        let sourceTitle: String?
        let truncated: Bool
    }

    /// Throws `ParserRefusal` rather than returning nil when this window is a conversation
    /// surface it will not let through. Both parsers own apps whose windows are dominated by a
    /// sidebar chat list, so a generic fall-through would store the titles of conversations the
    /// user never opened — worse than storing nothing (spec 4f rule 3, refusal case).
    static func extract(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        keyPrefix: String,
        requiresConversationIdentity: Bool = false,
        allowsFallback: Bool = true,
        // WhatsApp's two sender conventions: the user's own bubbles carry the literal sender
        // "You", and a whole bubble is often exposed as ONE accessible label reading
        // "<sender>: <body>". Teams does neither, so it opts out.
        usesWhatsAppSenderLabels: Bool = false,
        boundsContent: Bool = true
    ) throws -> Extracted {
        let boundary = mainPaneBoundary(window)
        let conversation = conversationTitle(
            in: window,
            app: app,
            mainBoundary: boundary,
            requiresHeaderSemantics: requiresConversationIdentity
        )
        var containers: [(y: CGFloat, sender: String?, texts: [String])] = []
        collectMessageContainers(
            window,
            mainBoundary: boundary,
            requiresMessageSemantics: requiresConversationIdentity,
            into: &containers
        )

        var bubbles = containers.sorted { $0.y < $1.y }
            .map { (sender: $0.sender, text: $0.texts.joined(separator: " ")) }
        if bubbles.isEmpty, allowsFallback {
            // The fallback reads loose main-pane text, so nothing there is sender-attributed.
            bubbles = fallbackMainPaneLines(in: window, mainBoundary: boundary)
                .map { (sender: nil, text: $0) }
        }
        bubbles = uniqueAdjacent(bubbles).filter { $0.sender != nil || !isChrome($0.text) }
        // Everything on screen was app chrome: a non-chat surface (Teams' Calendar, Activity or
        // Apps tab; WhatsApp with no chat open), not a message list this parser misread.
        guard !bubbles.isEmpty else {
            throw ParserRefusal(reason: "no-conversation-content")
        }
        // WhatsApp only: without a confirmed chat header there is no conversation to key on, so
        // the content cannot be attributed to a thread at all.
        guard !requiresConversationIdentity || conversation != nil else {
            throw ParserRefusal(reason: "unconfirmed-conversation-identity")
        }
        if usesWhatsAppSenderLabels {
            // Participants this walk can vouch for: the user, plus the contact in a 1:1 chat —
            // which is exactly the conversation title. No group marker survives the walk, so
            // `isGroup` below is always false and the title is always the contact; Phase D's
            // group detection must drop the title from this set for a group chat.
            var known: Set<String> = ["you"]
            if let conversation { known.insert(conversation.lowercased()) }
            bubbles = bubbles.map { split($0, byKnownParticipant: known) }
        }

        let identity = conversation ?? meaningfulWindowTitle(app.windowTitle, excluding: sourceApp) ?? "unknown"
        var typedMessages = bubbles.map {
            message(sender: $0.sender, text: $0.text,
                    labelsUserAsYou: usesWhatsAppSenderLabels)
        }
        if let draft = ComposerDraft.draft(window: window) { typedMessages.append(draft) }
        let typed = Conversation(
            channel: identity,
            // WhatsApp and Teams headers expose no group marker; Phase D's anchored parsers
            // read the participant list.
            isGroup: false,
            messages: typedMessages
        )
        let unbounded = CapturedContent.conversation(typed)
        let content = boundsContent
            ? CaptureAccumulator.boundHard(unbounded, to: contentCap)
            : unbounded
        return Extracted(
            content: content,
            sourceKey: "\(keyPrefix):\(slug(identity))",
            sourceTitle: conversation ?? app.windowTitle,
            truncated: content != unbounded
        )
    }

    static func capture(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        keyPrefix: String,
        requiresConversationIdentity: Bool = false,
        allowsFallback: Bool = true,
        usesWhatsAppSenderLabels: Bool = false
    ) throws -> ParsedCapture {
        let extracted = try extract(
            window: window, app: app, sourceApp: sourceApp, keyPrefix: keyPrefix,
            requiresConversationIdentity: requiresConversationIdentity,
            allowsFallback: allowsFallback,
            usesWhatsAppSenderLabels: usesWhatsAppSenderLabels
        )
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: extracted.sourceKey,
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000),
            structured: extracted.content,
            truncated: extracted.truncated
        )
    }

    /// Splits a one-label bubble ("<sender>: <body>") when the prefix names a KNOWN participant.
    /// Any other prefix is left alone: this walk cannot tell a speaker from a word, so
    /// "Note: check the doc" must stay a message rather than become a message from "Note".
    static func split(
        _ bubble: (sender: String?, text: String),
        byKnownParticipant known: Set<String>
    ) -> (sender: String?, text: String) {
        guard bubble.sender == nil, let separator = bubble.text.range(of: ": ") else { return bubble }
        let prefix = String(bubble.text[..<separator.lowerBound])
        guard known.contains(prefix.lowercased()) else { return bubble }
        return (prefix, String(bubble.text[separator.upperBound...]))
    }

    /// A bubble the AX walk attributed (`sender != nil`) or could not (`sender == nil`, which
    /// stays `"unknown"`). Never splits the text on `": "` — a single-label bubble reading
    /// "Note: check the doc" is a message, not a message from someone called "Note".
    static func message(sender: String?, text: String, labelsUserAsYou: Bool) -> Message {
        let name = sender ?? "unknown"
        return Message(
            id: Message.makeID(sender: name, timeString: nil, text: text),
            sender: name, text: text, timestamp: nil, timeString: nil,
            // WhatsApp labels the user's own bubbles with the literal sender "You", which is a
            // real outgoing signal; Teams exposes none, so it opts out. Bubble ALIGNMENT (the
            // other signal) does not survive this walk — Phase D's anchored parsers read it.
            isUser: labelsUserAsYou && name.caseInsensitiveCompare("You") == .orderedSame,
            isDraft: false
        )
    }

    static func mainPaneBoundary(_ window: AXNode) -> CGFloat {
        guard let frame = window.frame else { return 240 }
        return frame.minX + min(360, max(220, frame.width * 0.28))
    }

    static func conversationTitle(
        in root: AXNode,
        app: AppInfo,
        mainBoundary: CGFloat,
        requiresHeaderSemantics: Bool
    ) -> String? {
        let top = root.frame?.minY ?? 0
        let maxY = top + min(180, (root.frame?.height ?? 600) * 0.25)
        var candidates: [(score: Int, y: CGFloat, value: String)] = []
        collectTitleCandidates(
            root,
            mainBoundary: mainBoundary,
            maxY: maxY,
            requiresHeaderSemantics: requiresHeaderSemantics,
            into: &candidates
        )
        let appNames = [app.name.lowercased(), "whatsapp", "microsoft teams", "teams"]
        return candidates
            .filter { candidate in
                let lower = candidate.value.lowercased()
                return !appNames.contains(lower) && !isChrome(lower) && !isSystemNotice(lower)
            }
            .sorted { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.y < rhs.y }
            .first?.value
    }

    private static func collectTitleCandidates(
        _ node: AXNode,
        mainBoundary: CGFloat,
        maxY: CGFloat,
        requiresHeaderSemantics: Bool,
        into out: inout [(score: Int, y: CGFloat, value: String)]
    ) {
        if let raw = readableText(node) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let x = node.frame?.minX ?? mainBoundary
            let y = node.frame?.minY ?? 0
            if !value.isEmpty, value.count <= 120, x >= mainBoundary, y <= maxY,
               textRoles.contains(node.role) {
                var score = node.role == "AXHeading" ? 30 : 10
                let metadata = [node.identifier, node.label].compactMap { $0 }
                    .joined(separator: " ").lowercased()
                let hasHeaderSemantics = metadata.contains("conversation")
                    || metadata.contains("chat")
                    || metadata.contains("title")
                    || metadata.contains("header")
                if hasHeaderSemantics { score += 20 }
                if !requiresHeaderSemantics || hasHeaderSemantics {
                    out.append((score, y, value))
                }
            }
        }
        for child in node.children {
            collectTitleCandidates(
                child,
                mainBoundary: mainBoundary,
                maxY: maxY,
                requiresHeaderSemantics: requiresHeaderSemantics,
                into: &out
            )
        }
    }

    /// `texts` is the BODY of the bubble: the sender label, when the container exposes one, has
    /// already been lifted out into `sender`.
    private static func collectMessageContainers(
        _ node: AXNode,
        mainBoundary: CGFloat,
        requiresMessageSemantics: Bool,
        into out: inout [(y: CGFloat, sender: String?, texts: [String])]
    ) {
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let hasMessageHint = metadata.contains("message")
            || metadata.contains("bubble")
            || metadata.contains("wamessage")
        let x = node.frame?.minX ?? mainBoundary
        let candidate = x >= mainBoundary
            && (requiresMessageSemantics ? hasMessageHint : (messageRoles.contains(node.role) || hasMessageHint))
        if candidate {
            var values: [(y: CGFloat, x: CGFloat, value: String)] = []
            collectText(node, into: &values)
            let ordered = uniqueAdjacent(values.sorted {
                $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x
            }.map(\.value)).filter { !isChrome($0) }
            if !ordered.isEmpty {
                let sender = senderLabel(ordered)
                out.append((node.frame?.minY ?? 0, sender,
                            sender == nil ? ordered : Array(ordered.dropFirst())))
                return
            }
        }
        for child in node.children {
            collectMessageContainers(
                child,
                mainBoundary: mainBoundary,
                requiresMessageSemantics: requiresMessageSemantics,
                into: &out
            )
        }
    }

    private static func fallbackMainPaneLines(in root: AXNode, mainBoundary: CGFloat) -> [String] {
        var values: [(y: CGFloat, x: CGFloat, value: String)] = []
        collectText(root, into: &values)
        return values
            .filter { $0.x >= mainBoundary }
            .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            .map(\.value)
    }

    private static func collectText(
        _ node: AXNode,
        into out: inout [(y: CGFloat, x: CGFloat, value: String)]
    ) {
        if (textRoles.contains(node.role) || semanticLabelRoles.contains(node.role)),
           let raw = readableText(node) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                out.append((node.frame?.minY ?? 0, node.frame?.minX ?? 0, value))
            }
        }
        for child in node.children { collectText(child, into: &out) }
    }

    private static func readableText(_ node: AXNode) -> String? {
        if semanticLabelRoles.contains(node.role) {
            return node.label ?? node.title ?? node.value
        }
        if node.role == "AXHeading" || node.role == "AXStaticText" {
            return node.value ?? node.title ?? node.label
        }
        return node.value ?? node.title
    }

    /// The first text of a bubble is its sender only when there is a body after it and the value
    /// looks like a label (short, single-line). A bubble with one text value has no sender at all.
    ///
    /// Shared with `WebAppCaptureParser.messages`: a chat rendered in a browser exposes the same
    /// container shape, so both paths must decide "is this first value a speaker?" identically.
    static func senderLabel(_ values: [String]) -> String? {
        guard let first = values.first, values.count > 1,
              first.count <= 80, !first.contains("\n") else { return nil }
        return first
    }

    private static func meaningfulWindowTitle(_ title: String?, excluding appName: String) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.caseInsensitiveCompare(appName) != .orderedSame,
              title.caseInsensitiveCompare("WhatsApp") != .orderedSame,
              title.caseInsensitiveCompare("Microsoft Teams") != .orderedSame else { return nil }
        return title
    }

    /// Bubble-level twin of `uniqueAdjacent(_: [String])`: an AX tree that exposes the same
    /// bubble twice (a container and its accessible label) collapses, while two speakers saying
    /// the same thing in a row both survive.
    private static func uniqueAdjacent(
        _ bubbles: [(sender: String?, text: String)]
    ) -> [(sender: String?, text: String)] {
        bubbles.reduce(into: []) { result, bubble in
            let text = bubble.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let sender = bubble.sender?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = result.last,
               (last.sender ?? "").caseInsensitiveCompare(sender ?? "") == .orderedSame,
               last.text.caseInsensitiveCompare(text) == .orderedSame { return }
            result.append((sender, text))
        }
    }

    private static func uniqueAdjacent(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, result.last?.caseInsensitiveCompare(clean) != .orderedSame {
                result.append(clean)
            }
        }
    }

    private static func isChrome(_ value: String) -> Bool {
        chrome.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// WhatsApp exposes connection/call banners near the top of the message pane.
    /// They are not chat headers and must never become a durable thread key.
    private static func isSystemNotice(_ value: String) -> Bool {
        [
            "use whatsapp on your phone",
            "older messages",
            "syncing",
            "reconnecting",
            "pinned message",
            "tap to go to message",
            "voice call",
            "video call",
            "is speaking",
        ].contains { value.contains($0) }
    }

    static func slug(_ value: String) -> String {
        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = clean.split { !$0.isLetter && !$0.isNumber }
        return pieces.prefix(12).joined(separator: "-").prefix(120).description
    }
}

extension NativeConversationExtraction {
    /// The conversation identity the v1 parser already derives from the header, exposed so the
    /// structured parsers do not re-implement it. WhatsApp's window title is just "WhatsApp".
    static func conversationName(window: AXNode, app: AppInfo) -> String? {
        conversationTitle(
            in: window, app: app,
            mainBoundary: mainPaneBoundary(window),
            requiresHeaderSemantics: true
        )
    }
}

extension WhatsAppParser: StructuredParser {
    public static let config = ParserConfig(
        app: "WhatsApp",
        bundleIDs: ParserRegistry.whatsAppBundleIDs,
        hosts: ["web.whatsapp.com"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000),
        preferOverNative: true
    )

    /// The one stable anchor WhatsApp exposes. Cells outside it (the chat list, banners, the
    /// "Use WhatsApp on your phone" notice) are structurally excluded.
    static let bubbleCellIdentifier = "WAMessageBubbleTableViewCell"
    /// "16:02" or "4:02 PM".
    static let timeStringPattern = "^\\d{1,2}:\\d{2}(\\s?[AP]M)?$"

    /// A bubble's static texts are the body plus, usually, a trailing timestamp.
    static func splitBubbleTexts(_ texts: [String]) -> (body: String, timeString: String?) {
        guard let last = texts.last,
              last.range(of: timeStringPattern, options: .regularExpression) != nil else {
            return (texts.joined(separator: " "), nil)
        }
        return (texts.dropLast().joined(separator: " "), last)
    }

    /// A bubble cell can expose its entire accessible payload as `"Name: text"`. This is a
    /// structural cell-label convention, not a re-split of unanchored message text.
    static func splitCombinedCellLabel(_ label: String) -> (sender: String, text: String)? {
        guard let separator = label.range(of: ": ") else { return nil }
        let sender = String(label[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(label[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !text.isEmpty else { return nil }
        return (sender, text)
    }

    /// The bubble cell is the sender container. A separate label is paired with the rendered
    /// body through `senderLabel`; a combined cell label is structurally split first and then
    /// uses that same helper. A one-label non-combined cell remains unattributed.
    static func labeledBubble(
        _ cell: AXNode,
        staticTexts: [String]
    ) -> (sender: String?, text: String, timeString: String?)? {
        let split = splitBubbleTexts(staticTexts)
        let label = cell.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else {
            return split.body.isEmpty ? nil : (nil, split.body, split.timeString)
        }
        if let combined = splitCombinedCellLabel(label) {
            let text = split.body.isEmpty ? combined.text : split.body
            let sender = NativeConversationExtraction.senderLabel([combined.sender, text])
            return (sender, text, split.timeString)
        }
        guard !split.body.isEmpty else {
            return (nil, label, split.timeString)
        }
        return (
            NativeConversationExtraction.senderLabel([label, split.body]),
            split.body,
            split.timeString
        )
    }

    private static func boundedContent(
        _ snapshot: AXNode,
        context: ParseContext
    ) throws -> BoundedContent? {
        let cells = AXQuery.findAll("//*[identifier=\"\(Self.bubbleCellIdentifier)\"]", in: snapshot)
        guard !cells.isEmpty else { return nil }
        // Without a confirmed chat header there is no thread to attribute these bubbles to, and a
        // generic capture would store the sidebar list of every unopened chat. Refuse (F13).
        guard let channel = NativeConversationExtraction.conversationName(
            window: snapshot, app: context.app
        ) else {
            throw ParserRefusal(reason: "unconfirmed-conversation-identity")
        }
        let messages = AXQuery.sortedByVisualOrder(cells, relativeTo: snapshot.frame)
            .compactMap { cell -> Message? in
                guard let bubble = Self.labeledBubble(
                    cell, staticTexts: AXQuery.collectStaticTexts(in: cell)
                ) else { return nil }
                let isUser = MessagesParser.isUserBubble(cell, window: snapshot)
                let sender = isUser ? "You" : (bubble.sender ?? channel)
                return Message(
                    id: Message.makeID(sender: sender, timeString: bubble.timeString,
                                       text: bubble.text),
                    sender: sender, text: bubble.text, timestamp: nil,
                    timeString: bubble.timeString, isUser: isUser, isDraft: false
                )
        }
        guard !messages.isEmpty else {
            throw ParserRefusal(reason: "no-conversation-content")
        }
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        let unbounded = CapturedContent.conversation(
            Conversation(channel: channel, isGroup: isGroup, messages: messages)
        )
        let content = CaptureAccumulator.boundHard(unbounded, to: NativeConversationExtraction.contentCap)
        return BoundedContent(content: content, truncated: content != unbounded)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        try Self.boundedContent(snapshot, context: context)?.content
    }
}
