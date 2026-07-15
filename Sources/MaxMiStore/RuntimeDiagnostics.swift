import Foundation
import GRDB
import MaxMiCore

extension Store {
    /// Fixed-schema, content-free runtime metrics for diagnostics export.
    public func runtimeDiagnostics(nowMs: EpochMs, databaseURL: URL? = nil) throws
        -> SafeDiagnosticsDatabase
    {
        try db.dbQueue.read { database in
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(database, sql: sql) ?? 0
            }

            let integrityRows = try String.fetchAll(database, sql: "PRAGMA integrity_check")
            let migration = try String.fetchOne(
                database,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
            ) ?? "unknown"
            let migrationToken = SafeLogToken(validating: migration)
                ?? SafeLogToken(validating: "unknown")!

            return SafeDiagnosticsDatabase(
                latestMigration: migrationToken,
                migrationCount: try count("SELECT count(*) FROM grdb_migrations"),
                integrityOK: integrityRows == ["ok"],
                databaseBytes: fileBytes(databaseURL),
                walBytes: fileBytes(databaseURL.map { URL(fileURLWithPath: $0.path + "-wal") }),
                shmBytes: fileBytes(databaseURL.map { URL(fileURLWithPath: $0.path + "-shm") }),
                threads: try count("SELECT count(*) FROM threads"),
                versions: try count("SELECT count(*) FROM versions"),
                facts: try count("SELECT count(*) FROM derivatives"),
                latestContexts: try count("SELECT count(*) FROM latest_contexts"),
                recordings: try count("SELECT count(*) FROM meetings"),
                captureHealthEvents: try count("SELECT count(*) FROM capture_health_events"),
                retryTotal: try count("SELECT count(*) FROM retry_queue"),
                retryOverdue: try count(
                    "SELECT count(*) FROM retry_queue WHERE next_attempt_at <= \(nowMs)"
                ),
                retryMaxAttempts: try Int.fetchOne(
                    database,
                    sql: "SELECT coalesce(max(attempts), 0) FROM retry_queue"
                ) ?? 0,
                contextSummariesPending: try count(
                    "SELECT count(*) FROM latest_contexts WHERE summary_status='pending'"
                ),
                contextSummariesFailed: try count(
                    "SELECT count(*) FROM latest_contexts WHERE summary_status='failed'"
                ),
                activitySummariesPending: try count(
                    "SELECT count(*) FROM activity_sessions WHERE summary_status='pending'"
                ),
                activitySummariesFailed: try count(
                    "SELECT count(*) FROM activity_sessions WHERE summary_status='failed'"
                ),
                agentRunsRunning: try count(
                    "SELECT count(*) FROM agent_runs WHERE status='running'"
                ),
                agentRunsFailed: try count(
                    "SELECT count(*) FROM agent_runs WHERE status='failed'"
                ),
                actionItemsOpen: try count(
                    "SELECT count(*) FROM agent_action_items WHERE status='open'"
                )
            )
        }
    }
}

private func fileBytes(_ url: URL?) -> Int {
    guard let url,
          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let value = attributes[.size] as? NSNumber else { return 0 }
    return value.intValue
}
