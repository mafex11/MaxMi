import Foundation
import MaxMiCore

/// LinkedIn messaging (`linkedin.com/messaging`) → `.conversation`, routed by host (§7b, §14b).
///
/// EVERY OTHER LINKEDIN PAGE STAYS GENERIC V2: `parse` returns nil off `/messaging`, even when a
/// page exposes message classes (the feed's notification rail does). `contentKind` is decided by
/// `WebAppCaptureParser.classify` — `.conversation` for `/messaging`, `.webpage` elsewhere
/// (§12 Q3) — and the key stays `URLKeyNormalizer.normalize(tab.url)`, which already truncates
/// `/messaging/thread/<id>` to three path components.
///
/// `isUser` is TRUE only when a group's name equals the signed-in user's name, or when the
/// explicit `[user]` fixture marker identifies the group as the user's. It is never inferred from
/// geometry or bubble alignment. When the signed-in name cannot be resolved every unmarked
/// message is emitted with `isUser: false`.
///
/// ANCHORS. Per the privacy ruling, no live AX snapshot was inspected or recorded for this task.
/// The following candidate anchors are verified by the hand-authored, scrubbed fixtures and
/// parser tests only; a future live verification must retain this distinction:
///   `msg-s-message-list__event`        message list item     fixture-verified
///   `msg-s-message-group__name`        sender                fixture-verified
///   `msg-s-message-group__timestamp`   time                  fixture-verified
///   `msg-s-event-listitem__body`       body                  fixture-verified
///   `msg-entity-lockup__entity-title`  conversation header   fixture-verified
///   `msg-form__contenteditable`        composer              fixture-verified
///   `global-nav__me-photo`             signed-in name        fixture-verified
///   `global-nav__me`                   signed-in name        NOT EXPOSED — photo fixture used
public struct LinkedInMessagingParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "LinkedIn",
        bundleIDs: [],
        hosts: ["www.linkedin.com", "linkedin.com"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`). The
        // AXWebArea gate is what actually supplies these attributes on a browser tab.
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let messagingPathPrefix = "/messaging"
    static let eventClass = "msg-s-message-list__event"
    static let groupNameClass = "msg-s-message-group__name"
    static let groupTimestampClass = "msg-s-message-group__timestamp"
    static let bodyClass = "msg-s-event-listitem__body"
    static let titleClass = "msg-entity-lockup__entity-title"
    static let composerClass = "msg-form__contenteditable"
    static let navMeClass = "global-nav__me-photo"
    static let navMeContainerClass = "global-nav__me"
    /// LinkedIn labels the nav photo either with the bare name or with this prefix.
    static let photoPrefix = "Photo of "

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[domClass=\"\(composerClass)\"]", in: snapshot)
    }

    /// The signed-in user's name, from the nav "Me" control. nil is a legitimate answer.
    static func signedInName(in snapshot: AXNode) -> String? {
        let node = AXQuery.find("//*[domClass=\"\(navMeClass)\"]", in: snapshot)
            ?? AXQuery.find("//*[domClass=\"\(navMeContainerClass)\"]", in: snapshot)
        guard let node, var name = WebHostParsing.text(of: node) else { return nil }
        if name.hasPrefix(photoPrefix) { name = String(name.dropFirst(photoPrefix.count)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        if let title = AXQuery.find("//*[domClass=\"\(titleClass)\"]", in: snapshot)
            .flatMap(WebHostParsing.text(of:)) {
            return title
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per body node. The name and timestamp live on the FIRST list item of a group,
    /// so a continuation item inherits the group it follows — that is container structure, not
    /// geometry, and it is why `sortedByVisualOrder` runs first.
    static func messages(in snapshot: AXNode, selfName: String?) -> [Message] {
        let events = AXQuery.sortedByVisualOrder(
            AXQuery.findAll("//*[domClass=\"\(eventClass)\"]", in: snapshot),
            relativeTo: snapshot.frame
        )
        var currentSender: String?
        var currentTime: String?
        var out: [Message] = []
        for event in events {
            if let name = AXQuery.find("//*[domClass=\"\(groupNameClass)\"]", in: event)
                .flatMap(WebHostParsing.text(of:)) {
                currentSender = name
                currentTime = AXQuery.find("//*[domClass=\"\(groupTimestampClass)\"]", in: event)
                    .flatMap(WebHostParsing.text(of:))
            }
            let bodies = AXQuery.sortedByVisualOrder(
                AXQuery.findAll("//*[domClass=\"\(bodyClass)\"]", in: event),
                relativeTo: event.frame
            )
            let hasUserMarker = currentSender?.caseInsensitiveCompare("[user]") == .orderedSame
            let isUser = hasUserMarker
                || selfName.map { name in
                    currentSender?.caseInsensitiveCompare(name) == .orderedSame
                } ?? false
            for body in bodies {
                if let message = WebHostParsing.message(
                    sender: hasUserMarker ? "You" : currentSender, timeString: currentTime,
                    texts: AXQuery.collectStaticTexts(in: body), isUser: isUser
                ) {
                    out.append(message)
                }
            }
        }
        return out
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        // Off /messaging this parser has nothing to say and the page stays generic v2 (§14b).
        guard WebHostParsing.path(of: context.url).hasPrefix(Self.messagingPathPrefix) else {
            return nil
        }
        var messages = Self.messages(in: snapshot, selfName: Self.signedInName(in: snapshot))
        if let draft = WebHostParsing.draft(in: Self.composer(in: snapshot)) {
            messages.append(draft)
        }
        guard !messages.isEmpty else {
            // The ONE refusal case (§14b): a compose-only thread whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED: an empty messaging shell is still a page.
            return nil
        }
        return .conversation(Conversation(
            channel: Self.channel(in: snapshot, windowTitle: context.windowTitle),
            // LinkedIn's anchors expose no participant count, so a thread stays flat.
            isGroup: false,
            messages: messages
        ))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard WebHostParsing.path(of: context.url).hasPrefix(Self.messagingPathPrefix),
              let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.messages(in: snapshot, selfName: nil).isEmpty
    }
}
