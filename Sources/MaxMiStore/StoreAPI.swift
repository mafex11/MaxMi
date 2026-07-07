import Foundation
import GRDB
import MaxMiCore

public struct CaptureInput: Sendable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
    }
}

public enum CommitResult: Equatable, Sendable {
    case deduplicated
    case committed(versionID: String, contentHash: String)
}

public final class Store {
    let db: MaxMiDatabase
    public init(db: MaxMiDatabase) { self.db = db }

    public func commitCapture(_ input: CaptureInput, nowMs: EpochMs) throws -> CommitResult {
        let hash = ContentHash.sha256Hex(input.content)
        let bucket = HourBucket.bucket(forMs: nowMs)
        let words = input.content.split(whereSeparator: \.isWhitespace).count

        return try db.dbQueue.write { d in
            // 1. Upsert thread; dedup on unchanged tree hash.
            let existing = try Row.fetchOne(d,
                sql: "SELECT id, last_tree_hash FROM threads WHERE source_app=? AND source_key=?",
                arguments: [input.sourceApp, input.sourceKey])
            let threadID: String
            if let existing {
                if existing["last_tree_hash"] as String? == hash { return .deduplicated }
                threadID = existing["id"]
                try d.execute(sql: "UPDATE threads SET source_title=?, last_tree_hash=?, updated_at=? WHERE id=?",
                              arguments: [input.sourceTitle, hash, nowMs, threadID])
            } else {
                threadID = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?)
                    """, arguments: [threadID, input.sourceApp, input.sourceKey, input.sourceTitle, hash, nowMs, nowMs])
            }

            // 2. Freeze-then-create: seal mutable versions from past hours.
            try d.execute(sql: "UPDATE versions SET is_frozen=1 WHERE thread_id=? AND is_frozen=0 AND hour_bucket<>?",
                          arguments: [threadID, bucket])

            // 3. Upsert this hour's version (replace content, reset pending, un-freeze if clock stepped back).
            if let vid = try String.fetchOne(d, sql: "SELECT id FROM versions WHERE thread_id=? AND hour_bucket=?",
                                             arguments: [threadID, bucket]) {
                try d.execute(sql: """
                    UPDATE versions SET content=?, content_hash=?, word_count=?, committed_at=?,
                                        extract_status='pending', is_frozen=0 WHERE id=?
                    """, arguments: [input.content, hash, words, nowMs, vid])
                return .committed(versionID: vid, contentHash: hash)
            } else {
                let vid = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO versions (id, thread_id, hour_bucket, content, content_hash, word_count, is_frozen, committed_at, extract_status)
                    VALUES (?,?,?,?,?,?,0,?,'pending')
                    """, arguments: [vid, threadID, bucket, input.content, hash, words, nowMs])
                return .committed(versionID: vid, contentHash: hash)
            }
        }
    }
}
