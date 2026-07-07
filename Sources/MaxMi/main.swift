import AppKit

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
}

let wiring = try AppWiring()
wiring.start()

let permissionPoller: PermissionPoller? = {
    guard wiring.observer == nil else { return nil }
    let poller = PermissionPoller()
    poller.wiring = wiring
    poller.start()
    return poller
}()

app.run()
