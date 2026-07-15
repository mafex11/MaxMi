import Foundation
import GRDB
import MaxMiCore

public enum CapturePauseState: Sendable, Equatable {
    case active(untilMs: EpochMs?)
    case inactive

    public func isPaused(at nowMs: EpochMs) -> Bool {
        switch self {
        case .active(nil): return true
        case .active(let untilMs?): return untilMs > nowMs
        case .inactive: return false
        }
    }
}

public struct PausedThreadInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceApp: String?
    public let sourceTitle: String?

    public init(id: String, sourceApp: String?, sourceTitle: String?) {
        self.id = id
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
    }
}

public enum CloudProcessingState: String, Sendable, Equatable {
    case pendingReview
    case allowed
    case localOnly
}

extension Store {
    /// One-time upgrade behavior: sources already present before the review gate shipped retain
    /// their old cloud-processing behavior. Source apps first seen afterwards require review.
    public func bootstrapCloudProcessingReview(nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            guard try String.fetchOne(database, sql: "SELECT value FROM settings WHERE key='cloud_review_initialized'") == nil else {
                return
            }
            let apps = try String.fetchAll(database, sql: "SELECT DISTINCT source_app FROM threads ORDER BY source_app")
            let json = String(decoding: try JSONEncoder().encode(apps), as: UTF8.self)
            try database.execute(
                sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                arguments: ["cloud_reviewed_source_apps", json, nowMs]
            )
            try database.execute(
                sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                arguments: ["cloud_review_initialized", "true", nowMs]
            )
        }
    }

    public func cloudProcessingState(for sourceApp: String) throws -> CloudProcessingState {
        let reviewed = try readSet("cloud_reviewed_source_apps")
        guard reviewed.contains(sourceApp) else { return .pendingReview }
        return try readSet("cloud_local_only_source_apps").contains(sourceApp) ? .localOnly : .allowed
    }

    public func setCloudProcessing(_ sourceApp: String, allowed: Bool, nowMs: EpochMs) throws {
        try mutateSet("cloud_reviewed_source_apps", element: sourceApp, insert: true, nowMs: nowMs)
        try mutateSet("cloud_local_only_source_apps", element: sourceApp, insert: !allowed, nowMs: nowMs)
    }

    public func cloudReviewedSourceApps() throws -> Set<String> { try readSet("cloud_reviewed_source_apps") }
    public func cloudLocalOnlySourceApps() throws -> Set<String> { try readSet("cloud_local_only_source_apps") }
    // Review gate disabled for Minimi-style simplicity: new sources auto-process instead of waiting
    // for per-source approval (the approval UI is hidden). Was: settingValue == "true". The stored
    // `cloud_review_initialized` value is left intact so the gate can be re-enabled by restoring this.
    public func cloudReviewInitialized() throws -> Bool { false }

    public func capturePauseState(nowMs: EpochMs) throws -> CapturePauseState {
        let raw = try settingValue("capture_pause")
        guard let raw else { return .inactive }
        if raw == "indefinite" { return .active(untilMs: nil) }
        guard let until = EpochMs(raw), until > nowMs else { return .inactive }
        return .active(untilMs: until)
    }

    public func setCapturePaused(untilMs: EpochMs?, nowMs: EpochMs) throws {
        try writeSetting("capture_pause", value: untilMs.map(String.init) ?? "indefinite", nowMs: nowMs)
    }

    public func clearCapturePause(nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM settings WHERE key='capture_pause'")
        }
    }

    public func blockedDomains() throws -> Set<String> { try readSet("blocked_domains") }

    @discardableResult
    public func setDomain(_ input: String, blocked: Bool, nowMs: EpochMs) throws -> String? {
        guard let domain = Self.normalizeDomain(input) else { return nil }
        try mutateSet("blocked_domains", element: domain, insert: blocked, nowMs: nowMs)
        return domain
    }

    public func pausedThreadInfo() throws -> [PausedThreadInfo] {
        let keys = try pausedThreads().sorted()
        return try db.dbQueue.read { database in
            try keys.map { key in
                let row = try Row.fetchOne(database, sql: """
                    SELECT source_app, source_title FROM threads
                    WHERE source_key = ? ORDER BY updated_at DESC, id ASC LIMIT 1
                    """, arguments: [key])
                return PausedThreadInfo(
                    id: key,
                    sourceApp: row?["source_app"],
                    sourceTitle: row?["source_title"]
                )
            }
        }
    }

    public func retentionDays() throws -> Int? {
        guard let raw = try settingValue("retention_days"), let days = Int(raw), days > 0 else { return nil }
        return days
    }

    public func setRetentionDays(_ days: Int?, nowMs: EpochMs) throws {
        if let days {
            try writeSetting("retention_days", value: String(max(days, 1)), nowMs: nowMs)
        } else {
            try db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM settings WHERE key='retention_days'")
            }
        }
    }

    public static func normalizeDomain(_ input: String) -> String? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while raw.hasPrefix("*.") { raw.removeFirst(2) }
        while raw.hasPrefix(".") { raw.removeFirst() }
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty,
              !host.contains(" "), host.contains(".") || host == "localhost" else { return nil }
        return host
    }

    private func settingValue(_ key: String) throws -> String? {
        try db.dbQueue.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM settings WHERE key=?", arguments: [key])
        }
    }

    private func writeSetting(_ key: String, value: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                arguments: [key, value, nowMs]
            )
        }
    }
}
