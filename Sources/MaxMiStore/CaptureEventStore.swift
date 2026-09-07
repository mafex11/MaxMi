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

/// Which events one commit warrants, in write order.
///
/// The rule lives here, not in `AppWiring`, so it is a unit test: `AppWiring` owns the app, the
/// trigger and the previous URL (spec 12 Q12), but "one `content_delta` per committed changing
/// capture and none for a `.deduplicated` commit" is a rule, and the `MaxMi` executable target has
/// no test target.
public enum CaptureEventDecision {
    /// One event to write for a committed capture. `threadID` is intentionally optional: the
    /// event is still useful and attributable by `appBundle` when a post-commit thread lookup
    /// fails or finds no row.
    public struct Event: Sendable, Equatable {
        public let kind: CaptureEventKind
        public let threadID: String?

        public init(kind: CaptureEventKind, threadID: String?) {
            self.kind = kind
            self.threadID = threadID
        }
    }

    public static func kinds(for result: CommitResult, trigger: CaptureTrigger,
                            hasBrowserURL: Bool) -> [CaptureEventKind] {
        // A deduplicated commit changed nothing, so there is nothing to record.
        guard case .committed(_, _, let delta) = result else { return [] }
        var kinds: [CaptureEventKind] = []
        // NOT `!delta.isEmpty`: a .tasks or .calendar delta carries no arrays, so `isEmpty` is
        // always true for those two shapes (spec 5a) and gating on it would drop every Reminders
        // and Calendar event.
        if delta.hasRecordableChange { kinds.append(.contentDelta) }
        if !delta.dialogBlocks.isEmpty { kinds.append(.dialog) }
        if trigger == .browserNavigation, hasBrowserURL { kinds.append(.navigation) }
        return kinds
    }

    /// Preserves every event kind warranted by a commit when its optional thread association is
    /// unavailable. The writer stores nil as `capture_events.thread_id`, while still recording
    /// the required app bundle.
    public static func events(
        for result: CommitResult,
        trigger: CaptureTrigger,
        hasBrowserURL: Bool,
        threadID: String?
    ) -> [Event] {
        kinds(for: result, trigger: trigger, hasBrowserURL: hasBrowserURL)
            .map { Event(kind: $0, threadID: threadID) }
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
        let privacy = try sourceCloudEligibility()
        return try db.dbQueue.read { d in
            let privacySQL = privacy.sqlFilter(
                sourceAppColumn: "t.source_app",
                threadIDColumn: "t.id",
                urlColumn: "t.source_key"
            )
            return try Row.fetchAll(d, sql: """
                SELECT e.id, e.app_bundle, e.thread_id, e.version_id, e.at_ms, e.kind, e.trigger,
                       e.payload_ciphertext, t.id AS policy_thread_id, t.source_app,
                       t.source_key
                FROM capture_events e
                LEFT JOIN versions v ON v.id=e.version_id
                LEFT JOIN threads t ON t.id=coalesce(e.thread_id, v.thread_id)
                WHERE e.at_ms >= ? AND e.at_ms <= ?
                  AND (
                    (e.thread_id IS NULL AND e.version_id IS NULL)
                    OR (t.id IS NOT NULL AND (\(privacySQL.condition)))
                  )
                ORDER BY e.at_ms ASC, e.id ASC
                """, arguments: StatementArguments([fromMs, toMs] + privacySQL.arguments))
                .compactMap { row -> CaptureEventRecord? in
                    if let threadID: String = row["policy_thread_id"] {
                        let sourceApp: String = row["source_app"]
                        let sourceKey: String = row["source_key"]
                        guard privacy.allows(
                            sourceApp: sourceApp,
                            threadID: threadID,
                            url: sourceKey
                        ) else {
                            return nil
                        }
                    }
                    return self.eventRecord(from: row)
                }
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

    // MARK: - Event context lookups

    /// The thread id for an app + clean source key, or nil when the thread does not exist yet.
    /// One indexed read on the existing `UNIQUE(source_app, source_key)`.
    ///
    /// Separate from `threadID(forKey:)`, which ignores the app and throws: an event write must
    /// not fail a capture, and two apps can legitimately share a source key.
    public func threadID(sourceApp: String, sourceKey: String) throws -> String? {
        try db.dbQueue.read { d in
            try String.fetchOne(
                d, sql: "SELECT id FROM threads WHERE source_app=? AND source_key=?",
                arguments: [sourceApp, sourceKey])
        }
    }

    /// The URL currently stored for a thread, for a `navigation` event's `fromURL`. Must be read
    /// BEFORE `commitCapture`, which overwrites the row.
    ///
    /// nil for a thread that does not exist, for a shape that has no URL, and for an unreadable
    /// payload — all of which mean "no previous URL to report", never an error.
    public func previousContextURL(sourceApp: String, sourceKey: String) throws -> String? {
        let row = try db.dbQueue.read { d in
            try Row.fetchOne(d, sql: """
                SELECT c.content_ciphertext, c.structured_ciphertext, c.content_kind
                FROM latest_contexts c JOIN threads t ON t.id = c.thread_id
                WHERE t.source_app=? AND t.source_key=?
                """, arguments: [sourceApp, sourceKey])
        }
        guard let row else { return nil }
        let kind = (row["content_kind"] as String?)
            .flatMap(CaptureContentKind.init(rawValue:)) ?? .generic
        let structured = structuredOrLegacy(
            row["structured_ciphertext"] as String?,
            renderedContent: decryptOrMarker(row["content_ciphertext"]),
            kind: kind)
        switch structured {
        case .generic(let page):    return page.url
        case .document(let value):  return value.url
        default:                    return nil
        }
    }
}
