import Foundation
import GRDB
import MaxMiCore

public struct MemoryDeletionResult: Sendable, Equatable {
    public let threads: Int
    public let versions: Int
    public let facts: Int

    public init(threads: Int, versions: Int, facts: Int) {
        self.threads = threads; self.versions = versions; self.facts = facts
    }
}

private struct MemoryExport: Codable {
    let exportedAt: String
    let formatVersion: Int
    let threads: [MemoryExportThread]
}

private struct MemoryExportThread: Codable {
    let id: String
    let sourceApp: String
    let sourceKey: String
    let sourceTitle: String?
    let contentKind: String?
    let capturedAtMs: EpochMs?
    let latestContext: String?
    let displaySummary: String?
    let facts: [String]
}

extension Store {
    /// Consistent SQLite backup used immediately before destructive data controls.
    public func backupDatabase(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        let destination = try DatabaseQueue(path: url.path)
        defer { try? destination.close() }
        try db.dbQueue.backup(to: destination)
        try destination.inDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Exports the current memory surface and facts as explicit plaintext JSON.
    public func exportMemory(to url: URL) throws -> Int {
        let threads: [MemoryExportThread] = try db.dbQueue.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT t.id, t.source_app, t.source_key, t.source_title,
                       c.content_kind, c.captured_at, c.content_ciphertext,
                       c.display_summary_ciphertext
                FROM threads t
                LEFT JOIN latest_contexts c ON c.thread_id = t.id
                ORDER BY t.updated_at DESC, t.id ASC
                """)
            return try rows.map { row in
                let threadID: String = row["id"]
                let encryptedFacts = try String.fetchAll(database, sql: """
                    SELECT content FROM derivatives WHERE thread_id = ?
                    ORDER BY committed_at ASC, id ASC
                    """, arguments: [threadID])
                return MemoryExportThread(
                    id: threadID,
                    sourceApp: row["source_app"],
                    sourceKey: row["source_key"],
                    sourceTitle: row["source_title"],
                    contentKind: row["content_kind"],
                    capturedAtMs: row["captured_at"],
                    latestContext: (row["content_ciphertext"] as String?).map(decryptOrMarker),
                    displaySummary: (row["display_summary_ciphertext"] as String?).map(decryptOrMarker),
                    facts: encryptedFacts.map(decryptOrMarker)
                )
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let export = MemoryExport(exportedAt: formatter.string(from: Date()), formatVersion: 1, threads: threads)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return threads.count
    }

    /// Deletes material older than the cutoff while preserving current latest/meeting versions.
    public func pruneMemory(olderThan cutoffMs: EpochMs) throws -> MemoryDeletionResult {
        try db.dbQueue.write { database in
            let threadCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM threads WHERE updated_at < ?", arguments: [cutoffMs]) ?? 0
            let versionCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM versions WHERE committed_at < ?", arguments: [cutoffMs]) ?? 0
            let factCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM derivatives WHERE committed_at < ?", arguments: [cutoffMs]) ?? 0

            try database.execute(sql: "CREATE TEMP TABLE maxmi_prune_threads(id TEXT PRIMARY KEY)")
            try database.execute(sql: "INSERT INTO maxmi_prune_threads SELECT id FROM threads WHERE updated_at < ?", arguments: [cutoffMs])
            try database.execute(sql: "CREATE TEMP TABLE maxmi_prune_versions(id TEXT PRIMARY KEY)")
            try database.execute(sql: """
                INSERT INTO maxmi_prune_versions
                SELECT v.id FROM versions v
                WHERE v.committed_at < ?
                  AND v.thread_id NOT IN (SELECT id FROM maxmi_prune_threads)
                  AND v.id NOT IN (SELECT version_id FROM latest_contexts WHERE version_id IS NOT NULL)
                  AND v.id NOT IN (SELECT version_id FROM meetings WHERE version_id IS NOT NULL)
                """, arguments: [cutoffMs])

            try database.execute(sql: """
                DELETE FROM derivative_embeddings WHERE derivative_id IN (
                  SELECT id FROM derivatives
                  WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)
                     OR version_id IN (SELECT id FROM maxmi_prune_versions)
                )
                """)
            try database.execute(sql: """
                DELETE FROM retry_queue
                WHERE version_id IN (SELECT id FROM maxmi_prune_versions)
                   OR derivative_id IN (SELECT id FROM derivatives WHERE thread_id IN (SELECT id FROM maxmi_prune_threads))
                """)
            try database.execute(sql: """
                DELETE FROM activity_session_evidence
                WHERE version_id IN (SELECT id FROM maxmi_prune_versions)
                   OR version_id IN (SELECT id FROM versions WHERE thread_id IN (SELECT id FROM maxmi_prune_threads))
                """)
            try database.execute(sql: "DELETE FROM derivatives WHERE version_id IN (SELECT id FROM maxmi_prune_versions)")
            try database.execute(sql: "DELETE FROM versions WHERE id IN (SELECT id FROM maxmi_prune_versions)")

            try database.execute(sql: "DELETE FROM latest_contexts WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)")
            try database.execute(sql: "DELETE FROM meetings WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)")
            try database.execute(sql: "DELETE FROM message_fingerprints WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)")
            try database.execute(sql: "DELETE FROM derivatives WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)")
            try database.execute(sql: "DELETE FROM versions WHERE thread_id IN (SELECT id FROM maxmi_prune_threads)")
            try database.execute(sql: "DELETE FROM threads WHERE id IN (SELECT id FROM maxmi_prune_threads)")

            try database.execute(sql: "DELETE FROM activity_sessions WHERE coalesce(ended_at, last_activity_at) < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM activity_app_visits WHERE coalesce(ended_at, started_at) < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM agent_action_item_events WHERE item_id IN (SELECT id FROM agent_action_items WHERE status != 'open' AND updated_at < ?)", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM agent_action_items WHERE status != 'open' AND updated_at < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM agent_runs WHERE coalesce(ended_at, started_at) < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM capture_health_events WHERE at_ms < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM message_fingerprints WHERE seen_at < ?", arguments: [cutoffMs])

            try database.execute(sql: "DROP TABLE maxmi_prune_versions")
            try database.execute(sql: "DROP TABLE maxmi_prune_threads")
            return MemoryDeletionResult(threads: threadCount, versions: versionCount, facts: factCount)
        }
    }

    public func deleteAllMemory() throws -> MemoryDeletionResult {
        try db.dbQueue.write { database in
            let result = MemoryDeletionResult(
                threads: try Int.fetchOne(database, sql: "SELECT count(*) FROM threads") ?? 0,
                versions: try Int.fetchOne(database, sql: "SELECT count(*) FROM versions") ?? 0,
                facts: try Int.fetchOne(database, sql: "SELECT count(*) FROM derivatives") ?? 0
            )
            try database.execute(sql: "DELETE FROM derivative_embeddings")
            try database.execute(sql: "DELETE FROM retry_queue")
            try database.execute(sql: "DELETE FROM agent_action_item_events")
            try database.execute(sql: "DELETE FROM agent_action_items")
            try database.execute(sql: "DELETE FROM agent_runs")
            try database.execute(sql: "DELETE FROM activity_session_evidence")
            try database.execute(sql: "DELETE FROM activity_sessions")
            try database.execute(sql: "DELETE FROM activity_app_visits")
            try database.execute(sql: "DELETE FROM latest_contexts")
            try database.execute(sql: "DELETE FROM meetings")
            try database.execute(sql: "DELETE FROM message_fingerprints")
            try database.execute(sql: "DELETE FROM derivatives")
            try database.execute(sql: "DELETE FROM versions")
            try database.execute(sql: "DELETE FROM threads")
            try database.execute(sql: "DELETE FROM capture_health_events")
            try database.execute(sql: "DELETE FROM settings WHERE key='paused_threads'")
            return result
        }
    }
}
