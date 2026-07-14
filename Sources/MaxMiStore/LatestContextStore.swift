import Foundation
import GRDB
import MaxMiCore

public struct LatestContextRecord: Sendable, Equatable {
    public let id: String
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public let contentKind: CaptureContentKind
    public let parserID: String
    public let parserVersion: Int
    public let accumulationPolicy: CaptureAccumulationPolicy
    public let offscreenPolicy: OffscreenCapturePolicy
    public let trigger: CaptureTrigger
    public let capturedAtMs: EpochMs
    public let characterCount: Int
    public let truncated: Bool
    public let displaySummary: String?
    public let summaryStatus: String
}

extension Store {
    /// Freshness-ranked raw contexts, separate from semantic derivatives/facts.
    public func latestContexts(limit: Int = 10, source: String? = nil) throws -> [LatestContextRecord] {
        let boundedLimit = min(max(limit, 1), 100)
        let query = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.dbQueue.read { d in
            let rows: [Row]
            if let query, !query.isEmpty {
                let pattern = "%\(query)%"
                rows = try Row.fetchAll(d, sql: """
                    SELECT c.thread_id, t.source_app, t.source_key, t.source_title,
                           c.content_ciphertext, c.content_kind, c.parser_id, c.parser_version,
                           c.accumulation_policy, c.offscreen_mode, c.offscreen_max_steps,
                           c.offscreen_max_chars, c.trigger, c.captured_at,
                           c.character_count, c.truncated, c.display_summary_ciphertext,
                           c.summary_status
                    FROM latest_contexts c JOIN threads t ON t.id = c.thread_id
                    WHERE t.source_app LIKE ? COLLATE NOCASE
                       OR t.source_key LIKE ? COLLATE NOCASE
                       OR coalesce(t.source_title, '') LIKE ? COLLATE NOCASE
                    ORDER BY c.captured_at DESC, c.thread_id
                    LIMIT ?
                    """, arguments: [pattern, pattern, pattern, boundedLimit])
            } else {
                rows = try Row.fetchAll(d, sql: """
                    SELECT c.thread_id, t.source_app, t.source_key, t.source_title,
                           c.content_ciphertext, c.content_kind, c.parser_id, c.parser_version,
                           c.accumulation_policy, c.offscreen_mode, c.offscreen_max_steps,
                           c.offscreen_max_chars, c.trigger, c.captured_at,
                           c.character_count, c.truncated, c.display_summary_ciphertext,
                           c.summary_status
                    FROM latest_contexts c JOIN threads t ON t.id = c.thread_id
                    ORDER BY c.captured_at DESC, c.thread_id
                    LIMIT ?
                    """, arguments: [boundedLimit])
            }
            return rows.compactMap { row in
                guard
                    let kind = CaptureContentKind(rawValue: row["content_kind"]),
                    let accumulation = CaptureAccumulationPolicy(rawValue: row["accumulation_policy"]),
                    let offscreenMode = OffscreenCaptureMode(rawValue: row["offscreen_mode"]),
                    let trigger = CaptureTrigger(rawValue: row["trigger"])
                else { return nil }
                return LatestContextRecord(
                    id: row["thread_id"],
                    sourceApp: row["source_app"],
                    sourceKey: row["source_key"],
                    sourceTitle: row["source_title"],
                    content: decryptOrMarker(row["content_ciphertext"]),
                    contentKind: kind,
                    parserID: row["parser_id"],
                    parserVersion: row["parser_version"],
                    accumulationPolicy: accumulation,
                    offscreenPolicy: OffscreenCapturePolicy(
                        mode: offscreenMode,
                        maxSteps: row["offscreen_max_steps"],
                        maxCharacters: row["offscreen_max_chars"]
                    ),
                    trigger: trigger,
                    capturedAtMs: row["captured_at"],
                    characterCount: row["character_count"],
                    truncated: (row["truncated"] as Int) != 0,
                    displaySummary: (row["display_summary_ciphertext"] as String?).map(decryptOrMarker),
                    summaryStatus: row["summary_status"]
                )
            }
        }
    }
}
