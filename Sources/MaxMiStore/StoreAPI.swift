import Foundation
import GRDB
import MaxMiCore

struct VersionCaptureMetadata: Codable {
    let schemaVersion: Int
    let contentKind: CaptureContentKind
    let parserID: String
    let parserVersion: Int
    let accumulationPolicy: CaptureAccumulationPolicy
    let offscreenPolicy: OffscreenCapturePolicy
    let trigger: CaptureTrigger
    let truncated: Bool
}

public struct CaptureInput: Sendable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
    }

    var legacyEnvelope: CaptureEnvelope {
        .legacy(sourceApp: sourceApp, sourceKey: sourceKey, sourceTitle: sourceTitle, content: content)
    }
}

public enum CommitResult: Equatable, Sendable {
    case deduplicated
    case committed(versionID: String, contentHash: String, delta: CaptureDelta)
}

public final class Store {
    let db: MaxMiDatabase
    let cipher: any FieldCipher
    public init(db: MaxMiDatabase, cipher: any FieldCipher) {
        self.db = db; self.cipher = cipher
    }

    /// Decrypt for reads; integrity/malformed failures become a marker, never a throw.
    func decryptOrMarker(_ stored: String) -> String {
        (try? cipher.decrypt(stored)) ?? "[unreadable memory]"
    }

    /// A NULL column, a decrypt failure, a JSON decode failure, and a schema version newer than
    /// this build are all the same case: fall back to the legacy adaptation of the rendered
    /// content. Never a throw, never a lost capture.
    func structuredOrLegacy(
        _ stored: String?,
        renderedContent: String,
        kind: CaptureContentKind
    ) -> CapturedContent {
        guard let stored,
              let plain = try? cipher.decrypt(stored),
              let content = CapturedContentEnvelope.decode(plain) else {
            return LegacyContentAdapter.adapt(renderedContent: renderedContent, kind: kind)
        }
        return content
    }

