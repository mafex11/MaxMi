import Foundation
import GRDB
import MaxMiCore

public struct StoredCheckin: Sendable, Equatable {
    public let dayBucket: Int64
    public let generatedAtMs: EpochMs
    public let summary: String?
    public let openItemIDs: [String]
    public let resolvedYesterdayCount: Int
    public let dismissedAtMs: EpochMs?
    public let promptVersion: String

    public init(
        dayBucket: Int64,
        generatedAtMs: EpochMs,
        summary: String?,
        openItemIDs: [String],
        resolvedYesterdayCount: Int,
        dismissedAtMs: EpochMs?,
        promptVersion: String
    ) {
        self.dayBucket = dayBucket
        self.generatedAtMs = generatedAtMs
        self.summary = summary
        self.openItemIDs = openItemIDs
        self.resolvedYesterdayCount = resolvedYesterdayCount
        self.dismissedAtMs = dismissedAtMs
        self.promptVersion = promptVersion
    }
}

public struct CheckinOpenItemRecord: Sendable, Equatable {
    public let id: String
    public let title: String
    public let details: String?
    public let detectedAtMs: EpochMs
    public let sourceApp: String?

    public init(
        id: String,
        title: String,
        details: String?,
        detectedAtMs: EpochMs,
        sourceApp: String?
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.detectedAtMs = detectedAtMs
        self.sourceApp = sourceApp
    }
}

extension Store {
    public func checkin(dayBucket: Int64) throws -> StoredCheckin? {
        try db.dbQueue.read { d in
            guard let row = try Row.fetchOne(d, sql: """
                SELECT day_bucket, generated_at_ms, summary_ciphertext, open_item_ids,
                       resolved_yesterday_count, dismissed_at_ms, prompt_version
                FROM checkins
                WHERE day_bucket=?
                """, arguments: [dayBucket]) else {
                return nil
            }

            let openItemIDs: [String]
            let idsJSON: String = row["open_item_ids"]
            if let decoded = try? JSONDecoder().decode([String].self, from: Data(idsJSON.utf8)) {
                openItemIDs = decoded
            } else {
                SafeLogger.shared.log(
                    .warning,
                    subsystem: .store,
                    event: .settingsDecodeFailed,
                    fields: SafeLogFields(
                        operation: SafeLogToken(validating: "checkin_open_item_ids")
                    )
                )
                openItemIDs = []
            }

            let ciphertext: String = row["summary_ciphertext"]
            return StoredCheckin(
                dayBucket: row["day_bucket"],
                generatedAtMs: row["generated_at_ms"],
                summary: try? cipher.decrypt(ciphertext),
                openItemIDs: openItemIDs,
                resolvedYesterdayCount: row["resolved_yesterday_count"],
                dismissedAtMs: row["dismissed_at_ms"],
                promptVersion: row["prompt_version"]
            )
        }
    }

    public func saveCheckin(
        dayBucket: Int64,
        generatedAtMs: EpochMs,
        summary: String,
        openItemIDs: [String],
        resolvedYesterdayCount: Int,
        promptVersion: String
    ) throws {
        let ciphertext = try cipher.encrypt(summary)
        let ids = String(decoding: try JSONEncoder().encode(openItemIDs), as: UTF8.self)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO checkins (
                    day_bucket, generated_at_ms, summary_ciphertext, open_item_ids,
                    resolved_yesterday_count, dismissed_at_ms, prompt_version
                ) VALUES (?,?,?,?,?,NULL,?)
                ON CONFLICT(day_bucket) DO UPDATE SET
                    generated_at_ms=excluded.generated_at_ms,
                    summary_ciphertext=excluded.summary_ciphertext,
                    open_item_ids=excluded.open_item_ids,
                    resolved_yesterday_count=excluded.resolved_yesterday_count,
                    dismissed_at_ms=NULL,
                    prompt_version=excluded.prompt_version
                """, arguments: [
                    dayBucket, generatedAtMs, ciphertext, ids, resolvedYesterdayCount, promptVersion,
                ])
            try d.execute(
                sql: "DELETE FROM settings WHERE key IN (?,?)",
                arguments: [checkinRetryAttemptsKey(dayBucket), checkinRetryNextAttemptKey(dayBucket)]
            )
        }
    }

    public func dismissCheckin(dayBucket: Int64, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(
                sql: "UPDATE checkins SET dismissed_at_ms=? WHERE day_bucket=?",
                arguments: [nowMs, dayBucket]
            )
        }
    }

    public func openCheckinItems(limit: Int) throws -> [CheckinOpenItemRecord] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }

        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, title_ciphertext, details_ciphertext, source_refs, detected_at
                FROM agent_action_items
                WHERE status='open'
                ORDER BY detected_at DESC, id ASC
                LIMIT ?
                """, arguments: [boundedLimit])

            let sourceIDs = Set(rows.flatMap { row -> [String] in
                guard let json: String = row["source_refs"],
                      let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
                else {
                    return []
                }
                return ids
            })
            let sourceApps: [String: String]
            if sourceIDs.isEmpty {
                sourceApps = [:]
            } else {
                let sourceRows = try Row.fetchAll(d, sql: """
                    SELECT id, app_label
                    FROM activity_sessions
                    WHERE id IN (\(Self.placeholders(sourceIDs.count)))
                    """, arguments: StatementArguments(sourceIDs.sorted()))
                sourceApps = Dictionary(uniqueKeysWithValues: sourceRows.map {
                    ($0["id"] as String, $0["app_label"] as String)
                })
            }

