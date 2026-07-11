import Foundation
import GRDB
import MaxMiCore

public struct ActivitySession: Sendable {
    public let id, appBundle, appLabel: String
    public let startedAtMs: EpochMs
    public let endedAtMs: EpochMs?
    public let lastActivityAtMs: EpochMs
    public let summary: String?
    public let summaryStatus: String

    public init(id: String, appBundle: String, appLabel: String, startedAtMs: EpochMs, endedAtMs: EpochMs?, lastActivityAtMs: EpochMs, summary: String?, summaryStatus: String) {
        self.id = id
        self.appBundle = appBundle
        self.appLabel = appLabel
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.lastActivityAtMs = lastActivityAtMs
        self.summary = summary
        self.summaryStatus = summaryStatus
    }
}

public enum ActivityConsent: String, Sendable {
    case unset, granted, declined
}

extension Store {
    // MARK: - Visits

    public func openVisit(appBundle: String, appLabel: String, nowMs: EpochMs) throws -> String {
        try db.dbQueue.write { d in
            let id = Ident.uuidv7(nowMs: nowMs)
            let dayBucket = Self.dayBucket(forMs: nowMs, timeZone: .current)
            try d.execute(sql: """
                INSERT INTO activity_app_visits (id, app_bundle, app_label, started_at, ended_at, day_bucket)
                VALUES (?,?,?,?,NULL,?)
                """, arguments: [id, appBundle, appLabel, nowMs, dayBucket])
            return id
        }
    }

