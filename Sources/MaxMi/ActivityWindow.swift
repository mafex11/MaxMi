import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class ActivityWindow {
    private var window: NSWindow?
    private let viewModel: ActivityViewModel
    private let actionItemsViewModel: ActionItemsViewModel
    private let recentCapturesViewModel: RecentCapturesViewModel
    private let meetingHistoryViewModel: MeetingHistoryViewModel

    init(
        viewModel: ActivityViewModel,
        actionItemsViewModel: ActionItemsViewModel,
        recentCapturesViewModel: RecentCapturesViewModel,
        meetingHistoryViewModel: MeetingHistoryViewModel
    ) {
        self.viewModel = viewModel
        self.actionItemsViewModel = actionItemsViewModel
        self.recentCapturesViewModel = recentCapturesViewModel
        self.meetingHistoryViewModel = meetingHistoryViewModel
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
            window.contentViewController = NSHostingController(rootView: ActivityView(
                viewModel: viewModel,
                actionItemsViewModel: actionItemsViewModel,
                recentCapturesViewModel: recentCapturesViewModel,
                meetingHistoryViewModel: meetingHistoryViewModel
            ))
            window.setFrameAutosaveName("ActivityWindow")
            self.window = window
        }

        // Refresh the view models on show
        Task {
            await viewModel.refresh()
            await actionItemsViewModel.refresh()
            await recentCapturesViewModel.refresh()
            await meetingHistoryViewModel.refresh()
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
