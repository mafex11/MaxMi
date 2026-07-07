import Foundation
import MaxMiCore
import MaxMiStore

public final class MemoryQueries: @unchecked Sendable {
    /// vec0 cosine distance (1 - similarity). Hits above this are noise, not memory.
    /// Empirically tunable; 0.75 keeps similarity >= 0.25.
    public static let similarityDistanceFloor = 0.75
    static let hardCap = 20
    static let searchDefault = 10
    static let listDefault = 10
    static let lruCapacity = 32

    static let offlineText = "Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected."
    static let noDBText = "MaxMi hasn't captured anything yet — is the menu-bar app running?"
    static let stubText = "No meetings captured yet — meeting capture is a later MaxMi milestone. Use search_memory for everything read on screen."

    let store: Store
    let relay: any MemoryRelay
    let now: @Sendable () -> Date
    private var lruKeys: [String] = []              // most recent last
    private var lruVectors: [String: [Float]] = [:]
    private let lruLock = NSLock()

    public init(store: Store, relay: any MemoryRelay,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.relay = relay; self.now = now
    }

    public func searchMemory(query: String, limit: Int?) async -> ToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolResult(text: "query must not be empty", isError: true) }
        let k = min(max(limit ?? Self.searchDefault, 1), Self.hardCap)

        let vector: [Float]
        if let cached = lruGet(q) {
            vector = cached
        } else {
            do { vector = try await relay.embed(text: q) }
            catch {
                logStderr("embed failed: \(error)")
                return ToolResult(text: Self.offlineText, isError: true)
            }
            lruPut(q, vector)
        }

        do {
            let hits = try store.factHits(near: vector, limit: k)
                .filter { $0.distance <= Self.similarityDistanceFloor }
            let total = try store.totalFactCount()
            guard !hits.isEmpty else {
                let hint = total > 0
                    ? "Nothing sufficiently similar. Try different wording, or list_active_threads for recent activity."
                    : ""
                return ToolResult(text: "No memories matched \"\(q)\".\(hint.isEmpty ? "" : " \(hint)")")
            }
            var md = "## Memory search: \"\(q)\"\n\n"
            for h in hits {
                md += "- \(h.content)\n  — \(h.sourceTitle ?? h.sourceKey) (\(h.sourceKey)), \(relative(h.committedAt))\n"
            }
            md += "\n_\(hits.count) results (of \(total) memories)_"
            return ToolResult(text: md)
        } catch {
            return ToolResult(text: "Memory database unavailable: \(error)", isError: true)
        }
    }

    func relative(_ ms: EpochMs) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "en_US")
        f.dateTimeStyle = .named
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: now())
    }

    private func lruGet(_ key: String) -> [Float]? {
        lruLock.lock(); defer { lruLock.unlock() }
        guard let v = lruVectors[key] else { return nil }
        lruKeys.removeAll { $0 == key }; lruKeys.append(key)
        return v
    }
    private func lruPut(_ key: String, _ vector: [Float]) {
        lruLock.lock(); defer { lruLock.unlock() }
        lruVectors[key] = vector
        lruKeys.removeAll { $0 == key }; lruKeys.append(key)
        if lruKeys.count > Self.lruCapacity {
            lruVectors.removeValue(forKey: lruKeys.removeFirst())
        }
    }

    public func listActiveThreads(limit: Int?) -> ToolResult {
        let k = min(max(limit ?? Self.listDefault, 1), Self.hardCap)
        do {
            let threads = try store.recentThreads(limit: k)
            guard !threads.isEmpty else { return ToolResult(text: Self.noDBText) }
            var md = "## Recently active threads\n"
            for t in threads {
                md += "\n### \(t.sourceTitle ?? t.sourceKey)\n\(t.sourceKey) — last seen \(relative(t.updatedAt))\n"
                for f in t.recentFacts { md += "- \(f)\n" }
                if t.recentFacts.isEmpty { md += "_(no facts extracted yet)_\n" }
            }
            return ToolResult(text: md)
        } catch {
            return ToolResult(text: "Memory database unavailable: \(error)", isError: true)
        }
    }

    public func meetingMemory(action: String) -> ToolResult {
        ToolResult(text: Self.stubText)
    }
}
