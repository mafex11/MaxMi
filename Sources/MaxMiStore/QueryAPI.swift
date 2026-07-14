import Foundation
import GRDB
import MaxMiCore

public struct FactHit: Sendable, Equatable {
    public let id: String
    public let content: String
    /// Cosine distance (1 − cosine similarity), derived from vec0 L2 on unit vectors.
    public let distance: Double
    public let sourceTitle: String?
    public let sourceApp: String
    public let sourceKey: String
    public let threadID: String
    public let committedAt: EpochMs
}

public struct ThreadSummary: Sendable, Equatable {
    public let id: String
    public let sourceApp: String
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
                SELECT dv.id AS derivative_id, dv.content, e.distance,
                       t.id AS thread_id, t.source_app, t.source_title, t.source_key,
                       dv.committed_at
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
                    return FactHit(id: row["derivative_id"], content: decryptOrMarker(row["content"]), distance: cosineDistance,
                                   sourceTitle: row["source_title"], sourceApp: row["source_app"],
                                   sourceKey: row["source_key"], threadID: row["thread_id"],
                                   committedAt: row["committed_at"])
                }
        }
    }

    /// Threads by recency; each carries its OWN 3 latest facts (per-thread, not global).
    public func recentThreads(limit: Int) throws -> [ThreadSummary] {
        try db.dbQueue.read { d in
            let threads = try Row.fetchAll(d, sql: """
                SELECT id, source_app, source_title, source_key, updated_at
                FROM threads ORDER BY updated_at DESC LIMIT ?
                """, arguments: [limit])
            return try threads.map { t in
                let facts = try String.fetchAll(d, sql: """
                    SELECT content FROM derivatives WHERE thread_id = ?
                    ORDER BY committed_at DESC LIMIT 3
                    """, arguments: [t["id"] as String])
                return ThreadSummary(id: t["id"], sourceApp: t["source_app"],
                                     sourceTitle: t["source_title"], sourceKey: t["source_key"],
                                     updatedAt: t["updated_at"], recentFacts: facts.map(decryptOrMarker))
            }
        }
    }

    public func totalFactCount() throws -> Int {
        try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM derivatives") ?? 0 }
    }

    /// Deterministic semantic page. The KNN candidate set is frozen by `endAtMs`,
    /// while offset pagination is stabilized by a cursor-owned `as_of` boundary.
    public func factHits(
        near vector: [Float],
        filter: RetrievalFilter,
        offset: Int,
        limit: Int
    ) throws -> RetrievalPage<FactHit> {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), 100)
        return try db.dbQueue.read { d in
            let embeddingCount = try Int.fetchOne(d, sql: "SELECT count(*) FROM derivative_embeddings") ?? 0
            guard embeddingCount > 0 else { return RetrievalPage(records: [], hasMore: false) }

            var conditions = ["dv.committed_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [blob, embeddingCount, filter.endAtMs]
            if let start = filter.startAtMs {
                conditions.append("dv.committed_at >= ?")
                arguments.append(start)
            }
            if !filter.sourceApps.isEmpty {
                conditions.append("t.source_app COLLATE NOCASE IN (\(Self.placeholders(filter.sourceApps.count)))")
                arguments.append(contentsOf: filter.sourceApps)
            }
            arguments.append(boundedLimit + 1)
            arguments.append(boundedOffset)

            let rows = try Row.fetchAll(d, sql: """
                WITH matches AS (
                  SELECT derivative_id, distance FROM derivative_embeddings
                  WHERE embedding MATCH ? AND k = ?
                )
                SELECT dv.id AS derivative_id, dv.content, matches.distance,
                       t.id AS thread_id, t.source_app, t.source_title, t.source_key,
                       dv.committed_at
                FROM matches
                JOIN derivatives dv ON dv.id = matches.derivative_id
                JOIN threads t ON t.id = dv.thread_id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY matches.distance ASC, dv.committed_at DESC, dv.id ASC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments))
            let mapped = rows.map { row -> FactHit in
                let l2: Double = row["distance"]
                return FactHit(
                    id: row["derivative_id"],
                    content: decryptOrMarker(row["content"]),
                    distance: (l2 * l2) / 2.0,
                    sourceTitle: row["source_title"],
                    sourceApp: row["source_app"],
                    sourceKey: row["source_key"],
                    threadID: row["thread_id"],
                    committedAt: row["committed_at"]
                )
            }
            return RetrievalPage(records: Array(mapped.prefix(boundedLimit)), hasMore: mapped.count > boundedLimit)
        }
    }

    public func recentThreads(
        filter: RetrievalFilter,
        offset: Int,
        limit: Int
    ) throws -> RetrievalPage<ThreadSummary> {
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), 100)
        return try db.dbQueue.read { d in
            var conditions = ["updated_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [filter.endAtMs]
            if let start = filter.startAtMs {
                conditions.append("updated_at >= ?")
                arguments.append(start)
            }
            if !filter.sourceApps.isEmpty {
                conditions.append("source_app COLLATE NOCASE IN (\(Self.placeholders(filter.sourceApps.count)))")
                arguments.append(contentsOf: filter.sourceApps)
            }
            arguments.append(boundedLimit + 1)
            arguments.append(boundedOffset)
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, source_app, source_title, source_key, updated_at
                FROM threads
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY updated_at DESC, id ASC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments))
            let mapped = try rows.map { row -> ThreadSummary in
                let facts = try String.fetchAll(d, sql: """
                    SELECT content FROM derivatives WHERE thread_id = ? AND committed_at <= ?
                    ORDER BY committed_at DESC, id ASC LIMIT 3
                    """, arguments: [row["id"] as String, filter.endAtMs])
                return ThreadSummary(
                    id: row["id"], sourceApp: row["source_app"], sourceTitle: row["source_title"],
                    sourceKey: row["source_key"], updatedAt: row["updated_at"],
                    recentFacts: facts.map(decryptOrMarker)
                )
            }
            return RetrievalPage(records: Array(mapped.prefix(boundedLimit)), hasMore: mapped.count > boundedLimit)
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
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
