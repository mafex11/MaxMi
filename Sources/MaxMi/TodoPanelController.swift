import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class TodoPanelController: NSObject, NSWindowDelegate {
    static let panelWidth: CGFloat = 520
    static let maximumScreenHeightFraction: CGFloat = 0.60
    static let cornerRadius: CGFloat = 14

    private let viewModel: TodoPanelViewModel
    private let panel: NSPanel
    private var hostingView: NSHostingView<TodoPanelView>?

    init(viewModel: TodoPanelViewModel) {
        self.viewModel = viewModel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 1),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let root = TodoPanelView(viewModel: viewModel) { [weak self] in
            self?.close()
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = Self.cornerRadius
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        self.hostingView = hostingView
    }

    func show() {
        Task { @MainActor in
            await viewModel.refresh()
            guard let screen = screenContainingMouse() else { return }
            resizeAndCenter(on: screen)
            panel.orderFront(nil)
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func shutdown() {
        panel.delegate = nil
        panel.orderOut(nil)
        hostingView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              panel.isVisible else {
            return
        }
        if OutsideClickPolicy.shouldClose(
            clickLocation: NSEvent.mouseLocation,
            panelFrame: panel.frame
        ) {
            close()
        }
    }

    private func resizeAndCenter(on screen: NSScreen) {
        guard let hostingView else { return }
        let maximumHeight = screen.visibleFrame.height * Self.maximumScreenHeightFraction
        let size = NSSize(
            width: Self.panelWidth,
            height: min(maximumHeight, hostingView.fittingSize.height)
        )
        panel.setFrame(
            TodoPanelPlacement.centeredFrame(
                panelSize: size,
                screenVisibleFrame: screen.visibleFrame
            ),
            display: false
        )
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
