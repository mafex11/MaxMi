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

private struct CheckinVersionSource {
    let threadID: String
    let sourceApp: String
    let sourceKey: String
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
        let privacy = try sourceCloudEligibility()

        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, title_ciphertext, details_ciphertext, source_refs, detected_at
                FROM agent_action_items
                WHERE status='open'
                ORDER BY detected_at DESC, id ASC
                """)

            let refsByItemID = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["id"] as String, sourceReferences(from: $0))
            })
            let sourceIDs = Set(refsByItemID.values.flatMap { $0 })
            let sources = try checkinVersionSources(d, versionIDs: sourceIDs)

            return rows.compactMap { row -> CheckinOpenItemRecord? in
                let itemID: String = row["id"]
                let refs = refsByItemID[itemID] ?? []
                guard allowsCheckinActionItem(refs, sources: sources, privacy: privacy) else {
                    return nil
                }
                let titleCiphertext: String = row["title_ciphertext"]
                guard let title = try? cipher.decrypt(titleCiphertext) else { return nil }
                let details = (row["details_ciphertext"] as String?).flatMap {
                    try? cipher.decrypt($0)
                }
                return CheckinOpenItemRecord(
                    id: itemID,
                    title: title,
                    details: details,
                    detectedAtMs: row["detected_at"],
                    sourceApp: refs.compactMap { sources[$0]?.sourceApp }.first
                )
            }.prefix(boundedLimit).map { $0 }
        }
    }

    public func resolvedCheckinItems(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) throws -> (count: Int, titles: [String]) {
        let boundedLimit = max(limit, 0)
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, title_ciphertext, source_refs
                FROM agent_action_items
                WHERE status='resolved' AND resolved_at >= ? AND resolved_at <= ?
                ORDER BY resolved_at DESC, id ASC
                """, arguments: [fromMs, toMs])
            let refsByItemID = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["id"] as String, sourceReferences(from: $0))
            })
            let sourceIDs = Set(refsByItemID.values.flatMap { $0 })
            let sources = try checkinVersionSources(d, versionIDs: sourceIDs)
            let allowed = rows.filter { row in
                let itemID: String = row["id"]
                return allowsCheckinActionItem(
                    refsByItemID[itemID] ?? [],
                    sources: sources,
                    privacy: privacy
                )
            }
            guard boundedLimit > 0 else { return (allowed.count, []) }
            return (
                allowed.count,
                allowed.prefix(boundedLimit).compactMap {
                    try? cipher.decrypt($0["title_ciphertext"] as String)
                }
            )
        }
    }

    public func checkinCalendarCaptures(
        fromMs: EpochMs,
        toMs: EpochMs,
        limit: Int
    ) throws -> [CalendarEvent] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }
        let privacy = try sourceCloudEligibility()

        return try db.dbQueue.read { d in
            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "t.source_app",
                threadIDColumn: "t.id",
                urlColumn: "t.source_key"
            )
            let rows = try Row.fetchAll(d, sql: """
                SELECT c.thread_id, c.content_ciphertext, c.structured_ciphertext,
                       t.source_app, t.source_key
                FROM latest_contexts c JOIN threads t ON t.id=c.thread_id
                WHERE (\(privacySQL.condition))
                  AND c.content_kind='calendar' AND c.captured_at >= ? AND c.captured_at <= ?
                ORDER BY c.captured_at DESC, c.thread_id ASC
                """, arguments: StatementArguments(privacySQL.arguments + [fromMs, toMs]))
            let events = rows.flatMap { row -> [CalendarEvent] in
                let sourceApp: String = row["source_app"]
                let threadID: String = row["thread_id"]
                let sourceKey: String = row["source_key"]
                guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                    return []
                }
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
        let privacy = try sourceCloudEligibility()

        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
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
                    SELECT t.id
                    FROM latest_contexts c
                    JOIN threads t ON t.id=c.thread_id
                    WHERE t.source_app=a.app_label
                    ORDER BY c.captured_at DESC, c.thread_id ASC
                    LIMIT 1
                  ) AS thread_id,
                  (
                    SELECT t.source_app
                    FROM latest_contexts c
                    JOIN threads t ON t.id=c.thread_id
                    WHERE t.source_app=a.app_label
                    ORDER BY c.captured_at DESC, c.thread_id ASC
                    LIMIT 1
                  ) AS source_app,
                  (
                    SELECT t.source_key
                    FROM latest_contexts c
                    JOIN threads t ON t.id=c.thread_id
                    WHERE t.source_app=a.app_label
                    ORDER BY c.captured_at DESC, c.thread_id ASC
                    LIMIT 1
                  ) AS source_key,
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
                """, arguments: [fromMs, toMs, toMs, toMs, toMs, fromMs])
            return rows.compactMap { row -> (appLabel: String, sourceTitle: String?)? in
                let threadID: String? = row["thread_id"]
                if let threadID {
                    let sourceApp: String = row["source_app"]
                    let sourceKey: String = row["source_key"]
                    guard privacy.allows(sourceApp: sourceApp, threadID: threadID, url: sourceKey) else {
                        return nil
                    }
                }
                return (appLabel: row["app_label"], sourceTitle: row["source_title"])
            }.prefix(boundedLimit).map { $0 }
        }
    }

    private func sourceReferences(from row: Row) -> [String] {
        guard let json: String = row["source_refs"],
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else {
            return []
        }
        return ids
    }

    private func checkinVersionSources(
        _ database: Database,
        versionIDs: Set<String>
    ) throws -> [String: CheckinVersionSource] {
        guard !versionIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(database, sql: """
            SELECT v.id AS version_id, t.id AS thread_id, t.source_app, t.source_key
            FROM versions v JOIN threads t ON t.id=v.thread_id
            WHERE v.id IN (\(Self.placeholders(versionIDs.count)))
            """, arguments: StatementArguments(versionIDs.sorted()))
        return Dictionary(uniqueKeysWithValues: rows.map {
            (
                $0["version_id"] as String,
                CheckinVersionSource(
                    threadID: $0["thread_id"],
                    sourceApp: $0["source_app"],
                    sourceKey: $0["source_key"]
                )
            )
        })
    }

    private func allowsCheckinActionItem(
        _ refs: [String],
        sources: [String: CheckinVersionSource],
        privacy: SourceCloudEligibility
    ) -> Bool {
        refs.allSatisfy { versionID in
            guard let source = sources[versionID] else { return false }
            return privacy.allows(
                sourceApp: source.sourceApp,
                threadID: source.threadID,
                url: source.sourceKey
            )
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
