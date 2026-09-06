import Foundation
import GRDB
import MaxMiCore

/// One decrypted `capture_events` row. The payload stays JSON: the reader knows which shape a
/// kind carries, and keeping it opaque here means a new kind needs no change to this type.
public struct CaptureEventRecord: Sendable, Equatable {
    public let id: String
    /// The bundle id of the app this event belongs to, from the plaintext `app_bundle` column.
    /// Optional because the column is nullable, not because any current writer omits it.
    public let appBundle: String?
    public let threadID: String?
    public let versionID: String?
    public let atMs: EpochMs
    public let kind: CaptureEventKind
    public let trigger: CaptureTrigger
    /// nil when the column was NULL. A decrypt or read failure yields the same marker
    /// `decryptOrMarker` uses everywhere else, never a throw.
    public let payloadJSON: String?

    public init(id: String, appBundle: String?, threadID: String?, versionID: String?,
                atMs: EpochMs, kind: CaptureEventKind, trigger: CaptureTrigger,
                payloadJSON: String?) {
        self.id = id
        self.appBundle = appBundle
        self.threadID = threadID
        self.versionID = versionID
        self.atMs = atMs
        self.kind = kind
        self.trigger = trigger
        self.payloadJSON = payloadJSON
    }
}

extension Store {
    /// Records one capture event with an encrypted JSON payload, and bounds the ledger by AGE
    /// (30 days) rather than by row count — an activity window may reasonably look back a month.
    /// The trim is gated to at most once an hour so a capture does not pay for a DELETE.
    ///
    /// Callers are responsible for the privacy gate: `AppWiring.isActivityEligible(bundleID:)`
    /// must be satisfied before this is called (spec 8).
    public func recordCaptureEvent(
        kind: CaptureEventKind,
        // Plaintext, so a row is attributable to an app without decrypting its payload — the only
        // thing that makes spec 11 criterion 4 checkable. Required, with no default, so a new
        // event kind cannot silently write an unattributable row.
        appBundle: String?,
        threadID: String?,
        versionID: String?,
        trigger: CaptureTrigger,
        payload: some Encodable & Sendable,
        nowMs: EpochMs
    ) throws {
        let json = String(
            decoding: try CapturedContentEnvelope.makeEncoder().encode(payload), as: UTF8.self)
        let ciphertext = try cipher.encrypt(json)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (
                    id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                    payload_ciphertext, hour_bucket
                ) VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [
                    Ident.uuidv7(nowMs: nowMs), appBundle, threadID, versionID, nowMs,
                    kind.rawValue, trigger.rawValue, ciphertext, HourBucket.bucket(forMs: nowMs),
                ])
            try Self.trimCaptureEventsIfDue(d, nowMs: nowMs)
        }
    }

    /// The once-per-hour gate lives in `settings` next to every other scalar MaxMi keeps.
    static func trimCaptureEventsIfDue(_ d: Database, nowMs: EpochMs) throws {
        let lastTrim = try String.fetchOne(
            d, sql: "SELECT value FROM settings WHERE key=?",
            arguments: [CaptureEventRetention.lastTrimSettingsKey]
        ).flatMap { EpochMs($0) } ?? 0
        guard nowMs - lastTrim >= CaptureEventRetention.trimIntervalMs else { return }
        try d.execute(sql: "DELETE FROM capture_events WHERE at_ms < ?",
                      arguments: [CaptureEventRetention.cutoffMs(nowMs: nowMs)])
        try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                      arguments: [CaptureEventRetention.lastTrimSettingsKey, String(nowMs), nowMs])
    }

    /// Newest first, for the Capture Health window.
    public func recentCaptureEvents(limit: Int = 100) throws -> [CaptureEventRecord] {
        let boundedLimit = min(max(limit, 1), 500)
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                       payload_ciphertext
                FROM capture_events
                ORDER BY at_ms DESC, id DESC
                LIMIT ?
                """, arguments: [boundedLimit]).compactMap { self.eventRecord(from: $0) }
        }
    }

    /// Chronological, both bounds inclusive. This is the timeline's window read.
    public func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [CaptureEventRecord] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                       payload_ciphertext
                FROM capture_events
                WHERE at_ms >= ? AND at_ms <= ?
                ORDER BY at_ms ASC, id ASC
                """, arguments: [fromMs, toMs]).compactMap { self.eventRecord(from: $0) }
        }
    }

    /// An unrecognised `kind` or `trigger` drops the row rather than crashing: a database written
    /// by a newer build must not take the reader down. A payload that will not decrypt becomes
    /// the same `[unreadable memory]` marker every other read uses. An instance method, not
    /// `static`, because decryption needs `self.cipher`.
    private func eventRecord(from row: Row) -> CaptureEventRecord? {
        guard let kind = CaptureEventKind(rawValue: row["kind"]),
              let trigger = CaptureTrigger(rawValue: row["trigger"]) else { return nil }
        return CaptureEventRecord(
            id: row["id"],
            appBundle: row["app_bundle"],
            threadID: row["thread_id"],
            versionID: row["version_id"],
            atMs: row["at_ms"],
            kind: kind,
            trigger: trigger,
            payloadJSON: (row["payload_ciphertext"] as String?).map(decryptOrMarker)
        )
    }
}
