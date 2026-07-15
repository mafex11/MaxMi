import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics
import ApplicationServices
import MaxMiCore
import MaxMiStore
import MaxMiCapture
import MaxMiRelay
import MaxMiActivity
import MaxMiMeetings
import MaxMiUI

/// Format a time interval in a human-readable format (e.g., "5m ago", "2h ago", "3d ago").
fileprivate func formatTimeAgo(ms: EpochMs, nowMs: EpochMs) -> String {
    let deltaSec = Int((nowMs - ms) / 1000)
    if deltaSec < 60 { return "\(deltaSec)s ago" }
    let deltaMin = deltaSec / 60
    if deltaMin < 60 { return "\(deltaMin)m ago" }
    let deltaHour = deltaMin / 60
    if deltaHour < 24 { return "\(deltaHour)h ago" }
    let deltaDay = deltaHour / 24
    return "\(deltaDay)d ago"
}

fileprivate func safeFileTimestamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
}

fileprivate func maxMiProcessCount(matching pattern: String) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", pattern]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return 0 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    } catch {
        return 0
    }
}

@MainActor
fileprivate func openPrivacySettings(_ pane: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
    NSWorkspace.shared.open(url)
}

/// Adapts MaxMiStore.Store (concrete rows) to MaxMiCore.MemoryStore (pipeline types).
final class StoreAdapter: MemoryStore, @unchecked Sendable {   // Store is internally serialized by GRDB's DatabaseQueue
    let store: Store
    init(store: Store) { self.store = store }

    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion] {
        try store.pendingWork(nowMs: nowMs, idleThresholdMs: idleThresholdMs).map {
            PipelineVersion(id: $0.id, threadID: $0.threadID, content: $0.content,
                            contentHash: $0.contentHash, sourceApp: $0.sourceApp,
                            sourceKey: $0.sourceKey, previousFrozenContent: $0.previousFrozenContent)
        }
    }
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative] {
        try store.insertDerivatives(versionID: versionID, threadID: threadID, facts: facts, nowMs: nowMs)
            .map { PipelineDerivative(id: $0.id, content: $0.content) }
    }
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative] {
        try store.pendingDerivatives(versionID: versionID).map { PipelineDerivative(id: $0.id, content: $0.content) }
    }
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        try store.markExtracted(versionID: versionID, contentHashRead: contentHashRead)
    }
    func markExtractFailed(versionID: String) throws { try store.markExtractFailed(versionID: versionID) }
    func markEmbedded(derivativeID: String) throws { try store.markEmbedded(derivativeID: derivativeID) }
    func insertEmbedding(derivativeID: String, vector: [Float]) throws {
        try store.insertEmbedding(derivativeID: derivativeID, vector: vector)
    }
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        try store.enqueueRetry(kind: kind, versionID: versionID, derivativeID: derivativeID, error: error, nowMs: nowMs)
    }
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] {
        try store.dueRetries(nowMs: nowMs)
    }
    func clearRetry(id: String) throws { try store.clearRetry(id: id) }
}

@MainActor
final class AppWiring {
    let store: Store
    let pipeline: CapturePipeline
    var observer: FocusObserver?
    let menuBar: MenuBarController
    var pipelineTimer: Timer?
    var captureSummaryTimer: Timer?
    var paused = false
    private(set) var captureCount = 0
    let encryptionAvailable: Bool
    let registry = ParserRegistry()
    var recentApps: [(bundleID: String, name: String)] = []
    var lastSourceKey: String?

    // Meeting capture components
    var meetingDetector: MeetingDetector?
    var meetingSession: MeetingSession?
    var rightLanePanel: RightLanePanel?
    var modelStore: WhisperModelStore?
    let meetingLifecycleTracker: FileMeetingLifecycleTracker
    var meetingPreparationTask: Task<Void, Never>?
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var didInstallMenu = false
    private var isShuttingDown = false
    private var isLifecycleSuspended = false

    // Activity focus-generation mechanism
    var focusGeneration: Int = 0
    var currentVisitID: String?
    let displaySummarizer: DisplaySummarizer
    let captureDisplaySummarizer: CaptureDisplaySummarizer

    // Agent scheduler
    let agentScheduler: AgentScheduler
    var agentBackgroundScheduler: NSBackgroundActivityScheduler?
    var lastSummarizedCount: Int = 0

    // Activity UI
    let activityWindow: ActivityWindow
    let activityPrivacyWindow: ActivityPrivacyWindow
    let captureHealthWindow: CaptureHealthWindow
    let menuPopoverNavigation: MenuPopoverViewModel
    var trayHomeViewModel: TrayHomeViewModel!

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxMi", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        // Spec §6/§9: keep plaintext memories out of Time Machine.
        var dir = appSupport
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        meetingLifecycleTracker = FileMeetingLifecycleTracker(
            directoryURL: appSupport.appendingPathComponent("RecordingState", isDirectory: true)
        )

