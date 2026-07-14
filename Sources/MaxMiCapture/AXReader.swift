import ApplicationServices
import AppKit

public enum AXReader {
    public static func snapshotFrontmostWindow(pid: pid_t, maxNodes: Int = 20_000, maxDepth: Int = 40) -> (window: AXNode, title: String?)? {
        let app = AXUIElementCreateApplication(pid)
        // Chromium/Electron apps (Warp, Slack, Notion) keep their AX tree dormant until an
        // assistive client asks for it. Setting AXManualAccessibility wakes it; harmless for
        // native apps. Without this, terminals expose an empty tree and capture silently no-ops.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                ?? copyAttr(app, "AXMainWindow") as! AXUIElement?
                ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        var budget = maxNodes
        let node = convert(window, depth: 0, maxDepth: maxDepth, budget: &budget)
        let title = copyAttr(window, kAXTitleAttribute) as? String
        return (node, title)
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
                      identifier: identifier, label: label)
    }

    private static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
}
