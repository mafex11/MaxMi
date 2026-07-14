import Foundation
import GRDB
import MaxMiCore

public struct MeetingRecord: Sendable {
    public let id: String
    public let threadID: String
    public let versionID: String?
    public let app: String
    public let title: String?
    public let startedAtMs: EpochMs
    public let endedAtMs: EpochMs?
    public let state: String
    public let captureMode: String
    public let transcriptionStatus: String
}

public struct MeetingContext: Sendable {
    public let record: MeetingRecord
    public let transcript: String
    public let facts: [String]
}

public struct MeetingSearchHit: Sendable {
    public let record: MeetingRecord
    public let distance: Double
}

extension Store {
    public func commitMeeting(id: String, app: String, title: String?, transcript: String,
                              startedAtMs: EpochMs, endedAtMs: EpochMs, captureMode: String,
                              transcriptionStatus: String, nowMs: EpochMs) throws -> String {
        let isVoiceNote = app == "Voice Note" || captureMode.hasPrefix("voice-note")
        let threadKey = isVoiceNote ? "voice-note:\(id)" : "meeting:\(id)"
        let sourceApp = isVoiceNote ? "Voice Note" : "Meeting"
        let hash = ContentHash.sha256Hex(transcript)
        let bucket = HourBucket.bucket(forMs: startedAtMs)
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        let storedContent = try cipher.encrypt(transcript)
        let meta = String(decoding: try JSONSerialization.data(withJSONObject: ["meetingId": id]), as: UTF8.self)
        return try db.dbQueue.write { d in
            let threadID = Ident.uuidv7(nowMs: nowMs)
            try d.execute(sql: """
                INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [threadID, sourceApp, threadKey, title, hash, startedAtMs, endedAtMs])
            let vid = Ident.uuidv7(nowMs: nowMs)
            try d.execute(sql: """
                INSERT INTO versions (id, thread_id, hour_bucket, content, content_hash, word_count, is_frozen, committed_at, extract_status, metadata)
                VALUES (?,?,?,?,?,?,1,?, 'pending', ?)
                """, arguments: [vid, threadID, bucket, storedContent, hash, words, nowMs, meta])
            try d.execute(sql: """
                INSERT INTO meetings (id, thread_id, version_id, app, title, started_at, ended_at, state, capture_mode, transcription_status)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [id, threadID, vid, app, title, startedAtMs, endedAtMs,
                                 transcriptionStatus == "partial" ? "failed" : "completed", captureMode, transcriptionStatus])
            try d.execute(sql: """
                INSERT INTO latest_contexts (
                  thread_id, version_id, content_ciphertext, content_hash, content_kind,
                  parser_id, parser_version, accumulation_policy, offscreen_mode,
                  offscreen_max_steps, offscreen_max_chars, trigger, captured_at,
                  character_count, truncated, summary_status
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,'pending')
                """, arguments: [
                    threadID, vid, storedContent, hash,
                    isVoiceNote ? CaptureContentKind.voiceNote.rawValue : CaptureContentKind.meeting.rawValue,
                    isVoiceNote ? "VoiceNoteTranscriber" : "MeetingTranscriber", 1,
                    CaptureAccumulationPolicy.replace.rawValue, OffscreenCaptureMode.visibleOnly.rawValue,
                    0, 128_000, CaptureTrigger.unknown.rawValue, endedAtMs, transcript.count,
                ])
            return id
        }
    }

