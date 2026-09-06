import Foundation
import MaxMiCore

/// Region classification: which of a window's subtrees becomes which `RegionKind`.
/// Split out of `GenericPageExtractor` verbatim — no behaviour change.
extension GenericPageExtractor {
    static let sidebarNameHints = ["sidebar", "source list"]
    static let sidebarListRoles: Set<String> = ["AXOutline", "AXList", "AXTable"]
    static let sidebarMaxWidthShare = 0.35
    static let sidebarLeftEdgeShare = 0.05

    /// The first matching rule claims this node's entire subtree as one region. nil means
    /// "not claimed" — the node inherits the enclosing region, defaulting to `.main` (rule 6).
    /// A nested claim inside a claimed subtree wins for its own subtree.
    ///
    /// Frames are compared in WINDOW-RELATIVE coordinates: `AXFrame` is global screen
    /// coordinates, so a window that is not flush against the left edge of the primary display
    /// would otherwise misclassify its sidebar.
    static func classifyRegion(_ node: AXNode, window: AXNode, parentIsSplitGroup: Bool) -> RegionKind? {
        if dialogRoles.contains(node.role) { return .dialog }
        if let subrole = node.subrole, dialogSubroles.contains(subrole) { return .dialog }
        if node.role == "AXToolbar" { return .toolbar }
        if let subrole = node.subrole, let kind = landmarkRegions[subrole] { return kind }
        // Each name is tested on its own: concatenating them would invent a hint that neither
        // carries, e.g. identifier "dataSource" + label "List of items" spanning "source list".
        let names = [node.identifier, node.label].compactMap { $0?.lowercased() }
        if names.contains(where: { name in sidebarNameHints.contains(where: name.contains) }) {
            return .sidebar
        }
        if parentIsSplitGroup, isSplitGroupSidebar(node, window: window) { return .sidebar }
        return nil
    }

    static func isSplitGroupSidebar(_ node: AXNode, window: AXNode) -> Bool {
        guard let windowFrame = window.frame, windowFrame.width > 0,
              let frame = node.frame else { return false }
        guard frame.width < sidebarMaxWidthShare * windowFrame.width else { return false }
        let relativeX = frame.minX - windowFrame.minX
        guard relativeX <= sidebarLeftEdgeShare * windowFrame.width else { return false }
        return containsListLike(node)
    }

    /// The node itself or any descendant being an outline/list/table. Finder's source list is
    /// sometimes the pane and sometimes wrapped in a group, so both count.
    static func containsListLike(_ node: AXNode) -> Bool {
        if sidebarListRoles.contains(node.role) { return true }
        return node.children.contains(where: containsListLike)
    }
}
