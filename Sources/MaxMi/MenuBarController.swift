import AppKit

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let countItem = NSMenuItem(title: "Captures: 0", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "⚠ Grant Accessibility…", action: nil, keyEquivalent: "")
    private let keyItem = NSMenuItem(title: "⚠ No GEMINI_API_KEY in .env", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "p")

    var captureCount: Int = 0 { didSet { countItem.title = "Captures: \(captureCount)" } }
    var paused: Bool = false { didSet { pauseItem.title = paused ? "Resume Capture" : "Pause Capture" } }
    var hasAPIKey: Bool = true { didSet { keyItem.isHidden = hasAPIKey } }
    var accessibilityGranted: Bool = true { didSet { permissionItem.isHidden = accessibilityGranted } }

    func install(onTogglePause: @escaping () -> Void, onQuit: @escaping () -> Void) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧠"
        let menu = NSMenu()
        permissionItem.isHidden = accessibilityGranted
        keyItem.isHidden = hasAPIKey
        permissionItem.action = #selector(NSApplication.openAccessibilitySettings)
        permissionItem.target = NSApp
        menu.addItem(countItem)
        menu.addItem(.separator())
        menu.addItem(permissionItem)
        menu.addItem(keyItem)
        menu.addItem(pauseItem)
        pauseItem.setAction { onTogglePause() }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MaxMi", action: nil, keyEquivalent: "q")
        quit.setAction { onQuit() }
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }
}

// Closure-backed NSMenuItem actions (no @objc target boilerplate per item).
private final class ActionTrampoline: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
private let trampolineKey: StaticString = "trampolineKey"
extension NSMenuItem {
    func setAction(_ block: @escaping () -> Void) {
        let t = ActionTrampoline(block)
        objc_setAssociatedObject(self, trampolineKey.utf8Start, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ActionTrampoline.fire)
    }
}
extension NSApplication {
    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
