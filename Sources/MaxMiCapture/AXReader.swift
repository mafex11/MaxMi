import ApplicationServices
import AppKit

// Private AX API: returns the stable CGWindowID backing an AXUIElement window. Used to give each
// terminal window its own memory thread when there's no cwd to key on (full-screen TUIs).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public enum AXReader {
    /// Roles whose placeholder and selected-text are worth an extra AX round trip.
    static let textEntryRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]

    /// The CGWindowID of the app's currently focused window, or nil. Stable while the window lives.
    public static func focusedWindowID(pid: pid_t) -> UInt32? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                ?? copyAttr(app, "AXMainWindow") as! AXUIElement?
                ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(window, &wid) == .success && wid != 0 ? wid : nil
    }

    public static func snapshotFrontmostWindow(pid: pid_t, maxNodes: Int = 20_000, maxDepth: Int = 40) -> (window: AXNode, title: String?)? {
        let app = AXUIElementCreateApplication(pid)
        // Chromium/Electron apps (Warp, Slack, Notion) keep their AX tree dormant until an
        // assistive client asks for it. Setting AXManualAccessibility wakes it; harmless for
        // native apps. Without this, terminals expose an empty tree and capture silently no-ops.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // Waking a dormant tree isn't instantaneous — right after focusing a Warp/Electron window
        // the tree can still be empty for a few hundred ms, which showed up as `parserNoContent`
        // and left capture stuck on the previously-focused window. Re-read up to a few times with a
        // short backoff until the window exposes a non-trivial subtree.
        for attempt in 0..<4 {
            guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                    ?? copyAttr(app, "AXMainWindow") as! AXUIElement?
                    ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
                return nil
            }
            var budget = maxNodes
            let node = convert(window, depth: 0, maxDepth: maxDepth, budget: &budget)
            let title = copyAttr(window, kAXTitleAttribute) as? String
            if attempt == 3 || !isDormant(node) {
                return (node, title)
            }
            // Tree looks dormant/empty — give AXManualAccessibility a beat to populate, then retry.
            Thread.sleep(forTimeInterval: 0.12)
        }
        return nil
    }

    /// Shallow read of the app's focused UI element, for the case where the window snapshot
    /// contains no node with `focused == true` (virtualised trees, web areas). `maxDepth: 1`
    /// keeps this to the element plus its immediate children.
    public static func focusedElementSnapshot(pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        guard let element = copyAttr(app, kAXFocusedUIElementAttribute) as! AXUIElement? else { return nil }
        var budget = 64
        return convert(element, depth: 0, maxDepth: 1, budget: &budget)
    }

    /// A window subtree is "dormant" if it has essentially no descendants or carries no text/URL —
    /// the empty shell a Chromium/Electron app returns before its AX tree wakes.
    private static func isDormant(_ node: AXNode) -> Bool {
        var nodeCount = 0
        var hasSignal = false
        func walk(_ n: AXNode) {
            nodeCount += 1
            if (n.value?.isEmpty == false) || (n.url?.isEmpty == false) { hasSignal = true }
            for c in n.children where !hasSignal || nodeCount < 12 { walk(c) }
        }
        walk(node)
        return nodeCount < 6 || !hasSignal
    }

    private static func convert(_ el: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        let role = copyAttr(el, kAXRoleAttribute) as? String ?? "?"
        let rawValue = copyAttr(el, kAXValueAttribute)
        let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue
        let title = copyAttr(el, kAXTitleAttribute) as? String
        // AXURL (WebKit/Gecko) then AXDocument (Chromium) — spec §5 primary URL source.
        let url = (copyAttr(el, "AXURL") as? URL)?.absoluteString
            ?? (copyAttr(el, "AXURL") as? String)
            ?? (copyAttr(el, "AXDocument") as? String)
        let focused = (copyAttr(el, kAXFocusedAttribute) as? Bool) ?? false
        let identifier = copyAttr(el, kAXIdentifierAttribute) as? String
        let label = (copyAttr(el, kAXDescriptionAttribute) as? String)
            ?? (copyAttr(el, kAXHelpAttribute) as? String)
        // Three unconditional extra reads: region detection needs subrole, table rows need
        // selected, and hidden containers must never be walked for text.
        let subrole = copyAttr(el, kAXSubroleAttribute) as? String
        let selected = (copyAttr(el, kAXSelectedAttribute) as? Bool) ?? false
        let hidden = (copyAttr(el, "AXHidden") as? Bool) ?? false
        // Conditional reads: keep the per-node cost off the roles that cannot carry them.
        let headingLevel = role == "AXHeading"
            ? (copyAttr(el, "AXHeadingLevel") as? NSNumber)?.intValue
            : nil
        let isTextEntry = Self.textEntryRoles.contains(role)
        let placeholder = isTextEntry ? copyAttr(el, kAXPlaceholderValueAttribute) as? String : nil
        let selectedText = isTextEntry ? copyAttr(el, kAXSelectedTextAttribute) as? String : nil
        var frame: CGRect? = nil
        if let v = copyAttr(el, "AXFrame") {
            var r = CGRect.zero
            if AXValueGetValue(v as! AXValue, .cgRect, &r) { frame = r }
        }
        var children: [AXNode] = []
        if depth < maxDepth, budget > 0,
           let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for kid in kids {
                if budget <= 0 { break }
                children.append(convert(kid, depth: depth + 1, maxDepth: maxDepth, budget: &budget))
            }
        }
        return AXNode(role: role, value: value, title: title, url: url,
                      frame: frame, focused: focused, children: children,
                      identifier: identifier, label: label,
                      subrole: subrole, headingLevel: headingLevel, selected: selected,
                      placeholder: placeholder, selectedText: selectedText, hidden: hidden)
    }

    private static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
}
