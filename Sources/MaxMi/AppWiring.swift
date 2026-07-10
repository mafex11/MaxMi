import Foundation
import AppKit
import MaxMiCore
import MaxMiStore
import MaxMiCapture
import MaxMiRelay
import MaxMiActivity
import MaxMiMeetings

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

    // Activity focus-generation mechanism
    var focusGeneration: Int = 0
    var currentVisitID: String?
    let displaySummarizer: DisplaySummarizer

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxMi", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        // Spec §6/§9: keep plaintext memories out of Time Machine.
        var dir = appSupport
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)

        let config = EnvConfig.load(searchPaths: [
            appSupport.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ])
        let db = try MaxMiDatabase(path: appSupport.appendingPathComponent("maxmi.db").path)
        // Spec §6 ordering: key -> backfill -> capture. No key => capture stays paused
        // and we never write plaintext post-M3 (spec §9).
        let cipher: any FieldCipher
        var encryptionAvailable = true
        do {
            cipher = AESGCMFieldCipher(keyData: try KeychainKeyStore.getOrCreate())
        } catch {
            NSLog("MaxMi: encryption key unavailable: \(error)")
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
        menuBar.hasAPIKey = config.geminiAPIKey != nil
        let activityRepo = StoreActivitySummaryRepository(store: store)
        let activityRelay = GeminiActivityRelay(geminiClient: relay)
        displaySummarizer = DisplaySummarizer(repo: activityRepo, relay: activityRelay)
    }

    func start() {
        menuBar.install(
            onTogglePause: { [weak self] in self?.paused.toggle(); self?.menuBar.paused = self?.paused ?? false },
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
            }
        )
        menuBar.encryptionAvailable = encryptionAvailable
        guard encryptionAvailable else { return }          // capture paused per §9
        do { try store.encryptExistingContent(nowMs: epochNowMs()) }   // §6: backfill before capture
        catch { NSLog("MaxMi: backfill failed, will retry next launch: \(error)") }

        // Startup crash-repair for activity
        do {
            try store.closeOpenVisits(nowMs: epochNowMs())
            try store.closeOpenSessions(nowMs: epochNowMs())
        } catch {
            NSLog("MaxMi: activity startup crash-repair failed: \(error)")
        }

        // Sleep/lock notification for activity
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let nowMs = epochNowMs()
                if let visitID = self.currentVisitID {
                    try? self.store.closeSession(visitID, nowMs: nowMs)
                    self.currentVisitID = nil
                }
                try? self.store.closeActiveSession(nowMs: nowMs)
            }
        }

        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }  // re-checked by menu action
        guard self.observer == nil else { return }  // prevent double-start
        let observer = FocusObserver(
            isCapturable: { [registry] bid in
                // Capture-by-default: every app is capturable EXCEPT sensitive ones (System
                // Settings, password managers, keychain, banking). Browsers and registered
                // parsers always pass; everything else rides the generic fallback unless it's
                // on the sensitive-app denylist. (Was an allowlist — too narrow, missed Cursor/etc.)
                if Browser(rawValue: bid) != nil || registry.parser(for: bid) != nil { return true }
                return !Denylist.isSensitiveApp(bid)
            },
            onCapture: { [weak self] app, pid in
                self?.captureFrontmost(app: app, pid: pid)
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
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pipelineTimer = t

        // Meeting capture wiring — guarded by same availability as regular capture
        wireMeetingCapture()
    }

    private func handleFocusChange(app: AppInfo, isCapturable: Bool, pid: pid_t) {
        let nowMs = epochNowMs()

        // Bump generation on EVERY focus transition
        focusGeneration += 1

        // Close active session + prior visit
        do {
            try store.closeActiveSession(nowMs: nowMs)
            if let visitID = currentVisitID {
                try store.closeSession(visitID, nowMs: nowMs)
                currentVisitID = nil
            }
        } catch {
            NSLog("MaxMi: activity close failed on focus change: \(error)")
        }

        // Open new visit ONLY if eligible
        guard isActivityEligible(bundleID: app.bundleID) else { return }

        do {
            let visitID = try store.openVisit(appBundle: app.bundleID, appLabel: app.name, nowMs: nowMs)
            currentVisitID = visitID
        } catch {
            NSLog("MaxMi: activity visit open failed: \(error)")
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
            NSLog("MaxMi: activity eligibility check failed: \(error)")
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
            clock: SystemMeetingClock()
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
        Task { @MainActor in
            panel.showPreparing()
            do {
                try await modelStore.ensureModel { @Sendable remoteURL in
                    let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
                    return tempURL
                }
                panel.hidePanel()  // Model ready, hide preparing UI

                // Now start the detector
                let detector = MeetingDetector()
                self.meetingDetector = detector

                // Wire detector callbacks
                detector.onCandidate = { [weak session] bundleID, pid in
                    Task {
                        await session?.candidateDetected(bundleID: bundleID, pid: pid, title: nil)
                    }
                }
                detector.onEnded = { [weak session] bundleID in
                    Task {
                        await session?.inputStopped()
                    }
                }

                detector.start()
            } catch {
                NSLog("MaxMi: whisper model download failed: \(error)")
                panel.showError("Failed to prepare transcription model")
            }
        }
    }

    func captureFrontmost(app: AppInfo, pid: pid_t) {
        guard !paused else { return }
        // Pause gate: fail closed on DB error (privacy-safe).
        do {
            if try store.pausedApps().contains(app.bundleID) { return }
        } catch {
            NSLog("MaxMi: pausedApps read failed, skipping capture: \(error)")
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
        let needsRetry = Browser(rawValue: app.bundleID)?.isChromium == true || app.bundleID == ParserRegistry.slackBundleID
        let attemptsLeft = needsRetry ? 3 : 1
        attemptCapture(app: app, pid: pid, attemptsLeft: attemptsLeft, captureGeneration: gen)
    }

    private func attemptCapture(app: AppInfo, pid: pid_t, attemptsLeft: Int, captureGeneration: Int) {
        guard !paused else { return }
        // The AX tree read is synchronous cross-process IPC — for heavy trees (Mail ~3600 nodes)
        // it must NOT run on the main thread, or it freezes the menu-bar UI. Read off-main, then
        // resume on the main actor for the DB commit. AXNode is Sendable so the snapshot crosses
        // the actor boundary safely.
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = AXReader.snapshotFrontmostWindow(pid: pid)
            await self?.finishCapture(app: app, pid: pid, attemptsLeft: attemptsLeft, snapshot: snapshot, captureGeneration: captureGeneration)
        }
    }

    private func finishCapture(app: AppInfo, pid: pid_t, attemptsLeft: Int,
                               snapshot: (window: AXNode, title: String?)?, captureGeneration: Int) {
        guard !paused else { return }
        guard let (window, title) = snapshot else {
            retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft, captureGeneration: captureGeneration); return
        }

        // Build AppInfo with authoritative AXReader title
        let appInfo = AppInfo(bundleID: app.bundleID, name: app.name, windowTitle: title ?? app.windowTitle)

        do {
            let parsed: ParsedCapture?

            // Browsers: preserve exact behavior using BrowserTabExtractor
            if Browser(rawValue: app.bundleID) != nil {
                let cap = try BrowserTabExtractor.extract(window: window, windowTitle: title)
                guard !Denylist.isBlockedWebURL(cap.url) else { return }
                // Normalize the URL into a stable thread key so volatile URL state (map coords,
                // tracking params, doc tabs) doesn't fracture one page into many threads.
                let key = URLKeyNormalizer.normalize(cap.url)
                parsed = ParsedCapture(sourceApp: "Web", sourceKey: key, sourceTitle: cap.title, content: cap.content)
            } else {
                // Non-browsers: dispatch through CaptureDispatch
                parsed = CaptureDispatch.parse(window: window, app: appInfo, registry: registry)
            }

            // Shared tail: guard parsed, check denylist + pause, commit
            guard let parsed else {
                retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft, captureGeneration: captureGeneration)
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
                NSLog("MaxMi: pausedThreads read failed, skipping capture: \(error)")
                return
            }
            guard CaptureDispatch.shouldCommit(parsed: parsed, cleanKey: cleanKey, pausedThreads: pausedThreads) else { return }
            let nowMs = epochNowMs()
            let result = try store.commitCapture(
                CaptureInput(sourceApp: parsed.sourceApp, sourceKey: cleanKey,
                            sourceTitle: parsed.sourceTitle, content: parsed.content),
                nowMs: nowMs)

            // After normal memory capture commits, record activity evidence ONLY if generation matches
            let eligible = isActivityEligible(bundleID: appInfo.bundleID)
            if shouldRecordActivity(captureGeneration: captureGeneration, currentGeneration: focusGeneration, eligible: eligible) {
                do {
                    let vid: String?
                    switch result {
                    case .committed(let versionID, _): vid = versionID
                    case .deduplicated: vid = nil
                    }
                    _ = try store.recordActivityCapture(
                        appBundle: appInfo.bundleID,
                        appLabel: appInfo.name,
                        versionID: vid,
                        content: parsed.content,
                        nowMs: nowMs
                    )
                } catch {
                    NSLog("MaxMi: activity capture failed: \(error)")
                }
            }

            switch result {
            case .committed:
                captureCount += 1
                menuBar.captureCount = captureCount
                lastSourceKey = cleanKey
            case .deduplicated:
                // Update lastSourceKey even on dedup so "Pause current thread" targets the right thread.
                lastSourceKey = cleanKey
            }
        } catch ExtractionError.emptyContent, ExtractionError.noWebArea, ExtractionError.noURL {
            // Browser extraction errors: retry
            retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft, captureGeneration: captureGeneration)
        } catch {
            NSLog("MaxMi capture skipped: \(error)")             // logged, skipped, never crash (spec §10)
        }
    }

    private func retryOrGiveUp(app: AppInfo, pid: pid_t, attemptsLeft: Int, captureGeneration: Int) {
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptCapture(app: app, pid: pid, attemptsLeft: attemptsLeft - 1, captureGeneration: captureGeneration)
        }
    }
}