        let config = EnvConfig.load(searchPaths: [
            appSupport.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ])
        let databaseURL = appSupport.appendingPathComponent("maxmi.db")
        let db = try MaxMiDatabase(path: databaseURL.path)
        // Spec §6 ordering: key -> backfill -> capture. No key => capture stays paused
        // and we never write plaintext post-M3 (spec §9).
        let cipher: any FieldCipher
        var encryptionAvailable = true
        do {
            cipher = AESGCMFieldCipher(keyData: try KeychainKeyStore.getOrCreate())
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .app, event: .encryptionKeyUnavailable, error: error
            )
            // A cipher that throws on every operation: capture is paused below, but
            // even a future write path that slips past the guard fails loudly and
            // rolls back rather than writing plaintext-equivalent data (spec §9).
            cipher = UnavailableCipher()
            encryptionAvailable = false
        }
        store = Store(db: db, cipher: cipher)
        self.encryptionAvailable = encryptionAvailable
        let relay = GeminiClient(config: config)
        pipeline = CapturePipeline(store: StoreAdapter(store: store), relay: relay)
        menuBar = MenuBarController()
        menuBar.aiServiceAvailable = config.geminiAPIKey != nil
        let activityRepo = StoreActivitySummaryRepository(store: store, modelID: config.extractModel)
        let activityRelay = GeminiActivityRelay(
            geminiClient: relay,
            maxEvidenceChars: 12_000,
            modelID: config.extractModel
        )
        displaySummarizer = DisplaySummarizer(repo: activityRepo, relay: activityRelay, maxEvidenceChars: 12_000)
        captureDisplaySummarizer = CaptureDisplaySummarizer(
            repo: StoreCaptureSummaryRepository(store: store, modelID: config.extractModel),
            relay: activityRelay
        )

        // Initialize agent scheduler
        let agentRepo = StoreAgentRepository(store: store)
        let agentRelay = GeminiAgentRelay(geminiClient: relay)
        let hourlyAgent = HourlyAgent(repo: agentRepo, relay: agentRelay)
        agentScheduler = AgentScheduler(agent: hourlyAgent)

        // Initialize activity UI
        // Store is internally serialized by GRDB; we safely capture it via nonisolated(unsafe)
        nonisolated(unsafe) let activityStore = store
        let viewModel = ActivityViewModel(
            load: { @Sendable in
                do {
                    let sessions = try activityStore.recentSessions(limit: 100)
                    return try sessions.map { session in
                        let evidence = try activityStore.sessionEvidence(session.id)
                        return TimelineSessionDTO(
                            id: session.id,
                            appLabel: session.appLabel,
                            summary: session.summary,
                            startedAtMs: session.startedAtMs,
                            evidence: evidence
                        )
                    }
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .activity, event: .activityStateReadFailed, error: error
                    )
                    return []
                }
            },
            now: { epochNowMs() }
        )

        let actionItemsViewModel = ActionItemsViewModel(
            load: { @Sendable in
                do {
                    let nowMs = epochNowMs()
                    let open = try activityStore.actionItems(status: "open", limit: 100)
                    let resolved = try activityStore.actionItems(status: "resolved", limit: 50)
                    let dismissed = try activityStore.actionItems(status: "dismissed", limit: 50)

                    let openDTOs = open.map { item in
                        ActionItemDTO(
                            id: item.id,
                            title: item.title,
                            details: item.details,
                            status: item.status,
                            timeAgo: formatTimeAgo(ms: item.detectedAtMs, nowMs: nowMs)
                        )
                    }
                    let archivedDTOs = (resolved + dismissed).map { item in
                        ActionItemDTO(
                            id: item.id,
                            title: item.title,
                            details: item.details,
                            status: item.status,
                            timeAgo: formatTimeAgo(ms: item.updatedAtMs, nowMs: nowMs)
                        )
                    }
                    return (open: openDTOs, archived: archivedDTOs)
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .agent, event: .actionItemsReadFailed, error: error
                    )
                    return (open: [], archived: [])
                }
            },
            onResolve: { @Sendable id in
                try activityStore.resolveActionItem(id, nowMs: epochNowMs())
            },
            onDismiss: { @Sendable id in
                try activityStore.dismissActionItem(id, nowMs: epochNowMs())
            }
        )

        let recentCapturesViewModel = RecentCapturesViewModel(
            load: { @Sendable in
                do {
                    let reviewed = try activityStore.cloudReviewedSourceApps()
                    let localOnly = try activityStore.cloudLocalOnlySourceApps()
                    return try activityStore.latestContexts(limit: 100).map { context in
                        let cloudState: CloudProcessingDisplayState = !reviewed.contains(context.sourceApp)
                            ? .pendingReview
                            : (localOnly.contains(context.sourceApp) ? .localOnly : .allowed)
                        return RecentCaptureDTO(
                            id: context.id,
                            appLabel: context.sourceApp,
                            title: context.sourceTitle,
                            contentKind: context.contentKind,
                            parserID: context.parserID,
                            capturedAtMs: context.capturedAtMs,
                            characterCount: context.characterCount,
                            truncated: context.truncated,
                            displaySummary: context.displaySummary,
                            summaryStatus: context.summaryStatus,
                            cloudState: cloudState
                        )
                    }
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .capture, event: .recentCapturesReadFailed, error: error
                    )
                    return []
                }
            },
            now: { epochNowMs() },
            onSetCloudProcessing: { @Sendable sourceApp, allowed in
                do {
                    try activityStore.setCloudProcessing(sourceApp, allowed: allowed, nowMs: epochNowMs())
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .settings, event: .privacyStateWriteFailed, error: error
                    )
                }
            }
        )

        let meetingHistoryViewModel = MeetingHistoryViewModel(
            load: { @Sendable in
                do {
                    return try activityStore.recentMeetings(limit: 100).map { meeting in
                        let label = ApplicationRegistry.descriptor(for: meeting.app)?.displayName
                            ?? meeting.app
                        return MeetingHistoryDTO(
                            id: meeting.id,
                            appLabel: label,
                            title: meeting.title,
                            startedAtMs: meeting.startedAtMs,
                            endedAtMs: meeting.endedAtMs,
                            captureMode: meeting.captureMode,
                            transcriptionStatus: meeting.transcriptionStatus
                        )
                    }
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .meeting, event: .meetingHistoryReadFailed
                    )
                    return []
                }
            },
            now: { epochNowMs() }
        )

        activityWindow = ActivityWindow(
            viewModel: viewModel,
            actionItemsViewModel: actionItemsViewModel,
            recentCapturesViewModel: recentCapturesViewModel,
            meetingHistoryViewModel: meetingHistoryViewModel
        )
        activityPrivacyWindow = ActivityPrivacyWindow(store: store)

        let captureHealthViewModel = CaptureHealthViewModel(
            load: { @Sendable in
                do {
                    return try activityStore.recentCaptureHealth(limit: 100).map { event in
                        CaptureHealthDTO(
                            id: event.id,
                            atMs: event.atMs,
                            appLabel: event.appLabel,
                            trigger: event.trigger,
                            parser: event.parser,
                            outcome: event.outcome,
                            reason: event.reason,
                            characterCount: event.characterCount,
                            durationMs: event.durationMs,
                            truncated: event.truncated
                        )
                    }
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .capture, event: .captureHealthReadFailed, error: error
                    )
                    return []
                }
            },
            now: { epochNowMs() }
        )
        captureHealthWindow = CaptureHealthWindow(viewModel: captureHealthViewModel)

        // Initialize settings window
        // Capture values needed for settings load closure before self is fully initialized
        let aiServiceAvailable = config.geminiAPIKey != nil
        let encryptionOK = encryptionAvailable
        nonisolated(unsafe) let mb = menuBar
        nonisolated(unsafe) let privacyWindow = activityPrivacyWindow

        let settingsViewModel = SettingsViewModel(
            load: { @Sendable in
                do {
                    let launchStatus = LaunchAtLogin.status()
                    let activityEnabled = try activityStore.activityEnabled()
                    let consent = try activityStore.activityConsent()
                    let excluded = try activityStore.activityExcludedApps()
                    let observed = try activityStore.observedActivityApps()

                    let excludedApps = observed.map { app in
                        SettingsExcludedApp(id: app.bundle, name: app.label, excluded: excluded.contains(app.bundle))
                    }

                    let version = UpdateChecker.currentVersion()
                    let accessGranted = await MainActor.run { mb.accessibilityGranted }
                    let statusLines = [
                        accessGranted ? "Accessibility: Granted" : "Accessibility: Required",
                        aiServiceAvailable ? "AI Service: Available" : "AI Service: Unavailable",
                        encryptionOK ? "Encryption: Available" : "Encryption: Unavailable"
                    ]

                    return SettingsSnapshot(
                        launchAtLoginStatus: launchStatus,
                        activityEnabled: activityEnabled,
                        consentGranted: consent == .granted,
                        excludedApps: excludedApps,
                        version: version,
                        statusLines: statusLines
                    )
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .settings, event: .databaseReadFailed, error: error
                    )
                    return SettingsSnapshot(
                        launchAtLoginStatus: .unavailable,
                        activityEnabled: false,
                        consentGranted: false,
                        excludedApps: [],
                        version: UpdateChecker.currentVersion(),
                        statusLines: []
                    )
                }
            },
            onSetLaunchAtLogin: { @Sendable on in
                try await LaunchAtLogin.setEnabled(on)
            },
            onSetActivityEnabled: { @Sendable enabled in
                do {
                    // Consent gate: can't enable without consent
                    if enabled {
                        let consent = try activityStore.activityConsent()
                        guard consent == .granted else { return }
                    }
                    try activityStore.setActivityEnabled(enabled)
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
                    )
                }
            },
            onToggleExcluded: { @Sendable bundle, excluded in
                do {
                    try activityStore.setActivityExcludedAndDeleteActivity(bundle, excluded: excluded)
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
                    )
                }
            },
            onCheckUpdates: { @Sendable in
                let version = UpdateChecker.currentVersion()
                return "MaxMi \(version) · updates are manual"
            },
            onOpenPrivacy: { @MainActor in
                privacyWindow.show()
            },
            onOpenLoginItems: { @MainActor in
                SMAppService.openSystemSettingsLoginItems()
            }
        )

        let capturePrivacyViewModel = CapturePrivacyViewModel(
            load: { @Sendable in
                let nowMs = epochNowMs()
                do {
                    let pause = try activityStore.capturePauseState(nowMs: nowMs)
                    let pauseDescription: String
                    switch pause {
                    case .inactive:
                        pauseDescription = "Capture is active"
                    case .active(nil):
                        pauseDescription = "Capture paused indefinitely"
                    case .active(let untilMs?):
                        let formatter = DateFormatter()
                        formatter.dateStyle = .none
                        formatter.timeStyle = .short
                        pauseDescription = "Capture paused until \(formatter.string(from: Date(timeIntervalSince1970: Double(untilMs) / 1000)))"
                    }
                    let blockedApps = try activityStore.pausedApps().sorted().map { bundleID in
                        PrivacyBlockedApp(
                            id: bundleID,
                            name: ApplicationRegistry.descriptor(for: bundleID)?.displayName ?? bundleID
                        )
                    }
                    let threads = try activityStore.pausedThreadInfo().map { thread in
                        PrivacyPausedThread(
                            id: thread.id,
                            label: thread.sourceTitle?.isEmpty == false ? thread.sourceTitle! : thread.id,
                            sourceApp: thread.sourceApp ?? "Unknown source"
                        )
                    }
                    return CapturePrivacySnapshot(
                        isPaused: pause.isPaused(at: nowMs),
                        pauseDescription: pauseDescription,
                        blockedDomains: try activityStore.blockedDomains().sorted(),
                        blockedApps: blockedApps,
                        pausedThreads: threads,
                        localOnlySources: try activityStore.cloudLocalOnlySourceApps().sorted(),
                        retentionDays: try activityStore.retentionDays()
                    )
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .settings, event: .privacyStateReadFailed, error: error
                    )
                    return CapturePrivacySnapshot(
                        isPaused: true, pauseDescription: "Privacy settings unavailable — capture fails closed",
                        blockedDomains: [], blockedApps: [], pausedThreads: [], localOnlySources: [], retentionDays: nil
                    )
                }
            },
            onPause: { @Sendable choice in
                let nowMs = epochNowMs()
                switch choice {
                case .minutes(let minutes):
                    try activityStore.setCapturePaused(untilMs: nowMs + EpochMs(minutes) * 60_000, nowMs: nowMs)
                case .untilTomorrow:
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
                    try activityStore.setCapturePaused(untilMs: EpochMs(tomorrow.timeIntervalSince1970 * 1000), nowMs: nowMs)
                case .indefinite:
                    try activityStore.setCapturePaused(untilMs: nil, nowMs: nowMs)
                case .resume:
                    try activityStore.clearCapturePause(nowMs: nowMs)
                }
                let isPaused = try activityStore.capturePauseState(nowMs: nowMs).isPaused(at: nowMs)
                await MainActor.run { mb.paused = isPaused }
            },
            onSetDomain: { @Sendable domain, blocked in
                try activityStore.setDomain(domain, blocked: blocked, nowMs: epochNowMs()) != nil
            },
            onResumeApp: { @Sendable bundleID in
                try activityStore.setAppPaused(bundleID, paused: false, nowMs: epochNowMs())
            },
            onResumeThread: { @Sendable sourceKey in
                try activityStore.setThreadPaused(sourceKey, paused: false, nowMs: epochNowMs())
            },
            onSetRetention: { @Sendable days in
                try activityStore.setRetentionDays(days, nowMs: epochNowMs())
            },
            onAllowCloudSource: { @Sendable sourceApp in
                try activityStore.setCloudProcessing(sourceApp, allowed: true, nowMs: epochNowMs())
            }
        )

        let backupDirectory = appSupport.appendingPathComponent("Backups", isDirectory: true)
        let dataControlsViewModel = DataControlsViewModel(
            onExport: { @MainActor in
                let panel = NSSavePanel()
                panel.title = "Export MaxMi Memory as Plaintext"
                panel.nameFieldStringValue = "MaxMi Memory Export.json"
                panel.allowedContentTypes = [.json]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return "Export cancelled" }
                let count = try await Task.detached(priority: .userInitiated) {
                    try activityStore.exportMemory(to: url)
                }.value
                return "Exported \(count) memory threads as plaintext JSON"
            },
            onApplyRetention: { @MainActor in
                guard let days = try activityStore.retentionDays() else {
                    return "Retention is set to Forever; nothing was deleted"
                }
                let alert = NSAlert()
                alert.messageText = "Apply \(days)-day retention now?"
                alert.informativeText = "MaxMi will create a private database backup, then delete memories last updated before the cutoff. This cannot be undone inside the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Apply Retention")
                guard alert.runModal() == .alertSecondButtonReturn else { return "Retention cleanup cancelled" }
                let nowMs = epochNowMs()
                let cutoff = nowMs - EpochMs(days) * 86_400_000
                let backupURL = backupDirectory.appendingPathComponent("maxmi-before-retention-\(safeFileTimestamp()).db")
                let result = try await Task.detached(priority: .userInitiated) {
                    try activityStore.backupDatabase(to: backupURL)
                    return try activityStore.pruneMemory(olderThan: cutoff)
                }.value
                return "Removed \(result.threads) stale threads; backup: \(backupURL.lastPathComponent)"
            },
            onDeleteAll: { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Delete all MaxMi memory?"
                alert.informativeText = "This removes captured context, facts, recordings, activity, action items, and diagnostics. Privacy settings remain. A private database backup is created first."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Delete All Memory")
                guard alert.runModal() == .alertSecondButtonReturn else { return "Deletion cancelled" }
                let backupURL = backupDirectory.appendingPathComponent("maxmi-before-delete-all-\(safeFileTimestamp()).db")
                let result = try await Task.detached(priority: .userInitiated) {
                    try activityStore.backupDatabase(to: backupURL)
                    return try activityStore.deleteAllMemory()
                }.value
                return "Deleted \(result.threads) threads and \(result.facts) facts; backup: \(backupURL.lastPathComponent)"
            },
            onExportDiagnostics: { @MainActor in
                let panel = NSSavePanel()
                panel.title = "Export Privacy-Safe MaxMi Diagnostics"
                panel.nameFieldStringValue = "MaxMi Diagnostics-\(safeFileTimestamp())"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else {
                    return "Diagnostics export cancelled"
                }
                do {
                    let version = SafeLogToken(validating: MaxMiVersion.current)!
                    let buildValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                    let build = SafeLogToken(validating: buildValue)
                        ?? SafeLogToken(validating: "unknown")!
                    let helperProcesses = maxMiProcessCount(
                        matching: "/MaxMi.app/Contents/MacOS/maxmi-mcp$"
                    )
                    let meetingResources = MeetingResourceTracker.shared.snapshot()
                    let manifest = SafeDiagnosticsManifest(
                        appVersion: version,
                        appBuild: build,
                        encryptionAvailable: encryptionOK,
                        permissions: SafeDiagnosticsPermissions(
                            accessibility: AXIsProcessTrusted(),
                            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            screenRecording: CGPreflightScreenCaptureAccess()
                        ),
                        processes: SafeDiagnosticsProcesses(
                            app: maxMiProcessCount(matching: "/MaxMi.app/Contents/MacOS/MaxMi$"),
                            mcp: helperProcesses
                        ),
                        resources: SafeDiagnosticsResources(
                            audioEngines: meetingResources.audioEngines,
                            screenStreams: meetingResources.screenStreams,
                            deviceObservers: meetingResources.deviceObservers,
                            meetingDetectors: meetingResources.meetingDetectors,
                            helperProcesses: helperProcesses
                        ),
                        database: try activityStore.runtimeDiagnostics(
                            nowMs: epochNowMs(),
                            databaseURL: databaseURL
                        )
                    )
                    let entries = try SafeDiagnosticsBundleWriter.write(
                        manifest: manifest,
                        logDirectory: SafeLogger.defaultLogDirectory,
                        to: destination
                    )
                    SafeLogger.shared.log(
                        .info,
                        subsystem: .diagnostics,
                        event: .diagnosticsExported,
                        fields: SafeLogFields(count: entries)
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([
                        destination.appendingPathComponent("manifest.json")
                    ])
                    return "Exported content-free diagnostics with \(entries) safe log events"
                } catch {
                    SafeLogger.shared.log(
                        .error,
                        subsystem: .diagnostics,
                        event: .diagnosticsExportFailed,
                        error: error
                    )
                    throw error
                }
            },
            onRevealLogs: { @MainActor in
                NSWorkspace.shared.open(SafeLogger.defaultLogDirectory)
                return "Opened privacy-safe logs in Finder"
            }
        )

        let mcpURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/maxmi-mcp")
        let setupViewModel = SetupViewModel(
            load: { @MainActor in
                let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                let microphoneReady = microphone == .authorized
                let microphoneDetail: String
                switch microphone {
                case .authorized: microphoneDetail = "Granted for meetings and voice notes"
                case .notDetermined: microphoneDetail = "Not requested"
                case .denied: microphoneDetail = "Denied in System Settings"
                case .restricted: microphoneDetail = "Restricted by macOS policy"
                @unknown default: microphoneDetail = "Unknown"
                }
                let accessReady = AXIsProcessTrusted()
                let screenReady = CGPreflightScreenCaptureAccess()
                let mcp = await MCPStatusProbe.status(executableURL: mcpURL)
                return SetupSnapshot(
                    permissions: [
                        SetupStatusItem(
                            id: "accessibility", title: "Accessibility",
                            detail: accessReady ? "Granted for visible app context" : "Required for capture",
                            state: accessReady ? .ready : .attention,
                            actionTitle: accessReady ? nil : "Grant…"
                        ),
                        SetupStatusItem(
                            id: "microphone", title: "Microphone", detail: microphoneDetail,
                            state: microphoneReady ? .ready : .attention,
                            actionTitle: microphoneReady ? nil : "Request…"
                        ),
                        SetupStatusItem(
                            id: "screenRecording", title: "Screen Recording",
                            detail: screenReady ? "Granted for meeting system audio" : "Optional; meetings fall back to mic only",
                            state: screenReady ? .ready : .attention,
                            actionTitle: screenReady ? nil : "Request…"
                        ),
                    ],
                    encryption: SetupStatusItem(
                        id: "encryption", title: "Local encryption",
                        detail: encryptionOK ? "AES-256-GCM key available" : "Keychain key unavailable; capture is stopped",
                        state: encryptionOK ? .ready : .unavailable
                    ),
                    mcp: SetupStatusItem(
                        id: "mcp", title: "Claude MCP",
                        detail: mcp.claudeConnected ? "Connected to the bundled read-only server"
                            : (mcp.healthy ? "Server healthy; Claude is not connected to this path" : "Bundled server health check failed"),
                        state: mcp.claudeConnected ? .ready : (mcp.healthy ? .attention : .unavailable)
                    )
                )
            },
            onPermission: { @MainActor permission in
                switch permission {
                case .accessibility:
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    openPrivacySettings("Privacy_Accessibility")
                case .microphone:
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        _ = await MeetingPermissions().requestMicrophone()
                    } else {
                        openPrivacySettings("Privacy_Microphone")
                    }
                case .screenRecording:
                    if !CGRequestScreenCaptureAccess() { openPrivacySettings("Privacy_ScreenCapture") }
                }
            },
            onCopyMCPSetup: { @MainActor target in
                let text: String
                switch target {
                case .claudeCode:
                    text = "claude mcp add --scope user maxmi -- \"\(mcpURL.path)\""
                case .claudeDesktop:
                    text = "{ \"mcpServers\": { \"maxmi\": { \"command\": \"\(mcpURL.path)\" } } }"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return "Copied Claude setup to the clipboard"
            }
        )

        menuPopoverNavigation = MenuPopoverViewModel()

        // Purpose-built tray home: live state, recent summaries, and private lexical search.
        trayHomeViewModel = TrayHomeViewModel(
            loadStatus: { @MainActor [weak self] in
                guard let self else {
                    return TrayStatusDTO(state: .needsAttention, title: "MaxMi unavailable", detail: "Reopen MaxMi", captureCount: 0)
                }
                if !self.encryptionAvailable {
                    return TrayStatusDTO(
                        state: .needsAttention, title: "Memory is locked",
                        detail: "Open Settings for encryption status", captureCount: self.captureCount
                    )
                }
                if !self.menuBar.accessibilityGranted {
                    return TrayStatusDTO(
                        state: .needsAttention, title: "Accessibility required",
                        detail: "Grant permission in System Settings", captureCount: self.captureCount
                    )
                }
                if self.captureIsPaused(nowMs: epochNowMs()) {
                    return TrayStatusDTO(
                        state: .paused, title: "Capture paused",
                        detail: "Local memory is unchanged until you resume", captureCount: self.captureCount
                    )
                }
                let app = self.recentApps.first?.name
                return TrayStatusDTO(
                    state: .capturing,
                    title: app.map { "Watching \($0)" } ?? "MaxMi is capturing",
                    detail: self.lastSourceKey ?? "Waiting for an eligible window",
                    captureCount: self.captureCount
                )
            },
            search: { @Sendable query in
                try await Task.detached(priority: .userInitiated) {
                    try activityStore.searchLocalMemory(query: query, limit: 30).map { hit in
                        TraySearchResultDTO(
                            id: hit.threadID,
                            appLabel: hit.sourceApp,
                            title: hit.sourceTitle?.isEmpty == false ? hit.sourceTitle! : hit.sourceApp,
                            snippet: hit.snippet,
                            contentKind: hit.contentKind,
                            capturedAtMs: hit.capturedAtMs,
                            matchKind: hit.matchKind
                        )
                    }
                }.value
            }
        )
        let popoverController = NSHostingController(rootView: MenuPopoverView(
            navigation: menuPopoverNavigation,
            trayHomeViewModel: trayHomeViewModel,
            recentCapturesViewModel: recentCapturesViewModel,
            settingsViewModel: settingsViewModel,
            capturePrivacyViewModel: capturePrivacyViewModel,
            dataControlsViewModel: dataControlsViewModel,
            setupViewModel: setupViewModel,
            onTogglePause: { @MainActor [weak self] in
                self?.toggleGlobalPause()
            },
            onOpenMaxMi: { @MainActor [weak self] in self?.activityWindow.show() }
        ))
        popoverController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 650)
        menuBar.setPopoverContent(
            popoverController,
            onPrimaryShow: { [weak self] in self?.menuPopoverNavigation.showHome() }
        ) { [weak self] in
            Task {
                guard let self else { return }
                switch self.menuPopoverNavigation.page {
                case .home:
                    await recentCapturesViewModel.refresh()
                    await self.trayHomeViewModel.refresh()
                case .settings:
                    await settingsViewModel.refresh()
                    await capturePrivacyViewModel.refresh()
                    await setupViewModel.refresh()
                }
            }
        }
    }

    func start() {
        guard !isShuttingDown else { return }
        paused = (try? store.capturePauseState(nowMs: epochNowMs()).isPaused(at: epochNowMs())) ?? true
        menuBar.paused = paused
        if !didInstallMenu {
            didInstallMenu = true
            menuBar.install(
            onTogglePause: { [weak self] in self?.toggleGlobalPause() },
            onQuit: { NSApp.terminate(nil) },
            recentApps: { [weak self] in self?.recentApps ?? [] },
            pausedApps: { [weak self] in (try? self?.store.pausedApps()) ?? [] },
            onToggleAppPause: { [weak self] bundleID in
                guard let self else { return }
                let paused = (try? self.store.pausedApps().contains(bundleID)) ?? false
                try? self.store.setAppPaused(bundleID, paused: !paused, nowMs: epochNowMs())
            },
            lastSourceKey: { [weak self] in self?.lastSourceKey },
            onPauseCurrentThread: { [weak self] in
                guard let self, let key = self.lastSourceKey else { return }
                try? self.store.setThreadPaused(key, paused: true, nowMs: epochNowMs())
            },
            onOpenActivity: { [weak self] in self?.activityWindow.show() },
            onOpenCaptureHealth: { [weak self] in self?.captureHealthWindow.show() },
            onStartVoiceNote: { [weak self] in
                Task { await self?.meetingSession?.startVoiceNote() }
            },
            onOpenPrivacy: { [weak self] in self?.activityPrivacyWindow.show() },
            onOpenSettings: { [weak self] in
                guard let self else { return }
                self.menuPopoverNavigation.showSettings()
                DispatchQueue.main.async { [weak self] in self?.menuBar.showPopover() }
            }
            )
        }
        menuBar.encryptionAvailable = encryptionAvailable
        guard encryptionAvailable else { return }          // capture paused per §9
        do { try store.encryptExistingContent(nowMs: epochNowMs()) }   // §6: backfill before capture
        catch {
            SafeLogger.shared.log(.error, subsystem: .migration, event: .backfillFailed, error: error)
        }
        do { try store.bootstrapCloudProcessingReview(nowMs: epochNowMs()) }
        catch {
            SafeLogger.shared.log(
                .error, subsystem: .settings, event: .cloudReviewBootstrapFailed, error: error
            )
            paused = true
            menuBar.paused = true
            return
        }

        // Startup crash-repair for activity
        do {
            try store.closeOpenVisits(nowMs: epochNowMs())
            try store.closeOpenSessions(nowMs: epochNowMs())
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityCrashRepairFailed, error: error
            )
        }

        // Show privacy window on first run if consent is unset
        do {
            if try store.activityConsent() == .unset {
                activityPrivacyWindow.show()
            }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityConsentReadFailed, error: error
            )
        }

        installWorkspaceLifecycleObserversIfNeeded()

        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }  // re-checked by menu action
        guard self.observer == nil else { return }  // prevent double-start
        let observer = FocusObserver(
            recaptureIntervalForApp: { [registry] bid in
                // Dynamic/structured sources get a tighter safety sweep; AX events still
                // trigger capture sooner. Generic apps use a lower-cost fallback cadence.
                if ApplicationRegistry.isBrowser(bid) || registry.parser(for: bid) != nil { return 30 }
                return 60
            },
            isCapturable: { [registry] bid in
                // Capture-by-default: every app is capturable EXCEPT sensitive ones (System
                // Settings, password managers, keychain, banking). Browsers and registered
                // parsers always pass; everything else rides the generic fallback unless it's
                // on the sensitive-app denylist. (Was an allowlist — too narrow, missed Cursor/etc.)
                if ApplicationRegistry.isExcludedByDefault(bid) { return false }
                if ApplicationRegistry.isUnsupportedBrowserLike(bid) { return false }
                if ApplicationRegistry.isBrowser(bid) || registry.parser(for: bid) != nil { return true }
                return !Denylist.isSensitiveApp(bid)
            },
            onCapture: { [weak self] app, pid, trigger in
                self?.captureFrontmost(app: app, pid: pid, trigger: trigger)
            }
        )
        observer.onFocusChanged = { [weak self] app, isCapturable, pid in
            self?.handleFocusChange(app: app, isCapturable: isCapturable, pid: pid)
        }
        observer.start()
        self.observer = observer
        // Pipeline sweep every 30s: picks up idle/frozen versions and due retries (spec §3a sweeper).
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                await self.pipeline.tick()
                // Close idle activity sessions (5 min gap)
                _ = try? self.store.closeIdleSessions(idleGapMs: 5*60_000, nowMs: epochNowMs())
                // Summarize due sessions if activity enabled
                if self.isActivitySynthesisEnabled() {
                    await self.displaySummarizer.summarizeDue(nowMs: epochNowMs())

                    // Trigger agent when enough new summarized sessions exist
                    await self.triggerAgentIfNeeded()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pipelineTimer = t

        // Minimi-style display summaries are independent from the opt-in Activity timeline.
        // A short settle window in the repository prevents summarizing every keystroke.
        let summaryTimer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task {
                guard let self else { return }
                await self.captureDisplaySummarizer.summarizeDue(nowMs: epochNowMs())
            }
        }
        RunLoop.main.add(summaryTimer, forMode: .common)
        captureSummaryTimer = summaryTimer
        Task {
            await captureDisplaySummarizer.summarizeDue(nowMs: epochNowMs())
        }

        // Setup hourly background agent scheduler
        setupAgentBackgroundScheduler()

        // Run agent on launch if overdue (last run > 1h ago)
        Task { @MainActor in
            await self.runAgentIfOverdue()
        }

        // Meeting capture wiring — guarded by same availability as regular capture
        wireMeetingCapture()
    }

    private func handleFocusChange(app: AppInfo, isCapturable: Bool, pid: pid_t) {
        let nowMs = epochNowMs()

        // Bump generation on EVERY focus transition
        focusGeneration += 1

        // Close active session + all open visits (there should only be one, but closeOpenVisits is the clean approach)
        do {
            try store.closeActiveSession(nowMs: nowMs)
            try store.closeOpenVisits(nowMs: nowMs)
            currentVisitID = nil
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
            )
        }

        if !isCapturable {
            recordCaptureHealth(
                app: app,
                trigger: .appActivated,
                parser: "PolicyGate",
                outcome: .skipped(.excludedApp),
                startedAtMs: nowMs
            )
        }

        // Open new visit ONLY if eligible
        guard isActivityEligible(bundleID: app.bundleID) else { return }

        do {
            let visitID = try store.openVisit(appBundle: app.bundleID, appLabel: app.name, nowMs: nowMs)
            currentVisitID = visitID
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
            )
        }
    }

    private func isActivityEligible(bundleID: String) -> Bool {
        do {
            let consent = try store.activityConsent()
            let enabled = try store.activityEnabled()
            let excluded = try store.activityExcludedApps()

            return consent == .granted
                && enabled
                && !Denylist.isSensitiveApp(bundleID)
                && !excluded.contains(bundleID)
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityStateReadFailed, error: error
            )
            return false
        }
    }

    private func isActivitySynthesisEnabled() -> Bool {
        do {
            let consent = try store.activityConsent()
            let enabled = try store.activityEnabled()
            return consent == .granted && enabled
        } catch {
            return false
        }
    }

    private func installWorkspaceLifecycleObserversIfNeeded() {
        guard workspaceObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObserverTokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.suspendForWorkspaceLifecycle() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObserverTokens.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resumeFromWorkspaceLifecycle() }
            })
        }
    }

    private func suspendForWorkspaceLifecycle() async {
        guard !isShuttingDown, !isLifecycleSuspended else { return }
        isLifecycleSuspended = true
        observer?.stop()
        meetingDetector?.stop()
        await meetingSession?.interrupt()
        let nowMs = epochNowMs()
        try? store.closeOpenVisits(nowMs: nowMs)
        currentVisitID = nil
        try? store.closeActiveSession(nowMs: nowMs)
    }

    private func resumeFromWorkspaceLifecycle() {
        guard !isShuttingDown, isLifecycleSuspended else { return }
        isLifecycleSuspended = false
        if AXIsProcessTrusted() {
            observer?.start()
            meetingDetector?.start()
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        SafeLogger.shared.log(.info, subsystem: .app, event: .appCleanupStarted)

        pipelineTimer?.invalidate()
        pipelineTimer = nil
        captureSummaryTimer?.invalidate()
        captureSummaryTimer = nil
        agentBackgroundScheduler?.invalidate()
        agentBackgroundScheduler = nil
        meetingPreparationTask?.cancel()
        meetingPreparationTask = nil
        observer?.stop()
        observer = nil
        meetingDetector?.stop()
        meetingDetector = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach { center.removeObserver($0) }
        workspaceObserverTokens.removeAll()

        await meetingSession?.shutdown()
        meetingSession = nil
        rightLanePanel?.shutdown()
        rightLanePanel = nil

        let nowMs = epochNowMs()
        try? store.closeOpenVisits(nowMs: nowMs)
        try? store.closeOpenSessions(nowMs: nowMs)
        currentVisitID = nil

        SafeLogger.shared.log(.info, subsystem: .app, event: .appCleanupCompleted)
        SafeLogger.shared.log(.info, subsystem: .app, event: .appStopped)
    }

    private func wireMeetingCapture() {
        guard encryptionAvailable else { return }  // meetings also require encryption
        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }

        // Create model store
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxMi", isDirectory: true)
        let modelsDir = appSupport.appendingPathComponent("models", isDirectory: true)
        let modelStore = WhisperModelStore(dir: modelsDir)
        self.modelStore = modelStore

        // Create right-lane panel
        let panel = RightLanePanel()
        self.rightLanePanel = panel

        // Create persister
        let persister = StoreMeetingPersister(store: store)

        // Create session with all dependencies
        let session = MeetingSession(
            panel: panel,
            persister: persister,
            authorizer: MeetingPermissions(),
            makeCapture: { AudioCapture(mixer: AudioMixer()) },
            makeTranscriber: { WhisperTranscriber(modelURL: modelStore.modelURL) },
            clock: SystemMeetingClock(),
            stopGraceMs: 8_000,
            promptCooldownMs: 5_000,
            maxDurationMs: 4 * 60 * 60 * 1_000,
            lifecycleTracker: meetingLifecycleTracker
        )
        self.meetingSession = session

        // Wire panel button callbacks
        panel.onRecord = { [weak session] in
            Task {
                await session?.userAcceptedRecord()
            }
        }
        panel.onSkip = { [weak session] in
            Task {
                await session?.userSkipped()
            }
        }
        panel.onStop = { [weak session] in
            Task {
                await session?.userStopped()
            }
        }
        panel.onKeep = { [weak session] in
            Task {
                await session?.userKeptRecording()
            }
        }
        panel.onFinish = { [weak session] in
            Task {
                await session?.userStopped()
            }
        }

        // Ensure whisper model before arming detector
        meetingPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.meetingLifecycleTracker.recoverInterrupted() != nil {
                SafeLogger.shared.log(
                    .warning, subsystem: .meeting, event: .interruptedRecordingRecovered
                )
            }
            panel.showPreparing()
            do {
                try await modelStore.ensureModel { @Sendable remoteURL in
                    let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
                    return tempURL
                }
                panel.hidePanel()  // Model ready, hide preparing UI
                guard !Task.isCancelled, !self.isShuttingDown else { return }

                // Now start the detector
                let detector = MeetingDetector(browserURLProvider: { bundleID, pid in
                    guard let browser = ApplicationRegistry.browser(for: bundleID),
                          let snapshot = AXReader.snapshotFrontmostWindow(pid: pid),
                          let tab = try? BrowserTabExtractor.extract(
                            window: snapshot.window,
                            windowTitle: snapshot.title,
                            engine: browser.browserEngine
                          ) else { return nil }
                    return tab.url
                })
                self.meetingDetector = detector

                // Wire detector callbacks
                detector.onCandidate = { [weak session] bundleID, pid in
                    let title = AXReader.snapshotFrontmostWindow(pid: pid)?.title
                    Task {
                        await session?.candidateDetected(bundleID: bundleID, pid: pid, title: title)
                    }
                }
                detector.onEnded = { [weak session] bundleID in
                    Task {
                        await session?.inputStopped()
                    }
                }

                detector.start()
            } catch {
                SafeLogger.shared.log(
                    .error, subsystem: .meeting, event: .modelDownloadFailed, error: error
                )
                panel.showError("Failed to prepare transcription model")
            }
        }
    }

    func captureFrontmost(app: AppInfo, pid: pid_t, trigger: CaptureTrigger = .unknown) {
        guard !isShuttingDown, !isLifecycleSuspended else { return }
        let startedAtMs = epochNowMs()
        let parser = captureParserName(for: app.bundleID)
        guard !captureIsPaused(nowMs: startedAtMs) else {
            recordCaptureHealth(
                app: app, trigger: trigger, parser: parser,
                outcome: .skipped(.globalPaused), startedAtMs: startedAtMs
            )
            return
        }
        // Pause gate: fail closed on DB error (privacy-safe).
        do {
            if try store.pausedApps().contains(app.bundleID) {
                recordCaptureHealth(
                    app: app, trigger: trigger, parser: parser,
                    outcome: .skipped(.appPaused), startedAtMs: startedAtMs
                )
                return
            }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .capturePolicyReadFailed, error: error
            )
            recordCaptureHealth(
                app: app, trigger: trigger, parser: parser,
                outcome: .failed(.appPauseReadFailed), startedAtMs: startedAtMs
            )
            return
        }

        // Track recent apps on attempt (not just commit) so never-committing apps (e.g. WhatsApp shallow tree) can be paused.
        let entry = (bundleID: app.bundleID, name: app.name)
        if !recentApps.contains(where: { $0.bundleID == entry.bundleID }) {
            recentApps.insert(entry, at: 0)
            if recentApps.count > 8 { recentApps.removeLast() }
        }

        // Capture the current generation for this capture
        let gen = focusGeneration

        // Chromium browsers and Slack need retry-shortly for post-kick empty trees (spec §10).
        let needsRetry = ApplicationRegistry.needsAccessibilityWarmup(app.bundleID)
            || app.bundleID == ParserRegistry.slackBundleID
        let attemptsLeft = needsRetry ? 3 : 1
        attemptCapture(
            app: app, pid: pid, attemptsLeft: attemptsLeft,
            captureGeneration: gen, trigger: trigger, startedAtMs: startedAtMs
        )
    }

    private func attemptCapture(app: AppInfo, pid: pid_t, attemptsLeft: Int,
                                captureGeneration: Int, trigger: CaptureTrigger,
                                startedAtMs: EpochMs) {
        guard !isShuttingDown, !isLifecycleSuspended,
              !captureIsPaused(nowMs: epochNowMs()) else {
            recordCaptureHealth(
                app: app, trigger: trigger, parser: captureParserName(for: app.bundleID),
                outcome: .skipped(.globalPaused), startedAtMs: startedAtMs
            )
            return
        }
        // The AX tree read is synchronous cross-process IPC — for heavy trees (Mail ~3600 nodes)
        // it must NOT run on the main thread, or it freezes the menu-bar UI. Read off-main, then
        // resume on the main actor for the DB commit. AXNode is Sendable so the snapshot crosses
        // the actor boundary safely.
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = AXReader.snapshotFrontmostWindow(pid: pid)
            await self?.finishCapture(
                app: app, pid: pid, attemptsLeft: attemptsLeft, snapshot: snapshot,
                captureGeneration: captureGeneration, trigger: trigger, startedAtMs: startedAtMs
            )
        }
    }

    private func finishCapture(app: AppInfo, pid: pid_t, attemptsLeft: Int,
                               snapshot: (window: AXNode, title: String?)?, captureGeneration: Int,
                               trigger: CaptureTrigger, startedAtMs: EpochMs) {
        let parserName = captureParserName(for: app.bundleID)
        guard !isShuttingDown, !isLifecycleSuspended,
              !captureIsPaused(nowMs: epochNowMs()) else {
            recordCaptureHealth(
                app: app, trigger: trigger, parser: parserName,
                outcome: .skipped(.globalPaused), startedAtMs: startedAtMs
            )
            return
        }
        guard let (window, title) = snapshot else {
            retryOrGiveUp(
                app: app, pid: pid, attemptsLeft: attemptsLeft,
                captureGeneration: captureGeneration, trigger: trigger,
                startedAtMs: startedAtMs, terminalOutcome: .skipped(.noWindow)
            )
            return
        }

        // Build AppInfo with authoritative AXReader title
        let appInfo = AppInfo(bundleID: app.bundleID, name: app.name, windowTitle: title ?? app.windowTitle)

        do {
            let parsed: ParsedCapture?
            var effectiveParserName = parserName
            var browserTruncated = false

            // Browsers: engine-aware URL extraction followed by semantic web-app routing.
            if let browser = ApplicationRegistry.browser(for: app.bundleID) {
                let result = try BrowserCapturePipeline.parse(
                    window: window, windowTitle: title, browser: browser
                )
                effectiveParserName = result.parserID
                browserTruncated = result.truncated
                guard !Denylist.isBlockedWebURL(result.url) else {
                    recordCaptureHealth(
                        app: appInfo, trigger: trigger, parser: effectiveParserName,
                        outcome: .skipped(.blockedURL), startedAtMs: startedAtMs
                    )
                    return
                }
                do {
                    if Denylist.isBlockedByUser(result.url, blockedDomains: try store.blockedDomains()) {
                        recordCaptureHealth(
                            app: appInfo, trigger: trigger, parser: effectiveParserName,
                            outcome: .skipped(.userBlockedDomain), startedAtMs: startedAtMs
                        )
                        return
                    }
                } catch {
                    SafeLogger.shared.log(
                        .error, subsystem: .capture, event: .capturePolicyReadFailed, error: error
                    )
                    recordCaptureHealth(
                        app: appInfo, trigger: trigger, parser: effectiveParserName,
                        outcome: .failed(.privacySettingsReadFailed), startedAtMs: startedAtMs
                    )
                    return
                }
                parsed = result.capture
            } else {
                // Non-browsers: dispatch through CaptureDispatch
                switch CaptureDispatch.parseDetailed(window: window, app: appInfo, registry: registry) {
                case .parsed(let capture):
                    parsed = capture
                case .noContent:
                    retryOrGiveUp(
                        app: appInfo, pid: pid, attemptsLeft: attemptsLeft,
                        captureGeneration: captureGeneration, trigger: trigger,
                        startedAtMs: startedAtMs, terminalOutcome: .skipped(.parserNoContent)
                    )
                    return
                case .failed:
                    recordCaptureHealth(
                        app: appInfo, trigger: trigger, parser: parserName,
                        outcome: .failed(.parserFailed), startedAtMs: startedAtMs
                    )
                    return
                }
            }

            // Shared tail: guard parsed, check denylist + pause, commit
            guard let parsed else {
                retryOrGiveUp(
                    app: appInfo, pid: pid, attemptsLeft: attemptsLeft,
                    captureGeneration: captureGeneration, trigger: trigger,
                    startedAtMs: startedAtMs, terminalOutcome: .skipped(.parserNoContent)
                )
                return
            }

            // Central keying chokepoint: parsers propose a key; the deriver makes it clean+stable
            // (coarsen-don't-drop). No parser writes the final source_key directly (spec §3a).
            let cleanKey = ThreadKeyDeriver.derive(parsed)

            // Decision gate: denylist + per-thread pause. Fail closed on DB error.
            let pausedThreads: Set<String>
            do {
                pausedThreads = try store.pausedThreads()
            } catch {
                SafeLogger.shared.log(
                    .error, subsystem: .capture, event: .capturePolicyReadFailed, error: error
                )
                recordCaptureHealth(
                    app: appInfo, trigger: trigger, parser: effectiveParserName,
                    outcome: .failed(.threadPauseReadFailed), startedAtMs: startedAtMs
                )
                return
            }
            switch CaptureDispatch.decision(parsed: parsed, cleanKey: cleanKey, pausedThreads: pausedThreads) {
            case .blocked:
                recordCaptureHealth(
                    app: appInfo, trigger: trigger, parser: effectiveParserName,
                    outcome: .skipped(.blockedURL), startedAtMs: startedAtMs
                )
                return
            case .paused:
                recordCaptureHealth(
                    app: appInfo, trigger: trigger, parser: effectiveParserName,
                    outcome: .skipped(.pausedThread), startedAtMs: startedAtMs
                )
                return
            case .commit:
                break
            }
            let nowMs = epochNowMs()
            let wasTruncated = browserTruncated
                || (parsed.content.count >= 8_000 && Browser(rawValue: app.bundleID) == nil)
            let envelope = parsed.envelope(
                cleanSourceKey: cleanKey,
                parserID: effectiveParserName,
                trigger: trigger,
                truncated: wasTruncated
            )
            let result = try store.commitCapture(envelope, nowMs: nowMs)

            // After normal memory capture commits, record activity evidence ONLY if generation matches AND committed (not deduplicated)
            let eligible = isActivityEligible(bundleID: appInfo.bundleID)
            let cloudAllowed = (try? store.cloudProcessingState(for: parsed.sourceApp)) == .allowed
            if cloudAllowed && MaxMiCore.shouldRecordActivity(captureGeneration: captureGeneration, currentGeneration: focusGeneration, eligible: eligible) {
                // Only record activity for .committed captures (not deduplicated)
                if case .committed(let versionID, _) = result {
                    do {
                        _ = try store.recordActivityCapture(
                            appBundle: appInfo.bundleID,
                            appLabel: appInfo.name,
                            versionID: versionID,
                            content: parsed.content,
                            nowMs: nowMs
                        )
                    } catch {
                        SafeLogger.shared.log(
                            .error, subsystem: .activity, event: .activityCaptureFailed, error: error
                        )
                    }
                }
            }

            switch result {
            case .committed(let versionID, _):
                captureCount += 1
                menuBar.captureCount = captureCount
                lastSourceKey = cleanKey
                recordCaptureHealth(
                    app: appInfo, trigger: trigger, parser: effectiveParserName,
                    outcome: .captured(
                        versionID: versionID,
                        characterCount: parsed.content.count,
                        truncated: wasTruncated
                    ),
                    startedAtMs: startedAtMs
                )
            case .deduplicated:
                // Update lastSourceKey even on dedup so "Pause current thread" targets the right thread.
                lastSourceKey = cleanKey
                recordCaptureHealth(
                    app: appInfo, trigger: trigger, parser: effectiveParserName,
                    outcome: .deduplicated(
                        characterCount: parsed.content.count,
                        truncated: wasTruncated
                    ),
                    startedAtMs: startedAtMs
                )
            }
        } catch ExtractionError.addressFieldFocused {
            recordCaptureHealth(
                app: appInfo, trigger: trigger, parser: parserName,
                outcome: .skipped(.addressFieldFocused), startedAtMs: startedAtMs
            )
        } catch ExtractionError.emptyContent, ExtractionError.noWebArea,
                ExtractionError.noURL, ExtractionError.invalidURL {
            retryOrGiveUp(
                app: appInfo, pid: pid, attemptsLeft: attemptsLeft,
                captureGeneration: captureGeneration, trigger: trigger,
                startedAtMs: startedAtMs, terminalOutcome: .skipped(.emptyContent)
            )
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .captureCommitFailed, error: error
            )
            recordCaptureHealth(
                app: appInfo, trigger: trigger, parser: parserName,
                outcome: .failed(.storeCommitFailed), startedAtMs: startedAtMs
            )
        }
    }

    private func captureIsPaused(nowMs: EpochMs) -> Bool {
        do {
            let persisted = try store.capturePauseState(nowMs: nowMs).isPaused(at: nowMs)
            paused = persisted
            menuBar.paused = persisted
            return persisted
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .capturePauseReadFailed, error: error
            )
            paused = true
            menuBar.paused = true
            return true
        }
    }

    private func toggleGlobalPause() {
        let nowMs = epochNowMs()
        do {
            if try store.capturePauseState(nowMs: nowMs).isPaused(at: nowMs) {
                try store.clearCapturePause(nowMs: nowMs)
                paused = false
            } else {
                try store.setCapturePaused(untilMs: nil, nowMs: nowMs)
                paused = true
            }
            menuBar.paused = paused
            Task { await trayHomeViewModel?.refresh() }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .capturePauseWriteFailed, error: error
            )
            paused = true
            menuBar.paused = true
        }
    }

    private func retryOrGiveUp(app: AppInfo, pid: pid_t, attemptsLeft: Int,
                               captureGeneration: Int, trigger: CaptureTrigger,
                               startedAtMs: EpochMs, terminalOutcome: CaptureOutcome) {
        guard attemptsLeft > 1 else {
            recordCaptureHealth(
                app: app, trigger: trigger, parser: captureParserName(for: app.bundleID),
                outcome: terminalOutcome, startedAtMs: startedAtMs
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptCapture(
                app: app, pid: pid, attemptsLeft: attemptsLeft - 1,
                captureGeneration: captureGeneration, trigger: .retry,
                startedAtMs: epochNowMs()
            )
        }
    }

    private func captureParserName(for bundleID: String) -> String {
        if let browser = ApplicationRegistry.browser(for: bundleID) {
            return "BrowserWeb.v2/\(browser.browserEngine?.rawValue ?? "unknown")"
        }
        return registry.parserName(for: bundleID)
    }

    private func recordCaptureHealth(
        app: AppInfo,
        trigger: CaptureTrigger,
        parser: String,
        outcome: CaptureOutcome,
        startedAtMs: EpochMs
    ) {
        let nowMs = epochNowMs()
        do {
            try store.recordCaptureHealth(
                appBundle: app.bundleID,
                appLabel: app.name,
                trigger: trigger,
                parser: parser,
                outcome: outcome,
                durationMs: Int(max(0, nowMs - startedAtMs)),
                atMs: nowMs
            )
        } catch {
            // Diagnostics must never break capture or recursively record their own failure.
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .captureHealthWriteFailed
            )
        }
    }

    // MARK: - Agent Scheduling

    private func setupAgentBackgroundScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.maxmi.agent.hourly")
        scheduler.interval = 60 * 60  // ~1 hour
        scheduler.tolerance = 10 * 60  // 10 min tolerance
        scheduler.repeats = true
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }

                // Gate on consent + enabled
                guard self.isActivitySynthesisEnabled() else {
                    completion(.finished)
                    return
                }

                await self.agentScheduler.tick()
                completion(.finished)
            }
        }

        agentBackgroundScheduler = scheduler
    }

    private func runAgentIfOverdue() async {
        guard isActivitySynthesisEnabled() else { return }

        // Check last agent run time
        do {
            let nowMs = epochNowMs()
            let oneHourAgo = nowMs - (60 * 60 * 1000)

            // Query last completed run
            let lastRunMs = try store.lastAgentRunStartedAt()

            // If no run or last run > 1h ago, trigger now
            if lastRunMs == nil || lastRunMs! < oneHourAgo {
                await agentScheduler.tick()
            }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .agent, event: .agentStatusReadFailed, error: error
            )
        }
    }

    private func triggerAgentIfNeeded() async {
        guard isActivitySynthesisEnabled() else { return }

        do {
            // Count summarized sessions since last check
            let summarizedCount = try store.summarizedSessionCount()

            // Trigger when >= 10 new summarized sessions exist
            let newCount = summarizedCount - lastSummarizedCount
            if newCount >= 10 {
                await agentScheduler.tick()
                lastSummarizedCount = summarizedCount
            }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .agent, event: .agentStatusReadFailed, error: error
            )
        }
    }
}

// MARK: - AgentScheduler Actor

actor AgentScheduler {
    private let agent: HourlyAgent
    private var running = false
    private var nextRetryAt: EpochMs?
    private let initialBackoffMs: EpochMs = 60_000  // 1 minute
    private let maxBackoffMs: EpochMs = 30 * 60_000  // 30 minutes
    private var currentBackoffMs: EpochMs = 60_000

    init(agent: HourlyAgent) {
        self.agent = agent
    }

    func tick() async {
        // Early return if already running (synchronous guard before first await)
        guard !running else { return }

        // Check backoff
        if let retryAt = nextRetryAt {
            let nowMs = epochNowMs()
            guard nowMs >= retryAt else { return }
        }

        // Set running flag BEFORE first await
        running = true
        defer { running = false }

        // Clear retry backoff on successful start
        nextRetryAt = nil
        currentBackoffMs = initialBackoffMs

        // Run the agent (may process multiple pages)
        // Note: HourlyAgent internally handles errors by calling repo.fail()
        await agent.runIfDue()
    }
}
