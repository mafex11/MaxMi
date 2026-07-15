#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

// Content-free live parser diagnostic: reports only AX roles, attribute presence,
// node counts, and depth. It never prints or persists text-bearing attribute values.

struct RoleStats {
    var count = 0
    var withValue = 0
    var withTitle = 0
    var withDescription = 0
    var withIdentifier = 0
    var focused = 0
    var maximumDepth = 0
}

func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}

func hasStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
    guard let value = copyAttribute(element, attribute) as? String else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ax-structure-inventory.swift <bundle-id>\n".utf8))
    exit(2)
}

let bundleID = CommandLine.arguments[1]
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write(Data("application is not running\n".utf8))
    exit(3)
}

let application = AXUIElementCreateApplication(app.processIdentifier)
guard let window = copyAttribute(application, kAXFocusedWindowAttribute as CFString) else {
    FileHandle.standardError.write(Data("focused window is unavailable\n".utf8))
    exit(4)
}

var stats: [String: RoleStats] = [:]
var visited = 0
let maximumNodes = 5_000
let maximumDepth = 14

func walk(_ element: AXUIElement, depth: Int) {
    guard visited < maximumNodes, depth <= maximumDepth else { return }
    visited += 1
    let role = (copyAttribute(element, kAXRoleAttribute as CFString) as? String) ?? "unknown"
    var item = stats[role] ?? RoleStats()
    item.count += 1
    item.withValue += hasStringAttribute(element, kAXValueAttribute as CFString) ? 1 : 0
    item.withTitle += hasStringAttribute(element, kAXTitleAttribute as CFString) ? 1 : 0
    item.withDescription += hasStringAttribute(element, kAXDescriptionAttribute as CFString) ? 1 : 0
    item.withIdentifier += hasStringAttribute(element, kAXIdentifierAttribute as CFString) ? 1 : 0
    if (copyAttribute(element, kAXFocusedAttribute as CFString) as? Bool) == true { item.focused += 1 }
    item.maximumDepth = max(item.maximumDepth, depth)
    stats[role] = item

    guard let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else {
        return
    }
    for child in children { walk(child, depth: depth + 1) }
}

walk(window as! AXUIElement, depth: 0)
print("nodes=\(visited) capped=\(visited >= maximumNodes)")
print("role\tcount\twith_value\twith_title\twith_description\twith_identifier\tfocused\tmax_depth")
for role in stats.keys.sorted() {
    let item = stats[role]!
    print("\(role)\t\(item.count)\t\(item.withValue)\t\(item.withTitle)\t\(item.withDescription)\t\(item.withIdentifier)\t\(item.focused)\t\(item.maximumDepth)")
}
