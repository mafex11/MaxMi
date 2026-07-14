import Foundation
import CoreGraphics

/// Normalized audio frame crossing actor boundaries — Sendable value type (16kHz mono).
public struct PCMFrame: Sendable {
    public let samples: [Float]           // 16kHz mono
    public let hostTimeNs: UInt64         // source timestamp for alignment
    public init(samples: [Float], hostTimeNs: UInt64) { self.samples = samples; self.hostTimeNs = hostTimeNs }
}

/// What to capture — resolved from SCShareableContent BEFORE recording. Holds the app+display
/// SCContentFilter(display:includingApplications:exceptingWindows:) needs. Non-Sendable SC types
/// stay on the capture side; the session passes only the Sendable `bundleID`/`captureSystem`.
public struct CaptureRequest: Sendable {
    public let bundleID: String           // meeting app to scope audio to
    public let pid: pid_t                 // for resolving the app's SCWindow/SCDisplay (Codex plan#5)
    public let title: String?
    public let captureSystem: Bool        // false => mic-only (denied screen-rec / no shareable app)
    public init(bundleID: String, pid: pid_t, title: String?, captureSystem: Bool) {
        self.bundleID = bundleID; self.pid = pid; self.title = title; self.captureSystem = captureSystem
    }
}

/// A single active-input process snapshot (PID + bundle id) — Codex #3: keep both, not just a Set.
public struct AudioInputProcess: Sendable, Equatable { public let pid: pid_t; public let bundleID: String
    public init(pid: pid_t, bundleID: String) { self.pid = pid; self.bundleID = bundleID } }

/// Capture control — async everywhere so an ACTOR mock can conform (Codex plan#3: no sync
/// mutable onFrame / sync level on a Sendable an actor implements).
public protocol AudioCaptureControlling: Sendable {
    func start(_ request: CaptureRequest) async throws -> String   // returns captureMode "system+mic"|"mic-only"
    func stop() async
    func setFrameHandler(_ cb: @escaping @Sendable (PCMFrame) -> Void) async
    func level() async -> Float
    func resolvedWindowFrame() async -> CGRect?    // ▲REV3 (Codex#2): meeting window frame post-start,
                                                   // so the session can reposition the panel to its screen
}

/// Transcriber is an ACTOR (not just Sendable — Codex plan#3) — receives only normalized PCMFrames.
public protocol Transcribing: Actor {
    func start() async throws
    func feed(_ frame: PCMFrame) async
    func finish() async -> String
    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) async
}

/// Session -> UI callbacks are @MainActor. Includes ALL required states (Codex plan#6):
/// preparing (model download), prompt, recording, end-suggestion (Finish/Keep), finishing, error.
@MainActor public protocol MeetingPanelPresenting: AnyObject {
    func showPreparing()                       // whisper model downloading
    func showPrompt(app: String)               // Record / Don't record
    func showRecording()                       // ● + timer + level + Stop
    func showVoiceNoteRecording()
    func showEndSuggestion()                    // debounced "Finish or keep recording?"
    func showFinishing()                        // saving spinner
    func showError(_ message: String)
    func hidePanel()
    func updateLevel(_ level: Float)       // 10Hz live meter (polled, not tied to transcription windows)
    func updateTranscript(_ text: String)  // running stitched transcript (~30s cadence)
    func repositionToMeetingScreen(windowFrame: CGRect)
}
public protocol MeetingPersisting: Sendable {   // adapter over Store; actor or audited @unchecked Sendable
    func persist(app: String, title: String?, transcript: String, startedAtMs: Int64,
                 endedAtMs: Int64, captureMode: String, transcriptionStatus: String) async
}
/// Permission gate injected into the session (Codex plan#4 — session can't reach the app target).
public protocol MeetingAuthorizing: Sendable {
    func requestMicrophone() async -> Bool
    func screenRecordingAuthorized() async -> Bool         // CGPreflightScreenCaptureAccess
    func requestScreenRecordingAccess() async -> Bool       // ▲REV3 (Codex#1): CGRequestScreenCaptureAccess;
                                                            // only if preflight false, before degrading to mic-only
}
/// Injected clock so debounce is testable (Codex #3).
public protocol MeetingClock: Sendable { func nowMs() -> Int64; func sleep(ms: Int) async }
