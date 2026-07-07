import Foundation

public struct TabCapture: Equatable, Sendable {
    public let url: String
    public let title: String?
    public let content: String
}

public enum ExtractionError: Error, Equatable {
    case noWebArea, noURL, addressFieldFocused, emptyContent
}

public enum BrowserTabExtractor {
    static let addressRoles: Set<String> = ["AXTextField", "AXComboBox"]

    public static func extract(window: AXNode, windowTitle: String?) throws -> TabCapture {
        // 1. Primary: web area's own URL (AXURL / AXDocument) — presentation-independent.
        let webArea = firstNode(in: window) { $0.role == "AXWebArea" }
        if let urlString = webArea?.url, !urlString.isEmpty {
            let content = try visualOrderText(in: webArea!)
            return TabCapture(url: urlString, title: windowTitle ?? window.title, content: content)
        }
        // 2. Fallback: toolbar address field. Refuse mid-typing states outright.
        let address = firstNode(in: window) { addressRoles.contains($0.role) && ($0.value?.contains(".") ?? false) }
        if let address {
            if address.focused { throw ExtractionError.addressFieldFocused }
            guard var raw = address.value, !raw.isEmpty else { throw ExtractionError.noURL }
            if !raw.contains("://") { raw = "https://" + raw }   // browsers strip the scheme (verified on Zen)
            let content = try visualOrderText(in: webArea ?? window, excludingToolbars: true)
            return TabCapture(url: raw, title: windowTitle ?? window.title, content: content)
        }
        throw ExtractionError.noURL
    }

    static func visualOrderText(in root: AXNode, excludingToolbars: Bool = false) throws -> String {
        var texts: [(AXNode, CGFloat, CGFloat)] = []
        collectStaticText(root, into: &texts, skipToolbars: excludingToolbars)
        // top->bottom then left->right (spec §5): sort by y, then x
        let sorted = texts.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
        let joined = sorted.compactMap { $0.0.value }.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !joined.isEmpty else { throw ExtractionError.emptyContent }
        return joined
    }

    private static func collectStaticText(_ node: AXNode, into out: inout [(AXNode, CGFloat, CGFloat)], skipToolbars: Bool) {
        if skipToolbars && node.role == "AXToolbar" { return }
        if node.role == "AXStaticText", node.value != nil {
            out.append((node, node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0))
        }
        for child in node.children { collectStaticText(child, into: &out, skipToolbars: skipToolbars) }
    }

    private static func firstNode(in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        if match(root) { return root }
        for child in root.children { if let hit = firstNode(in: child, where: match) { return hit } }
        return nil
    }
}
