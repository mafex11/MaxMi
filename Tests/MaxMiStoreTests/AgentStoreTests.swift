import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class AgentStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    var versionCounter = 0
    let t0 = EpochMs(497_000) * 3_600_000

    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        versionCounter = 0
    }

    func testClaimReadsVersionsAndCompletesWithVersionSourceRefs() throws {
        let versionID = try seedVersion(
            sourceKey: "cursor:plan",
            content: "Implement raw embeddings"
        )
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 1
        ))

        XCTAssertEqual(page.versions.map(\.sourceKey), ["cursor:plan"])
        XCTAssertEqual(page.versions.map(\.versionID), [versionID])
        XCTAssertEqual(page.versions.first?.compactContent, "Implement raw embeddings")
        _ = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Review embedding",
                details: nil,
                sourceRefs: [versionID],
                reminder: .unchanged
            )],
            nowMs: t0 + 2
        )
        XCTAssertEqual(try store.actionItems(status: "open", limit: 1).first?.sourceRefs, [versionID])
    }

    func testCompleteRejectsUnknownVersionSourceRefs() throws {
        let versionID = try seedVersion(sourceKey: "cursor:refs", content: "Review the source refs")
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 1
        ))

        _ = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Keep only known refs",
                details: nil,
                sourceRefs: [versionID, "unknown-version-id"],
                reminder: .unchanged
            )],
            nowMs: t0 + 2
        )

        XCTAssertEqual(
            try store.actionItems(status: "open", limit: 1).first?.sourceRefs,
            [versionID]
        )
    }

    func testClaimCompleteAdvancesKeysetCursorNoSkipAcrossPages() throws {
        try seedVersions(120)
        var runs = 0
        while let page = try store.claimNextAgentRun(
            maxVersions: 50,
            leaseMs: 60_000,
            nowMs: t0 + EpochMs(runs)
        ) {
            _ = try store.completeAgentRun(runID: page.runID, ops: [], nowMs: t0 + EpochMs(runs))
            runs += 1
            if runs > 10 { break }
        }
        XCTAssertEqual(runs, 3, "120 versions / 50 per page = 3 runs, none skipped")
        XCTAssertNil(try store.claimNextAgentRun(
            maxVersions: 50,
            leaseMs: 60_000,
            nowMs: t0 + 999
        ))
    }

    func testStaleLeaseRecovered() throws {
        try seedVersions(10)
        let p1 = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 1_000, nowMs: t0
        ))
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 1_000, nowMs: t0 + 5_000
        ))
        XCTAssertEqual(p1.versions, p2.versions, "stale lease reclaimed, window not lost")
    }

    func testCreateResolveDismissAndTerminalAndIdempotency() throws {
        try seedVersions(2)
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0
        ))
        let result = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Reply",
                details: "Send the update",
                sourceRefs: page.versions.map(\.versionID),
                reminder: .unchanged
            )],
            nowMs: t0
        )
        XCTAssertEqual(result.newCount, 1)
        let id = try store.actionItems(status: "open", limit: 10)[0].id
        try db.dbQueue.read { database in
            let ciphertext = try String.fetchOne(
                database,
                sql: "SELECT title_ciphertext FROM agent_action_items"
            )
            XCTAssertTrue(ciphertext?.hasPrefix("enc:v1:") == true)
        }
        let repeatResult = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Reply",
                details: nil,
                sourceRefs: page.versions.map(\.versionID),
                reminder: .unchanged
            )],
            nowMs: t0 + 1
        )
        XCTAssertEqual(repeatResult.newCount, 0, "already-completed run is a no-op")

        try store.dismissActionItem(id, nowMs: t0 + 10)
        try seedVersions(1)
        let nextPage = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 100
        ))
        let resolveResult = try store.completeAgentRun(
            runID: nextPage.runID,
            ops: [.resolve(id: id, evidence: "done")],
            nowMs: t0 + 100
        )
        XCTAssertEqual(resolveResult.resolvedCount, 0, "dismissed is terminal")
    }

    func testNeverResolveOnAbsenceAndUnknownIgnored() throws {
        try seedVersions(2)
        let firstPage = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0
        ))
        let createResult = try store.completeAgentRun(
            runID: firstPage.runID,
            ops: [.create(
                kind: "todo",
                title: "Task",
                details: nil,
                sourceRefs: firstPage.versions.map(\.versionID),
                reminder: .unchanged
            )],
            nowMs: t0
        )
        XCTAssertEqual(createResult.newCount, 1)
        let itemID = try store.actionItems(status: "open", limit: 10)[0].id

        try seedVersions(1)
        let nextPage = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 100
        ))
        let resolveResult = try store.completeAgentRun(
            runID: nextPage.runID,
            ops: [.resolve(id: "unknown-id", evidence: "done")],
            nowMs: t0 + 100
        )
        XCTAssertEqual(resolveResult.resolvedCount, 0, "unknown id ignored")

        let items = try store.actionItems(status: "open", limit: 10)
        XCTAssertEqual(items.count, 1, "item stays open when not mentioned")
        XCTAssertEqual(items[0].id, itemID)
    }

    func testSourceRefsMustBelongToPage() throws {
        try seedVersions(2)
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0
        ))
        let result = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Task",
                details: nil,
                sourceRefs: ["invalid-version-id-1", "invalid-version-id-2"],
                reminder: .unchanged
            )],
            nowMs: t0
        )
        XCTAssertEqual(result.newCount, 1, "item created")

        let items = try store.actionItems(status: "open", limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sourceRefs, [], "invalid source refs dropped")
    }

    func testUnexpiredLeaseBlocksSecondClaim() throws {
        try seedVersions(10)
        _ = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0
        ))
        XCTAssertNil(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 1
        ))
    }

    func testClaimExcludesLocalOnlyPausedAndBlockedVersionsBeforePromptPageBuild() throws {
        let ordinary = try seedVersion(
            sourceApp: "Web",
            sourceKey: "https://ordinary-agent.example",
            content: "Ordinary agent content"
        )
        _ = try seedVersion(
            sourceApp: "Local",
            sourceKey: "local:agent",
            content: "Keep local agent content"
        )
        _ = try seedVersion(
            sourceApp: "Web",
            sourceKey: "https://paused-agent.example",
            content: "Paused agent content"
        )
        _ = try seedVersion(
            sourceApp: "Web",
            sourceKey: "https://blocked-agent.example",
            content: "Blocked agent content"
        )
        try store.setCloudProcessing("Local", allowed: false, nowMs: t0 + 100)
        try store.setThreadPaused("https://paused-agent.example", paused: true, nowMs: t0 + 100)
        _ = try store.setDomain("blocked-agent.example", blocked: true, nowMs: t0 + 100)

        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 200
        ))

        XCTAssertEqual(page.versions.map(\.versionID), [ordinary])
        XCTAssertEqual(page.versions.map(\.compactContent), ["Ordinary agent content"])
    }

    func testCompleteRebuildExcludesSourceMadeLocalOnlyAfterClaim() throws {
        let versionID = try seedVersion(
            sourceApp: "Web",
            sourceKey: "https://completion-local-only.example",
            content: "Source is local only before completion"
        )
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50, leaseMs: 60_000, nowMs: t0 + 1
        ))
        XCTAssertEqual(page.versions.map(\.versionID), [versionID])

        try store.setCloudProcessing("Web", allowed: false, nowMs: t0 + 2)
        _ = try store.completeAgentRun(
            runID: page.runID,
            ops: [.create(
                kind: "todo",
                title: "Do not retain the newly local source",
                details: nil,
                sourceRefs: [versionID],
                reminder: .unchanged
            )],
            nowMs: t0 + 3
        )

        XCTAssertEqual(try store.actionItems(status: "open", limit: 1).first?.sourceRefs, [])
    }

    func testAgentCreateAndUpdateApplyAcceptedReminderUsingStoreSetReminderPath() throws {
        let versionID = try seedVersion(
            sourceKey: "cursor:reminder",
            content: "Deadline is today at 15:00."
        )
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50,
            leaseMs: 60_000,
            nowMs: t0
        ))

        _ = try store.completeAgentRun(
            runID: page.runID,
            ops: [
                .create(
                    kind: "todo",
                    title: "Send draft",
                    details: nil,
                    sourceRefs: [versionID],
                    reminder: .set(t0 + 3_600_000)
                ),
            ],
            nowMs: t0
        )
        let itemID = try XCTUnwrap(try store.actionItems(status: "open", limit: 1).first?.id)

        try seedVersions(1)
        let updatePage = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 50,
            leaseMs: 60_000,
            nowMs: t0 + 1
        ))
        _ = try store.completeAgentRun(
            runID: updatePage.runID,
            ops: [
                .update(
                    id: itemID,
                    title: nil,
                    details: nil,
                    reminder: .set(t0 + 7_200_000)
                ),
            ],
            nowMs: t0 + 1
        )

        XCTAssertEqual(
            try store.actionItems(status: "open", limit: 1).first?.remindAtMs,
            t0 + 7_200_000
        )
    }

    func testDueRemindersIncludesOnlyDueUnremindedItemsInsideTwentyFourHourWindow() throws {
        let nowMs: EpochMs = 10_000_000
        try insertActionItem(id: "due", status: "open", remindAtMs: nowMs, remindedAtMs: nil)
        try insertActionItem(id: "future", status: "open", remindAtMs: nowMs + 1, remindedAtMs: nil)
        try insertActionItem(id: "already", status: "open", remindAtMs: nowMs - 1, remindedAtMs: nowMs)
        try insertActionItem(
            id: "expired",
            status: "open",
            remindAtMs: nowMs - ReminderWindow.maximumPastDueMs - 1,
            remindedAtMs: nil
        )

        let due = try store.dueReminders(nowMs: nowMs)
        let expired = try store.actionItems(status: "open", limit: 10)
            .first { $0.id == "expired" }

        XCTAssertEqual(due.map(\.id), ["due"])
        XCTAssertEqual(expired?.remindedAtMs, nowMs)
    }

    func testResolveAndDismissClearReminderColumns() throws {
        try insertActionItem(id: "resolve-me", status: "open", remindAtMs: t0 + 1_000, remindedAtMs: nil)
        try insertActionItem(id: "dismiss-me", status: "open", remindAtMs: t0 + 2_000, remindedAtMs: nil)

        try store.resolveActionItem("resolve-me", nowMs: t0 + 3_000)
        try store.dismissActionItem("dismiss-me", nowMs: t0 + 3_000)

        try db.dbQueue.read { database in
            XCTAssertNil(try Int64.fetchOne(
                database,
                sql: "SELECT remind_at_ms FROM agent_action_items WHERE id='resolve-me'"
            ))
            XCTAssertNil(try Int64.fetchOne(
                database,
                sql: "SELECT remind_at_ms FROM agent_action_items WHERE id='dismiss-me'"
            ))
        }
    }

    func testDeleteAllAndPruneRemoveActionRowsThatContainReminderColumns() throws {
        try insertActionItem(
            id: "old-resolved",
            status: "resolved",
            remindAtMs: t0,
            remindedAtMs: t0,
            updatedAtMs: t0
        )
        _ = try store.pruneMemory(olderThan: t0 + 1)

        let prunedCount = try db.dbQueue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT count(*) FROM agent_action_items WHERE id='old-resolved'"
            )
        }
        XCTAssertEqual(prunedCount, 0)

        try insertActionItem(id: "delete-me", status: "open", remindAtMs: t0 + 2, remindedAtMs: nil)
        _ = try store.deleteAllMemory()

        let remainingCount = try db.dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT count(*) FROM agent_action_items")
        }
        XCTAssertEqual(remainingCount, 0)
    }

    private func insertActionItem(
        id: String,
        status: String,
        remindAtMs: EpochMs?,
        remindedAtMs: EpochMs?,
        updatedAtMs: EpochMs? = nil
    ) throws {
        try db.dbQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO agent_action_items (
                        id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                        detected_at, updated_at, resolved_at, remind_at_ms, reminded_at_ms
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    id, "todo", status, try AESGCMFieldCipher.testCipher.encrypt("Fixture \(id)"),
                    nil, nil, t0, updatedAtMs ?? t0, status == "resolved" ? t0 : nil,
                    remindAtMs, remindedAtMs,
                ]
            )
        }
    }

    private func seedVersions(_ count: Int) throws {
        for index in 0..<count {
            _ = try seedVersion(
                sourceKey: "cursor:\(versionCounter)-\(index)",
                content: "Version \(versionCounter) content"
            )
        }
    }

    private func seedVersion(
        sourceApp: String = "Web",
        sourceKey: String,
        content: String
    ) throws -> String {
        let nowMs = t0 + EpochMs(versionCounter * 10)
        versionCounter += 1
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: sourceApp,
                sourceKey: sourceKey,
                sourceTitle: "Plan",
                content: content
            ),
            nowMs: nowMs
        ) else {
            XCTFail("test capture must commit")
            throw SeedError.captureDidNotCommit
        }
        return versionID
    }

    private enum SeedError: Error {
        case captureDidNotCommit
    }
}
