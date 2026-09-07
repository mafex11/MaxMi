import Foundation
import GRDB
import MaxMiActivity
import MaxMiCore

public struct ActionItem: Sendable {
    public let id, kind, status, title: String
    public let details: String?
    public let sourceRefs: [String]
    public let detectedAtMs, updatedAtMs: EpochMs
    public let resolvedAtMs: EpochMs?

    public init(id: String, kind: String, status: String, title: String, details: String?, sourceRefs: [String], detectedAtMs: EpochMs, updatedAtMs: EpochMs, resolvedAtMs: EpochMs?) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.details = details
        self.sourceRefs = sourceRefs
        self.detectedAtMs = detectedAtMs
        self.updatedAtMs = updatedAtMs
        self.resolvedAtMs = resolvedAtMs
    }
}

public struct SessionCursor: Sendable, Equatable {
    public let atMs: EpochMs
    public let sessionID: String

    public init(atMs: EpochMs, sessionID: String) {
        self.atMs = atMs
        self.sessionID = sessionID
    }
}

public struct AgentPage: Sendable {
    public let runID: String
    public let versions: [ReviewVersion]
    public let openItems: [ReviewOpenItem]
    public let fromMs: EpochMs
    public let toMs: EpochMs

    public init(
        runID: String,
        versions: [ReviewVersion],
        openItems: [ReviewOpenItem],
        fromMs: EpochMs,
        toMs: EpochMs
    ) {
        self.runID = runID
        self.versions = versions
        self.openItems = openItems
        self.fromMs = fromMs
        self.toMs = toMs
    }
}

public enum AgentOp: Sendable {
    case create(kind: String, title: String, details: String?, sourceRefs: [String])
    case update(id: String, title: String?, details: String?)
    case resolve(id: String, evidence: String)
}

public struct AgentRunResult: Sendable {
    public let newCount, resolvedCount, updatedCount: Int

    public init(newCount: Int, resolvedCount: Int, updatedCount: Int) {
        self.newCount = newCount
        self.resolvedCount = resolvedCount
        self.updatedCount = updatedCount
    }
}

private enum AgentReviewPromptVersion {
    static let versions = "agent-review-v2-versions"
}

extension Store {
    public func claimNextAgentRun(maxVersions: Int, leaseMs: EpochMs, nowMs: EpochMs) throws -> AgentPage? {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                UPDATE agent_runs SET status='failed'
                WHERE status='running' AND lease_expires_at < ?
                """, arguments: [nowMs])

            if let _ = try String.fetchOne(d, sql: """
                SELECT id FROM agent_runs WHERE status='running' AND lease_expires_at >= ?
                """, arguments: [nowMs]) {
                return nil
            }

            let lastCursor = try Row.fetchOne(d, sql: """
                SELECT input_to_at, input_to_session_id FROM agent_runs
                WHERE status='completed' ORDER BY input_to_at DESC, input_to_session_id DESC LIMIT 1
                """)

            let curAt: EpochMs = lastCursor?["input_to_at"] ?? 0
            let curID: String = lastCursor?["input_to_session_id"] ?? ""

            let versions = try agentReviewVersions(
                d,
                cursorAt: curAt,
                cursorID: curID,
                maxVersions: maxVersions
            )
            guard let first = versions.first, let last = versions.last else { return nil }

            let runID = Ident.uuidv7(nowMs: nowMs)
            let dayBucket = Store.dayBucket(forMs: nowMs, timeZone: .current)
            let leaseExpires = nowMs + leaseMs

            try d.execute(sql: """
                INSERT INTO agent_runs (
                    id, kind, status, input_from, input_to, input_to_at, input_to_session_id,
                    lease_expires_at, started_at, day_bucket
                ) VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [
                    runID, "hourly", "running", first.committedAt, last.committedAt,
                    last.committedAt, last.versionID, leaseExpires, nowMs, dayBucket,
                ])

            let openItemRows = try Row.fetchAll(d, sql: """
                SELECT id, title_ciphertext, details_ciphertext, detected_at
                FROM agent_action_items
                WHERE status='open'
                """)
            let openItems = openItemRows.map {
                ReviewOpenItem(
                    id: $0["id"],
                    title: decryptOrMarker($0["title_ciphertext"]),
                    details: ($0["details_ciphertext"] as String?).map(decryptOrMarker),
                    sourceApp: nil,
                    createdAt: $0["detected_at"]
                )
            }

