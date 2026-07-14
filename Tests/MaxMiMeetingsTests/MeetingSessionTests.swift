import XCTest
@testable import MaxMiMeetings
import CoreGraphics

// MARK: - Mock Implementations

@MainActor
final class MockPanel: MeetingPanelPresenting {
    var preparingCalled = false
    var promptApp: String?
    var recordingCalled = false
    var voiceNoteRecordingCalled = false
    var endSuggestionCalled = false
    var finishingCalled = false
    var errorMessage: String?
    var hideCalled = false
    var lastLevel: Float = 0
    var lastTranscript: String = ""
    var repositionedFrame: CGRect?

    func showPreparing() { preparingCalled = true }
    func showPrompt(app: String) { promptApp = app }
    func showRecording() { recordingCalled = true }
    func showVoiceNoteRecording() { voiceNoteRecordingCalled = true }
    func showEndSuggestion() { endSuggestionCalled = true }
    func showFinishing() { finishingCalled = true }
    func showError(_ message: String) { errorMessage = message }
    func hidePanel() { hideCalled = true }
    func updateLevel(_ level: Float) { lastLevel = level }
    func updateTranscript(_ text: String) { lastTranscript = text }
    func repositionToMeetingScreen(windowFrame: CGRect) { repositionedFrame = windowFrame }
}

actor MockPersister: MeetingPersisting {
    var persistedMeetings: [(app: String, title: String?, transcript: String, startedAtMs: Int64,
                             endedAtMs: Int64, captureMode: String, transcriptionStatus: String)] = []

    func persist(app: String, title: String?, transcript: String, startedAtMs: Int64,
                 endedAtMs: Int64, captureMode: String, transcriptionStatus: String) async {
        persistedMeetings.append((app, title, transcript, startedAtMs, endedAtMs, captureMode, transcriptionStatus))
    }
}

actor MockAuthorizer: MeetingAuthorizing {
    var microphoneGranted = true
    var screenRecordingGranted = true
    var requestMicCalled = false
    var screenRecordingAuthorizedCalled = false
    var requestScreenRecordingCalled = false

    func requestMicrophone() async -> Bool {
        requestMicCalled = true
        return microphoneGranted
    }

    func screenRecordingAuthorized() async -> Bool {
        screenRecordingAuthorizedCalled = true
        return screenRecordingGranted
    }

    func requestScreenRecordingAccess() async -> Bool {
        requestScreenRecordingCalled = true
        return screenRecordingGranted
    }
}

actor MockCapture: AudioCaptureControlling {
    var startRequest: CaptureRequest?
    var stopCalled = false
    var frameHandler: (@Sendable (PCMFrame) -> Void)?
    var currentLevel: Float = 0.5
    var windowFrame: CGRect?
    var shouldThrowOnStart = false

    func start(_ request: CaptureRequest) async throws -> String {
        if shouldThrowOnStart {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "capture failed"])
        }
        startRequest = request
        return request.captureSystem ? "system+mic" : "mic-only"
    }

    func stop() async {
        stopCalled = true
    }

    func setFrameHandler(_ cb: @escaping @Sendable (PCMFrame) -> Void) async {
        frameHandler = cb
    }

    func level() async -> Float {
        return currentLevel
    }

    func resolvedWindowFrame() async -> CGRect? {
        return windowFrame
    }
}

actor MockSessionTranscriber: Transcribing {
    var startCalled = false
    var fedFrames: [PCMFrame] = []
    var finishResult = "test transcript"
    var partialCallback: (@Sendable (String) -> Void)?

    func start() async throws {
        startCalled = true
    }

    func feed(_ frame: PCMFrame) async {
        fedFrames.append(frame)
    }

    func finish() async -> String {
        return finishResult
    }

    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) async {
        partialCallback = cb
    }
}

// Test clock using actor for async sleep tracking
actor FakeClock: MeetingClock {
    private var _time: Int64 = 1000000
    private var _sleepCalls: [Int] = []

    // Note: nowMs() is synchronous per MeetingClock protocol but actor methods are isolated.
    // Making it nonisolated creates a race, but for tests this is acceptable.
    // In production, SystemMeetingClock.nowMs() would read mach_absolute_time atomically.
    nonisolated func nowMs() -> Int64 {
        // Test limitation: reads without isolation. Tests should await clock state when precision matters.
        return 1000000 // Return constant for simplicity; tests use advance() before checking
    }

    func sleep(ms: Int) async {
        _sleepCalls.append(ms)
        _time += Int64(ms)
    }

    func advance(ms: Int64) {
        _time += ms
    }

    func currentTime() -> Int64 {
        return _time
    }

    var sleepCalls: [Int] {
        return _sleepCalls
    }
}

// MARK: - Tests

final class MeetingSessionTests: XCTestCase {

    @MainActor
    func testCandidateDetectedTransitionsToPrompting() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Daily Standup")