    public func closeOpenVisits(nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE activity_app_visits SET ended_at=? WHERE ended_at IS NULL", arguments: [nowMs])
        }
    }

    // MARK: - Sessions

    public func recordActivityCapture(appBundle: String, appLabel: String, versionID: String?, content: String, nowMs: EpochMs) throws -> String {
        try db.dbQueue.write { d in
            // Find the single open session
            let openRow = try Row.fetchOne(d, sql: """
                SELECT id, app_bundle, last_activity_at FROM activity_sessions WHERE ended_at IS NULL
                """)

            let sessionID: String
            if let openRow = openRow {
                let openApp = openRow["app_bundle"] as String
                let openID = openRow["id"] as String

                if openApp == appBundle {
                    // Same app: reuse session
                    sessionID = openID
                } else {
                    // Different app: close old, open new (defensive; AppWiring should have closed)
                    try d.execute(sql: "UPDATE activity_sessions SET ended_at=?, updated_at=? WHERE id=?",
                                  arguments: [nowMs, nowMs, openID])
                    sessionID = try insertNewSession(d, appBundle: appBundle, appLabel: appLabel, nowMs: nowMs)
                }
            } else {
                // No open session: insert new
                sessionID = try insertNewSession(d, appBundle: appBundle, appLabel: appLabel, nowMs: nowMs)
            }

            // Insert evidence (coalesced by content_hash)
            let hash = ContentHash.sha256Hex(content)
            let encrypted = try cipher.encrypt(content)
            let evidenceID = Ident.uuidv7(nowMs: nowMs)
            try d.execute(sql: """
                INSERT OR IGNORE INTO activity_session_evidence (id, session_id, version_id, captured_at, content_hash, content_ciphertext)
                VALUES (?,?,?,?,?,?)
                """, arguments: [evidenceID, sessionID, versionID, nowMs, hash, encrypted])

            // Bump last_activity_at even on coalesced duplicate
            try d.execute(sql: "UPDATE activity_sessions SET last_activity_at=?, updated_at=? WHERE id=?",
                          arguments: [nowMs, nowMs, sessionID])

            return sessionID
        }
    }

    private func insertNewSession(_ d: Database, appBundle: String, appLabel: String, nowMs: EpochMs) throws -> String {
        let id = Ident.uuidv7(nowMs: nowMs)
        let dayBucket = Self.dayBucket(forMs: nowMs, timeZone: .current)
        try d.execute(sql: """
            INSERT INTO activity_sessions (id, app_bundle, app_label, started_at, ended_at, last_activity_at, day_bucket, summary_status, created_at, updated_at)
            VALUES (?,?,?,?,NULL,?,?,'pending',?,?)
            """, arguments: [id, appBundle, appLabel, nowMs, nowMs, dayBucket, nowMs, nowMs])
        return id
    }

    public func closeActiveSession(nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE activity_sessions SET ended_at=?, updated_at=? WHERE ended_at IS NULL",
                          arguments: [nowMs, nowMs])
        }
    }

    public func closeSession(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE activity_sessions SET ended_at=?, updated_at=? WHERE id=?",
                          arguments: [nowMs, nowMs, id])
        }
    }

    public func closeIdleSessions(idleGapMs: EpochMs, nowMs: EpochMs) throws -> [String] {
        try db.dbQueue.write { d in
            let threshold = nowMs - idleGapMs
            let ids = try String.fetchAll(d, sql: """
                SELECT id FROM activity_sessions WHERE ended_at IS NULL AND last_activity_at < ?
                """, arguments: [threshold])
            if !ids.isEmpty {
                try d.execute(sql: "UPDATE activity_sessions SET ended_at=?, updated_at=? WHERE ended_at IS NULL AND last_activity_at < ?",
                              arguments: [nowMs, nowMs, threshold])
            }
            return ids
        }
    }

    public func closeOpenSessions(nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE activity_sessions SET ended_at=?, updated_at=? WHERE ended_at IS NULL",
                          arguments: [nowMs, nowMs])
        }
    }

    // MARK: - Summary

    public func setSessionSummary(_ id: String, summary: String, expectedSourceHash: String, modelID: String, promptVersion: String, nowMs: EpochMs) throws -> Bool {
        try db.dbQueue.write { d in
            // Recompute source hash in-txn
            let currentHash = try computeSourceHash(d, sessionID: id)
            guard currentHash == expectedSourceHash else { return false }

            let encrypted = try cipher.encrypt(summary)
            try d.execute(sql: """
                UPDATE activity_sessions
                SET summary_ciphertext=?, summary_status='summarized', source_hash=?, model_id=?, prompt_version=?, updated_at=?
                WHERE id=?
                """, arguments: [encrypted, currentHash, modelID, promptVersion, nowMs, id])
            return true
        }
    }

    public func markSessionSummaryFailed(_ id: String, error: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            let row = try Row.fetchOne(d, sql: "SELECT summary_attempts FROM activity_sessions WHERE id=?", arguments: [id])
            let attempts = (row?["summary_attempts"] as Int?) ?? 0
            let backoff: EpochMs = min(30_000 * EpochMs(1 << min(attempts, 10)), 3_600_000)
            let nextAttempt = nowMs + backoff

            try d.execute(sql: """
                UPDATE activity_sessions
                SET summary_status='failed', summary_attempts=?, summary_next_attempt_at=?, updated_at=?
                WHERE id=?
                """, arguments: [attempts + 1, nextAttempt, nowMs, id])
        }
    }

    public func sessionSourceHash(_ id: String) throws -> String {
        try db.dbQueue.read { d in
            try computeSourceHash(d, sessionID: id)
        }
    }

    private func computeSourceHash(_ d: Database, sessionID: String) throws -> String {
        let hashes = try String.fetchAll(d, sql: """
            SELECT content_hash FROM activity_session_evidence WHERE session_id=? ORDER BY content_hash
            """, arguments: [sessionID])
        return ContentHash.sha256Hex(hashes.joined(separator: "\n"))
    }

    public func sessionsNeedingSummary(nowMs: EpochMs, limit: Int) throws -> [ActivitySession] {
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, app_label, started_at, ended_at, last_activity_at, summary_ciphertext, summary_status
                FROM activity_sessions
                WHERE ended_at IS NOT NULL
                  AND (summary_status='pending' OR (summary_status='failed' AND summary_next_attempt_at<=?))
                ORDER BY started_at DESC
                LIMIT ?
                """, arguments: [nowMs, limit])
            return rows.map { mapActivitySession($0) }
        }
    }

    // MARK: - Queries

    public func recentSessions(limit: Int) throws -> [ActivitySession] {
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, app_label, started_at, ended_at, last_activity_at, summary_ciphertext, summary_status
                FROM activity_sessions
                ORDER BY started_at DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { mapActivitySession($0) }
        }
    }

    public func sessionEvidence(_ id: String) throws -> [String] {
        try db.dbQueue.read { d in
            try String.fetchAll(d, sql: """
                SELECT content_ciphertext FROM activity_session_evidence WHERE session_id=? ORDER BY captured_at
                """, arguments: [id])
                .map { try cipher.decrypt($0) }
        }
    }

    private func mapActivitySession(_ row: Row) -> ActivitySession {
        let encryptedSummary = row["summary_ciphertext"] as String?
        let summary = encryptedSummary.flatMap { try? cipher.decrypt($0) }
        return ActivitySession(
            id: row["id"],
            appBundle: row["app_bundle"],
            appLabel: row["app_label"],
            startedAtMs: row["started_at"],
            endedAtMs: row["ended_at"],
            lastActivityAtMs: row["last_activity_at"],
            summary: summary,
            summaryStatus: row["summary_status"]
        )
    }

    // MARK: - Settings & Privacy

    public func activityConsent() throws -> ActivityConsent {
        let raw = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key='activity_consent'")
        }
        guard let raw = raw, let consent = ActivityConsent(rawValue: raw) else {
            return .unset
        }
        return consent
    }

    public func setActivityConsent(_ c: ActivityConsent) throws {
        try db.dbQueue.write { d in
            let nowMs = epochNowMs()
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                          arguments: ["activity_consent", c.rawValue, nowMs])
        }
    }

    public func activityEnabled() throws -> Bool {
        try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key='activity_enabled'") == "true"
        }
    }

    public func setActivityEnabled(_ on: Bool) throws {
        try db.dbQueue.write { d in
            let nowMs = epochNowMs()
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                          arguments: ["activity_enabled", on ? "true" : "false", nowMs])
        }
    }

    public func activityExcludedApps() throws -> Set<String> {
        try readSet("activity_excluded_apps")
    }

    public func setActivityExcluded(_ bundle: String, _ excluded: Bool) throws {
        try mutateSet("activity_excluded_apps", element: bundle, insert: excluded, nowMs: epochNowMs())
    }

    public func deleteActivityForApp(_ appBundle: String) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM activity_app_visits WHERE app_bundle=?", arguments: [appBundle])
            try d.execute(sql: "DELETE FROM activity_sessions WHERE app_bundle=?", arguments: [appBundle])
        }
    }

    public func setActivityExcludedAndDeleteActivity(_ bundle: String, excluded: Bool) throws {
        try db.dbQueue.write { d in
            let nowMs = epochNowMs()

            // Read current set (JSON format)
            var set: Set<String> = []
            if let json = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?", arguments: ["activity_excluded_apps"]) {
                if let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                    set = Set(arr)
                } else {
                    NSLog("MaxMi: activity_excluded_apps JSON decode failed, treating as empty: \(json)")
                }
            }

            // Update set
            if excluded {
                set.insert(bundle)
            } else {
                set.remove(bundle)
            }

            // Write updated set (JSON format)
            let json = String(decoding: try JSONEncoder().encode(set.sorted()), as: UTF8.self)
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                          arguments: ["activity_excluded_apps", json, nowMs])

            // Delete activity data if excluding
            if excluded {
                try d.execute(sql: "DELETE FROM activity_app_visits WHERE app_bundle=?", arguments: [bundle])
                try d.execute(sql: "DELETE FROM activity_sessions WHERE app_bundle=?", arguments: [bundle])
            }
        }
    }

    public func observedActivityApps() throws -> [(bundle: String, label: String)] {
        // Read excluded apps first (outside the main read transaction)
        let excludedSet = try activityExcludedApps()

        return try db.dbQueue.read { d in
            // Union of observed apps from sessions AND visits, plus excluded apps
            let rows = try Row.fetchAll(d, sql: """
                WITH observed AS (
                    SELECT app_bundle, app_label, MAX(started_at) AS latest_ts
                    FROM activity_sessions
                    GROUP BY app_bundle
                    UNION
                    SELECT app_bundle, app_label, MAX(started_at) AS latest_ts
                    FROM activity_app_visits
                    GROUP BY app_bundle
                )
                SELECT app_bundle,
                       MAX(app_label) AS app_label
                FROM observed
                GROUP BY app_bundle
                ORDER BY app_label, app_bundle
                """)

            var result = rows.map { (bundle: $0["app_bundle"] as String, label: $0["app_label"] as String) }

            // Add excluded apps that aren't in the observed set
            let observedBundles = Set(result.map { $0.bundle })
            for excludedBundle in excludedSet {
                if !observedBundles.contains(excludedBundle) {
                    result.append((bundle: excludedBundle, label: excludedBundle))
                }
            }

            // Sort final result by label, then bundle (deterministic)
            result.sort { lhs, rhs in
                if lhs.label != rhs.label {
                    return lhs.label < rhs.label
                }
                return lhs.bundle < rhs.bundle
            }

            return result
        }
    }

    // MARK: - Helpers

    public static func dayBucket(forMs ms: EpochMs, timeZone: TimeZone) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let calendar = Calendar.current
        var cal = calendar
        cal.timeZone = timeZone
        let components = cal.dateComponents([.year, .month, .day], from: date)
        guard let dayStart = cal.date(from: components) else {
            return ms / (24 * 3_600_000)
        }
        return Int64(dayStart.timeIntervalSince1970 * 1000)
    }
}
