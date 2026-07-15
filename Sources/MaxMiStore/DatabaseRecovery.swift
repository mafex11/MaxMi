import Foundation
import GRDB

public struct DatabaseRestoreResult: Sendable, Equatable {
    public let preservedDatabaseURL: URL
    public let migrationIdentifier: String

    public init(preservedDatabaseURL: URL, migrationIdentifier: String) {
        self.preservedDatabaseURL = preservedDatabaseURL
        self.migrationIdentifier = migrationIdentifier
    }
}

public enum DatabaseRecoveryError: LocalizedError, Equatable {
    case missingDatabase
    case sameSourceAndDestination
    case integrityCheckFailed
    case incompatibleBackup
    case replacementFailed

    public var errorDescription: String? {
        switch self {
        case .missingDatabase: "The selected database file does not exist."
        case .sameSourceAndDestination: "The active database cannot be restored from itself."
        case .integrityCheckFailed: "The selected backup failed SQLite integrity validation."
        case .incompatibleBackup: "The selected backup is not compatible with this MaxMi version."
        case .replacementFailed: "MaxMi could not safely replace the active database."
        }
    }
}

/// Recovery operations for a short-lived helper that runs after the MaxMi app exits.
public enum DatabaseRecovery {
    public static func restore(
        backupURL: URL,
        databaseURL: URL,
        archiveDirectory: URL
    ) throws -> DatabaseRestoreResult {
        let fileManager = FileManager.default
        let source = backupURL.resolvingSymlinksInPath().standardizedFileURL
        let active = databaseURL.resolvingSymlinksInPath().standardizedFileURL
        guard source.path != active.path else { throw DatabaseRecoveryError.sameSourceAndDestination }
        guard fileManager.fileExists(atPath: source.path),
              fileManager.fileExists(atPath: active.path) else {
            throw DatabaseRecoveryError.missingDatabase
        }

        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archiveDirectory.path)
        let token = UUID().uuidString.lowercased()
        let staged = active.deletingLastPathComponent()
            .appendingPathComponent(".maxmi-restore-\(token).db")
        let original = active.deletingLastPathComponent()
            .appendingPathComponent(".maxmi-pre-restore-\(token).db")
        let preserved = archiveDirectory
            .appendingPathComponent("maxmi-before-restore-\(token).db")

        defer {
            removeDatabase(at: staged)
            removeDatabase(at: original)
        }

        let migrationIdentifier = try prepareValidatedCopy(from: source, at: staged)
        try createPortableBackup(of: active, at: preserved)

        do {
            // The current database has just been opened, backed up, checkpointed, and
            // closed, so any remaining sidecars are stale. Foundation performs the two
            // same-volume renames as one atomic replacement operation.
            removeSidecars(for: active)
            _ = try fileManager.replaceItemAt(
                active,
                withItemAt: staged,
                backupItemName: original.lastPathComponent,
                options: .withoutDeletingBackupItem
            )
        } catch {
            throw DatabaseRecoveryError.replacementFailed
        }

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.path)
        return DatabaseRestoreResult(
            preservedDatabaseURL: preserved,
            migrationIdentifier: migrationIdentifier
        )
    }

    private static func prepareValidatedCopy(from source: URL, at staged: URL) throws -> String {
        let fileManager = FileManager.default
        removeDatabase(at: staged)
        try fileManager.copyItem(at: source, to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)

        do {
            let preflight = try MaxMiDatabase(path: staged.path, migrate: false)
            defer { try? preflight.dbQueue.close() }
            try preflight.dbQueue.read { db in
                let hasMigrationHistory = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='grdb_migrations'"
                ) ?? 0
                guard hasMigrationHistory == 1 else {
                    throw DatabaseRecoveryError.incompatibleBackup
                }
                let knownIdentifiers = Set((1...9).map { "v\($0)" })
                let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
                guard !applied.isEmpty, Set(applied).isSubset(of: knownIdentifiers) else {
                    throw DatabaseRecoveryError.incompatibleBackup
                }
            }
            try preflight.dbQueue.close()

            let database = try MaxMiDatabase(path: staged.path)
            defer { try? database.dbQueue.close() }
            let migrationIdentifier = try database.dbQueue.read { db -> String in
                guard (try String.fetchOne(db, sql: "PRAGMA integrity_check"))?.lowercased() == "ok" else {
                    throw DatabaseRecoveryError.integrityCheckFailed
                }
                let required = ["threads", "versions", "settings", "latest_contexts", "grdb_migrations"]
                for table in required {
                    let present = try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
                        arguments: [table]
                    ) ?? 0
                    guard present == 1 else { throw DatabaseRecoveryError.incompatibleBackup }
                }
                guard let identifier = try String.fetchOne(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                ), identifier == Migrations.currentIdentifier else {
                    throw DatabaseRecoveryError.incompatibleBackup
                }
                return identifier
            }
            try database.dbQueue.inDatabase { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            return migrationIdentifier
        } catch {
            removeDatabase(at: staged)
            throw error
        }
    }

    private static func createPortableBackup(of sourceURL: URL, at destinationURL: URL) throws {
        removeDatabase(at: destinationURL)
        let source = try MaxMiDatabase(path: sourceURL.path)
        let destination = try DatabaseQueue(path: destinationURL.path)
        defer {
            try? destination.close()
            try? source.dbQueue.close()
        }
        try source.dbQueue.backup(to: destination)
        try destination.inDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeSidecars(for: url)
    }

    private static func removeSidecars(for url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
