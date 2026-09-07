import Foundation
import GRDB
import MaxMiCore

public struct FactHit: Sendable, Equatable {
    public let id: String
    public let versionID: String
    public let content: String
    /// Cosine distance (1 − cosine similarity), derived from vec0 L2 on unit vectors.
    public let distance: Double
    public let sourceTitle: String?
    public let sourceApp: String
    public let sourceKey: String
    public let threadID: String
    public let committedAt: EpochMs
}

public struct ContextHit: Sendable, Equatable {
    public let versionID: String
    public let compactContent: String
    public let sourceTitle: String?
    public let sourceApp: String
    public let sourceKey: String
    public let threadID: String
    public let committedAt: EpochMs
    public let distance: Double
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
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "t.source_app",
                threadIDColumn: "t.id",
                urlColumn: "t.source_key"
            )
            return try Row.fetchAll(d, sql: """
                SELECT dv.id AS derivative_id, dv.version_id, dv.content, e.distance,
                       t.id AS thread_id, t.source_app, t.source_title, t.source_key,
                       dv.committed_at
                FROM (SELECT derivative_id, distance FROM derivative_embeddings
                      WHERE embedding MATCH ? AND k = ?) e
                JOIN derivatives dv ON dv.id = e.derivative_id
                JOIN threads t ON t.id = dv.thread_id
                WHERE \(privacySQL.condition)
                ORDER BY e.distance
                """, arguments: StatementArguments([blob, limit] + privacySQL.arguments))
                .compactMap { row -> FactHit? in
                    let sourceApp: String = row["source_app"]
                    let threadID: String = row["thread_id"]
                    let sourceKey: String = row["source_key"]
                    guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                        return nil
                    }
                    // vec0 table uses L2 distance (default when no distance_metric specified).
                    // All vectors are unit-normalized, so L2 = sqrt(2 − 2·cos_sim).
                    // Convert to cosine distance via: cosine_distance = L2² / 2
                    let l2: Double = row["distance"]
                    let cosineDistance = (l2 * l2) / 2.0
                    return FactHit(id: row["derivative_id"], versionID: row["version_id"],
                                   content: decryptOrMarker(row["content"]), distance: cosineDistance,
                                   sourceTitle: row["source_title"], sourceApp: row["source_app"],
                                   sourceKey: row["source_key"], threadID: row["thread_id"],
                                   committedAt: row["committed_at"])
                }
        }
    }

    /// Threads by recency; each carries its OWN 3 latest facts (per-thread, not global).
    public func recentThreads(limit: Int) throws -> [ThreadSummary] {
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "source_app",
                threadIDColumn: "id",
                urlColumn: "source_key"
            )
            let threads = try Row.fetchAll(d, sql: """
                SELECT id, source_app, source_title, source_key, updated_at
                FROM threads
                WHERE \(privacySQL.condition)
                ORDER BY updated_at DESC LIMIT ?
                """, arguments: StatementArguments(privacySQL.arguments + [limit]))
            return try threads.compactMap { t -> ThreadSummary? in
                let sourceApp: String = t["source_app"]
                let threadID: String = t["id"]
                let sourceKey: String = t["source_key"]
                guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                    return nil
                }
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
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let embeddingCount = try Int.fetchOne(d, sql: "SELECT count(*) FROM derivative_embeddings") ?? 0
            guard embeddingCount > 0 else { return RetrievalPage(records: [], hasMore: false) }

            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "t.source_app",
                threadIDColumn: "t.id",
                urlColumn: "t.source_key"
            )
            var conditions = [privacySQL.condition, "dv.committed_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [blob, embeddingCount] + privacySQL.arguments + [filter.endAtMs]
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
                SELECT dv.id AS derivative_id, dv.version_id, dv.content, matches.distance,
                       t.id AS thread_id, t.source_app, t.source_title, t.source_key,
                       dv.committed_at
                FROM matches
                JOIN derivatives dv ON dv.id = matches.derivative_id
                JOIN threads t ON t.id = dv.thread_id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY matches.distance ASC, dv.committed_at DESC, dv.id ASC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments))
            let mapped = rows.compactMap { row -> FactHit? in
                let sourceApp: String = row["source_app"]
                let threadID: String = row["thread_id"]
                let sourceKey: String = row["source_key"]
                guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                    return nil
                }
                let l2: Double = row["distance"]
                return FactHit(
                    id: row["derivative_id"],
                    versionID: row["version_id"],
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

    public func contextHits(
        near vector: [Float],
        filter: RetrievalFilter,
        limit: Int
    ) throws -> [ContextHit] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        let boundedLimit = min(max(limit, 1), 5)
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let embeddingCount = try Int.fetchOne(d, sql: "SELECT count(*) FROM context_embeddings") ?? 0
            guard embeddingCount > 0 else { return [] }

            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "t.source_app",
                threadIDColumn: "t.id",
                urlColumn: "t.source_key"
            )
            var conditions = [privacySQL.condition, "v.committed_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [blob, embeddingCount] + privacySQL.arguments + [filter.endAtMs]
            if let start = filter.startAtMs {
                conditions.append("v.committed_at >= ?")
                arguments.append(start)
            }
            if !filter.sourceApps.isEmpty {
                conditions.append("t.source_app COLLATE NOCASE IN (\(Self.placeholders(filter.sourceApps.count)))")
                arguments.append(contentsOf: filter.sourceApps)
            }
            arguments.append(boundedLimit)

            let rows = try Row.fetchAll(d, sql: """
                WITH matches AS (
                  SELECT version_id, distance FROM context_embeddings
                  WHERE embedding MATCH ? AND k = ?
                )
                SELECT v.id AS version_id, v.content, v.structured_ciphertext, v.metadata,
                       matches.distance,
                       t.id AS thread_id, t.source_app, t.source_title, t.source_key,
                       v.committed_at
                FROM matches
                JOIN versions v ON v.id = matches.version_id
                JOIN threads t ON t.id = v.thread_id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY matches.distance ASC, v.committed_at DESC, v.id ASC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                let sourceApp: String = row["source_app"]
                let threadID: String = row["thread_id"]
                let sourceKey: String = row["source_key"]
                guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                    return nil
                }
                let l2: Double = row["distance"]
                return ContextHit(
                    versionID: row["version_id"],
                    compactContent: ContentRenderer.render(
                        structuredOrLegacy(
                            row["structured_ciphertext"] as String?,
                            renderedContent: decryptOrMarker(row["content"]),
                            kind: (try? JSONDecoder().decode(
                                VersionCaptureMetadata.self,
                                from: Data((row["metadata"] as String? ?? "").utf8)
                            ))?.contentKind ?? .generic
                        ),
                        style: .compact(maxChars: 6_000)
                    ),
                    sourceTitle: row["source_title"],
                    sourceApp: sourceApp,
                    sourceKey: sourceKey,
                    threadID: row["thread_id"],
                    committedAt: row["committed_at"],
                    distance: (l2 * l2) / 2.0
                )
            }
        }
    }

    public func recentThreads(
        filter: RetrievalFilter,
        offset: Int,
        limit: Int
    ) throws -> RetrievalPage<ThreadSummary> {
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), 100)
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "source_app",
                threadIDColumn: "id",
                urlColumn: "source_key"
            )
            var conditions = [privacySQL.condition, "updated_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = privacySQL.arguments + [filter.endAtMs]
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
            let mapped = try rows.compactMap { row -> ThreadSummary? in
                let sourceApp: String = row["source_app"]
                let threadID: String = row["id"]
                let sourceKey: String = row["source_key"]
                guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                    return nil
                }
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
