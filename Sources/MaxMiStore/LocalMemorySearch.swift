import Foundation
import GRDB
import MaxMiCore

public struct LocalMemorySearchHit: Sendable, Equatable {
    public let threadID: String
    public let sourceApp: String
    public let sourceTitle: String?
    public let contentKind: CaptureContentKind
    public let snippet: String
    public let capturedAtMs: EpochMs
    public let matchKind: String
}

extension Store {
    /// Private lexical search for the product UI. It decrypts a bounded local candidate set,
    /// performs matching in-process, and never invokes a relay or writes search terms to disk.
    public func searchLocalMemory(query: String, limit: Int = 30) throws -> [LocalMemorySearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let boundedLimit = min(max(limit, 1), 100)
        return try db.dbQueue.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT t.id AS thread_id, t.source_app, t.source_title,
                       c.content_kind, c.content_ciphertext AS content,
                       c.captured_at AS at_ms, 'context' AS match_kind
                FROM latest_contexts c
                JOIN threads t ON t.id = c.thread_id
                UNION ALL
                SELECT t.id AS thread_id, t.source_app, t.source_title,
                       coalesce(c.content_kind, 'generic') AS content_kind,
                       d.content, d.committed_at AS at_ms, 'fact' AS match_kind
                FROM derivatives d
                JOIN threads t ON t.id = d.thread_id
                LEFT JOIN latest_contexts c ON c.thread_id = d.thread_id
                ORDER BY at_ms DESC, thread_id ASC
                LIMIT 4000
                """)
            var seenThreads: Set<String> = []
            var hits: [LocalMemorySearchHit] = []
            for row in rows {
                let threadID: String = row["thread_id"]
                guard !seenThreads.contains(threadID) else { continue }
                let title: String? = row["source_title"]
                let sourceApp: String = row["source_app"]
                let plaintext = decryptOrMarker(row["content"])
                let searchable = [sourceApp, title ?? "", plaintext].joined(separator: "\n")
                guard searchable.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
                guard let kind = CaptureContentKind(rawValue: row["content_kind"]) else { continue }
                seenThreads.insert(threadID)
                hits.append(LocalMemorySearchHit(
                    threadID: threadID,
                    sourceApp: sourceApp,
                    sourceTitle: title,
                    contentKind: kind,
                    snippet: Self.searchSnippet(in: plaintext, matching: needle),
                    capturedAtMs: row["at_ms"],
                    matchKind: row["match_kind"]
                ))
                if hits.count == boundedLimit { break }
            }
            return hits
        }
    }

    private static func searchSnippet(in text: String, matching needle: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Matched source metadata" }
        guard let range = collapsed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(collapsed.prefix(220))
        }
        let matchOffset = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
        let startOffset = max(0, matchOffset - 80)
        let endOffset = min(collapsed.count, matchOffset + needle.count + 140)
        let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let end = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "") + collapsed[start..<end] + (endOffset < collapsed.count ? "…" : "")
    }
}

