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
            onQuit: { NSApp.terminate(nil) }
        )
        menuBar.encryptionAvailable = encryptionAvailable
        guard encryptionAvailable else { return }          // capture paused per §9
        do { try store.encryptExistingContent(nowMs: epochNowMs()) }   // §6: backfill before capture
        catch { NSLog("MaxMi: backfill failed, will retry next launch: \(error)") }
        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }  // re-checked by menu action
        guard self.observer == nil else { return }  // prevent double-start
        let observer = FocusObserver { [weak self] browser, pid in
            self?.captureFrontmost(browser: browser, pid: pid)
        }
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

    func captureFrontmost(browser: Browser, pid: pid_t) {
        guard !paused else { return }
        // Chromium post-kick: empty tree is "retry shortly", NOT a failed capture (spec §10).
        attemptCapture(browser: browser, pid: pid, attemptsLeft: browser.isChromium ? 3 : 1)
    }

    private func attemptCapture(browser: Browser, pid: pid_t, attemptsLeft: Int) {
        guard !paused else { return }
        guard let (window, title) = AXReader.snapshotFrontmostWindow(pid: pid) else {
            retryOrGiveUp(browser: browser, pid: pid, attemptsLeft: attemptsLeft); return
        }
        do {
            let cap = try BrowserTabExtractor.extract(window: window, windowTitle: title)
            guard !Denylist.isBlocked(cap.url) else { return }   // dropped, never stored (spec §5)
            let result = try store.commitCapture(
                CaptureInput(sourceApp: "Web", sourceKey: cap.url, sourceTitle: cap.title, content: cap.content),
                nowMs: epochNowMs())
            if case .committed = result {
                captureCount += 1
                menuBar.captureCount = captureCount
            }
        } catch ExtractionError.emptyContent, ExtractionError.noWebArea, ExtractionError.noURL {
            retryOrGiveUp(browser: browser, pid: pid, attemptsLeft: attemptsLeft)
        } catch {
            NSLog("MaxMi capture skipped: \(error)")             // logged, skipped, never crash (spec §10)
        }
    }

    private func retryOrGiveUp(browser: Browser, pid: pid_t, attemptsLeft: Int) {
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptCapture(browser: browser, pid: pid, attemptsLeft: attemptsLeft - 1)
        }
    }
}