    /// Split content into items, fingerprint each (normalized), record novel ones.
    /// Returns true if ANY item was novel (=> commit). Fails OPEN (true) on error (spec §7).
    private func recordNovelFingerprints(_ content: String, threadID: String, nowMs: EpochMs,
                                         _ d: Database) -> Bool {
        // Items = non-empty lines (chat/mail/terminal); a single-line/document is one item.
        let items = content.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return true }
        var anyNovel = false
        for item in items {
            let fp = ContentHash.sha256Hex("\(threadID)\n\(item)")   // thread-scoped fingerprint
            do {
                let exists = try Int.fetchOne(d, sql:
                    "SELECT 1 FROM message_fingerprints WHERE fingerprint=? LIMIT 1", arguments: [fp]) != nil
                if !exists {
                    anyNovel = true
                    try d.execute(sql: "INSERT OR IGNORE INTO message_fingerprints (fingerprint, thread_id, seen_at) VALUES (?,?,?)",
                                  arguments: [fp, threadID, nowMs])
                }
            } catch {
                return true   // fail open: never lose a capture over a dedup error
            }
        }
        return anyNovel
    }

    public func commitCapture(_ input: CaptureInput, nowMs: EpochMs) throws -> CommitResult {
        try commitCapture(input.legacyEnvelope, nowMs: nowMs)
    }

    public func commitCapture(_ envelope: CaptureEnvelope, nowMs: EpochMs) throws -> CommitResult {
        let incomingHash = ContentHash.sha256Hex(envelope.content)
        let bucket = HourBucket.bucket(forMs: nowMs)
        let metadata = try captureMetadataJSON(envelope)

        return try db.dbQueue.write { d in
            // 1. Upsert the stable thread and retain the hash of the actual observed tree.
            let existing = try Row.fetchOne(d,
                sql: "SELECT id, last_tree_hash FROM threads WHERE source_app=? AND source_key=?",
                arguments: [envelope.sourceApp, envelope.sourceKey])
            let threadID: String
            if let existing {
                threadID = existing["id"]
                try d.execute(sql: "UPDATE threads SET source_title=?, last_tree_hash=?, updated_at=? WHERE id=?",
                              arguments: [envelope.sourceTitle, incomingHash, nowMs, threadID])
            } else {
                threadID = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?)
                    """, arguments: [threadID, envelope.sourceApp, envelope.sourceKey,
                                      envelope.sourceTitle, incomingHash, nowMs, nowMs])
            }

            // 2. Accumulate the raw latest context independently from semantic versions.
            let previousContext = try Row.fetchOne(d, sql: """
                SELECT content_ciphertext, content_hash, structured_ciphertext, content_kind
                FROM latest_contexts WHERE thread_id=?
                """, arguments: [threadID])
            let previousStored = previousContext?["content_ciphertext"] as String?
            let previousContextHash = previousContext?["content_hash"] as String?
            let previous = previousStored.flatMap { try? cipher.decrypt($0) }
            let previousStructured: CapturedContent? = previous.map { rendered in
                let kind = (previousContext?["content_kind"] as String?)
                    .flatMap(CaptureContentKind.init(rawValue:)) ?? .generic
                return structuredOrLegacy(previousContext?["structured_ciphertext"] as String?,
                                          renderedContent: rendered, kind: kind)
            }
            let accumulated = CaptureAccumulator.merge(
                previous: previousStructured,
                incoming: envelope.structured,
                policy: envelope.accumulationPolicy,
                maxCharacters: envelope.offscreenPolicy.maxCharacters
            )
            // An empty render is not new information, and under `.replace` accumulation it would
            // wipe a thread that already holds a real capture (a browser page whose AX tree went
            // blank for one poll, a window mid-relayout). Refused before any write, so both the
            // latest context and this hour's version keep the last non-empty render.
            if accumulated.rendered.isEmpty, previous?.isEmpty == false { return .deduplicated }
            let accumulatedHash = ContentHash.sha256Hex(accumulated.rendered)
            let accumulatedStored = try cipher.encrypt(accumulated.rendered)
            let structuredStored = try cipher.encrypt(
                try CapturedContentEnvelope.encode(accumulated.content))
            let contextTruncated = envelope.truncated
                || accumulated.rendered.count >= envelope.offscreenPolicy.maxCharacters
            try d.execute(sql: """
                INSERT INTO latest_contexts (
                  thread_id, version_id, content_ciphertext, content_hash, content_kind,
                  parser_id, parser_version, accumulation_policy, offscreen_mode,
                  offscreen_max_steps, offscreen_max_chars, trigger, captured_at,
                  character_count, truncated, structured_ciphertext
                ) VALUES (?,NULL,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(thread_id) DO UPDATE SET
                  content_ciphertext=excluded.content_ciphertext,
                  content_hash=excluded.content_hash,
                  content_kind=excluded.content_kind,
                  parser_id=excluded.parser_id,
                  parser_version=excluded.parser_version,
                  accumulation_policy=excluded.accumulation_policy,
                  offscreen_mode=excluded.offscreen_mode,
                  offscreen_max_steps=excluded.offscreen_max_steps,
                  offscreen_max_chars=excluded.offscreen_max_chars,
                  trigger=excluded.trigger,
                  captured_at=excluded.captured_at,
                  character_count=excluded.character_count,
                  truncated=excluded.truncated,
                  structured_ciphertext=excluded.structured_ciphertext
                """, arguments: [
                    threadID, accumulatedStored, accumulatedHash, envelope.contentKind.rawValue,
                    envelope.parserID, envelope.parserVersion, envelope.accumulationPolicy.rawValue,
                    envelope.offscreenPolicy.mode.rawValue, envelope.offscreenPolicy.maxSteps,
                    envelope.offscreenPolicy.maxCharacters, envelope.trigger.rawValue, nowMs,
                    accumulated.rendered.count, contextTruncated ? 1 : 0, structuredStored,
                ])
            if previousContextHash != nil, previousContextHash != accumulatedHash {
                try d.execute(sql: """
                    UPDATE latest_contexts
                    SET summary_status='pending', summary_attempts=0, summary_next_attempt_at=NULL
                    WHERE thread_id=?
                    """, arguments: [threadID])
            }

            // An identical observed tree refreshes latest-context recency but creates no work.
            if existing?["last_tree_hash"] as String? == incomingHash { return .deduplicated }

            // 3. Per-item fingerprint dedup: if no line is novel for this thread, skip.
            // Complements last_tree_hash (which catches identical whole trees) by catching
            // recaptures where only order/chrome changed but no new message appeared.
            if !recordNovelFingerprints(envelope.content, threadID: threadID, nowMs: nowMs, d) {
                return .deduplicated
            }

            let versionContent = accumulated.rendered
            let versionHash = ContentHash.sha256Hex(versionContent)
            let words = versionContent.split(whereSeparator: \.isWhitespace).count
            let storedContent = try cipher.encrypt(versionContent)

            // 4. Freeze-then-create: seal mutable versions from past hours.
            try d.execute(sql: "UPDATE versions SET is_frozen=1 WHERE thread_id=? AND is_frozen=0 AND hour_bucket<>?",
                          arguments: [threadID, bucket])

            // 5. Upsert this hour's accumulated version and attach parser metadata.
            let versionID: String
            if let vid = try String.fetchOne(d, sql: "SELECT id FROM versions WHERE thread_id=? AND hour_bucket=?",
                                             arguments: [threadID, bucket]) {
                try d.execute(sql: """
                    UPDATE versions SET content=?, content_hash=?, word_count=?, committed_at=?,
                                        extract_status='pending', is_frozen=0, metadata=?,
                                        structured_ciphertext=? WHERE id=?
                    """, arguments: [storedContent, versionHash, words, nowMs, metadata,
                                     structuredStored, vid])
                versionID = vid
            } else {
                let vid = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO versions (
                      id, thread_id, hour_bucket, content, content_hash, word_count,
                      is_frozen, committed_at, extract_status, metadata, structured_ciphertext
                    ) VALUES (?,?,?,?,?,?,0,?,'pending',?,?)
                    """, arguments: [vid, threadID, bucket, storedContent, versionHash, words,
                                     nowMs, metadata, structuredStored])
                versionID = vid
            }
            try d.execute(sql: "UPDATE latest_contexts SET version_id=? WHERE thread_id=?",
                          arguments: [versionID, threadID])
            return .committed(versionID: versionID, contentHash: versionHash,
                              delta: accumulated.delta)
        }
    }

    private func captureMetadataJSON(_ envelope: CaptureEnvelope) throws -> String {
        let metadata = VersionCaptureMetadata(
            schemaVersion: 1,
            contentKind: envelope.contentKind,
            parserID: envelope.parserID,
            parserVersion: envelope.parserVersion,
            accumulationPolicy: envelope.accumulationPolicy,
            offscreenPolicy: envelope.offscreenPolicy,
            trigger: envelope.trigger,
            truncated: envelope.truncated
        )
        return String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
    }
}

