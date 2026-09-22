import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CheckinStoreTests: XCTestCase {
    private var store: Store!
    private var db: MaxMiDatabase!
    private let t0: EpochMs = 1_800_000_000_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    private func lastSafeLogLine() throws -> String {
        let contents = try String(contentsOf: SafeLogger.shared.activeFileURL, encoding: .utf8)
        return String(try XCTUnwrap(contents.split(separator: "\n").last))
    }

    func testSaveOverwriteDismissAndMalformedIDJSON() throws {
        let day = Store.dayBucket(forMs: t0, timeZone: .current)
        try store.saveCheckin(
            dayBucket: day, generatedAtMs: t0, summary: "You shipped the migration.",
            openItemIDs: ["item-1"], resolvedYesterdayCount: 2, promptVersion: "checkin-v1"
        )
        try store.dismissCheckin(dayBucket: day, nowMs: t0 + 1)
        let dismissed = try XCTUnwrap(try store.checkin(dayBucket: day))
        XCTAssertEqual(dismissed.dismissedAtMs, t0 + 1)
        try store.saveCheckin(
            dayBucket: day, generatedAtMs: t0 + 2, summary: "You reviewed the plan.",
            openItemIDs: ["item-2"], resolvedYesterdayCount: 3, promptVersion: "checkin-v1"
        )

        let row = try XCTUnwrap(try store.checkin(dayBucket: day))
        XCTAssertEqual(row.summary, "You reviewed the plan.")
        XCTAssertEqual(row.openItemIDs, ["item-2"])
        XCTAssertNil(row.dismissedAtMs)
        let ciphertext = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT summary_ciphertext FROM checkins WHERE day_bucket=?", arguments: [day])
        }
        let rowCount = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT count(*) FROM checkins WHERE day_bucket=?", arguments: [day])
        }
        XCTAssertTrue(ciphertext?.hasPrefix("enc:v1:") == true)
        XCTAssertNotEqual(ciphertext, row.summary)
        XCTAssertEqual(rowCount, 1)

        try db.dbQueue.write { d in
            try d.execute(
                sql: "UPDATE checkins SET open_item_ids=? WHERE day_bucket=?",
                arguments: ["{not-json}", day]
            )
        }
        let malformed = try XCTUnwrap(try store.checkin(dayBucket: day))
        let logLine = try lastSafeLogLine()
        XCTAssertEqual(malformed.openItemIDs, [])
        XCTAssertTrue(logLine.contains("\"event\":\"settings_decode_failed\""))
        XCTAssertTrue(logLine.contains("checkin_open_item_ids"))
    }

    func testUnreadableSummaryReturnsNilRatherThanAMarker() throws {
        let day = Store.dayBucket(forMs: t0, timeZone: .current)
        try store.saveCheckin(
            dayBucket: day, generatedAtMs: t0, summary: "A private summary.",
            openItemIDs: [], resolvedYesterdayCount: 0, promptVersion: "checkin-v1"
        )
        try db.dbQueue.write { d in
            try d.execute(
                sql: "UPDATE checkins SET summary_ciphertext=? WHERE day_bucket=?",
                arguments: ["enc:v1:not-valid", day]
            )
        }

        let row = try XCTUnwrap(try store.checkin(dayBucket: day))
        XCTAssertNil(row.summary)
    }

    func testRetryBackoffPersistsAcrossCallsAndClearsAfterSave() throws {
        let day = Store.dayBucket(forMs: t0, timeZone: .current)

        try store.recordCheckinRetry(dayBucket: day, nowMs: t0)
        let first = try store.checkinRetryState(dayBucket: day)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertEqual(first.nextAttemptAtMs, t0 + 30_000)

        try store.recordCheckinRetry(dayBucket: day, nowMs: t0 + 30_001)
        let second = try store.checkinRetryState(dayBucket: day)
        XCTAssertEqual(second.attempts, 2)
        XCTAssertEqual(second.nextAttemptAtMs, t0 + 90_001)

        try store.saveCheckin(
            dayBucket: day, generatedAtMs: t0 + 30_002, summary: "Completed.",
            openItemIDs: [], resolvedYesterdayCount: 0, promptVersion: "checkin-v1"
        )
        let cleared = try store.checkinRetryState(dayBucket: day)
        XCTAssertEqual(cleared.attempts, 0)
        XCTAssertNil(cleared.nextAttemptAtMs)
    }

    func testOpenResolvedCalendarAndTopAppQueriesUseExplicitRanges() throws {
        try seedActionItems()
        let openItems = try store.openCheckinItems(limit: 10)
        XCTAssertEqual(openItems.map(\.id), ["open-item"])
        XCTAssertEqual(openItems.first?.title, "Open task")
        XCTAssertEqual(openItems.first?.details, "Follow up")
        XCTAssertEqual(openItems.first?.detectedAtMs, t0 + 10)
        XCTAssertEqual(openItems.first?.sourceApp, "Editor")

        let resolved = try store.resolvedCheckinItems(
            fromMs: t0 + 20, toMs: t0 + 40, limit: 10
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.titles, ["Resolved task"])
        XCTAssertFalse(resolved.titles.contains("Before range"))
        XCTAssertFalse(resolved.titles.contains("After range"))

        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Calendar", sourceKey: "calendar:today", sourceTitle: "Today",
                content: "Plan review", contentKind: .calendar, parserID: "TestCalendar",
                parserVersion: 1, accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .periodic, truncated: false,
                structured: .calendar([
                    CalendarEvent(
                        title: "Plan review", dateString: "Today 10:00", start: nil, end: nil,
                        organizer: nil, location: nil, hasConference: false, notes: nil
                    ),
                ])
            ),
            nowMs: t0 + 50
        )
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Calendar", sourceKey: "calendar:before", sourceTitle: "Before",
                content: "Before range", contentKind: .calendar, parserID: "TestCalendar",
                parserVersion: 1, accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .periodic, truncated: false,
                structured: .calendar([
                    CalendarEvent(
                        title: "Before range", dateString: "Today 09:00", start: nil, end: nil,
                        organizer: nil, location: nil, hasConference: false, notes: nil
                    ),
                ])
            ),
            nowMs: t0 + 39
        )
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Calendar", sourceKey: "calendar:after", sourceTitle: "After",
                content: "After range", contentKind: .calendar, parserID: "TestCalendar",
                parserVersion: 1, accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .periodic, truncated: false,
                structured: .calendar([
                    CalendarEvent(
                        title: "After range", dateString: "Today 11:00", start: nil, end: nil,
                        organizer: nil, location: nil, hasConference: false, notes: nil
                    ),
                ])
            ),
            nowMs: t0 + 61
        )
        let calendar = try store.checkinCalendarCaptures(
            fromMs: t0 + 40, toMs: t0 + 60, limit: 10
        )
        XCTAssertEqual(calendar.map(\.title), ["Plan review"])
        XCTAssertFalse(calendar.map(\.title).contains("Before range"))
        XCTAssertFalse(calendar.map(\.title).contains("After range"))

        _ = try store.openVisit(
            appBundle: "com.example.before", appLabel: "Before", nowMs: t0 - 100
        )
        try store.closeOpenVisits(nowMs: t0 - 1)
        _ = try store.openVisit(
            appBundle: "com.example.editor", appLabel: "Editor", nowMs: t0 + 100
        )
        try store.closeOpenVisits(nowMs: t0 + 500)
        _ = try store.openVisit(
            appBundle: "com.example.chat", appLabel: "Chat", nowMs: t0 + 600
        )
        try store.closeOpenVisits(nowMs: t0 + 700)
        _ = try store.openVisit(
            appBundle: "com.example.after", appLabel: "After", nowMs: t0 + 801
        )
        try store.closeOpenVisits(nowMs: t0 + 900)
        _ = try store.commitCapture(
            CaptureInput(
                sourceApp: "Editor", sourceKey: "editor:workspace",
                sourceTitle: "Workspace", content: "Editing"
            ),
            nowMs: t0 + 400
        )

        let apps = try store.checkinTopApps(fromMs: t0, toMs: t0 + 800, limit: 10)
        XCTAssertEqual(apps.map(\.appLabel), ["Editor", "Chat"])
        XCTAssertFalse(apps.map(\.appLabel).contains("Before"))
        XCTAssertFalse(apps.map(\.appLabel).contains("After"))
        XCTAssertEqual(apps.first?.sourceTitle, "Workspace")
    }

    func testPruneAndDeleteAllRemoveCheckins() throws {
        let oldDay = Store.dayBucket(forMs: t0, timeZone: .current)
        let newTime = t0 + 86_400_000
        let newDay = Store.dayBucket(forMs: newTime, timeZone: .current)
        try store.saveCheckin(
            dayBucket: oldDay, generatedAtMs: t0, summary: "Old check-in.",
            openItemIDs: [], resolvedYesterdayCount: 0, promptVersion: "checkin-v1"
        )
        try store.saveCheckin(
            dayBucket: newDay, generatedAtMs: newTime, summary: "New check-in.",
            openItemIDs: [], resolvedYesterdayCount: 0, promptVersion: "checkin-v1"
        )
        _ = try store.pruneMemory(olderThan: t0 + 1)
        XCTAssertNil(try store.checkin(dayBucket: oldDay))
        XCTAssertNotNil(try store.checkin(dayBucket: newDay))

        try store.saveCheckin(
            dayBucket: oldDay, generatedAtMs: t0 + 2, summary: "Delete all check-in.",
            openItemIDs: [], resolvedYesterdayCount: 0, promptVersion: "checkin-v1"
        )
        _ = try store.deleteAllMemory()
        XCTAssertNil(try store.checkin(dayBucket: oldDay))
        XCTAssertNil(try store.checkin(dayBucket: newDay))
    }

    func testCheckinInputsExcludeLocalOnlyPausedAndBlockedSourcesBeforeReadingContent() throws {
        let ordinary = try seedCalendarSource(
            app: "Calendar",
            key: "https://ordinary-checkin.example",
            title: "Ordinary calendar",
            eventTitle: "Ordinary event",
            at: t0
        )
        let local = try seedCalendarSource(
            app: "Local Calendar",
            key: "local:checkin",
            title: "Local calendar",
            eventTitle: "Local event",
            at: t0 + 1
        )
        let paused = try seedCalendarSource(
            app: "Paused Calendar",
            key: "https://paused-checkin.example",
            title: "Paused calendar",
            eventTitle: "Paused event",
            at: t0 + 2
        )
        let blocked = try seedCalendarSource(
            app: "Blocked Calendar",
            key: "https://blocked-checkin.example",
            title: "Blocked calendar",
            eventTitle: "Blocked event",
            at: t0 + 3
        )
        try store.setCloudProcessing("Local Calendar", allowed: false, nowMs: t0 + 4)
        try store.setThreadPaused("https://paused-checkin.example", paused: true, nowMs: t0 + 4)
        _ = try store.setDomain("blocked-checkin.example", blocked: true, nowMs: t0 + 4)
        try insertOpenItems(for: [ordinary, local, paused, blocked])

        for (index, source) in [ordinary, local, paused, blocked].enumerated() {
            let startedAt = t0 + 100 + EpochMs(index * 10)
            _ = try store.openVisit(
                appBundle: "com.example.checkin.\(index)",
                appLabel: source.app,
                nowMs: startedAt
            )
            try store.closeOpenVisits(nowMs: startedAt + 5)
            try store.recordCaptureEvent(
                kind: .contentDelta,
                appBundle: "com.example.checkin.\(index)",
                threadID: source.threadID,
                versionID: source.versionID,
                trigger: .periodic,
                payload: CaptureDelta(
                    addedBlocks: [.init(type: .paragraph, text: source.eventTitle)]
                ),
                nowMs: startedAt + 1
            )
        }

        let openItems = try store.openCheckinItems(limit: 10)
        let calendar = try store.checkinCalendarCaptures(fromMs: t0, toMs: t0 + 10, limit: 10)
        let topApps = try store.checkinTopApps(fromMs: t0, toMs: t0 + 200, limit: 10)
        let timelineEvents = try StoreTimelineRepository(store: store)
            .captureEvents(fromMs: t0, toMs: t0 + 200)

        XCTAssertEqual(openItems.map(\.title), ["Ordinary open item"])
        XCTAssertEqual(calendar.map(\.title), ["Ordinary event"])
        XCTAssertEqual(topApps.map(\.appLabel), ["Calendar"])
        XCTAssertEqual(timelineEvents.map(\.threadID), [ordinary.threadID])
    }

    func testCheckinResolvesOpenItemCreatedByVersionBasedAgentSourceReference() throws {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: "Editor",
                sourceKey: "editor:post-task-four",
                sourceTitle: "Post Task 4",
                content: "Follow up on the version reference"
            ),
            nowMs: t0
        ) else {
            return XCTFail("Expected source version to commit.")
        }
        let page = try XCTUnwrap(try store.claimNextAgentRun(
            maxVersions: 10,
            leaseMs: 60_000,
            nowMs: t0 + 1
        ))
        XCTAssertEqual(page.versions.map(\.versionID), [versionID])
        _ = try store.completeAgentRun(
            runID: page.runID,
            ops: [
                .create(
                    kind: "todo",
                    title: "Follow up",
                    details: nil,
                    sourceRefs: [versionID]
                ),
            ],
            nowMs: t0 + 2
        )

        let item = try XCTUnwrap(store.openCheckinItems(limit: 1).first)

        XCTAssertEqual(item.title, "Follow up")
        XCTAssertEqual(item.sourceApp, "Editor")
    }

    private func seedActionItems() throws {
        let titleCipher = try AESGCMFieldCipher.testCipher.encrypt("Open task")
        let detailsCipher = try AESGCMFieldCipher.testCipher.encrypt("Follow up")
        let resolvedCipher = try AESGCMFieldCipher.testCipher.encrypt("Resolved task")
        let beforeResolvedCipher = try AESGCMFieldCipher.testCipher.encrypt("Before range")
        let afterResolvedCipher = try AESGCMFieldCipher.testCipher.encrypt("After range")
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: "Editor",
                sourceKey: "editor:workspace",
                sourceTitle: "Workspace",
                content: "Open task source"
            ),
            nowMs: t0
        ) else {
            return XCTFail("Expected action-item source capture to commit.")
        }
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('open-item','todo','open',?,?,?, ?,?,NULL)
                """, arguments: [
                    titleCipher, detailsCipher,
                    String(decoding: try JSONEncoder().encode([versionID]), as: UTF8.self),
                    t0 + 10, t0 + 10,
                ])
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('resolved-item','todo','resolved',?,NULL,NULL,?,?,?)
                """, arguments: [resolvedCipher, t0 + 20, t0 + 30, t0 + 30])
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('resolved-before','todo','resolved',?,NULL,NULL,?,?,?)
                """, arguments: [beforeResolvedCipher, t0 + 10, t0 + 19, t0 + 19])
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('resolved-after','todo','resolved',?,NULL,NULL,?,?,?)
                """, arguments: [afterResolvedCipher, t0 + 41, t0 + 41, t0 + 41])
        }
    }

    private func seedCalendarSource(
        app: String,
        key: String,
        title: String,
        eventTitle: String,
        at: EpochMs
    ) throws -> CheckinSourceFixture {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: app,
                sourceKey: key,
                sourceTitle: title,
                content: eventTitle,
                contentKind: .calendar,
                parserID: "TestCalendar",
                parserVersion: 1,
                accumulationPolicy: .replace,
                offscreenPolicy: .visibleOnly(),
                trigger: .periodic,
                truncated: false,
                structured: .calendar([
                    CalendarEvent(
                        title: eventTitle,
                        dateString: "Today",
                        start: nil,
                        end: nil,
                        organizer: nil,
                        location: nil,
                        hasConference: false,
                        notes: nil
                    ),
                ])
            ),
            nowMs: at
        ) else {
            throw FixtureError.captureDidNotCommit
        }
        return CheckinSourceFixture(
            app: app,
            eventTitle: eventTitle,
            versionID: versionID,
            threadID: try store.threadID(forKey: key)
        )
    }

    private func insertOpenItems(for sources: [CheckinSourceFixture]) throws {
        try db.dbQueue.write { d in
            for (index, source) in sources.enumerated() {
                try d.execute(
                    sql: """
                    INSERT INTO agent_action_items (
                        id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                        detected_at, updated_at
                    ) VALUES (?,?,?,?,?,?,?,?)
                    """,
                    arguments: [
                        "privacy-item-\(index)",
                        "todo",
                        "open",
                        try AESGCMFieldCipher.testCipher.encrypt(
                            "\(source.eventTitle.replacingOccurrences(of: "event", with: "open item"))"
                        ),
                        nil,
                        String(decoding: try JSONEncoder().encode([source.versionID]), as: UTF8.self),
                        t0 + EpochMs(index),
                        t0 + EpochMs(index),
                    ]
                )
            }
        }
    }

    private struct CheckinSourceFixture {
        let app: String
        let eventTitle: String
        let versionID: String
        let threadID: String
    }

    private enum FixtureError: Error {
        case captureDidNotCommit
    }
}
