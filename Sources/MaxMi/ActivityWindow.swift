import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class ActivityWindow {
    private var window: NSWindow?
    private let viewModel: ActivityViewModel

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MaxMi Activity"
            window.center()
            window.contentViewController = NSHostingController(rootView: ActivityView(viewModel: viewModel))
            window.setFrameAutosaveName("ActivityWindow")
            self.window = window
        }

        // Refresh the view model on show
        Task {
            await viewModel.refresh()
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
