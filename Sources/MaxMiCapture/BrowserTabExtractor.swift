import Foundation
import MaxMiCore

public enum BrowserURLSource: String, Sendable, Equatable {
    case webArea
    case addressBar
}

public enum BrowserCaptureQuality: String, Sendable, Equatable {
    case high
    case standard
    case fallback
}

public struct TabCapture: Equatable, Sendable {
    public let url: String
    public let title: String?
    public let content: String
    public let urlSource: BrowserURLSource
    public let quality: BrowserCaptureQuality
    public let truncated: Bool

    public init(
        url: String,
        title: String?,
        content: String,
        urlSource: BrowserURLSource = .webArea,
        quality: BrowserCaptureQuality = .standard,
        truncated: Bool = false
    ) {
        self.url = url
        self.title = title
        self.content = content
        self.urlSource = urlSource
        self.quality = quality
        self.truncated = truncated
    }
}

public enum ExtractionError: Error, Equatable {
    case noWebArea, noURL, invalidURL, addressFieldFocused, emptyContent
}

/// Engine-aware Accessibility extraction for the active browser tab.
///
/// Web-area AXURL/AXDocument is authoritative. Address fields are a guarded fallback:
/// only toolbar/location-labelled controls qualify, and a focused field is never read.
public enum BrowserTabExtractor {
    static let addressRoles: Set<String> = ["AXTextField", "AXComboBox"]
    static let contentRoles: Set<String> = ["AXStaticText", "AXHeading"]
    static let contentCap = 16_000
    static let addressHints = ["address", "location", "search or enter", "url", "omnibox"]

    public static func extract(
        window: AXNode,
        windowTitle: String?,
        engine: BrowserEngine? = nil
    ) throws -> TabCapture {
        let webAreas = nodes(in: window) { $0.role == "AXWebArea" }
        let activeWebArea = bestWebArea(from: webAreas, windowTitle: windowTitle, engine: engine)

        if let candidate = bestWebURL(from: webAreas, windowTitle: windowTitle, engine: engine) {
            let text = try visualOrderText(in: candidate.node)
            return TabCapture(
                url: candidate.url,
                title: windowTitle ?? candidate.node.title ?? window.title,
                content: text.content,
                urlSource: .webArea,
                quality: candidate.score >= 80 ? .high : .standard,
                truncated: text.truncated
            )
        }

        guard let address = bestAddressField(in: window) else {
            throw ExtractionError.noURL
        }
        if address.focused { throw ExtractionError.addressFieldFocused }
        guard let raw = address.value, let url = normalizedURL(raw) else {
            throw ExtractionError.invalidURL
        }

        let text = try visualOrderText(
            in: activeWebArea ?? window,
            excludingToolbars: activeWebArea == nil
        )
        return TabCapture(
            url: url,
            title: windowTitle ?? activeWebArea?.title ?? window.title,
            content: text.content,
            urlSource: .addressBar,
            quality: .fallback,
            truncated: text.truncated
        )
    }

    static func visualOrderText(
        in root: AXNode,
        excludingToolbars: Bool = false
    ) throws -> (content: String, truncated: Bool) {
        var texts: [(node: AXNode, y: CGFloat, x: CGFloat)] = []
        collectText(root, into: &texts, skipToolbars: excludingToolbars)
        let sorted = texts.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }

        var lines: [String] = []
        var previous: String?
        for item in sorted {
            guard let raw = item.node.value ?? item.node.title else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != previous else { continue }
            lines.append(value)
            previous = value
        }
        guard !lines.isEmpty else { throw ExtractionError.emptyContent }

