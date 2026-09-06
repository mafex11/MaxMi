import Foundation

public extension AXQuery {
    /// Composable predicates for the cases a path literal cannot express — an OR across two
    /// attributes, or a check a parser wants to reuse at several depths.
    enum Matchers {
        public static func hasRole(_ r: String) -> (AXNode) -> Bool {
            { $0.role == r }
        }

        public static func hasIdentifierPrefix(_ p: String) -> (AXNode) -> Bool {
            { ($0.identifier ?? "").hasPrefix(p) && $0.identifier != nil }
        }

        /// Case-insensitive, matching the `domClass` predicate.
        public static func hasClass(_ c: String) -> (AXNode) -> Bool {
            let needle = c.lowercased()
            return { ($0.domClassList ?? []).contains { $0.lowercased() == needle } }
        }

        public static func hasTitleContaining(_ s: String) -> (AXNode) -> Bool {
            { ($0.title ?? "").contains(s) && $0.title != nil }
        }

        public static func and(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool {
            { node in ms.allSatisfy { $0(node) } }
        }

        public static func or(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool {
            { node in ms.contains { $0(node) } }
        }

        public static func not(_ m: @escaping (AXNode) -> Bool) -> (AXNode) -> Bool {
            { !m($0) }
        }
    }

    /// Pre-order descendants (including `root`) satisfying `match`.
    static func all(in root: AXNode, where match: (AXNode) -> Bool) -> [AXNode] {
        var out: [AXNode] = []
        func visit(_ node: AXNode) {
            if match(node) { out.append(node) }
            for child in node.children { visit(child) }
        }
        visit(root)
        return out
    }

    static func first(in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        all(in: root, where: match).first
    }

    /// Sorts by (minY, minX). `AXFrame` is global screen coordinates, so `origin` is subtracted
    /// first: the ORDER of the same layout must not depend on which display the window is on.
    static func sortedByVisualOrder(_ nodes: [AXNode], relativeTo origin: CGRect?) -> [AXNode] {
        let ox = origin?.minX ?? 0
        let oy = origin?.minY ?? 0
        return nodes.enumerated().sorted { lhs, rhs in
            let ly = (lhs.element.frame?.minY ?? oy) - oy
            let ry = (rhs.element.frame?.minY ?? oy) - oy
            if ly != ry { return ly < ry }
            let lx = (lhs.element.frame?.minX ?? ox) - ox
            let rx = (rhs.element.frame?.minX ?? ox) - ox
            if lx != rx { return lx < rx }
            // Stable: equal positions keep their input order.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Static-text values under `node` (including `node` itself) in visual order, trimmed,
    /// empties dropped, adjacent duplicates collapsed. Menu and hidden subtrees are excluded.
    static func collectStaticTexts(in node: AXNode) -> [String] {
        var found: [AXNode] = []
        func visit(_ current: AXNode) {
            if menuRoles.contains(current.role) || current.hidden { return }
            if current.subrole == GenericPageExtractor.secureSubrole { return }
            if current.role == "AXStaticText" { found.append(current) }
            for child in current.children { visit(child) }
        }
        visit(node)
        let ordered = sortedByVisualOrder(found, relativeTo: node.frame)
            .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ordered.reduce(into: [String]()) { result, value in
            if result.last != value { result.append(value) }
        }
    }

    /// Menu content is structurally excluded from every helper, not filtered by text. Aliased to
    /// the extractor's set rather than restated, so the capture layer has one menu-skip policy.
    static var menuRoles: Set<String> { GenericPageExtractor.menuRoles }
}
