import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MaxMi Settings"
            window.center()
            window.contentViewController = NSHostingController(rootView: SettingsView(
                viewModel: viewModel
            ))
            window.setFrameAutosaveName("SettingsWindow")
            self.window = window
        }

        // Refresh the view model on show so launch-at-login status reflects external changes
        Task {
            await viewModel.refresh()
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
