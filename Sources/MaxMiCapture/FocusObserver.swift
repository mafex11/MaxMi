import AppKit
import ApplicationServices

public enum Browser: String, CaseIterable, Sendable {
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case zen = "app.zen-browser.zen"
    case safari = "com.apple.Safari"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"
    public var isChromium: Bool {
        switch self { case .safari, .zen: return false; default: return true }
    }
}

/// Observes browser focus changes and triggers captures.
/// Callers MUST call stop() before releasing; deinit cannot tear down MainActor state under Swift 6.
@MainActor
public final class FocusObserver {
    let debounceMs: Int
    let recaptureIntervalSec: Double
    let onCapture: @MainActor (Browser, pid_t) -> Void

    var debounceTask: Task<Void, Never>?
    var recaptureTimer: Timer?
    var axObserver: AXObserver?
    var observedPid: pid_t?
    var workspaceObserver: NSObjectProtocol?
    var current: (browser: Browser, pid: pid_t)?

    public init(debounceMs: Int = 1_000, recaptureIntervalSec: Double = 45,
                onCapture: @escaping @MainActor (Browser, pid_t) -> Void) {
        self.debounceMs = debounceMs
        self.recaptureIntervalSec = recaptureIntervalSec
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
        guard let bid = app.bundleIdentifier, let browser = Browser(rawValue: bid) else {
            detachAXObserver()
            recaptureTimer?.invalidate(); recaptureTimer = nil
            current = nil; return   // non-browser frontmost -> ignore (spec §5)
        }
        let newPid = app.processIdentifier
        if let cur = current, cur.pid == newPid, cur.browser == browser {
            // same browser, same pid -> skip detach/re-attach churn
            scheduleCapture()
            return
        }
        detachAXObserver()
        recaptureTimer?.invalidate(); recaptureTimer = nil
        current = (browser, newPid)
        if browser.isChromium { ChromiumKick.apply(pid: newPid) }
        attachAXObserver(pid: newPid)
        scheduleCapture()
        recaptureTimer = Timer.scheduledTimer(withTimeInterval: recaptureIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleCapture() }
        }
    }

    func scheduleCapture() {
        debounceTask?.cancel()
        let ms = debounceMs
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self, let cur = self.current else { return }
            self.onCapture(cur.browser, cur.pid)
        }
    }

    func attachAXObserver(pid: pid_t) {
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in me.scheduleCapture() }
        }
        guard AXObserverCreate(pid, cb, &observer) == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appEl, kAXTitleChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPid = pid
    }

    func detachAXObserver() {
        if let axObserver, let pid = observedPid {
            let appEl = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(axObserver, appEl, kAXFocusedUIElementChangedNotification as CFString)
            AXObserverRemoveNotification(axObserver, appEl, kAXTitleChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedPid = nil
    }
}
