import AppKit
import ApplicationServices
import MaxMiCore

/// Compatibility wrapper around MaxMiCore's canonical application registry.
/// AppWiring and meeting detection now share the same browser inventory.
public struct Browser: RawRepresentable, Sendable, Equatable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard ApplicationRegistry.isBrowser(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var isChromium: Bool {
        ApplicationRegistry.browser(for: rawValue)?.browserEngine == .chromium
    }
}

/// Pure mapping kept separate from AXObserver so tab/SPA trigger behavior is testable.
public enum CaptureNotificationClassifier {
    public static func trigger(notification: String, isBrowser: Bool) -> CaptureTrigger {
        guard isBrowser else { return .accessibilityChanged }
        switch notification {
        case kAXTitleChangedNotification,
             kAXSelectedChildrenChangedNotification,
             kAXSelectedRowsChangedNotification,
             "AXLoadComplete":
            return .browserNavigation
        case kAXValueChangedNotification, "AXLiveRegionChanged":
            return .webContentChanged
        default:
            return .accessibilityChanged
        }
    }
}

/// Observes app focus changes and triggers captures for capturable apps.
/// Callers MUST call stop() before releasing; deinit cannot tear down MainActor state under Swift 6.
@MainActor
public final class FocusObserver {
    static let observedAXNotifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXTitleChangedNotification,
        kAXValueChangedNotification,
        kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification,
        "AXLoadComplete",
        "AXLiveRegionChanged",
    ]
    let debounceMs: Int
    let recaptureIntervalSec: Double
    let recaptureIntervalForApp: @Sendable (String) -> Double
    let isCapturable: @Sendable (String) -> Bool
    let onCapture: @MainActor (AppInfo, pid_t, CaptureTrigger) -> Void
    public var onFocusChanged: (@MainActor (AppInfo, _ isCapturable: Bool, pid_t) -> Void)?

    var debounceTask: Task<Void, Never>?
    var recaptureTimer: Timer?
    var axObserver: AXObserver?
    var observedPid: pid_t?
    var workspaceObserver: NSObjectProtocol?
    var current: (bundleID: String, pid: pid_t)?
    var appName: String = ""

    public init(debounceMs: Int = 1_000, recaptureIntervalSec: Double = 45,
                recaptureIntervalForApp: (@Sendable (String) -> Double)? = nil,
                isCapturable: @escaping @Sendable (String) -> Bool,
                onCapture: @escaping @MainActor (AppInfo, pid_t, CaptureTrigger) -> Void) {
        self.debounceMs = debounceMs
        self.recaptureIntervalSec = recaptureIntervalSec
        self.recaptureIntervalForApp = recaptureIntervalForApp ?? { _ in recaptureIntervalSec }
        self.isCapturable = isCapturable
        self.onCapture = onCapture
    }

    public func start() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.frontmostChanged(app) }
        }
        if let app = NSWorkspace.shared.frontmostApplication { frontmostChanged(app) }
    }

    public func stop() {
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserver = nil
        recaptureTimer?.invalidate(); recaptureTimer = nil
        debounceTask?.cancel()
        detachAXObserver()
        current = nil
    }

    func frontmostChanged(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else { return }
        let newPid = app.processIdentifier
        let capturable = isCapturable(bid)
        let newAppName = app.localizedName ?? bid

        // Fire onFocusChanged on EVERY frontmost change (before the capturable gate)
        onFocusChanged?(AppInfo(bundleID: bid, name: newAppName, windowTitle: nil), capturable, newPid)

        guard capturable else {
            detachAXObserver()
            recaptureTimer?.invalidate(); recaptureTimer = nil
            current = nil; return
        }
        if let cur = current, cur.bundleID == bid, cur.pid == newPid {
            scheduleCapture(trigger: .appActivated); return   // same app/pid -> no observer churn
        }
        detachAXObserver()
        current = (bundleID: bid, pid: newPid)
        appName = newAppName
        if ApplicationRegistry.needsAccessibilityWarmup(bid) {
            ChromiumKick.apply(pid: newPid)
        }
        attachAXObserver(pid: newPid)
        recaptureTimer?.invalidate()
        let interval = max(10, recaptureIntervalForApp(bid))
        recaptureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleCapture(trigger: .periodic) }
        }
        scheduleCapture(trigger: .appActivated)
    }

    func scheduleCapture(trigger: CaptureTrigger) {
        debounceTask?.cancel()
        let ms = debounceMs
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self, let cur = self.current else { return }
            let title: String? = nil
            self.onCapture(AppInfo(bundleID: cur.bundleID, name: self.appName, windowTitle: title), cur.pid, trigger)
        }
    }

    func attachAXObserver(pid: pid_t) {
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            Task { @MainActor in me.handleAXNotification(name) }
        }
        guard AXObserverCreate(pid, cb, &observer) == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.observedAXNotifications {
            // Browsers vary in which application-level notifications they support.
            // Unsupported registrations are harmless; the 30-second sweep remains a backstop.
            AXObserverAddNotification(observer, appEl, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPid = pid
    }

    func handleAXNotification(_ notification: String) {
        guard let current else { return }
        let trigger = CaptureNotificationClassifier.trigger(
            notification: notification,
            isBrowser: ApplicationRegistry.isBrowser(current.bundleID)
        )
        scheduleCapture(trigger: trigger)
    }

    func detachAXObserver() {
        if let axObserver, let pid = observedPid {
            let appEl = AXUIElementCreateApplication(pid)
            for notification in Self.observedAXNotifications {
                AXObserverRemoveNotification(axObserver, appEl, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedPid = nil
    }
}
