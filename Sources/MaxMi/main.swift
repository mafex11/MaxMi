import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only; pairs with LSUIElement in Info.plist

let wiring = try AppWiring()
wiring.start()

// If permission was missing at launch, poll until granted, then start capture.
@MainActor
final class PermissionPoller {
    weak var wiring: AppWiring?
    var timer: Timer?

    func start() {
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            guard let self, let wiring = self.wiring else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                wiring.start()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

if wiring.observer == nil {
    let poller = PermissionPoller()
    poller.wiring = wiring
    poller.start()
}

app.run()