            return rows.compactMap { row in
                let titleCiphertext: String = row["title_ciphertext"]
                guard let title = try? cipher.decrypt(titleCiphertext) else { return nil }
                let details = (row["details_ciphertext"] as String?).flatMap {
                    try? cipher.decrypt($0)
                }
                let refs: [String]
                if let json: String = row["source_refs"],
                   let decoded = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                    refs = decoded
                } else {
                    refs = []
                }
                return CheckinOpenItemRecord(
                    id: row["id"],
                    title: title,
                    details: details,
                    detectedAtMs: row["detected_at"],
                    sourceApp: refs.compactMap { sourceApps[$0] }.first
                )
            }
        }
    }

    public func resolvedCheckinItems(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) throws -> (count: Int, titles: [String]) {
        let boundedLimit = max(limit, 0)
        return try db.dbQueue.read { d in
            let count = try Int.fetchOne(d, sql: """
                SELECT count(*)
                FROM agent_action_items
                WHERE status='resolved' AND resolved_at >= ? AND resolved_at <= ?
                """, arguments: [fromMs, toMs]) ?? 0
            guard boundedLimit > 0 else { return (count, []) }

            let titles = try String.fetchAll(d, sql: """
                SELECT title_ciphertext
                FROM agent_action_items
                WHERE status='resolved' AND resolved_at >= ? AND resolved_at <= ?
                ORDER BY resolved_at DESC, id ASC
                LIMIT ?
                """, arguments: [fromMs, toMs, boundedLimit])
                .compactMap { try? cipher.decrypt($0) }
            return (count, titles)
        }
    }

    public func checkinCalendarCaptures(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) throws -> [CalendarEvent] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }

        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT content_ciphertext, structured_ciphertext
                FROM latest_contexts
                WHERE content_kind='calendar' AND captured_at >= ? AND captured_at <= ?
                ORDER BY captured_at DESC, thread_id ASC
                """, arguments: [fromMs, toMs])
            let events = rows.flatMap { row -> [CalendarEvent] in
                let ciphertext: String = row["content_ciphertext"]
                let rendered = (try? cipher.decrypt(ciphertext)) ?? ""
                let content = structuredOrLegacy(
                    row["structured_ciphertext"] as String?,
                    renderedContent: rendered,
                    kind: .calendar
                )
                guard case .calendar(let values) = content else { return [] }
                return values
            }
            return Array(events.prefix(boundedLimit))
        }
    }

    public func checkinTopApps(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) throws -> [(appLabel: String, sourceTitle: String?)] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }

        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                WITH overlapping_visits AS (
                  SELECT
                    app_bundle,
                    app_label,
                    max(started_at, ?) AS overlap_started_at,
                    min(coalesce(ended_at, ?), ?) AS overlap_ended_at
                  FROM activity_app_visits
                  WHERE started_at <= ? AND coalesce(ended_at, ?) >= ?
                ),
                app_totals AS (
                  SELECT
                    app_bundle,
                    app_label,
                    sum(overlap_ended_at - overlap_started_at) AS overlap_duration
                  FROM overlapping_visits
                  GROUP BY app_bundle, app_label
                )
                SELECT
                  a.app_label,
                  (
                    SELECT t.source_title
                    FROM latest_contexts c
                    JOIN threads t ON t.id=c.thread_id
                    WHERE t.source_app=a.app_label
                    ORDER BY c.captured_at DESC, c.thread_id ASC
                    LIMIT 1
                  ) AS source_title
                FROM app_totals a
                ORDER BY overlap_duration DESC, a.app_label ASC, a.app_bundle ASC
                LIMIT ?
                """, arguments: [fromMs, toMs, toMs, toMs, toMs, fromMs, boundedLimit])
                .map { (appLabel: $0["app_label"], sourceTitle: $0["source_title"]) }
        }
    }

    public func checkinRetryState(dayBucket: Int64) throws -> (attempts: Int, nextAttemptAtMs: EpochMs?) {
        try db.dbQueue.read { d in
            let attempts = Int(
                try String.fetchOne(
                    d,
                    sql: "SELECT value FROM settings WHERE key=?",
                    arguments: [checkinRetryAttemptsKey(dayBucket)]
                ) ?? "0"
            ) ?? 0
            let nextAttemptAtMs = try String.fetchOne(
                d,
                sql: "SELECT value FROM settings WHERE key=?",
                arguments: [checkinRetryNextAttemptKey(dayBucket)]
            ).flatMap(EpochMs.init)
            return (attempts, nextAttemptAtMs)
        }
    }

    public func recordCheckinRetry(dayBucket: Int64, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            let attempts = Int(
                try String.fetchOne(
                    d,
                    sql: "SELECT value FROM settings WHERE key=?",
                    arguments: [checkinRetryAttemptsKey(dayBucket)]
                ) ?? "0"
            ) ?? 0
            let delay: EpochMs = min(30_000 * EpochMs(1 << min(attempts, 10)), 3_600_000)
            try d.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?,?,?)",
                arguments: [checkinRetryAttemptsKey(dayBucket), String(attempts + 1), nowMs]
            )
            try d.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?,?,?)",
                arguments: [checkinRetryNextAttemptKey(dayBucket), String(nowMs + delay), nowMs]
            )
        }
    }

    public func clearCheckinRetry(dayBucket: Int64) throws {
        try db.dbQueue.write { d in
            try d.execute(
                sql: "DELETE FROM settings WHERE key IN (?,?)",
                arguments: [checkinRetryAttemptsKey(dayBucket), checkinRetryNextAttemptKey(dayBucket)]
            )
        }
    }

    private func checkinRetryAttemptsKey(_ dayBucket: Int64) -> String {
        "checkin_retry_attempts_\(dayBucket)"
    }

    private func checkinRetryNextAttemptKey(_ dayBucket: Int64) -> String {
        "checkin_retry_next_attempt_at_\(dayBucket)"
    }
}
