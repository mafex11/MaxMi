import Foundation
import GRDB
import MaxMiCore

extension Store {
    /// Records one content-free terminal capture outcome and bounds the ledger by row count.
    /// The event stores no source key, URL, title, captured text, or raw error description.
    public func recordCaptureHealth(
        appBundle: String,
        appLabel: String,
        trigger: CaptureTrigger,
        parser: String,
        outcome: CaptureOutcome,
        durationMs: Int,
        atMs: EpochMs,
        retainLatest: Int = 500
    ) throws {
        let keep = max(1, retainLatest)
        try db.dbQueue.write { d in
            let id = Ident.uuidv7(nowMs: atMs)
            try d.execute(sql: """
                INSERT INTO capture_health_events (
                    id, at_ms, app_bundle, app_label, trigger, parser, outcome, reason,
                    character_count, duration_ms, truncated, version_id
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [
                    id, atMs, appBundle, appLabel, trigger.rawValue, parser,
                    outcome.kind.rawValue, outcome.reason, outcome.characterCount,
                    max(0, durationMs), outcome.truncated ? 1 : 0, outcome.versionID,
                ])

            try d.execute(sql: """
                DELETE FROM capture_health_events
                WHERE id NOT IN (
                    SELECT id FROM capture_health_events
                    ORDER BY at_ms DESC, id DESC
                    LIMIT ?
                )
                """, arguments: [keep])
        }
    }

    public func recentCaptureHealth(limit: Int = 100) throws -> [CaptureHealthRecord] {
        let boundedLimit = min(max(limit, 1), 500)
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, at_ms, app_bundle, app_label, trigger, parser, outcome, reason,
                       character_count, duration_ms, truncated, version_id
                FROM capture_health_events
                ORDER BY at_ms DESC, id DESC
                LIMIT ?
                """, arguments: [boundedLimit]).compactMap { row in
                    guard
                        let trigger = CaptureTrigger(rawValue: row["trigger"]),
                        let outcome = CaptureOutcomeKind(rawValue: row["outcome"])
                    else { return nil }
                    return CaptureHealthRecord(
                        id: row["id"],
                        atMs: row["at_ms"],
                        appBundle: row["app_bundle"],
                        appLabel: row["app_label"],
                        trigger: trigger,
                        parser: row["parser"],
                        outcome: outcome,
                        reason: row["reason"],
                        characterCount: row["character_count"],
                        durationMs: row["duration_ms"],
                        truncated: (row["truncated"] as Int) != 0,
                        versionID: row["version_id"]
                    )
                }
        }
    }
}
