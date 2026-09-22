import Foundation
import MaxMiCore

/// Outlook on the web (`outlook.office.com`, `outlook.live.com`), routed by host (§7b, §14b).
///
/// Reading pane → `.conversation`; message list → `.generic` table rows; compose → the draft
/// alone. `contentKind` stays `.email` on every path because `WebAppCaptureParser.classify`
/// decides it (§12 Q3), and the key stays `URLKeyNormalizer.normalize(tab.url)`, which already
/// keeps only `itemid`.
///
/// `outlook.office365.com` is classified `.outlook` today but is NOT registered here: its DOM
/// anchors have not been verified, so it stays on generic v2.
///
/// ANCHORS. Per the privacy ruling, no live AX snapshot was inspected or recorded for this task.
/// These anchors are fixture-verified against hand-authored, scrubbed AX trees only:
///   `outlook-message-card`       message card, plus AXDescription "Message" or AXDocument role
///   `outlook-message-header`     card header carrying the From/Sent description
///   `outlook-message-body`       received-message body
///   `outlook-compose-body`       compose editor with AXDescription "Message body"
///   `outlook-message-row`        AXRow in the message list
///   `outlook-subject`            reading-pane subject heading
public struct OutlookWebParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Outlook Web",
        bundleIDs: [],
        hosts: ["outlook.office.com", "outlook.live.com"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`).
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let cardDescriptionPrefix = "Message"
    static let cardRole = "AXDocument"
    static let composeBodyDescription = "Message body"
    static let listRole = "AXRow"
    static let senderPrefix = "From: "
    static let sentSeparator = ", Sent: "

    private static let cardClass = "outlook-message-card"
    private static let headerClass = "outlook-message-header"
    private static let bodyClass = "outlook-message-body"
    private static let composerIdentifier = "outlook-compose-body"
    private static let rowClass = "outlook-message-row"
    private static let subjectClass = "outlook-subject"

    // MARK: - Header description

    /// Outlook's card header commonly describes itself as `"… From: <name>, Sent: <time>"`.
    /// Both halves are optional; anything that does not carry `"From: "` yields `(nil, nil)` and
    /// the caller falls back to the header's static texts in visual order (§14b).
    static func headerFields(fromDescription description: String) -> (sender: String?, time: String?) {
        guard let fromRange = description.range(of: senderPrefix) else { return (nil, nil) }
        let tail = description[fromRange.upperBound...]
        guard let sentRange = tail.range(of: sentSeparator) else {
            let sender = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            return (sender.isEmpty ? nil : sender, nil)
        }
        let sender = tail[..<sentRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let time = tail[sentRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (sender.isEmpty ? nil : sender, time.isEmpty ? nil : time)
    }

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.findAll("//*[domId=\"\(composerIdentifier)\"]", in: snapshot)
            .first(where: { $0.label == composeBodyDescription })
    }

    /// DOM-class-anchored cards, constrained by Outlook's description shape or its AXDocument
    /// alternative. A description alone is deliberately never sufficient to emit content.
    static func messageCards(in snapshot: AXNode) -> [AXNode] {
        let cards = AXQuery.findAll("//*[domClass=\"\(cardClass)\"]", in: snapshot)
            .filter {
                $0.label?.hasPrefix(cardDescriptionPrefix) == true || $0.role == cardRole
            }
        return AXQuery.sortedByVisualOrder(cards, relativeTo: snapshot.frame)
    }

    static func subject(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.find("//*[domClass=\"\(subjectClass)\"]", in: snapshot)
            .flatMap(WebHostParsing.text(of:)) {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per card. Sender and time come from the card header's From/Sent description
    /// when present; otherwise the shared `senderLabel` rule interprets the header's texts.
    static func readingPaneMessages(in snapshot: AXNode) -> [Message] {
        messageCards(in: snapshot).compactMap { card -> Message? in
            guard let header = AXQuery.find("//*[domClass=\"\(headerClass)\"]", in: card),
                  let body = AXQuery.find("//*[domClass=\"\(bodyClass)\"]", in: card)
            else { return nil }
            let described: (sender: String?, time: String?)
            if let description = header.label ?? card.label {
                described = headerFields(fromDescription: description)
            } else {
                described = (nil, nil)
            }
            let headerTexts = AXQuery.collectStaticTexts(in: header)
            let sender = described.sender ?? NativeConversationExtraction.senderLabel(headerTexts)
            let time = described.time ?? (headerTexts.count > 1 ? headerTexts[1] : nil)
            let isUser = sender?.caseInsensitiveCompare("[user]") == .orderedSame
            return WebHostParsing.message(
                sender: isUser ? "You" : sender,
                timeString: time,
                texts: AXQuery.collectStaticTexts(in: body),
                isUser: isUser
            )
        }
    }

    static func listRows(in snapshot: AXNode) -> [Block] {
        let rows = AXQuery.findAll("//\(listRole)[domClass=\"\(rowClass)\"]", in: snapshot)
        return AXQuery.sortedByVisualOrder(rows, relativeTo: snapshot.frame)
            .compactMap { GenericPageExtractor.block(for: $0, listDepth: 0) }
            .filter { !$0.text.isEmpty }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let draft = WebHostParsing.draft(in: Self.composer(in: snapshot))
        var messages = Self.readingPaneMessages(in: snapshot)
        if !messages.isEmpty {
            if let draft { messages.append(draft) }
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false,
                messages: messages
            ))
        }
        if let draft {
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false,
                messages: [draft]
            ))
        }
        let rows = Self.listRows(in: snapshot)
        guard !rows.isEmpty else {
            // The one refusal case: a compose-only window whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Settings, calendar, and unrecognised layouts remain NOT_HANDLED and fall through.
            return nil
        }
        return .generic(GenericPage(regions: [Region(kind: .main, blocks: rows)],
                                    focused: nil, url: context.url))
    }

    /// True only for a compose-only window whose draft is empty. All other empty reads are
    /// NOT_HANDLED and fall through to generic v2.
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.messageCards(in: snapshot).isEmpty
            && Self.listRows(in: snapshot).isEmpty
    }
}
