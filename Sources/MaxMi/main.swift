import AppKit
import MaxMiCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only; pairs with LSUIElement in Info.plist

// If permission was missing at launch, poll until granted, then start capture.
@MainActor
final class PermissionPoller {
    weak var wiring: AppWiring?
    var timer: Timer?

    nonisolated func start() {
        let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, let wiring = self.wiring else { return }
                if AXIsProcessTrusted() {
                    self.timer?.invalidate()
                    wiring.start()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        Task { @MainActor [weak self] in self?.timer = t }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    private weak var wiring: AppWiring?
    weak var permissionPoller: PermissionPoller?
    private var terminationStarted = false
    private var terminationReplied = false

    init(wiring: AppWiring) {
        self.wiring = wiring
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        permissionPoller?.stop()

        Task { @MainActor [weak self] in
            await self?.wiring?.shutdown()
            self?.replyToTermination()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

let wiring = try AppWiring()
let lifecycleDelegate = ApplicationLifecycleDelegate(wiring: wiring)
app.delegate = lifecycleDelegate
SafeLogger.shared.log(.info, subsystem: .app, event: .appStarted)
wiring.start()

let permissionPoller: PermissionPoller? = {
    guard wiring.observer == nil else { return nil }
    let poller = PermissionPoller()
    poller.wiring = wiring
    poller.start()
    return poller
}()
lifecycleDelegate.permissionPoller = permissionPoller

app.run()
