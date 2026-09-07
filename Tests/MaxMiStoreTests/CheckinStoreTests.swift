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
        let calendar = try store.checkinCalendarCaptures(
            fromMs: t0 + 40, toMs: t0 + 60, limit: 10
        )
        XCTAssertEqual(calendar.map(\.title), ["Plan review"])

        _ = try store.openVisit(
            appBundle: "com.example.editor", appLabel: "Editor", nowMs: t0 + 100
        )
        try store.closeOpenVisits(nowMs: t0 + 500)
        _ = try store.openVisit(
            appBundle: "com.example.chat", appLabel: "Chat", nowMs: t0 + 600
        )
        try store.closeOpenVisits(nowMs: t0 + 700)
        _ = try store.commitCapture(
            CaptureInput(
                sourceApp: "Editor", sourceKey: "editor:workspace",
                sourceTitle: "Workspace", content: "Editing"
            ),
            nowMs: t0 + 400
        )

        let apps = try store.checkinTopApps(fromMs: t0, toMs: t0 + 800, limit: 10)
        XCTAssertEqual(apps.map(\.appLabel), ["Editor", "Chat"])
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

    private func seedActionItems() throws {
        let titleCipher = try AESGCMFieldCipher.testCipher.encrypt("Open task")
        let detailsCipher = try AESGCMFieldCipher.testCipher.encrypt("Follow up")
        let resolvedCipher = try AESGCMFieldCipher.testCipher.encrypt("Resolved task")
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO activity_sessions (
                    id, app_bundle, app_label, started_at, ended_at, last_activity_at,
                    day_bucket, created_at, updated_at
                ) VALUES ('session-1','com.example.editor','Editor',?,NULL,?,?,?,?)
                """, arguments: [
                    t0, t0, Store.dayBucket(forMs: t0, timeZone: .current), t0, t0,
                ])
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('open-item','todo','open',?,?,?, ?,?,NULL)
                """, arguments: [
                    titleCipher, detailsCipher, "[\"session-1\"]", t0 + 10, t0 + 10,
                ])
            try d.execute(sql: """
                INSERT INTO agent_action_items (
                    id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                    detected_at, updated_at, resolved_at
                ) VALUES ('resolved-item','todo','resolved',?,NULL,NULL,?,?,?)
                """, arguments: [resolvedCipher, t0 + 20, t0 + 30, t0 + 30])
        }
    }
}
