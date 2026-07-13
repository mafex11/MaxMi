import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class CaptureHealthWindow {
    private var window: NSWindow?
    private let viewModel: CaptureHealthViewModel

    init(viewModel: CaptureHealthViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MaxMi Capture Health"
            window.center()
            window.contentViewController = NSHostingController(rootView: CaptureHealthView(viewModel: viewModel))
            window.setFrameAutosaveName("CaptureHealthWindow")
            self.window = window
        }

        Task { await viewModel.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
