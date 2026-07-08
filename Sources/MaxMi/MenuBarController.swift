import AppKit

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let countItem = NSMenuItem(title: "Captures: 0", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "⚠ Grant Accessibility…", action: nil, keyEquivalent: "")
    private let keyItem = NSMenuItem(title: "⚠ No GEMINI_API_KEY in .env", action: nil, keyEquivalent: "")
    private let encryptionItem = NSMenuItem(title: "⚠ Memory encryption unavailable", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "p")
    private var menuDelegate: MenuDelegate?

    var captureCount: Int = 0 { didSet { countItem.title = "Captures: \(captureCount)" } }
    var paused: Bool = false { didSet { pauseItem.title = paused ? "Resume Capture" : "Pause Capture" } }
    var hasAPIKey: Bool = true { didSet { keyItem.isHidden = hasAPIKey } }
    var accessibilityGranted: Bool = true { didSet { permissionItem.isHidden = accessibilityGranted } }
    var encryptionAvailable: Bool = true { didSet { encryptionItem.isHidden = encryptionAvailable } }

    func install(
        onTogglePause: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        recentApps: @escaping () -> [(bundleID: String, name: String)],
        pausedApps: @escaping () -> Set<String>,
        onToggleAppPause: @escaping (String) -> Void,
        lastSourceKey: @escaping () -> String?,
        onPauseCurrentThread: @escaping () -> Void
    ) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧠"
        let menu = NSMenu()
        permissionItem.isHidden = accessibilityGranted
        keyItem.isHidden = hasAPIKey
        encryptionItem.isHidden = encryptionAvailable
        permissionItem.action = #selector(NSApplication.openAccessibilitySettings)
        permissionItem.target = NSApp
        menu.addItem(countItem)
        menu.addItem(.separator())
        menu.addItem(permissionItem)
        menu.addItem(keyItem)
        menu.addItem(encryptionItem)
        menu.addItem(pauseItem)
        pauseItem.setAction { onTogglePause() }

        // Per-app pause submenu
        let appPauseItem = NSMenuItem(title: "Pause capture for ▸", action: nil, keyEquivalent: "")
        let appPauseMenu = NSMenu()
        appPauseItem.submenu = appPauseMenu
        // Populate dynamically on menu open
        let delegate = MenuDelegate(
            updateAppPauseMenu: { [weak appPauseMenu] in
                guard let appPauseMenu else { return }
                appPauseMenu.removeAllItems()
                let recent = recentApps()
                let paused = pausedApps()
                for app in recent {
                    let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
                    item.state = paused.contains(app.bundleID) ? .on : .off
                    item.setAction { onToggleAppPause(app.bundleID) }
                    appPauseMenu.addItem(item)
                }
                if recent.isEmpty {
                    let placeholder = NSMenuItem(title: "No recent apps", action: nil, keyEquivalent: "")
                    placeholder.isEnabled = false
                    appPauseMenu.addItem(placeholder)
                }
            }
        )
        self.menuDelegate = delegate
        menu.delegate = delegate
        menu.addItem(appPauseItem)

        // Pause current thread
        let pauseThreadItem = NSMenuItem(title: "Pause capture for current thread", action: nil, keyEquivalent: "")
        pauseThreadItem.setAction {
            if lastSourceKey() != nil { onPauseCurrentThread() }
        }
        menu.addItem(pauseThreadItem)

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

private final class MenuDelegate: NSObject, NSMenuDelegate {
    let updateAppPauseMenu: () -> Void
    init(updateAppPauseMenu: @escaping () -> Void) {
        self.updateAppPauseMenu = updateAppPauseMenu
    }
    func menuWillOpen(_ menu: NSMenu) {
        updateAppPauseMenu()
    }
}
