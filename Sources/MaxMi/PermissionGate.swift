import ApplicationServices

@MainActor
enum PermissionGate {
    /// Spec §5: check AXIsProcessTrustedWithOptions with the system prompt on first run.
    static func ensureAccessibility(menuBar: MenuBarController) -> Bool {
        // The string key works fine; the constant involves shared mutable state that Swift 6 warns about.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        menuBar.accessibilityGranted = trusted
        return trusted
    }
}
