import Foundation
import GRDB
import MaxMiCore

extension Store {
    public func isContentEncrypted() throws -> Bool {
        try db.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='content_encrypted'") == "true"
        }
    }

    /// Spec §6: batches of 200 per transaction; prefix check makes each row idempotent;
    /// the settings flag makes the whole pass idempotent. Caller (app wiring) pauses
    /// capture until this returns — spec ordering: key -> backfill -> capture.
    @discardableResult
    public func encryptExistingContent(batchSize: Int = 200, nowMs: EpochMs) throws -> Int {
        guard try !isContentEncrypted() else { return 0 }
        var total = 0
        for table in ["versions", "derivatives"] {
            while true {
                let encrypted: Int = try db.dbQueue.write { d in
                    let rows = try Row.fetchAll(d, sql:
                        "SELECT id, content FROM \(table) WHERE substr(content,1,7) <> 'enc:v1:' LIMIT ?",
                        arguments: [batchSize])
                    for r in rows {
                        let enc = try cipher.encrypt(r["content"])
                        try d.execute(sql: "UPDATE \(table) SET content=? WHERE id=?",
                                      arguments: [enc, r["id"] as String])
                    }
                    return rows.count
                }
                total += encrypted
                SafeLogger.shared.log(
                    .info,
                    subsystem: .migration,
                    event: .backfillProgress,
                    fields: SafeLogFields(
                        operation: SafeLogToken(validating: table),
                        count: encrypted
                    )
                )
                if encrypted < batchSize { break }
            }
        }
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('content_encrypted','true',?)",
                          arguments: [nowMs])
        }
        return total
    }
}
