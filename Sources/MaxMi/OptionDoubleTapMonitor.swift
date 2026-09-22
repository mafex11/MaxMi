import AppKit
import MaxMiActivity
import MaxMiCore

@MainActor
final class OptionDoubleTapMonitor {
    private let onDoubleTap: @Sendable @MainActor () -> Void
    private var detector = OptionDoubleTapDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var optionIsDown = false

    init(onDoubleTap: @escaping @Sendable @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeFlagsChanged(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.consumeFlagsChanged(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        detector = OptionDoubleTapDetector()
        optionIsDown = false
    }

    private func consumeFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let nowMs = EpochMs(event.timestamp * 1_000)
        guard let mapped = OptionEventMapper.map(
            flags: flags,
            isOptionDown: optionIsDown,
            timestampMs: nowMs
        ) else {
            return
        }
        optionIsDown = flags.contains(.option)
        if detector.consume(mapped) {
            onDoubleTap()
        }
    }
}
