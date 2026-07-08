import Foundation
import AppKit
import MaxMiCore
import MaxMiStore
import MaxMiCapture
import MaxMiRelay

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

// Known-capturable apps that use generic fallback (spec §3).
private let KnownApps: Set<String> = [
    "net.whatsapp.WhatsApp",
    "com.apple.Notes",
    "notion.id",
    "md.obsidian",
    "com.apple.mail"
]

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
        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }  // re-checked by menu action
        guard self.observer == nil else { return }  // prevent double-start
        let observer = FocusObserver(
            isCapturable: { [registry] bid in
                Browser(rawValue: bid) != nil || registry.parser(for: bid) != nil || KnownApps.contains(bid)
            },
            onCapture: { [weak self] app, pid in
                self?.captureFrontmost(app: app, pid: pid)
            }
        )
        observer.start()
        self.observer = observer
        // Pipeline sweep every 30s: picks up idle/frozen versions and due retries (spec §3a sweeper).
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                await self.pipeline.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pipelineTimer = t
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

        // Chromium browsers and Slack need retry-shortly for post-kick empty trees (spec §10).
        let needsRetry = Browser(rawValue: app.bundleID)?.isChromium == true || app.bundleID == ParserRegistry.slackBundleID
        let attemptsLeft = needsRetry ? 3 : 1
        attemptCapture(app: app, pid: pid, attemptsLeft: attemptsLeft)
    }

    private func attemptCapture(app: AppInfo, pid: pid_t, attemptsLeft: Int) {
        guard !paused else { return }
        guard let (window, title) = AXReader.snapshotFrontmostWindow(pid: pid) else {
            retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft); return
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
                retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft)
                return
            }

            // Decision gate: denylist + per-thread pause. Fail closed on DB error.
            let pausedThreads: Set<String>
            do {
                pausedThreads = try store.pausedThreads()
            } catch {
                NSLog("MaxMi: pausedThreads read failed, skipping capture: \(error)")
                return
            }
            guard CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: pausedThreads) else { return }

            let result = try store.commitCapture(
                CaptureInput(sourceApp: parsed.sourceApp, sourceKey: parsed.sourceKey,
                            sourceTitle: parsed.sourceTitle, content: parsed.content),
                nowMs: epochNowMs())

            switch result {
            case .committed:
                captureCount += 1
                menuBar.captureCount = captureCount
                lastSourceKey = parsed.sourceKey
            case .deduplicated:
                // Update lastSourceKey even on dedup so "Pause current thread" targets the right thread.
                lastSourceKey = parsed.sourceKey
            }
        } catch ExtractionError.emptyContent, ExtractionError.noWebArea, ExtractionError.noURL {
            // Browser extraction errors: retry
            retryOrGiveUp(app: app, pid: pid, attemptsLeft: attemptsLeft)
        } catch {
            NSLog("MaxMi capture skipped: \(error)")             // logged, skipped, never crash (spec §10)
        }
    }

    private func retryOrGiveUp(app: AppInfo, pid: pid_t, attemptsLeft: Int) {
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptCapture(app: app, pid: pid, attemptsLeft: attemptsLeft - 1)
        }
    }
}
