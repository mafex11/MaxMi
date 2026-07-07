import Foundation

public actor CapturePipeline {
    let store: any MemoryStore
    let relay: any MemoryRelay
    let idleThresholdMs: EpochMs
    let clock: @Sendable () -> EpochMs

    public init(store: any MemoryStore, relay: any MemoryRelay,
                idleThresholdMs: EpochMs = 300_000,
                clock: @escaping @Sendable () -> EpochMs = epochNowMs) {
        self.store = store; self.relay = relay
        self.idleThresholdMs = idleThresholdMs; self.clock = clock
    }

    /// One sweep. Called by the app's timer and after freezes. Never throws; errors route to the retry queue.
    public func tick() async {
        let now = clock()
        // Retry queue is a wake-up list: clear due rows; their versions re-qualify via pendingWork.
        if let due = try? store.dueRetries(nowMs: now) {
            for r in due { try? store.clearRetry(id: r.id) }
        }
        guard let work = try? store.pendingWork(nowMs: now, idleThresholdMs: idleThresholdMs) else { return }
        for v in work { await process(v, now: now) }
    }

    private func process(_ v: PipelineVersion, now: EpochMs) async {
        do {
            let facts = try await relay.extract(newContent: v.content,
                                                previousContent: v.previousFrozenContent,
                                                sourceApp: v.sourceApp, sourceKey: v.sourceKey)
            let fresh = try store.insertDerivatives(versionID: v.id, threadID: v.threadID,
                                                    facts: facts, nowMs: now)
            // fresh + anything a previous crashed/failed run left pending
            var toEmbed = fresh
            let freshIDs = Set(fresh.map(\.id))
            toEmbed += (try store.pendingDerivatives(versionID: v.id)).filter { !freshIDs.contains($0.id) }
            for d in toEmbed {
                let vec = try await relay.embed(text: d.content)
                try store.insertEmbedding(derivativeID: d.id, vector: vec)
                try store.markEmbedded(derivativeID: d.id)
            }
            // Hash guard (§3a): false = content moved mid-flight; stays pending for next tick.
            _ = try store.markExtracted(versionID: v.id, contentHashRead: v.contentHash)
        } catch let e as RelayError {
            if case .malformedResponse = e { try? store.markExtractFailed(versionID: v.id) }
            try? store.enqueueRetry(kind: "extract", versionID: v.id, derivativeID: nil,
                                    error: String(describing: e), nowMs: now)
        } catch {
            try? store.enqueueRetry(kind: "extract", versionID: v.id, derivativeID: nil,
                                    error: String(describing: error), nowMs: now)
        }
    }
}