        let joined = lines.joined(separator: "\n")
        guard joined.count > contentCap else { return (joined, false) }
        return (String(joined.suffix(contentCap)), true)
    }

    static func normalizedURL(_ rawValue: String) -> String? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }

        if !raw.contains("://") {
            guard looksLikeHost(raw) else { return nil }
            raw = "https://" + raw
        }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
        }
        return components.string
    }

    private struct WebURLCandidate {
        let node: AXNode
        let url: String
        let score: Int
    }

    private static func bestWebURL(
        from webAreas: [AXNode],
        windowTitle: String?,
        engine: BrowserEngine?
    ) -> WebURLCandidate? {
        webAreas.compactMap { node -> WebURLCandidate? in
            guard let raw = node.url, let url = normalizedURL(raw) else { return nil }
            var score = 60
            if node.focused { score += 20 }
            if hasUsableFrame(node) { score += 10 }
            if containsReadableText(node) { score += 10 }
            if title(node.title, resembles: windowTitle) { score += 5 }
            if engine == .webkit, raw.hasPrefix("http") { score += 2 }
            return WebURLCandidate(node: node, url: url, score: score)
        }.max { lhs, rhs in lhs.score < rhs.score }
    }

    private static func bestWebArea(
        from webAreas: [AXNode],
        windowTitle: String?,
        engine: BrowserEngine?
    ) -> AXNode? {
        webAreas.max { lhs, rhs in
            webAreaScore(lhs, title: windowTitle, engine: engine)
                < webAreaScore(rhs, title: windowTitle, engine: engine)
        }
    }

    private static func webAreaScore(_ node: AXNode, title: String?, engine: BrowserEngine?) -> Int {
        var score = 0
        if node.focused { score += 20 }
        if hasUsableFrame(node) { score += 10 }
        if containsReadableText(node) { score += 10 }
        if node.url != nil { score += 20 }
        if self.title(node.title, resembles: title) { score += 5 }
        if engine == .gecko, node.role == "AXWebArea" { score += 1 }
        return score
    }

    private static func bestAddressField(in root: AXNode) -> AXNode? {
        var candidates: [(node: AXNode, score: Int)] = []
        collectAddressFields(root, insideToolbar: false, insideWebArea: false, into: &candidates)
        return candidates.max { $0.score < $1.score }?.node
    }

    private static func collectAddressFields(
        _ node: AXNode,
        insideToolbar: Bool,
        insideWebArea: Bool,
        into out: inout [(node: AXNode, score: Int)]
    ) {
        let toolbar = insideToolbar || node.role == "AXToolbar"
        let webArea = insideWebArea || node.role == "AXWebArea"
        if !webArea, addressRoles.contains(node.role), let value = node.value,
           normalizedURL(value) != nil {
            let metadata = [node.title, node.label, node.identifier]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            let labelled = addressHints.contains { metadata.contains($0) }
            if toolbar || labelled {
                var score = toolbar ? 30 : 10
                if labelled { score += 20 }
                if node.focused { score += 5 }
                out.append((node, score))
            }
        }
        for child in node.children {
            collectAddressFields(
                child, insideToolbar: toolbar, insideWebArea: webArea, into: &out
            )
        }
    }

    private static func collectText(
        _ node: AXNode,
        into out: inout [(node: AXNode, y: CGFloat, x: CGFloat)],
        skipToolbars: Bool
    ) {
        if skipToolbars && node.role == "AXToolbar" { return }
        if contentRoles.contains(node.role), node.value != nil || node.title != nil {
            out.append((node, node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0))
        }
        for child in node.children {
            collectText(child, into: &out, skipToolbars: skipToolbars)
        }
    }

    private static func nodes(in root: AXNode, where match: (AXNode) -> Bool) -> [AXNode] {
        var result: [AXNode] = match(root) ? [root] : []
        for child in root.children { result.append(contentsOf: nodes(in: child, where: match)) }
        return result
    }

    private static func containsReadableText(_ node: AXNode) -> Bool {
        if contentRoles.contains(node.role), node.value?.isEmpty == false { return true }
        return node.children.contains(where: containsReadableText)
    }

    private static func hasUsableFrame(_ node: AXNode) -> Bool {
        guard let frame = node.frame else { return false }
        return frame.width > 1 && frame.height > 1
    }

    private static func title(_ lhs: String?, resembles rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        let a = lhs.lowercased(), b = rhs.lowercased()
        return a.contains(b) || b.contains(a)
    }

    private static func looksLikeHost(_ raw: String) -> Bool {
        let hostPart = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        return hostPart == "localhost" || hostPart.contains(".")
    }
}
