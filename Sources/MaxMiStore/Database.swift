import Foundation
import GRDB
import CSQLiteVec

public final class MaxMiDatabase {
    public let dbQueue: DatabaseQueue

    public init(path: String, readOnly: Bool = false, migrate: Bool = true) throws {
        var config = Configuration()
        config.readonly = readOnly
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            var err: UnsafeMutablePointer<CChar>? = nil
            let rc = sqlite3_vec_init(db.sqliteConnection, &err, nil)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "sqlite3_vec_init failed"
                sqlite3_free(err)
                throw DatabaseError(resultCode: ResultCode(rawValue: rc), message: msg)
            }
        }
        let isFile = path != ":memory:"
        if isFile && !readOnly {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        if isFile && !readOnly {
            // Must be outside transaction (GRDB starts a deferred transaction in .write).
            try dbQueue.inDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
        }
        if !readOnly && migrate {
            try Migrations.migrator.migrate(dbQueue)
        }
    }

    public static func inMemory() throws -> MaxMiDatabase {
        try MaxMiDatabase(path: ":memory:")
    }
}
