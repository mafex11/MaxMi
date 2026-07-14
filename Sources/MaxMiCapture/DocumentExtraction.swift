import Foundation

/// Shared mechanical text walk for document-shape apps (Notion/Obsidian/Notes).
/// Per-app parsers own key derivation; only the body-text collection lives here.
enum DocumentExtraction {
    static let contentCap = 8000

    /// AXTextArea + AXStaticText values in visual order (y then x), newest-anchored
    /// hard cap. Returns "" if there is no text (caller returns nil → no empty thread).
    static func bodyText(in root: AXNode, maxCharacters: Int = contentCap) -> String {
        var texts: [(y: CGFloat, x: CGFloat, s: String)] = []
        collect(root, into: &texts)
        guard !texts.isEmpty else { return "" }
        let ordered = texts.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }.map(\.s)
        // newest-anchored: keep whole trailing lines within the cap, then hard-bound.
        var kept: [String] = []
        var total = 0
        for line in ordered.reversed() {
            let add = line.count + 1
            if total + add > maxCharacters && !kept.isEmpty { break }
            kept.insert(line, at: 0)
            total += add
        }
        return String(kept.joined(separator: "\n").suffix(maxCharacters))
    }

    private static func collect(_ node: AXNode, into out: inout [(y: CGFloat, x: CGFloat, s: String)]) {
        if node.role == "AXTextArea" || node.role == "AXStaticText",
           let v = node.value, !v.isEmpty {
            out.append((node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0, v))
        }
        for c in node.children { collect(c, into: &out) }
    }
}

/// slug: lowercased, trimmed, spaces→"-". Shared by the document parsers' keys.
func docSlug(_ s: String) -> String {
    s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
}
