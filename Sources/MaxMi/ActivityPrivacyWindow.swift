import AppKit
import SwiftUI
import MaxMiCore
import MaxMiStore

@MainActor
final class ActivityPrivacyWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store

    init(store: Store) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Activity Privacy"
            window.center()
            let contentView = ActivityPrivacyView(store: store)
            window.contentViewController = NSHostingController(rootView: contentView)
            window.setFrameAutosaveName("ActivityPrivacyWindow")
            window.delegate = self
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // When the privacy window closes and consent is still unset, persist .declined
        Task { @MainActor in
            do {
                let consent = try store.activityConsent()
                if consent == .unset {
                    try store.setActivityConsent(.declined)
                }
            } catch {
                NSLog("MaxMi: failed to persist declined consent on window close: \(error)")
            }
        }
    }
}

// MARK: - SwiftUI Content

private struct ActivityPrivacyView: View {
    let store: Store
    @State private var enabled: Bool = false
    @State private var excludedApps: Set<String> = []
    @State private var recentApps: [(bundleID: String, label: String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Consent disclosure
                VStack(alignment: .leading, spacing: 12) {
                    Text("Activity Synthesis")
                        .font(.title2.bold())

                    Text("""
                        MaxMi can synthesize your Mac activity into a timeline using Gemini AI. Screen content will be:
                        • Encrypted locally before processing
                        • Sent to Google's Gemini API for processing
                        • Subject to Google's Gemini API data use policies

                        You can exclude specific apps and disable this feature at any time.
                        """)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                // Global enable toggle
                Toggle("Enable activity synthesis", isOn: $enabled)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .onChange(of: enabled) { oldValue, newValue in
                        handleEnableToggle(newValue)
                    }

                // Per-app exclusion list
                if enabled {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("App Exclusions")
                            .font(.headline)

                        if recentApps.isEmpty {
                            Text("No apps to exclude yet. Use your Mac to see apps here.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(recentApps, id: \.bundleID) { app in
                                Toggle(app.label, isOn: Binding(
                                    get: { !excludedApps.contains(app.bundleID) },
                                    set: { included in
                                        handleAppToggle(bundleID: app.bundleID, included: included)
                                    }
                                ))
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            loadState()
        }
    }

    private func loadState() {
        do {
            let consent = try store.activityConsent()
            let activityEnabled = try store.activityEnabled()
            enabled = consent == .granted && activityEnabled
            excludedApps = try store.activityExcludedApps()

            // Load recent apps from activity sessions
            let sessions = try store.recentSessions(limit: 50)
            var seen: Set<String> = []
            var apps: [(String, String)] = []
            for session in sessions {
                if !seen.contains(session.appBundle) {
                    apps.append((session.appBundle, session.appLabel))
                    seen.insert(session.appBundle)
                }
            }
            recentApps = apps
        } catch {
            NSLog("MaxMi: failed to load activity privacy state: \(error)")
        }
    }

    private func handleEnableToggle(_ newValue: Bool) {
        do {
            if newValue {
                // First enable: set consent to granted
                let consent = try store.activityConsent()
                if consent == .unset {
                    try store.setActivityConsent(.granted)
                }
                try store.setActivityEnabled(true)
            } else {
                // Disable: close active sessions/visits and persist the disable
                let nowMs = epochNowMs()
                try store.closeOpenVisits(nowMs: nowMs)
                try store.closeActiveSession(nowMs: nowMs)

                let consent = try store.activityConsent()
                if consent == .unset {
                    try store.setActivityConsent(.declined)
                }
                try store.setActivityEnabled(false)
            }
        } catch {
            NSLog("MaxMi: failed to update activity enabled state: \(error)")
        }
    }

    private func handleAppToggle(bundleID: String, included: Bool) {
        do {
            let excluded = !included
            try store.setActivityExcluded(bundleID, excluded)
            if excluded {
                try store.deleteActivityForApp(bundleID)
                // Refresh the recent apps list
                loadState()
            }

            // Update local state
            if excluded {
                excludedApps.insert(bundleID)
            } else {
                excludedApps.remove(bundleID)
            }
        } catch {
            NSLog("MaxMi: failed to update app exclusion: \(error)")
        }
    }
}
