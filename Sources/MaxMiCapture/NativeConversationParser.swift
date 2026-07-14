import Foundation
import MaxMiCore

public struct WhatsAppParser: SourceParser {
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        NativeConversationExtraction.parse(
            window: window,
            app: app,
            sourceApp: "WhatsApp",
            keyPrefix: "whatsapp"
        )
    }
}

public struct TeamsParser: SourceParser {
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        NativeConversationExtraction.parse(
            window: window,
            app: app,
            sourceApp: "Microsoft Teams",
            keyPrefix: "teams"
        )
    }
}

enum NativeConversationExtraction {
    static let contentCap = 16_000
    static let messageRoles: Set<String> = ["AXRow", "AXListItem"]
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXHeading"]
    static let chrome: Set<String> = [
        "chats", "calls", "updates", "communities", "settings", "search",
        "new chat", "more", "reply", "react", "forward", "edited",
        "activity", "chat", "teams", "calendar", "apps", "copilot",
    ]

    static func parse(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        keyPrefix: String
    ) -> ParsedCapture? {
        let boundary = mainPaneBoundary(window)
        let conversation = conversationTitle(in: window, app: app, mainBoundary: boundary)
        var messages: [(y: CGFloat, line: String)] = []
        collectMessageContainers(window, mainBoundary: boundary, into: &messages)

        var lines = messages.sorted { $0.y < $1.y }.map(\.line)
        if lines.isEmpty {
            lines = fallbackMainPaneLines(in: window, mainBoundary: boundary)
        }
        lines = uniqueAdjacent(lines).filter { !isChrome($0) }
        guard !lines.isEmpty else { return nil }

        let content = String(lines.joined(separator: "\n").suffix(contentCap))
        let identity = conversation ?? meaningfulWindowTitle(app.windowTitle, excluding: sourceApp) ?? "unknown"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(keyPrefix):\(slug(identity))",
            sourceTitle: conversation ?? app.windowTitle,
            content: content,
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000)
        )
    }

    private static func mainPaneBoundary(_ window: AXNode) -> CGFloat {
        guard let frame = window.frame else { return 240 }
        return frame.minX + min(360, max(220, frame.width * 0.28))
    }

    private static func conversationTitle(
        in root: AXNode,
        app: AppInfo,
        mainBoundary: CGFloat
    ) -> String? {
        let top = root.frame?.minY ?? 0
        let maxY = top + min(180, (root.frame?.height ?? 600) * 0.25)
        var candidates: [(score: Int, y: CGFloat, value: String)] = []
        collectTitleCandidates(root, mainBoundary: mainBoundary, maxY: maxY, into: &candidates)
        let appNames = [app.name.lowercased(), "whatsapp", "microsoft teams", "teams"]
        return candidates
            .filter { candidate in
                let lower = candidate.value.lowercased()
                return !appNames.contains(lower) && !isChrome(lower)
            }
            .sorted { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.y < rhs.y }
            .first?.value
    }

    private static func collectTitleCandidates(
        _ node: AXNode,
        mainBoundary: CGFloat,
        maxY: CGFloat,
        into out: inout [(score: Int, y: CGFloat, value: String)]
    ) {
        if let raw = node.value ?? node.title {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let x = node.frame?.minX ?? mainBoundary
            let y = node.frame?.minY ?? 0
            if !value.isEmpty, value.count <= 120, x >= mainBoundary, y <= maxY,
               textRoles.contains(node.role) {
                var score = node.role == "AXHeading" ? 30 : 10
                let metadata = [node.identifier, node.label].compactMap { $0 }
                    .joined(separator: " ").lowercased()
                if metadata.contains("title") || metadata.contains("header") { score += 20 }
                out.append((score, y, value))
            }
        }
        for child in node.children {
            collectTitleCandidates(child, mainBoundary: mainBoundary, maxY: maxY, into: &out)
        }
    }

    private static func collectMessageContainers(
        _ node: AXNode,
        mainBoundary: CGFloat,
        into out: inout [(y: CGFloat, line: String)]
    ) {
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let hasMessageHint = metadata.contains("message") || metadata.contains("bubble")
        let x = node.frame?.minX ?? mainBoundary
        let candidate = x >= mainBoundary && (messageRoles.contains(node.role) || hasMessageHint)
        if candidate {
            var values: [(y: CGFloat, x: CGFloat, value: String)] = []
            collectText(node, into: &values)
            let ordered = uniqueAdjacent(values.sorted {
                $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x
            }.map(\.value)).filter { !isChrome($0) }
            if let line = atomicMessageLine(ordered) {
                out.append((node.frame?.minY ?? 0, line))
                return
            }
        }
        for child in node.children {
            collectMessageContainers(child, mainBoundary: mainBoundary, into: &out)
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
        if textRoles.contains(node.role), let raw = node.value ?? node.title {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                out.append((node.frame?.minY ?? 0, node.frame?.minX ?? 0, value))
            }
        }
        for child in node.children { collectText(child, into: &out) }
    }

    private static func atomicMessageLine(_ values: [String]) -> String? {
        guard let first = values.first else { return nil }
        guard values.count > 1 else { return first }
        let senderLike = first.count <= 80 && !first.contains("\n")
        return senderLike
            ? "\(first): \(values.dropFirst().joined(separator: " "))"
            : values.joined(separator: " ")
    }

    private static func meaningfulWindowTitle(_ title: String?, excluding appName: String) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.caseInsensitiveCompare(appName) != .orderedSame,
              title.caseInsensitiveCompare("WhatsApp") != .orderedSame,
              title.caseInsensitiveCompare("Microsoft Teams") != .orderedSame else { return nil }
        return title
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

    private static func slug(_ value: String) -> String {
        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = clean.split { !$0.isLetter && !$0.isNumber }
        return pieces.prefix(12).joined(separator: "-").prefix(120).description
    }
}
