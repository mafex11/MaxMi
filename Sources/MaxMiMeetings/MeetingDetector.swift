import Foundation
#if os(macOS)
import CoreAudio
import os.log
#endif

/// Protocol for meeting detection
public protocol MeetingDetecting: AnyObject {
    var onCandidate: ((_ bundleID: String, _ pid: pid_t) -> Void)? { get set }
    var onEnded: ((_ bundleID: String) -> Void)? { get set }
    func start()
    func stop()
}

/// Real clock implementation
public struct SystemMeetingClock: MeetingClock {
    public init() {}
    public func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
    public func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

/// Meeting detector using public CoreAudio APIs
public final class MeetingDetector: MeetingDetecting {
    private let clock: MeetingClock
    private let debounceMs: Int

    // State tracking for multi-process detection
    private var activeBundleIDs: Set<String> = []
    private var lastSeenPIDs: [String: Set<pid_t>] = [:]  // bundleID -> set of active PIDs
    private var debounceTimers: [String: Task<Void, Never>] = [:]

    #if os(macOS)
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processInputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let logger = Logger(subsystem: "MaxMi", category: "MeetingDetector")
    #endif

    public var onCandidate: ((_ bundleID: String, _ pid: pid_t) -> Void)?
    public var onEnded: ((_ bundleID: String) -> Void)?

    public init(clock: MeetingClock = SystemMeetingClock(), debounceMs: Int = 1500) {
        self.clock = clock
        self.debounceMs = debounceMs
    }

    /// Pure testable evaluation logic
    public func evaluate(active: [AudioInputProcess]) {
        // Audio-process activity is sufficient only for native meeting apps. Browsers require
        // URL verification (Google Meet/Zoom/Teams/etc.) and must not fire merely because the
        // browser is using a microphone for dictation or another recording site.
        let meetingProcs = active.filter {
            guard case .native? = MeetingAppList.classify(bundleID: $0.bundleID) else { return false }
            return true
        }

        // Group by bundle ID
        var currentBundleIDs = Set<String>()
        var currentPIDs: [String: Set<pid_t>] = [:]

        for proc in meetingProcs {
            currentBundleIDs.insert(proc.bundleID)
            currentPIDs[proc.bundleID, default: []].insert(proc.pid)
        }

        // Detect new meeting apps (first process for a bundle ID)
        for bundleID in currentBundleIDs {
            if !activeBundleIDs.contains(bundleID) {
                // Fire candidate on first appearance
                if let firstPID = currentPIDs[bundleID]?.first {
                    onCandidate?(bundleID, firstPID)
                }
            }
        }

        // Detect ended meetings (all processes for a bundle ID stopped)
        for bundleID in activeBundleIDs {
            if !currentBundleIDs.contains(bundleID) {
                // All processes for this bundle ID are gone
                onEnded?(bundleID)
            }
        }

        // Update state
        activeBundleIDs = currentBundleIDs
        lastSeenPIDs = currentPIDs
    }

    public func start() {
        #if os(macOS)
        startCoreAudioMonitoring()
        #else
        // Non-macOS: no-op
        #endif
    }

    public func stop() {
        #if os(macOS)
        stopCoreAudioMonitoring()
        #endif
    }

    #if os(macOS)
    private func startCoreAudioMonitoring() {
        // Listen for process list changes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildProcessListeners()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            listenerBlock
        )

        guard status == noErr else {
            logger.error("Failed to add process list listener: \(status)")
            return
        }

        processListListener = listenerBlock

        // Initial build of listeners
        rebuildProcessListeners()
    }

    private func rebuildProcessListeners() {
        // Get all process objects
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processIDs
        ) == noErr else { return }

        // Remove listeners for processes no longer in the list
        let currentSet = Set(processIDs)
        for (processID, _) in processInputListeners {
            if !currentSet.contains(processID) {
                removeProcessInputListener(processID)
            }
        }

        // Add listeners for new processes
        for processID in processIDs {
            if processInputListeners[processID] == nil {
                addProcessInputListener(processID)
            }
        }

        // Rebuild snapshot
        rebuildSnapshot()
    }

    private func addProcessInputListener(_ processID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildSnapshot()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            processID,
            &address,
            nil,
            listenerBlock
        )

        if status == noErr {
            processInputListeners[processID] = listenerBlock
        }
    }

    private func removeProcessInputListener(_ processID: AudioObjectID) {
        guard let listener = processInputListeners[processID] else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            processID,
            &address,
            nil,
            listener
        )

        processInputListeners[processID] = nil
    }

    private func rebuildSnapshot() {
        var activeProcesses: [AudioInputProcess] = []

        for processID in processInputListeners.keys {
            // Check if running input
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var isRunning: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)

            guard AudioObjectGetPropertyData(
                processID,
                &address,
                0,
                nil,
                &dataSize,
                &isRunning
            ) == noErr, isRunning != 0 else { continue }

            // Get PID
            address.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            dataSize = UInt32(MemoryLayout<pid_t>.size)

            guard AudioObjectGetPropertyData(
                processID,
                &address,
                0,
                nil,
                &dataSize,
                &pid
            ) == noErr else { continue }

            // Get bundle ID
            address.mSelector = kAudioProcessPropertyBundleID
            var cfBundleID: Unmanaged<CFString>?
            dataSize = UInt32(MemoryLayout<CFString>.size)

            guard AudioObjectGetPropertyData(
                processID,
                &address,
                0,
                nil,
                &dataSize,
                &cfBundleID
            ) == noErr, let bundleIDRef = cfBundleID else { continue }

            let bundleID = bundleIDRef.takeRetainedValue() as String

            activeProcesses.append(AudioInputProcess(pid: pid, bundleID: bundleID))
        }

        evaluate(active: activeProcesses)
    }

    private func stopCoreAudioMonitoring() {
        // Remove all process input listeners
        for processID in processInputListeners.keys {
            removeProcessInputListener(processID)
        }
        processInputListeners.removeAll()

        // Remove process list listener
        if let listener = processListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                listener
            )

            processListListener = nil
        }
    }
    #endif
}
