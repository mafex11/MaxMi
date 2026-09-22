import Foundation
import MaxMiCore

/// Gmail on the web (`mail.google.com`), routed by host (spec §7b, §14b).
///
/// Three surfaces, one parser: an open thread is a `.conversation`, a list view is a `.generic`
/// page of table rows, and a compose window is the draft alone. `contentKind` is NOT decided
/// here — `WebAppCaptureParser.classify` keeps Gmail on `.email` for all three (§12 Q3) — and
/// the thread key stays `URLKeyNormalizer.normalize(tab.url)`.
///
/// ANCHORS. Per the privacy ruling, no live AX snapshot was inspected or recorded for this task.
/// The following candidate anchors are verified by the hand-authored, scrubbed fixtures and
/// parser tests only; a future live verification must retain this distinction:
///   `adn`  message container          fixture-verified
///   `gD`   sender name                fixture-verified
///   `go`   sender address             fixture-verified
///   `g3`   time                       fixture-verified
///   `a3s`  message body               fixture-verified
///   `zA`   list row                   fixture-verified
///   AXDescription "Message Body"      compose editor fixture-verified
public struct GmailParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Gmail",
        bundleIDs: [],
        hosts: ["mail.google.com"],
        // Declared as §14b asks. INERT for a hosts-only parser: `forcedAttributes(for:)` is keyed
        // by bundle ID and the bundle here is the browser's. What supplies these attributes is
        // Task 1's AXWebArea-ancestor gate, which a real browser tab always satisfies.
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        // No native app shares mail.google.com, so no native claim competes for the window.
        preferOverNative: false
    )

    static let messageClass = "adn"
    static let senderNameClass = "gD"
    static let senderAddressClass = "go"
    static let timeClass = "g3"
    static let bodyClass = "a3s"
    static let listRowClass = "zA"
    static let composeBodyDescription = "Message Body"
    /// Headings Gmail renders AROUND the mail. None of them is ever a subject.
    static let chromeHeadings: Set<String> = [
        "gmail", "main menu", "search mail", "chat", "meet", "spaces", "conversations",
    ]

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[description=\"\(composeBodyDescription)\"]", in: snapshot)
    }

    /// The thread subject: the first non-chrome heading, else the window title (§14b).
    static func subject(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.findAll("//AXHeading", in: snapshot)
            .compactMap(WebHostParsing.text(of:))
            .first(where: { !chromeHeadings.contains($0.lowercased()) }) {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per EXPANDED container. A collapsed row carries no `a3s` body at all, and a
    /// message with a real sender and an empty body is worse than no message (§14b).
    static func threadMessages(in snapshot: AXNode) -> [Message] {
        let containers = AXQuery.findAll("//*[domClass=\"\(messageClass)\"]", in: snapshot)
        return AXQuery.sortedByVisualOrder(containers, relativeTo: snapshot.frame)
            .compactMap { container in
                guard let body = AXQuery.find("//*[domClass=\"\(bodyClass)\"]", in: container)
                else { return nil }
                let name = AXQuery.find("//*[domClass=\"\(senderNameClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                let address = AXQuery.find("//*[domClass=\"\(senderAddressClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                let time = AXQuery.find("//*[domClass=\"\(timeClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                let sender = name ?? address
                let isUser = sender?.caseInsensitiveCompare("[user]") == .orderedSame
                // Only the body subtree's texts, so the sender line cannot leak into the text.
                return WebHostParsing.message(sender: isUser ? "You" : sender, timeString: time,
                                              texts: AXQuery.collectStaticTexts(in: body),
                                              isUser: isUser)
            }
    }

    /// `[sender, subject + snippet, time]` per list row (§14b). The middle cell is JOINED rather
    /// than split further: Gmail exposes subject and snippet as two texts, and a row exposing
    /// only two texts has no time to read.
    static func listRows(in snapshot: AXNode) -> [Block] {
        let rows = AXQuery.findAll("//*[domClass=\"\(listRowClass)\"]", in: snapshot)
        return AXQuery.sortedByVisualOrder(rows, relativeTo: snapshot.frame).compactMap { row in
            let texts = AXQuery.collectStaticTexts(in: row)
            guard texts.count >= 2 else { return nil }
            let hasTime = texts.count >= 3
            let cells = [
                texts[0],
                texts.dropFirst().dropLast(hasTime ? 1 : 0).joined(separator: " "),
                hasTime ? texts[texts.count - 1] : "",
            ]
            return Block(type: .tableRow(cells: cells, selected: row.selected),
                         text: cells.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let draft = WebHostParsing.draft(in: Self.composer(in: snapshot))
        var messages = Self.threadMessages(in: snapshot)
        if !messages.isEmpty {
            if let draft { messages.append(draft) }
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                // Gmail's anchors expose no recipient list, so the thread stays flat.
                isGroup: false,
                messages: messages
            ))
        }
        // A live draft over the inbox is what the user is doing; the rows behind it are not.
        if let draft {
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false, messages: [draft]
            ))
        }
        let rows = Self.listRows(in: snapshot)
        guard !rows.isEmpty else {
            // The ONE refusal case (§14b): a compose-only window whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED: §4f rule 3 routes this window to `WebPageParser` and the
            // health ledger records "GenericPageExtractor.v2/fallback/GmailParser".
            return nil
        }
        return .generic(GenericPage(regions: [Region(kind: .main, blocks: rows)],
                                    focused: nil, url: context.url))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.threadMessages(in: snapshot).isEmpty
            && Self.listRows(in: snapshot).isEmpty
    }
}
