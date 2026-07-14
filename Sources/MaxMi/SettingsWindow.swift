import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel
    private let capturePrivacyViewModel: CapturePrivacyViewModel
    private let dataControlsViewModel: DataControlsViewModel
    private let setupViewModel: SetupViewModel

    init(viewModel: SettingsViewModel, capturePrivacyViewModel: CapturePrivacyViewModel,
         dataControlsViewModel: DataControlsViewModel, setupViewModel: SetupViewModel) {
        self.viewModel = viewModel
        self.capturePrivacyViewModel = capturePrivacyViewModel
        self.dataControlsViewModel = dataControlsViewModel
        self.setupViewModel = setupViewModel
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MaxMi Settings"
            window.center()
            window.contentViewController = NSHostingController(rootView: SettingsView(
                viewModel: viewModel,
                capturePrivacyViewModel: capturePrivacyViewModel,
                dataControlsViewModel: dataControlsViewModel,
                setupViewModel: setupViewModel
            ))
            window.setFrameAutosaveName("SettingsWindow")
            self.window = window
        }

        // Refresh the view model on show so launch-at-login status reflects external changes
        Task {
            await viewModel.refresh()
            await capturePrivacyViewModel.refresh()
            await setupViewModel.refresh()
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