extension Store {
    public func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PendingVersion] {
        // Note: failed-baseline edge is accepted M1 semantics (an extract_status='failed' earlier version
        // can serve as baseline; its unextracted facts are suppressed from the newer diff).
        let reviewed = try cloudReviewedSourceApps()
        let localOnly = try cloudLocalOnlySourceApps()
        let reviewGateEnabled = try cloudReviewInitialized()
        return try db.dbQueue.read { d in
            let currentBucket = HourBucket.bucket(forMs: nowMs)
            let rows = try Row.fetchAll(d, sql: """
                SELECT v.id, v.thread_id, v.hour_bucket, v.content, v.content_hash,
                       v.structured_ciphertext, v.metadata, v.committed_at,
                       t.source_app, t.source_key, t.source_title,
                       (SELECT p.content FROM versions p
                         WHERE p.thread_id = v.thread_id AND p.hour_bucket < v.hour_bucket
                         ORDER BY p.hour_bucket DESC LIMIT 1) AS previous_frozen_content,
                       (SELECT p.structured_ciphertext FROM versions p
                         WHERE p.thread_id = v.thread_id AND p.hour_bucket < v.hour_bucket
                         ORDER BY p.hour_bucket DESC LIMIT 1) AS previous_structured_ciphertext,
                       (SELECT e.payload_ciphertext FROM capture_events e
                         WHERE e.kind = 'content_delta' AND e.version_id = v.id
                         ORDER BY e.at_ms DESC, e.id DESC LIMIT 1) AS delta_ciphertext
                FROM versions v JOIN threads t ON t.id = v.thread_id
                WHERE v.extract_status = 'pending'
                  AND (v.is_frozen = 1 OR v.hour_bucket < ? OR v.committed_at <= ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM retry_queue r
                    WHERE r.kind = 'extract' AND r.version_id = v.id AND r.next_attempt_at > ?
                  )
                ORDER BY v.committed_at
                """, arguments: [currentBucket, nowMs - idleThresholdMs, nowMs])
            return rows.filter { row in
                let sourceApp: String = row["source_app"]
                return !reviewGateEnabled || (reviewed.contains(sourceApp) && !localOnly.contains(sourceApp))
            }.map { row in
                let metadata = (try? JSONDecoder().decode(
                    VersionCaptureMetadata.self,
                    from: Data((row["metadata"] as String? ?? "").utf8)
                ))
                let kind = metadata?.contentKind ?? .generic
                let renderedContent = decryptOrMarker(row["content"])
                let current = structuredOrLegacy(
                    row["structured_ciphertext"] as String?,
                    renderedContent: renderedContent,
                    kind: kind
                )
                let previous = (row["previous_structured_ciphertext"] as String?).map {
                    structuredOrLegacy(
                        $0,
                        renderedContent: decryptOrMarker(row["previous_frozen_content"]),
                        kind: kind
                    )
                }
                let delta = decodeCaptureDelta(row["delta_ciphertext"] as String?) ?? .empty
                let sourceApp: String = row["source_app"]
                let sourceKey: String = row["source_key"]
                let sourceTitle: String? = row["source_title"]
                let url = captureURL(of: current)
                let capturedAt: EpochMs = row["committed_at"]
                let input = ExtractInputBuilder.build(
                    delta: delta,
                    previousStructured: previous,
                    metadata: ExtractMetadata(
                        sourceApp: sourceApp,
                        sourceKey: sourceKey,
                        title: sourceTitle,
                        url: url,
                        kind: kind,
                        capturedAt: capturedAt
                    )
                )
                return PendingVersion(
                    id: row["id"],
                    threadID: row["thread_id"],
                    hourBucket: row["hour_bucket"],
                    content: renderedContent,
                    contentHash: row["content_hash"],
                    sourceApp: sourceApp,
                    sourceKey: sourceKey,
                    sourceTitle: sourceTitle,
                    url: url,
                    contentKind: kind,
                    capturedAt: capturedAt,
                    renderedDelta: input.newContent,
                    previousCompactContent: input.previousContent,
                    previousFrozenContent: (row["previous_frozen_content"] as String?)
                        .map(decryptOrMarker)
                )
            }
        }
    }

    private func decodeCaptureDelta(_ ciphertext: String?) -> CaptureDelta? {
        guard let ciphertext, let plaintext = try? cipher.decrypt(ciphertext) else { return nil }
        return try? JSONDecoder().decode(CaptureDelta.self, from: Data(plaintext.utf8))
    }

    private func captureURL(of content: CapturedContent) -> String? {
        switch content {
        case .document(let document): return document.url
        case .generic(let page): return page.url
        case .conversation, .tasks, .calendar, .terminal: return nil
        }
    }

    public func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE versions SET extract_status='completed' WHERE id=? AND content_hash=?",
                          arguments: [versionID, contentHashRead])
            return d.changesCount > 0
        }
    }

    public func markExtractFailed(versionID: String) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE versions SET extract_status='failed' WHERE id=?", arguments: [versionID])
        }
    }

    public func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PendingDerivative] {
        try db.dbQueue.write { d in
            var inserted: [PendingDerivative] = []
            for fact in facts {
                let id = Ident.uuidv7(nowMs: nowMs)
                let hash = ContentHash.sha256Hex(fact)
                let storedContent = try cipher.encrypt(fact)
                try d.execute(sql: """
                    INSERT OR IGNORE INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                    VALUES (?,?,?,?,?,?,'pending')
                    """, arguments: [id, threadID, versionID, storedContent, hash, nowMs])
                if d.changesCount > 0 { inserted.append(PendingDerivative(id: id, content: fact)) }
            }
            return inserted
        }
    }

    public func markEmbedded(derivativeID: String) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE derivatives SET embedding_status='completed' WHERE id=?", arguments: [derivativeID])
        }
    }

    public func pendingDerivatives(versionID: String) throws -> [PendingDerivative] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT id, content FROM derivatives WHERE version_id=? AND embedding_status='pending'",
                             arguments: [versionID])
                .map { PendingDerivative(id: $0["id"], content: decryptOrMarker($0["content"])) }
        }
    }

    public func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            let existing = try Row.fetchOne(d, sql: """
                SELECT id, attempts FROM retry_queue
                WHERE kind=? AND ifnull(version_id,'')=ifnull(?,'') AND ifnull(derivative_id,'')=ifnull(?,'')
                """, arguments: [kind, versionID, derivativeID])
            let attempts = (existing?["attempts"] as Int? ?? 0)
            let backoff: EpochMs = min(30_000 * EpochMs(1 << min(attempts, 10)), 3_600_000)
            if let existing {
                try d.execute(sql: "UPDATE retry_queue SET attempts=?, next_attempt_at=?, last_error=? WHERE id=?",
                              arguments: [attempts + 1, nowMs + backoff, error, existing["id"] as String])
            } else {
                try d.execute(sql: """
                    INSERT INTO retry_queue (id, kind, version_id, derivative_id, attempts, next_attempt_at, last_error)
                    VALUES (?,?,?,?,1,?,?)
                    """, arguments: [Ident.uuidv7(nowMs: nowMs), kind, versionID, derivativeID, nowMs + backoff, error])
            }
        }
    }

    public func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM retry_queue WHERE next_attempt_at <= ? ORDER BY next_attempt_at",
                             arguments: [nowMs])
                .map { ($0["id"], $0["kind"], $0["version_id"], $0["derivative_id"]) }
        }
    }

    public func clearRetry(id: String) throws {
        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM retry_queue WHERE id=?", arguments: [id]) }
    }
}
