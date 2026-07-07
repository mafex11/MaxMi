import Foundation
import GRDB
import MaxMiCore

public struct FactHit: Sendable, Equatable {
    public let content: String
    /// Cosine distance (1 − cosine similarity), derived from vec0 L2 on unit vectors.
    public let distance: Double
    public let sourceTitle: String?
    public let sourceKey: String
    public let committedAt: EpochMs
}

public struct ThreadSummary: Sendable, Equatable {
    public let sourceTitle: String?
    public let sourceKey: String
    public let updatedAt: EpochMs
    public let recentFacts: [String]
}

extension Store {
    /// KNN over derivative embeddings joined back to fact + thread. Distance ascending.
    public func factHits(near vector: [Float], limit: Int) throws -> [FactHit] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT dv.content, e.distance, t.source_title, t.source_key, dv.committed_at
                FROM (SELECT derivative_id, distance FROM derivative_embeddings
                      WHERE embedding MATCH ? AND k = ?) e
                JOIN derivatives dv ON dv.id = e.derivative_id
                JOIN threads t ON t.id = dv.thread_id
                ORDER BY e.distance
                """, arguments: [blob, limit])
                .map { row in
                    // vec0 table uses L2 distance (default when no distance_metric specified).
                    // All vectors are unit-normalized, so L2 = sqrt(2 − 2·cos_sim).
                    // Convert to cosine distance via: cosine_distance = L2² / 2
                    let l2: Double = row["distance"]
                    let cosineDistance = (l2 * l2) / 2.0
                    return FactHit(content: decryptOrMarker(row["content"]), distance: cosineDistance,
                                   sourceTitle: row["source_title"], sourceKey: row["source_key"],
                                   committedAt: row["committed_at"])
                }
        }
    }

    /// Threads by recency; each carries its OWN 3 latest facts (per-thread, not global).
    public func recentThreads(limit: Int) throws -> [ThreadSummary] {
        try db.dbQueue.read { d in
            let threads = try Row.fetchAll(d, sql: """
                SELECT id, source_title, source_key, updated_at
                FROM threads ORDER BY updated_at DESC LIMIT ?
                """, arguments: [limit])
            return try threads.map { t in
                let facts = try String.fetchAll(d, sql: """
                    SELECT content FROM derivatives WHERE thread_id = ?
                    ORDER BY committed_at DESC LIMIT 3
                    """, arguments: [t["id"] as String])
                return ThreadSummary(sourceTitle: t["source_title"], sourceKey: t["source_key"],
                                     updatedAt: t["updated_at"], recentFacts: facts.map(decryptOrMarker))
            }
        }
    }

    public func totalFactCount() throws -> Int {
        try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM derivatives") ?? 0 }
    }

    /// Test/support helper: thread id for a source_key (any app).
    public func threadID(forKey key: String) throws -> String {
        try db.dbQueue.read {
            guard let tid = try String.fetchOne($0, sql: "SELECT id FROM threads WHERE source_key = ?", arguments: [key]) else {
                throw DatabaseError(message: "no thread for key \(key)")
            }
            return tid
        }
    }
}
