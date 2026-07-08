import Foundation
import GRDB
import MaxMiCore

extension Store {
    public func pausedApps() throws -> Set<String> { try readSet("paused_apps") }
    public func pausedThreads() throws -> Set<String> { try readSet("paused_threads") }

    public func setAppPaused(_ bundleID: String, paused: Bool, nowMs: EpochMs) throws {
        try mutateSet("paused_apps", element: bundleID, insert: paused, nowMs: nowMs)
    }
    public func setThreadPaused(_ sourceKey: String, paused: Bool, nowMs: EpochMs) throws {
        try mutateSet("paused_threads", element: sourceKey, insert: paused, nowMs: nowMs)
    }

    private func readSet(_ key: String) throws -> Set<String> {
        try db.dbQueue.read { d in
            guard let json = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?", arguments: [key]),
                  let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
            return Set(arr)
        }
    }

    private func mutateSet(_ key: String, element: String, insert: Bool, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            var set: Set<String> = []
            if let json = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?", arguments: [key]),
               let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                set = Set(arr)
            }
            if insert { set.insert(element) } else { set.remove(element) }
            let json = String(decoding: try JSONEncoder().encode(set.sorted()), as: UTF8.self)
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)", arguments: [key, json, nowMs])
        }
    }
}