            return AgentPage(
                runID: runID,
                versions: versions,
                openItems: openItems,
                fromMs: first.committedAt,
                toMs: last.committedAt
            )
        }
    }

    public func completeAgentRun(runID: String, ops: [AgentOp], nowMs: EpochMs) throws -> AgentRunResult {
        try db.dbQueue.write { d in
            guard let runRow = try Row.fetchOne(d, sql: """
                SELECT status, input_from, input_to, input_to_at, input_to_session_id
                FROM agent_runs
                WHERE id=?
                """, arguments: [runID]),
                  runRow["status"] as String == "running" else {
                return AgentRunResult(newCount: 0, resolvedCount: 0, updatedCount: 0)
            }

            let firstAt: EpochMs = runRow["input_from"] ?? 0
            let inputTo: EpochMs = runRow["input_to"] ?? 0
            let lastAt: EpochMs = runRow["input_to_at"]!
            let lastID: String = runRow["input_to_session_id"]!

            // Rebuild the claimed page: find the *previous* completed cursor, then select the page
            let prevCursor = try Row.fetchOne(d, sql: """
                SELECT input_to_at, input_to_session_id FROM agent_runs
                WHERE status='completed' AND (input_to_at < ? OR (input_to_at = ? AND input_to_session_id < ?))
                ORDER BY input_to_at DESC, input_to_session_id DESC
                LIMIT 1
                """, arguments: [lastAt, lastAt, lastID])

            let curAt: EpochMs = prevCursor?["input_to_at"] ?? 0
            let curID: String = prevCursor?["input_to_session_id"] ?? ""

            let page = try agentReviewVersions(
                d,
                cursorAt: curAt,
                cursorID: curID,
                fromMs: firstAt,
                toMs: inputTo,
                throughAt: lastAt,
                throughID: lastID
            )
            let pageSourceSet = Set(page.map(\.versionID))
            var newCount = 0
            var resolvedCount = 0
            var updatedCount = 0
            var newIDs: [String] = []
            var resolvedIDs: [String] = []
            var updatedIDs: [String] = []

            for (i, op) in ops.enumerated() {
                switch op {
                case .create(let kind, let title, let details, let sourceRefs):
                    let idemKey = "\(runID):\(i)"
                    let itemID = Ident.uuidv7(nowMs: nowMs + EpochMs(i))
                    let titleCipher = try cipher.encrypt(title)
                    let detailsCipher = try details.map { try cipher.encrypt($0) }
                    let validRefs = sourceRefs.filter { pageSourceSet.contains($0) }
                    let refsJSON = try? JSONEncoder().encode(validRefs)
                    let refsStr = refsJSON.map { String(data: $0, encoding: .utf8)! }

                    let exists = try Int.fetchOne(d, sql: """
                        SELECT 1 FROM agent_action_items WHERE idem_key=? LIMIT 1
                        """, arguments: [idemKey])

                    if exists == nil {
                        try d.execute(sql: """
                            INSERT INTO agent_action_items (
                                id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                                detected_at, updated_at, idem_key
                            ) VALUES (?,?,?,?,?,?,?,?,?)
                            """, arguments: [itemID, kind, "open", titleCipher, detailsCipher, refsStr, nowMs, nowMs, idemKey])
                    }

                    if d.changesCount > 0 {
                        newCount += 1
                        newIDs.append(itemID)
                        let eventID = Ident.uuidv7(nowMs: nowMs + EpochMs(i))
                        try d.execute(sql: """
                            INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                            VALUES (?,?,?,?,?)
                            """, arguments: [eventID, itemID, "created", runID, nowMs])
                    }

                case .update(let id, let title, let details):
                    guard let itemRow = try Row.fetchOne(d, sql: """
                        SELECT status FROM agent_action_items WHERE id=?
                        """, arguments: [id]),
                          itemRow["status"] as String == "open" else {
                        continue
                    }

                    var updates: [String] = []
                    var args: [DatabaseValueConvertible] = []

                    if let title = title {
                        let titleCipher = try cipher.encrypt(title)
                        updates.append("title_ciphertext=?")
                        args.append(titleCipher)
                    }
                    if let details = details {
                        let detailsCipher = try cipher.encrypt(details)
                        updates.append("details_ciphertext=?")
                        args.append(detailsCipher)
                    }

                    if !updates.isEmpty {
                        updates.append("updated_at=?")
                        args.append(nowMs)
                        args.append(id)

                        try d.execute(sql: """
                            UPDATE agent_action_items SET \(updates.joined(separator: ", "))
                            WHERE id=?
                            """, arguments: StatementArguments(args))

                        if d.changesCount > 0 {
                            updatedCount += 1
                            updatedIDs.append(id)
                            let eventID = Ident.uuidv7(nowMs: nowMs + EpochMs(i))
                            try d.execute(sql: """
                                INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                                VALUES (?,?,?,?,?)
                                """, arguments: [eventID, id, "updated", runID, nowMs])
                        }
                    }

                case .resolve(let id, let evidence):
                    guard let itemRow = try Row.fetchOne(d, sql: """
                        SELECT status FROM agent_action_items WHERE id=?
                        """, arguments: [id]),
                          itemRow["status"] as String == "open" else {
                        continue
                    }

                    let evidenceCipher = try cipher.encrypt(evidence)
                    try d.execute(sql: """
                        UPDATE agent_action_items
                        SET status='resolved', resolution_evidence_ciphertext=?, resolved_at=?, updated_at=?
                        WHERE id=?
                        """, arguments: [evidenceCipher, nowMs, nowMs, id])

                    if d.changesCount > 0 {
                        resolvedCount += 1
                        resolvedIDs.append(id)
                        let eventID = Ident.uuidv7(nowMs: nowMs + EpochMs(i))
                        try d.execute(sql: """
                            INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                            VALUES (?,?,?,?,?)
                            """, arguments: [eventID, id, "resolved", runID, nowMs])
                    }
                }
            }

            let newIDsJSON = try? JSONEncoder().encode(newIDs)
            let resolvedIDsJSON = try? JSONEncoder().encode(resolvedIDs)
            let updatedIDsJSON = try? JSONEncoder().encode(updatedIDs)

            try d.execute(sql: """
                UPDATE agent_runs
                SET status='completed', ended_at=?, prompt_version=?,
                    new_count=?, resolved_count=?, updated_count=?,
                    new_item_ids=?, resolved_item_ids=?, updated_item_ids=?
                WHERE id=? AND status='running'
                """, arguments: [
                    nowMs,
                    AgentReviewPromptVersion.versions,
                    newCount, resolvedCount, updatedCount,
                    newIDsJSON.map { String(data: $0, encoding: .utf8)! },
                    resolvedIDsJSON.map { String(data: $0, encoding: .utf8)! },
                    updatedIDsJSON.map { String(data: $0, encoding: .utf8)! },
                    runID
                ])

            return AgentRunResult(newCount: newCount, resolvedCount: resolvedCount, updatedCount: updatedCount)
        }
    }

    private func agentReviewVersions(
        _ database: Database,
        cursorAt: EpochMs,
        cursorID: String,
        maxVersions: Int
    ) throws -> [ReviewVersion] {
        let rows = try Row.fetchAll(database, sql: """
            SELECT v.id AS version_id, v.thread_id, v.content, v.word_count, v.committed_at, v.metadata,
                   v.structured_ciphertext, t.source_app, t.source_title, t.source_key,
                   (SELECT payload_ciphertext
                    FROM capture_events e
                    WHERE e.version_id = v.id AND e.kind = 'content_delta'
                    ORDER BY e.at_ms DESC, e.id DESC LIMIT 1) AS delta_ciphertext
            FROM versions v
            JOIN threads t ON t.id = v.thread_id
            WHERE v.committed_at > ?
               OR (v.committed_at = ? AND v.id > ?)
            ORDER BY v.committed_at ASC, v.id ASC
            LIMIT ?
            """, arguments: [cursorAt, cursorAt, cursorID, maxVersions])
        return rows.map(agentReviewVersion)
    }

    private func agentReviewVersions(
        _ database: Database,
        cursorAt: EpochMs,
        cursorID: String,
        fromMs: EpochMs,
        toMs: EpochMs,
        throughAt: EpochMs,
        throughID: String
    ) throws -> [ReviewVersion] {
        let rows = try Row.fetchAll(database, sql: """
            SELECT v.id AS version_id, v.thread_id, v.content, v.word_count, v.committed_at, v.metadata,
                   v.structured_ciphertext, t.source_app, t.source_title, t.source_key,
                   (SELECT payload_ciphertext
                    FROM capture_events e
                    WHERE e.version_id = v.id AND e.kind = 'content_delta'
                    ORDER BY e.at_ms DESC, e.id DESC LIMIT 1) AS delta_ciphertext
            FROM versions v
            JOIN threads t ON t.id = v.thread_id
            WHERE v.committed_at >= ?
              AND v.committed_at <= ?
              AND (v.committed_at > ? OR (v.committed_at = ? AND v.id > ?))
              AND (v.committed_at < ? OR (v.committed_at = ? AND v.id <= ?))
            ORDER BY v.committed_at ASC, v.id ASC
            """, arguments: [
                fromMs, toMs, cursorAt, cursorAt, cursorID, throughAt, throughAt, throughID,
            ])
        return rows.map(agentReviewVersion)
    }

    private func agentReviewVersion(_ row: Row) -> ReviewVersion {
        let metadata = (try? JSONDecoder().decode(
            VersionCaptureMetadata.self,
            from: Data((row["metadata"] as String? ?? "").utf8)
        ))
        let kind = metadata?.contentKind ?? .generic
        let renderedContent = decryptOrMarker(row["content"])
        let structured = structuredOrLegacy(
            row["structured_ciphertext"] as String?,
            renderedContent: renderedContent,
            kind: kind
        )
        let delta = agentCaptureDelta(row["delta_ciphertext"] as String?)
        let deltaSummary = delta.map {
            CaptureDeltaRenderer.render($0, maxChars: HourlyReviewBudget.versionDeltaCap)
        }
        let deltaChars = delta.map {
            CaptureDeltaRenderer.render($0, maxChars: Int.max).count
        } ?? 0

        return ReviewVersion(
            versionID: row["version_id"],
            threadID: row["thread_id"],
            sourceApp: row["source_app"],
            sourceTitle: row["source_title"],
            sourceKey: row["source_key"],
            kind: kind,
            wordCount: row["word_count"],
            committedAt: row["committed_at"],
            compactContent: ContentRenderer.render(
                structured,
                style: .compact(maxChars: HourlyReviewBudget.versionCompactCap)
            ),
            deltaSummary: deltaSummary,
            deltaChars: deltaChars
        )
    }

    private func agentCaptureDelta(_ ciphertext: String?) -> CaptureDelta? {
        guard let ciphertext, let plaintext = try? cipher.decrypt(ciphertext) else {
            return nil
        }
        return try? JSONDecoder().decode(CaptureDelta.self, from: Data(plaintext.utf8))
    }

    public func renewAgentRunLease(runID: String, leaseMs: EpochMs, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                UPDATE agent_runs SET lease_expires_at=?
                WHERE id=? AND status='running'
                """, arguments: [nowMs + leaseMs, runID])
        }
    }

    public func failAgentRun(runID: String, error: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            // Store a fixed error KIND instead of the full error text to avoid leaking model output
            let errorKind: String
            if error.contains("malformed") || error.contains("decode") {
                errorKind = "relay_malformed"
            } else if error.contains("validation") || error.contains("ValidationError") {
                errorKind = "validation_error"
            } else {
                errorKind = "unknown_error"
            }
            try d.execute(sql: """
                UPDATE agent_runs SET status='failed', error=?, ended_at=?
                WHERE id=?
                """, arguments: [errorKind, nowMs, runID])
        }
    }

    public func resolveActionItem(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                UPDATE agent_action_items
                SET status='resolved', resolved_at=?, updated_at=?
                WHERE id=? AND status='open'
                """, arguments: [nowMs, nowMs, id])

            if d.changesCount > 0 {
                let eventID = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                    VALUES (?,?,?,NULL,?)
                    """, arguments: [eventID, id, "resolved_user", nowMs])
            }
        }
    }

    public func dismissActionItem(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                UPDATE agent_action_items
                SET status='dismissed', updated_at=?
                WHERE id=? AND status='open'
                """, arguments: [nowMs, id])

            if d.changesCount > 0 {
                let eventID = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                    VALUES (?,?,?,NULL,?)
                    """, arguments: [eventID, id, "dismissed_user", nowMs])
            }
        }
    }

    public func actionItems(status: String, limit: Int) throws -> [ActionItem] {
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                       detected_at, updated_at, resolved_at
                FROM agent_action_items
                WHERE status=?
                ORDER BY detected_at DESC
                LIMIT ?
                """, arguments: [status, limit])

            return rows.map { row in
                let title = decryptOrMarker(row["title_ciphertext"])
                let details: String? = (row["details_ciphertext"] as String?).map(decryptOrMarker)
                let sourceRefsJSON = row["source_refs"] as String?
                let sourceRefs = sourceRefsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []

                return ActionItem(
                    id: row["id"],
                    kind: row["kind"],
                    status: row["status"],
                    title: title,
                    details: details,
                    sourceRefs: sourceRefs,
                    detectedAtMs: row["detected_at"],
                    updatedAtMs: row["updated_at"],
                    resolvedAtMs: row["resolved_at"]
                )
            }
        }
    }

    public func lastAgentRunStartedAt() throws -> EpochMs? {
        try db.dbQueue.read { d in
            try Int64.fetchOne(d, sql: """
                SELECT MAX(started_at) FROM agent_runs WHERE status='completed'
                """)
        }
    }

    public func summarizedSessionCount() throws -> Int {
        try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM activity_sessions WHERE summary_status='summarized'
                """) ?? 0
        }
    }
}
