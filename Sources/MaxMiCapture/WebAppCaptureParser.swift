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
}

/// Routes known web applications to semantic capture profiles while retaining a
/// URL-keyed `Web` thread. No network or DOM injection is used; content remains the
/// visible Accessibility tree and is bounded before it reaches storage or Gemini.
public enum WebAppCaptureParser {
    static let contentCap = 16_000
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

    public static func parse(tab: TabCapture, window: AXNode) -> WebAppParseResult {
        let app = classify(url: tab.url)
        let isLinkedInMessaging = app == .linkedin
            && (URLComponents(string: tab.url)?.path.hasPrefix("/messaging") == true)
        let isConversation = [.slack, .discord, .whatsapp, .teams].contains(app)
            || isLinkedInMessaging
        let isEmail = app == .gmail || app == .outlook

        let semanticLines = isConversation ? messageLines(in: window) : []
        let content: String
        let preservedBoundaries: Bool
        if !semanticLines.isEmpty {
            content = bounded(semanticLines.joined(separator: "\n"))
            preservedBoundaries = true
        } else {
            content = bounded(tab.content)
            preservedBoundaries = false
        }

        let kind: CaptureContentKind = isConversation ? .conversation : (isEmail ? .email : .webpage)
        let accumulation: CaptureAccumulationPolicy = isConversation ? .appendItems : .rollingText
        let capture = ParsedCapture(
            sourceApp: "Web",
            sourceKey: URLKeyNormalizer.normalize(tab.url),
            sourceTitle: tab.title,
            content: content,
            contentKind: kind,
            parserVersion: 2,
            accumulationPolicy: accumulation,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000)
        )
        return WebAppParseResult(capture: capture, app: app, preservedBoundaries: preservedBoundaries)
    }

    /// One line per visible message container: `sender: body`. Containers without a
    /// distinct sender still remain one atomic line, which keeps append dedup stable.
    static func messageLines(in root: AXNode) -> [String] {
        var rows: [(y: CGFloat, line: String)] = []
        collectMessageContainers(root, into: &rows)
        let sorted = rows.sorted { $0.y < $1.y }.map(\.line)
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func collectMessageContainers(
        _ node: AXNode,
        into out: inout [(y: CGFloat, line: String)]
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
                out.append((node.frame?.origin.y ?? 0, line))
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

    private static func bounded(_ content: String) -> String {
        String(content.suffix(contentCap))
    }
}
