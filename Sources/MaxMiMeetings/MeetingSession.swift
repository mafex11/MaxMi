import Foundation
import CoreGraphics

/// Unsafe transfer wrapper for crossing actor boundaries with non-Sendable @MainActor types
private struct UnsafeTransfer<T>: @unchecked Sendable {
    let wrappedValue: T
    init(_ value: T) { wrappedValue = value }
}

/// Current state of the meeting session.
public enum MeetingState: Equatable, Sendable {
    case idle
    case prompting
    case recording
    case finishing
    case failed
    case skipped
}

/// Actor state machine orchestrating meeting detection, authorization, capture, transcription, and persistence.
/// All capture/transcriber objects are created inside the actor via @Sendable factories and never escape.
/// Panel calls hop to @MainActor; PCMFrame (Sendable) is the only audio type crossing boundaries.
public actor MeetingSession {
    private nonisolated(unsafe) let panel: any MeetingPanelPresenting
    private let persister: any MeetingPersisting
    private let authorizer: any MeetingAuthorizing
    private let makeCapture: @Sendable () -> any AudioCaptureControlling
    private let makeTranscriber: @Sendable () -> any Transcribing
    private let clock: any MeetingClock

    private var _state: MeetingState = .idle
    public var state: MeetingState { _state }

    // Current meeting context
    private var currentBundleID: String?
    private var currentPid: pid_t?
    private var currentTitle: String?
    private var startedAtMs: Int64?
    private var captureMode: String?

    // Active objects during recording
    private var capture: (any AudioCaptureControlling)?
    private var transcriber: (any Transcribing)?
    private var levelTask: Task<Void, Never>?

    public init(
        panel: any MeetingPanelPresenting,
        persister: any MeetingPersisting,
        authorizer: any MeetingAuthorizing,
        makeCapture: @Sendable @escaping () -> any AudioCaptureControlling,
        makeTranscriber: @Sendable @escaping () -> any Transcribing,
        clock: any MeetingClock
    ) {
        self.panel = panel
        self.persister = persister
        self.authorizer = authorizer
        self.makeCapture = makeCapture
        self.makeTranscriber = makeTranscriber
        self.clock = clock
    }

    /// Candidate detected -> prompting state, show prompt UI
    public func candidateDetected(bundleID: String, pid: pid_t, title: String?) {
        _state = .prompting
        currentBundleID = bundleID
        currentPid = pid
        currentTitle = title

        Task { @MainActor in
            panel.showPrompt(app: bundleID)
        }
    }

    /// User accepted record -> authorize, create capture/transcriber, wire audio->text, start recording
    public func userAcceptedRecord() async {
        guard _state == .prompting,
              let bundleID = currentBundleID,
              let pid = currentPid else {
            return
        }

        // Request microphone permission
        let micGranted = await authorizer.requestMicrophone()
        guard micGranted else {
            _state = .failed
            await MainActor.run {
                panel.showError("Microphone access is required to record meetings")
                panel.hidePanel()
            }
            return
        }

        // Check screen recording permission, request if needed
        var captureSystem = true
        let screenGranted = await authorizer.screenRecordingAuthorized()
        if !screenGranted {
            let requested = await authorizer.requestScreenRecordingAccess()
            if !requested {
                // Degrade to mic-only
                captureSystem = false
            }
        }

        // Create capture and transcriber
        let captureInstance = makeCapture()
        let transcriberInstance = makeTranscriber()

        do {
            // Start transcriber
            try await transcriberInstance.start()

            // Wire partial transcript updates to panel
            let panelUnsafe = UnsafeTransfer(panel)
            await transcriberInstance.setOnPartial { text in
                Task { @MainActor in
                    panelUnsafe.wrappedValue.updateTranscript(text)
                }
            }

            // Wire audio frames from capture to transcriber
            await captureInstance.setFrameHandler { [weak transcriberInstance] frame in
                guard let transcriber = transcriberInstance else { return }
                Task {
                    await transcriber.feed(frame)
                }
            }

            // Start capture
            let request = CaptureRequest(
                bundleID: bundleID,
                pid: pid,
                title: currentTitle,
                captureSystem: captureSystem
            )

            let mode = try await captureInstance.start(request)
            captureMode = mode
            startedAtMs = clock.nowMs()

            // Store active objects
            capture = captureInstance
            transcriber = transcriberInstance

            // Start level polling at 10Hz
            startLevelPolling()

            // Reposition panel if window frame is available
            if let windowFrame = await captureInstance.resolvedWindowFrame() {
                // Panel repositioning happens in the UI layer - just note it's available
                _ = windowFrame
            }

            // Transition to recording
            _state = .recording
            await MainActor.run {
                panel.showRecording()
            }

        } catch {
            _state = .failed
            levelTask?.cancel()
            capture = nil
            transcriber = nil
            await MainActor.run {
                panel.hidePanel()
            }
        }
    }

    /// User skipped -> no persist, hide panel
    public func userSkipped() async {
        // Skip is a prompt-time action, but be defensive: if we're somehow recording,
        // tear down capture/transcriber + the level poll so nothing leaks.
        levelTask?.cancel()
        levelTask = nil
        if _state == .recording {
            await capture?.stop()
        }
        capture = nil
        transcriber = nil
        _state = .skipped
        await MainActor.run {
            panel.hidePanel()
        }
    }

    /// User stopped recording -> finishing, stop capture, get transcript, persist
    public func userStopped() async {
        guard _state == .recording else { return }

        _state = .finishing
        await MainActor.run {
            panel.showFinishing()
        }

        // Cancel level polling
        levelTask?.cancel()

        // Stop capture
        if let capture = capture {
            await capture.stop()
        }

        // Get final transcript
        let transcript: String
        if let transcriber = transcriber {
            transcript = await transcriber.finish()
        } else {
            transcript = ""
        }

        // Persist
        if let app = currentBundleID,
           let startMs = startedAtMs,
           let mode = captureMode {
            let endMs = clock.nowMs()
            await persister.persist(
                app: app,
                title: currentTitle,
                transcript: transcript,
                startedAtMs: startMs,
                endedAtMs: endMs,
                captureMode: mode,
                transcriptionStatus: "complete"
            )
        }

        // Clean up
        capture = nil
        transcriber = nil
        _state = .idle

        await MainActor.run {
            panel.hidePanel()
        }
    }

    /// Input stopped -> debounced end suggestion, but never auto-persist
    public func inputStopped() async {
        guard _state == .recording else { return }

        // Debounce
        await clock.sleep(ms: 1500)

        // Show end suggestion but stay in recording state
        await MainActor.run {
            panel.showEndSuggestion()
        }
    }

    /// User chose to keep recording after end suggestion
    public func userKeptRecording() async {
        guard _state == .recording else { return }

        await MainActor.run {
            panel.showRecording()
        }
    }

    // MARK: - Private Helpers

    private func startLevelPolling() {
        guard let capture = capture else { return }

        let panelUnsafe = UnsafeTransfer(panel)
        levelTask = Task { [clock] in
            while !Task.isCancelled {
                let level = await capture.level()
                await MainActor.run {
                    panelUnsafe.wrappedValue.updateLevel(level)
                }
                await clock.sleep(ms: 100) // 10Hz
            }
        }
    }
}
