import ApplicationServices

public enum ChromiumKick {
    nonisolated(unsafe) static var kicked = Set<pid_t>()

    /// Chromium builds its renderer AX tree lazily (spec §5). AXManualAccessibility
    /// is Chromium-specific and avoids AXEnhancedUserInterface's window-manager side effects.
    public static func apply(pid: pid_t) {
        guard !kicked.contains(pid) else { return }
        kicked.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
