import AppKit
import MaxMiMeetings

/// NSPanel-based right-lane meeting recorder UI conforming to MeetingPanelPresenting.
/// Floats over all spaces, docks to the right edge of the meeting window's screen.
@MainActor
final class RightLanePanel: NSObject, MeetingPanelPresenting {
    private let panel: NSPanel
    private var contentView: NSView?
    private var currentState: State = .hidden
    private var startTime: Date?
    private var timerUpdateTask: Task<Void, Never>?
    private var timerLabel: NSTextField?
    private var levelBar: NSLevelIndicator?
    private var transcriptLabel: NSTextField?
    private var recordingLabel = "Meeting"

    // Button action closures (wired by AppWiring)
    var onRecord: (() -> Void)?
    var onSkip: (() -> Void)?
    var onStop: (() -> Void)?
    var onKeep: (() -> Void)?
    var onFinish: (() -> Void)?

    private enum State {
        case hidden, preparing, prompt, recording, endSuggestion, finishing, error
    }

    override init() {
        let panelSize = CGSize(width: 300, height: 160)

        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.hasShadow = true

        observeScreenChanges()
    }

    // MARK: - MeetingPanelPresenting

    func showPreparing() {
        currentState = .preparing
        buildPreparingView()
        positionPanel(meetingWindow: nil)
        panel.orderFront(nil)
    }

