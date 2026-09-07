import Foundation
import GRDB
import MaxMiCore

public struct PendingCaptureSummary: Sendable, Equatable {
    public let threadID: String
    public let appLabel: String
    public let sourceTitle: String?
    public let contentKind: CaptureContentKind
    public let content: String
    public let expectedSourceHash: String
    public let promptVersion: String
}

extension Store {
    public func captureContextsNeedingSummary(
        nowMs: EpochMs,
        settleMs: EpochMs = 10_000,
        limit: Int = 1
    ) throws -> [PendingCaptureSummary] {
        let boundedLimit = min(max(limit, 1), 20)
        let reviewed = try cloudReviewedSourceApps()
        let localOnly = try cloudLocalOnlySourceApps()
        let reviewGateEnabled = try cloudReviewInitialized()
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT c.thread_id, c.content_ciphertext, c.content_hash, c.content_kind,
                       t.source_app, t.source_title
                FROM latest_contexts c JOIN threads t ON t.id=c.thread_id
                WHERE c.captured_at <= ?
                  AND (
                    c.summary_status='pending'
                    OR (c.summary_status='failed' AND coalesce(c.summary_next_attempt_at, 0) <= ?)
                    OR (
                        coalesce(c.summary_prompt_version, '') <> CASE
                            WHEN c.content_kind = 'conversation' THEN ?
                            ELSE ?
                        END
                    )
                )
                ORDER BY c.captured_at DESC, c.thread_id
                """, arguments: [
                    nowMs - settleMs,
                    nowMs,
                    CaptureDisplaySummaryFormat.recentConversation,
                    CaptureDisplaySummaryFormat.standard,
                ]).filter { row in
                    let sourceApp: String = row["source_app"]
                    return !reviewGateEnabled || (reviewed.contains(sourceApp) && !localOnly.contains(sourceApp))
                }.prefix(boundedLimit).map { row in
                    let contentKind = CaptureContentKind(rawValue: row["content_kind"]) ?? .generic
                    let sourceApp: String = row["source_app"]
                    return PendingCaptureSummary(
                        threadID: row["thread_id"],
                        appLabel: sourceApp,
                        sourceTitle: row["source_title"],
                        contentKind: contentKind,
                        content: decryptOrMarker(row["content_ciphertext"]),
                        expectedSourceHash: row["content_hash"],
                        promptVersion: CaptureDisplaySummaryFormat.promptVersion(
                            sourceApp: sourceApp,
                            contentKind: contentKind
                        )
                    )
                }
        }
    }

    @discardableResult
    public func saveCaptureDisplaySummary(
        threadID: String,
        summary: String,
        expectedSourceHash: String,
        modelID: String,
        promptVersion: String,
        nowMs: EpochMs
    ) throws -> Bool {
        let encrypted = try cipher.encrypt(summary)
        return try db.dbQueue.write { d in
            try d.execute(sql: """
                UPDATE latest_contexts
                SET display_summary_ciphertext=?, summary_status='completed',
                    summary_source_hash=?, summary_attempts=0, summary_next_attempt_at=NULL,
                    summary_model_id=?, summary_prompt_version=?
                WHERE thread_id=? AND content_hash=?
                """, arguments: [
                    encrypted, expectedSourceHash, modelID, promptVersion,
                    threadID, expectedSourceHash,
                ])
            return d.changesCount > 0
        }
    }

    public func markCaptureSummaryFailed(
        threadID: String,
        expectedSourceHash: String,
        errorKind: String,
        nowMs: EpochMs
    ) throws {
        try db.dbQueue.write { d in
            let attempts = try Int.fetchOne(d, sql:
                "SELECT summary_attempts FROM latest_contexts WHERE thread_id=? AND content_hash=?",
                arguments: [threadID, expectedSourceHash]) ?? 0
            let backoff: EpochMs = min(30_000 * EpochMs(1 << min(attempts, 10)), 3_600_000)
            // errorKind is deliberately not persisted; it may originate from an untrusted response.
            _ = errorKind
            try d.execute(sql: """
                UPDATE latest_contexts
                SET summary_status='failed', summary_attempts=?, summary_next_attempt_at=?
                WHERE thread_id=? AND content_hash=?
                """, arguments: [attempts + 1, nowMs + backoff, threadID, expectedSourceHash])
        }
    }
}
