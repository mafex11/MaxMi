import Foundation
import MaxMiCore

/// The app-agnostic half of the five §14b web-app parsers. The DOM anchors live in each parser;
/// the message-building rules live here, so Gmail, LinkedIn, Outlook, Slack web and Teams web
/// cannot drift apart on what counts as a sender or a draft.
enum WebHostParsing {
    /// The readable text of an anchor node. `label` is consulted last because it is
    /// `AXDescription ?? AXHelp` (spec §12 Q1) and is often a verbose restatement.
    static func text(of node: AXNode) -> String? {
        let raw = node.value ?? node.title ?? node.label
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// A composer's text: its own value, else the static texts a contenteditable exposes as
    /// children (every one of these five composers is a contenteditable, not a text field).
    static func editorText(in node: AXNode) -> String {
        if let value = node.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return AXQuery.collectStaticTexts(in: node).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The composer's live text as the user's draft. nil for a missing OR empty composer, which
    /// is what makes "compose-only window with an empty draft" decidable.
    static func draft(in composer: AXNode?) -> Message? {
        guard let composer else { return nil }
        let text = editorText(in: composer)
        guard !text.isEmpty else { return nil }
        return Message(id: Message.makeID(sender: "You", timeString: nil, text: text),
                       sender: "You", text: text, timestamp: nil, timeString: nil,
                       isUser: true, isDraft: true)
    }

    /// One message from one container's OWN texts.
    ///
    /// `texts` must already have the anchored sender and timestamp values removed, because when
    /// `sender` is nil the shared `NativeConversationExtraction.senderLabel` heuristic decides
    /// whether the FIRST value is a speaker. A joined line is never re-split on `": "` — "Note:
    /// check the doc" is a message, not a message from someone called "Note" (§14b).
    static func message(
        sender: String?,
        timeString: String?,
        texts: [String],
        isUser: Bool = false
    ) -> Message? {
        let values = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolved: String?
        let bodyValues: [String]
        if let sender, !sender.isEmpty {
            // The sender came from its own anchored node, so no value is consumed from the body.
            resolved = sender
            bodyValues = values
        } else if let heuristic = NativeConversationExtraction.senderLabel(values) {
            resolved = heuristic
            bodyValues = Array(values.dropFirst())
        } else {
            resolved = nil
            bodyValues = values
        }
        let body = bodyValues.joined(separator: " ")
        guard !body.isEmpty else { return nil }
        let time = timeString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = time?.isEmpty == false ? time : nil
        let name = resolved ?? "unknown"
        return Message(id: Message.makeID(sender: name, timeString: stamp, text: body),
                       sender: name, text: body, timestamp: nil, timeString: stamp,
                       isUser: isUser, isDraft: false)
    }

    /// The URL path, `""` when there is no URL. `LinkedInMessagingParser` uses it to stay off
    /// every LinkedIn page that is not `/messaging`.
    static func path(of url: String?) -> String {
        guard let url, let path = URLComponents(string: url)?.path else { return "" }
        return path
    }
}