    func showPrompt(app: String) {
        currentState = .prompt
        buildPromptView(app: app)
        positionPanel(meetingWindow: nil)
        panel.orderFront(nil)

        // Auto-dismiss nudge after 30 seconds
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if currentState == .prompt {
                hidePanel()
            }
        }
    }

    func showRecording() {
        showRecording(label: "Meeting")
    }

    func showVoiceNoteRecording() {
        showRecording(label: "Voice note")
    }

    private func showRecording(label: String) {
        recordingLabel = label
        let continuing = currentState == .recording || currentState == .endSuggestion
        currentState = .recording
        if !continuing { startTime = Date() }
        buildRecordingView(label: label)
        positionPanel(meetingWindow: nil)  // Will reposition when session provides window frame
        panel.orderFront(nil)
        startTimerUpdates()
    }

    func showEndSuggestion() {
        currentState = .endSuggestion
        stopTimerUpdates()
        buildEndSuggestionView()
        panel.orderFront(nil)
    }

    func showFinishing() {
        currentState = .finishing
        stopTimerUpdates()
        buildFinishingView()
        panel.orderFront(nil)
    }

    func showError(_ message: String) {
        currentState = .error
        stopTimerUpdates()
        buildErrorView(message: message)
        positionPanel(meetingWindow: nil)
        panel.orderFront(nil)

        // Auto-dismiss error after 10 seconds
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if currentState == .error {
                hidePanel()
            }
        }
    }

    func hidePanel() {
        stopTimerUpdates()
        panel.orderOut(nil)
        currentState = .hidden
    }

    func updateLevel(_ level: Float) {
        levelBar?.floatValue = level
    }

    func updateTranscript(_ text: String) {
        transcriptLabel?.stringValue = text.prefix(100) + (text.count > 100 ? "..." : "")
    }

    // MARK: - Positioning

    func repositionToMeetingScreen(windowFrame: CGRect) {
        positionPanel(meetingWindow: windowFrame)
    }

    private func positionPanel(meetingWindow: CGRect?) {
        let screens = NSScreen.screens.map { $0.visibleFrame }
        let cursor = NSEvent.mouseLocation

        let chosenScreen = RightLanePlacement.chooseScreen(
            meetingWindow: meetingWindow,
            screens: screens,
            cursor: cursor
        )

        let origin = RightLanePlacement.origin(
            inScreen: chosenScreen,
            panelSize: panel.frame.size,
            topInset: 80,
            margin: 16
        )

        panel.setFrameOrigin(origin)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionPanel(meetingWindow: nil)
            }
        }
    }

    // MARK: - View Building

    private func buildPreparingView() {
        let container = makeContainer()

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        let label = makeLabel("Preparing transcription...")
        container.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            spinner.widthAnchor.constraint(equalToConstant: 32),
            spinner.heightAnchor.constraint(equalToConstant: 32),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])

        setContent(container)
    }

    private func buildPromptView(app: String) {
        let container = makeContainer()

        let titleLabel = makeLabel("Meeting detected")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        container.addSubview(titleLabel)

        let appLabel = makeLabel(app)
        appLabel.font = .systemFont(ofSize: 11)
        appLabel.textColor = .secondaryLabelColor
        container.addSubview(appLabel)

        let recordButton = makeButton("Record", target: self, action: #selector(didTapRecord))
        recordButton.bezelColor = .systemBlue
        container.addSubview(recordButton)

        let skipButton = makeButton("Don't record", target: self, action: #selector(didTapSkip))
        container.addSubview(skipButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            appLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            appLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            recordButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            recordButton.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 16),
            recordButton.widthAnchor.constraint(equalToConstant: 120),

            skipButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            skipButton.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 8),
            skipButton.widthAnchor.constraint(equalToConstant: 120),
        ])

        setContent(container)
    }

    private func buildRecordingView(label: String) {
        let container = makeContainer()

        let modeLabel = makeLabel(label)
        modeLabel.font = .boldSystemFont(ofSize: 11)
        container.addSubview(modeLabel)

        let dotView = NSView()
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView.layer?.cornerRadius = 6
        container.addSubview(dotView)

        let timerLabelView = makeLabel("00:00")
        timerLabelView.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        self.timerLabel = timerLabelView
        container.addSubview(timerLabelView)

        let levelBarView = NSLevelIndicator()
        levelBarView.translatesAutoresizingMaskIntoConstraints = false
        levelBarView.minValue = 0
        levelBarView.maxValue = 1
        levelBarView.warningValue = 0.7
        levelBarView.criticalValue = 0.9
        levelBarView.levelIndicatorStyle = .continuousCapacity
        self.levelBar = levelBarView
        container.addSubview(levelBarView)

        let stopButton = makeButton("Stop", target: self, action: #selector(didTapStop))
        stopButton.bezelColor = .systemRed
        container.addSubview(stopButton)

        let transcriptLabelView = makeLabel("")
        transcriptLabelView.font = .systemFont(ofSize: 9)
        transcriptLabelView.textColor = .tertiaryLabelColor
        transcriptLabelView.lineBreakMode = .byTruncatingTail
        self.transcriptLabel = transcriptLabelView
        container.addSubview(transcriptLabelView)

        NSLayoutConstraint.activate([
            modeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            modeLabel.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),

            dotView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            dotView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            dotView.widthAnchor.constraint(equalToConstant: 12),
            dotView.heightAnchor.constraint(equalToConstant: 12),

            timerLabelView.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            timerLabelView.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),

            levelBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            levelBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            levelBarView.topAnchor.constraint(equalTo: dotView.bottomAnchor, constant: 12),
            levelBarView.heightAnchor.constraint(equalToConstant: 8),

            stopButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stopButton.topAnchor.constraint(equalTo: levelBarView.bottomAnchor, constant: 12),
            stopButton.widthAnchor.constraint(equalToConstant: 100),

            transcriptLabelView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            transcriptLabelView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            transcriptLabelView.topAnchor.constraint(equalTo: stopButton.bottomAnchor, constant: 8),
        ])

        setContent(container)
    }

    private func buildEndSuggestionView() {
        let container = makeContainer()

        let label = makeLabel("Still in a meeting?")
        label.font = .boldSystemFont(ofSize: 12)
        container.addSubview(label)

        let finishButton = makeButton("Finish", target: self, action: #selector(didTapFinish))
        finishButton.bezelColor = .systemBlue
        container.addSubview(finishButton)

        let keepButton = makeButton("Keep recording", target: self, action: #selector(didTapKeep))
        container.addSubview(keepButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            finishButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            finishButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            finishButton.widthAnchor.constraint(equalToConstant: 120),

            keepButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            keepButton.topAnchor.constraint(equalTo: finishButton.bottomAnchor, constant: 8),
            keepButton.widthAnchor.constraint(equalToConstant: 120),
        ])

        setContent(container)
    }

    private func buildFinishingView() {
        let container = makeContainer()

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        let label = makeLabel(recordingLabel == "Voice note" ? "Saving voice note..." : "Saving meeting...")
        container.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            spinner.widthAnchor.constraint(equalToConstant: 32),
            spinner.heightAnchor.constraint(equalToConstant: 32),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])

        setContent(container)
    }

    private func buildErrorView(message: String) {
        let container = makeContainer()

        let titleLabel = makeLabel("Error")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.textColor = .systemRed
        container.addSubview(titleLabel)

        let messageLabel = makeLabel(message)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.alignment = .center
        container.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
        ])

        setContent(container)
    }

    // MARK: - Helpers

    private func makeContainer() -> NSView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12  // Theme.cornerRadiusLarge equivalent
        view.layer?.masksToBounds = true
        return view
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        return label
    }

    private func makeButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        return button
    }

    private func setContent(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        panel.contentView = view
    }

    // MARK: - Timer

    private func startTimerUpdates() {
        stopTimerUpdates()
        timerUpdateTask = Task { @MainActor in
            while !Task.isCancelled {
                updateTimerLabel()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopTimerUpdates() {
        timerUpdateTask?.cancel()
        timerUpdateTask = nil
    }

    private func updateTimerLabel() {
        guard let start = startTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        timerLabel?.stringValue = String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    @objc private func didTapRecord() {
        onRecord?()
    }

    @objc private func didTapSkip() {
        onSkip?()
    }

    @objc private func didTapStop() {
        onStop?()
    }

    @objc private func didTapKeep() {
        onKeep?()
    }

    @objc private func didTapFinish() {
        onFinish?()
    }
}
