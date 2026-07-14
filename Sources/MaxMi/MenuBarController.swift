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
    private var clickHandler: ClickHandler?

    // Left-click activity popover, anchored to the status-item button.
    private let popover = NSPopover()
    private var onPopoverWillShow: (() -> Void)?

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
        onPauseCurrentThread: @escaping () -> Void,
        onOpenActivity: @escaping () -> Void,
        onOpenCaptureHealth: @escaping () -> Void,
        onStartVoiceNote: @escaping () -> Void,
        onOpenPrivacy: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set dog icon from bundle
        if let imageURL = Bundle.main.url(forResource: "tray-dog", withExtension: "png"),
           let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = true
            item.button?.image = image
        }

        let menu = NSMenu()

        // Activity menu items
        let openActivityItem = NSMenuItem(title: "Open MaxMi", action: nil, keyEquivalent: "")
        openActivityItem.setAction { onOpenActivity() }
        menu.addItem(openActivityItem)

        let captureHealthItem = NSMenuItem(title: "Capture Health…", action: nil, keyEquivalent: "")
        captureHealthItem.setAction { onOpenCaptureHealth() }
        menu.addItem(captureHealthItem)

        let voiceNoteItem = NSMenuItem(title: "Start Voice Note", action: nil, keyEquivalent: "v")
        voiceNoteItem.setAction { onStartVoiceNote() }
        menu.addItem(voiceNoteItem)

        let privacyItem = NSMenuItem(title: "Activity Privacy…", action: nil, keyEquivalent: "")
        privacyItem.setAction { onOpenPrivacy() }
        menu.addItem(privacyItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        settingsItem.setAction { onOpenSettings() }
        menu.addItem(settingsItem)

        menu.addItem(.separator())

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

        // Pause current thread
        let pauseThreadItem = NSMenuItem(title: "Pause capture for current thread", action: nil, keyEquivalent: "")
        pauseThreadItem.setAction(onPauseCurrentThread)

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
            },
            updatePauseThreadItem: { [weak pauseThreadItem] in
                pauseThreadItem?.isEnabled = lastSourceKey() != nil
            }
        )
        self.menuDelegate = delegate
        menu.delegate = delegate
        menu.addItem(appPauseItem)
        menu.addItem(pauseThreadItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MaxMi", action: nil, keyEquivalent: "q")
        quit.setAction { onQuit() }
        menu.addItem(quit)

        // Install click handler: statusItem.menu stays nil; we popUpMenu directly on right-click
        statusItem = item
        if let button = item.button {
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let handler = ClickHandler(
                onLeftClick: { [weak self] in self?.togglePopover() },
                onRightClick: { @MainActor [weak item] in
                    guard let item else { return }
                    item.popUpMenu(menu)
                }
            )
            self.clickHandler = handler
            button.target = handler
            button.action = #selector(ClickHandler.handleClick)
        }
    }

    /// Provide the SwiftUI content shown in the left-click popover. `onWillShow` runs
    /// each time the popover is about to appear (e.g. to refresh the view models).
    func setPopoverContent(_ viewController: NSViewController, onWillShow: @escaping () -> Void) {
        popover.contentViewController = viewController
        popover.behavior = .transient   // auto-close when the user clicks away
        popover.animates = true
        onPopoverWillShow = onWillShow
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard popover.contentViewController != nil else { return }
        onPopoverWillShow?()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
    let updatePauseThreadItem: () -> Void
    init(updateAppPauseMenu: @escaping () -> Void, updatePauseThreadItem: @escaping () -> Void) {
        self.updateAppPauseMenu = updateAppPauseMenu
        self.updatePauseThreadItem = updatePauseThreadItem
    }
    func menuWillOpen(_ menu: NSMenu) {
        updateAppPauseMenu()
        updatePauseThreadItem()
    }
}

@MainActor
private final class ClickHandler: NSObject {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    init(onLeftClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
    }

    @objc func handleClick() {
        // Accessibility/API-driven presses may not carry a mouse event. Treat those as
        // the primary action so the menu item remains keyboard/automation accessible.
        guard let event = NSApp.currentEvent else {
            onLeftClick()
            return
        }
        switch event.type {
        case .leftMouseUp:
            onLeftClick()
        case .rightMouseUp:
            onRightClick()
        default:
            onLeftClick()
        }
    }
}