    public func recentMeetings(limit: Int) throws -> [MeetingRecord] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM meetings ORDER BY started_at DESC LIMIT ?", arguments: [limit]).map(Self.rec)
        }
    }

    public func recentMeetings(
        filter: RetrievalFilter,
        threadID: String? = nil,
        offset: Int,
        limit: Int
    ) throws -> RetrievalPage<MeetingRecord> {
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), 100)
        return try db.dbQueue.read { d in
            var conditions = ["started_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [filter.endAtMs]
            if let start = filter.startAtMs {
                conditions.append("started_at >= ?")
                arguments.append(start)
            }
            if !filter.sourceApps.isEmpty {
                conditions.append("app COLLATE NOCASE IN (\(Self.placeholders(filter.sourceApps.count)))")
                arguments.append(contentsOf: filter.sourceApps)
            }
            if let threadID, !threadID.isEmpty {
                conditions.append("thread_id = ?")
                arguments.append(threadID)
            }
            arguments.append(boundedLimit + 1)
            arguments.append(boundedOffset)
            let rows = try Row.fetchAll(d, sql: """
                SELECT * FROM meetings
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY started_at DESC, id ASC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments))
            let records = rows.map(Self.rec)
            return RetrievalPage(records: Array(records.prefix(boundedLimit)), hasMore: records.count > boundedLimit)
        }
    }

    public func meeting(id: String) throws -> MeetingRecord? {
        try db.dbQueue.read { d in try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id]).map(Self.rec) }
    }

    public func meetingContext(id: String) throws -> MeetingContext? {
        try db.dbQueue.read { d in
            guard let r = try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id]) else { return nil }
            let rec = Self.rec(r)
            var transcript = ""
            if let vid = rec.versionID, let enc = try String.fetchOne(d, sql: "SELECT content FROM versions WHERE id=?", arguments: [vid]) {
                transcript = (try? cipher.decrypt(enc)) ?? ""
            }
            let facts = try String.fetchAll(d, sql: "SELECT content FROM derivatives WHERE thread_id=?", arguments: [rec.threadID])
                .compactMap { try? cipher.decrypt($0) }
            return MeetingContext(record: rec, transcript: transcript, facts: facts)
        }
    }

    public func meetingContext(threadID: String) throws -> MeetingContext? {
        try db.dbQueue.read { d in
            guard let id = try String.fetchOne(d, sql: "SELECT id FROM meetings WHERE thread_id = ?", arguments: [threadID]) else {
                return nil
            }
            return try meetingContextInDatabase(d, id: id)
        }
    }

    public func meetingFactHits(near vector: [Float], limit: Int) throws -> [MeetingRecord] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT m.* FROM (SELECT derivative_id, distance FROM derivative_embeddings
                                 WHERE embedding MATCH ? AND k = ?) e
                JOIN derivatives dv ON dv.id = e.derivative_id
                JOIN meetings m ON m.thread_id = dv.thread_id
                ORDER BY e.distance
                """, arguments: [blob, limit]).map(Self.rec)
        }
    }

    public func meetingFactHits(
        near vector: [Float],
        filter: RetrievalFilter,
        threadID: String? = nil,
        offset: Int,
        limit: Int
    ) throws -> RetrievalPage<MeetingSearchHit> {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        let boundedOffset = max(offset, 0)
        let boundedLimit = min(max(limit, 1), 100)
        return try db.dbQueue.read { d in
            let embeddingCount = try Int.fetchOne(d, sql: "SELECT count(*) FROM derivative_embeddings") ?? 0
            guard embeddingCount > 0 else { return RetrievalPage(records: [], hasMore: false) }
            var conditions = ["m.started_at <= ?"]
            var arguments: [DatabaseValueConvertible?] = [blob, embeddingCount, filter.endAtMs]
            if let start = filter.startAtMs {
                conditions.append("m.started_at >= ?")
                arguments.append(start)
            }
            if !filter.sourceApps.isEmpty {
                conditions.append("m.app COLLATE NOCASE IN (\(Self.placeholders(filter.sourceApps.count)))")
                arguments.append(contentsOf: filter.sourceApps)
            }
            if let threadID, !threadID.isEmpty {
                conditions.append("m.thread_id = ?")
                arguments.append(threadID)
            }
            arguments.append(boundedLimit + 1)
            arguments.append(boundedOffset)
            let rows = try Row.fetchAll(d, sql: """
                WITH matches AS (
                  SELECT derivative_id, distance FROM derivative_embeddings
                  WHERE embedding MATCH ? AND k = ?
                )
                SELECT m.*, min(matches.distance) AS best_distance
                FROM matches
                JOIN derivatives dv ON dv.id = matches.derivative_id
                JOIN meetings m ON m.thread_id = dv.thread_id
                WHERE \(conditions.joined(separator: " AND "))
                GROUP BY m.id
                ORDER BY best_distance ASC, m.started_at DESC, m.id ASC
                LIMIT ? OFFSET ?
                """, arguments: StatementArguments(arguments))
            let hits = rows.map { row -> MeetingSearchHit in
                let l2: Double = row["best_distance"]
                return MeetingSearchHit(record: Self.rec(row), distance: (l2 * l2) / 2.0)
            }
            return RetrievalPage(records: Array(hits.prefix(boundedLimit)), hasMore: hits.count > boundedLimit)
        }
    }

    private func meetingContextInDatabase(_ d: Database, id: String) throws -> MeetingContext? {
        guard let r = try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id]) else { return nil }
        let rec = Self.rec(r)
        var transcript = ""
        if let vid = rec.versionID, let enc = try String.fetchOne(d, sql: "SELECT content FROM versions WHERE id=?", arguments: [vid]) {
            transcript = (try? cipher.decrypt(enc)) ?? ""
        }
        let facts = try String.fetchAll(d, sql: "SELECT content FROM derivatives WHERE thread_id=? ORDER BY committed_at, id", arguments: [rec.threadID])
            .map(decryptOrMarker)
        return MeetingContext(record: rec, transcript: transcript, facts: facts)
    }

    private static func rec(_ r: Row) -> MeetingRecord {
        MeetingRecord(id: r["id"], threadID: r["thread_id"], versionID: r["version_id"], app: r["app"],
                      title: r["title"], startedAtMs: r["started_at"], endedAtMs: r["ended_at"],
                      state: r["state"], captureMode: r["capture_mode"], transcriptionStatus: r["transcription_status"])
    }
}