        let state = await session.state
        XCTAssertEqual(state, .prompting)
        XCTAssertEqual(panel.promptApp, "us.zoom.xos")
    }

    @MainActor
    func testSecondCandidateCannotOverwriteActivePrompt() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let session = MeetingSession(
            panel: panel, persister: persister, authorizer: authorizer,
            makeCapture: { capture }, makeTranscriber: { transcriber }, clock: FakeClock()
        )
        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 10, title: "First")
        await session.candidateDetected(bundleID: "com.microsoft.teams2", pid: 20, title: "Second")
        await session.userAcceptedRecord()
        let request = await capture.startRequest
        XCTAssertEqual(request?.bundleID, "us.zoom.xos")
        XCTAssertEqual(request?.pid, 10)
        XCTAssertEqual(request?.title, "First")
    }

    @MainActor
    func testDifferentCandidateCannotOverwriteRecording() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let session = MeetingSession(
            panel: panel, persister: persister, authorizer: authorizer,
            makeCapture: { capture }, makeTranscriber: { transcriber }, clock: FakeClock()
        )
        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 10, title: "First")
        await session.userAcceptedRecord()
        await session.candidateDetected(bundleID: "com.microsoft.teams2", pid: 20, title: "Second")
        await session.userStopped()
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.first?.app, "us.zoom.xos")
        XCTAssertEqual(meetings.first?.title, "First")
    }

    @MainActor
    func testResolvedMeetingWindowRepositionsPanel() async throws {
        let panel = MockPanel()
        let capture = MockCapture()
        let expected = CGRect(x: 1200, y: 100, width: 800, height: 600)
        await capture.setWindowFrame(expected)
        let session = MeetingSession(
            panel: panel, persister: MockPersister(), authorizer: MockAuthorizer(),
            makeCapture: { capture }, makeTranscriber: { MockSessionTranscriber() }, clock: FakeClock()
        )
        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 10, title: "Meeting")
        await session.userAcceptedRecord()
        XCTAssertEqual(panel.repositionedFrame, expected)
    }

    @MainActor
    func testUserAcceptedRecordTransitionsToRecording() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(panel.recordingCalled)

        // Verify capture was started with correct request
        let startRequest = await capture.startRequest
        XCTAssertNotNil(startRequest)
        XCTAssertEqual(startRequest?.bundleID, "us.zoom.xos")
        XCTAssertEqual(startRequest?.pid, 123)
        XCTAssertEqual(startRequest?.title, "Meeting")
        XCTAssertTrue(startRequest?.captureSystem ?? false)

        // Verify transcriber was started
        let transcriberStarted = await transcriber.startCalled
        XCTAssertTrue(transcriberStarted)
    }

    @MainActor
    func testVoiceNoteUsesMicOnlySharedPipelineAndPersists() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let session = MeetingSession(
            panel: panel, persister: persister, authorizer: authorizer,
            makeCapture: { capture }, makeTranscriber: { transcriber }, clock: FakeClock()
        )

        await session.startVoiceNote(title: "Idea")
        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(panel.voiceNoteRecordingCalled)
        let request = await capture.startRequest
        XCTAssertEqual(request?.bundleID, "Voice Note")
        XCTAssertFalse(request?.captureSystem ?? true)
        let screenPermissionChecked = await authorizer.screenRecordingAuthorizedCalled
        XCTAssertFalse(screenPermissionChecked)

        await session.userStopped()
        let recordings = await persister.persistedMeetings
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].app, "Voice Note")
        XCTAssertEqual(recordings[0].title, "Idea")
        XCTAssertEqual(recordings[0].captureMode, "voice-note-mic")
    }

    @MainActor
    func testAudioToTextWiring() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        // Verify frame handler was set on capture
        let handler = await capture.frameHandler
        XCTAssertNotNil(handler, "Frame handler must be wired to capture")

        // Simulate audio frame from capture -> should feed transcriber
        let frame = PCMFrame(samples: [0.1, 0.2, 0.3], hostTimeNs: 1000)
        await handler?(frame)

        // Give a moment for async feed to complete
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let fedFrames = await transcriber.fedFrames
        XCTAssertEqual(fedFrames.count, 1)
        XCTAssertEqual(fedFrames.first?.samples, [0.1, 0.2, 0.3])

        // Verify partial callback was set and updates panel
        let partialCallback = await transcriber.partialCallback
        XCTAssertNotNil(partialCallback, "Partial callback must be wired")

        await partialCallback?("partial transcript")
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        XCTAssertEqual(panel.lastTranscript, "partial transcript")
    }

    @MainActor
    func testUserStoppedPersistsAndFinishes() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        let startTime = await clock.currentTime()
        await session.userAcceptedRecord()

        await clock.advance(ms: 60_000) // 1 minute later
        await session.userStopped()

        let state = await session.state
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(panel.finishingCalled)
        XCTAssertTrue(panel.hideCalled)

        // Verify capture was stopped
        let stopCalled = await capture.stopCalled
        XCTAssertTrue(stopCalled)

        // Verify persistence
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 1)
        let meeting = meetings.first!
        XCTAssertEqual(meeting.app, "us.zoom.xos")
        XCTAssertEqual(meeting.title, "Meeting")
        XCTAssertEqual(meeting.transcript, "test transcript")
        XCTAssertEqual(meeting.startedAtMs, startTime)
        XCTAssertEqual(meeting.captureMode, "system+mic")
        XCTAssertEqual(meeting.transcriptionStatus, "complete")
    }

    @MainActor
    func testUserSkippedNoPerist() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userSkipped()

        let state = await session.state
        XCTAssertEqual(state, .skipped)
        XCTAssertTrue(panel.hideCalled)

        // Verify no persistence
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 0)
    }

    @MainActor
    func testInputStoppedStaysRecordingNeverAutoPersists() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        // Input stops - should show end suggestion but NOT auto-persist
        await session.inputStopped()

        // Give time for debounce
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let state = await session.state
        XCTAssertEqual(state, .recording, "State must stay .recording after inputStopped")
        XCTAssertTrue(panel.endSuggestionCalled)

        // Verify NO persistence occurred
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 0, "inputStopped must NEVER auto-persist")

        // Verify capture was NOT stopped
        let stopCalled = await capture.stopCalled
        XCTAssertFalse(stopCalled, "inputStopped must not stop capture")
    }

    @MainActor
    func testUserKeptRecordingAfterEndSuggestion() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()
        await session.inputStopped()

        panel.endSuggestionCalled = false
        panel.recordingCalled = false

        await session.userKeptRecording()

        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(panel.recordingCalled, "Should show recording UI again")
    }

    @MainActor
    func testMicrophoneDeniedFailsWithError() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        await authorizer.setMicDenied()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        let state = await session.state
        XCTAssertEqual(state, .failed)
        XCTAssertNotNil(panel.errorMessage)
        XCTAssertTrue(panel.hideCalled)

        // Verify capture was never started
        let startRequest = await capture.startRequest
        XCTAssertNil(startRequest)

        // Verify no persistence
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 0)
    }

    @MainActor
    func testCaptureStartThrowsFailsWithoutPersist() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        await capture.setShouldThrow(true)
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        let state = await session.state
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(panel.hideCalled)

        // Verify no persistence
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 0)
    }

    @MainActor
    func testScreenRecordingDegradesGracefully() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        await authorizer.setScreenRecordingDenied()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        let state = await session.state
        XCTAssertEqual(state, .recording, "Should still record with mic-only")

        // Verify capture was started with captureSystem=false
        let startRequest = await capture.startRequest
        XCTAssertNotNil(startRequest)
        XCTAssertFalse(startRequest?.captureSystem ?? true, "Should degrade to mic-only")
    }

    @MainActor
    func testLevelPollingOccurs() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        await capture.setLevel(0.75)
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        // Give time for level polling to occur
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms for at least one poll

        XCTAssertGreaterThan(panel.lastLevel, 0, "Level should be updated from polling")
    }

    @MainActor
    func testSkipDuringRecordingTearsDownAndNoLeak() async throws {
        let panel = MockPanel()
        let persister = MockPersister()
        let authorizer = MockAuthorizer()
        let capture = MockCapture()
        let transcriber = MockSessionTranscriber()
        let clock = FakeClock()

        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: authorizer,
            makeCapture: { capture },
            makeTranscriber: { transcriber },
            clock: clock
        )

        // Detect -> accept (recording) -> skip
        await session.candidateDetected(bundleID: "us.zoom.xos", pid: 123, title: "Meeting")
        await session.userAcceptedRecord()

        let stateBeforeSkip = await session.state
        XCTAssertEqual(stateBeforeSkip, .recording, "Should be recording before skip")

        // Skip while recording
        await session.userSkipped()

        // Assert state is .skipped
        let state = await session.state
        XCTAssertEqual(state, .skipped)

        // Assert capture was stopped
        let stopCalled = await capture.stopCalled
        XCTAssertTrue(stopCalled, "Capture should be stopped when skipping during recording")

        // Assert no persistence occurred
        let meetings = await persister.persistedMeetings
        XCTAssertEqual(meetings.count, 0, "userSkipped should never persist")

        // Assert panel was hidden
        XCTAssertTrue(panel.hideCalled)
    }
}

// MARK: - Mock Extensions for Test Control

extension MockAuthorizer {
    func setMicDenied() {
        microphoneGranted = false
    }

    func setScreenRecordingDenied() {
        screenRecordingGranted = false
    }
}

extension MockCapture {
    func setShouldThrow(_ shouldThrow: Bool) {
        shouldThrowOnStart = shouldThrow
    }

    func setLevel(_ level: Float) {
        currentLevel = level
    }

    func setWindowFrame(_ frame: CGRect) {
        windowFrame = frame
    }
}
