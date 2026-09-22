# MaxMi M9 — Double-tap Option Todo Panel with Reminders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a dark, non-activating todo panel with a double Option-key tap, allow users to resolve or dismiss hourly-review action items, and deliver local reminder notifications for concrete near-term deadlines.

**Architecture:** Keep deterministic gesture, reminder-time, scheduler, and view-model behavior in `MaxMiActivity` or `MaxMiUI`, where SwiftPM has XCTest coverage. Keep SQLite and encrypted action-item operations in `MaxMiStore`, and put Store-to-protocol adapters, AppKit panel ownership, notification authorization, and AppWiring lifecycle work in the executable target so `MaxMiUI` never imports `MaxMiStore`.

**Tech Stack:** Swift 6, SwiftPM, macOS 14+, SwiftUI, AppKit, UserNotifications, GRDB 7, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-22-maxmi-m9-todo-panel-design.md`

## Global Constraints

- Swift 6 strict concurrency; XCTest only; all existing tests stay green except the two known-red cases (`ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`, `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`). `cloudReviewInitialized()` stays `{ false }`.
- MaxMiUI never imports MaxMiStore; adapters live in Sources/MaxMi. No new SwiftPM test target for the executable; testable logic lives in MaxMiActivity/MaxMiUI.
- Fixtures hand-invented; commit messages plain, no AI attribution; process stop is `pkill -9 -x MaxMi`.

---

## File Structure

- `Sources/MaxMiActivity/OptionDoubleTapDetector.swift` — pure, timestamp-driven Option double-tap recognizer shared by AppKit monitors.
- `Sources/MaxMiActivity/ReminderTimeValidator.swift` — pure ISO-8601-with-offset deadline acceptance rule and its 48-hour bound.
- `Sources/MaxMiActivity/ReminderScheduler.swift` — consent-gated, single-flight reminder polling actor and platform-neutral notification contracts.
- `Sources/MaxMiActivity/HourlyAgent.swift` — reminder-aware hourly-review DTO, validated operation representation, and repository contract.
- `Sources/MaxMiActivity/AgentPrompts.swift` — the single additive `remind_at` instruction and JSON operation shape.
- `Sources/MaxMiStore/Migrations.swift` — additive v14 reminder columns and reminder due-query index.
- `Sources/MaxMiStore/AgentStore.swift` — action-item reminder persistence, due-item expiry marking, source-app lookup, and agent-operation persistence.
- `Sources/MaxMi/StoreAgentRepository.swift` — executable adapter that forwards already validated Activity operations to Store.
- `Sources/MaxMiUI/TodoPanelDTO.swift` — portable panel item type and repository protocol.
- `Sources/MaxMiUI/TodoPanelViewModel.swift` — main-actor loading, selection, resolve, and dismiss state.
- `Sources/MaxMiUI/TodoPanelView.swift` — always-dark SwiftUI panel content and keyboard hooks.
- `Sources/MaxMi/StoreTodoPanelRepository.swift` and `Sources/MaxMi/StoreReminderRepository.swift` — Store adapters that derive the first-source app without exposing Store to UI/Activity.
- `Sources/MaxMi/UNUserNotificationCenterNotifier.swift` — lazy local-notification authorization and notification-click bridge.
- `Sources/MaxMi/TodoPanelController.swift` and `Sources/MaxMi/OptionDoubleTapMonitor.swift` — AppKit panel lifetime, placement, closing behavior, and global/local event monitors.
- `Sources/MaxMi/AppWiring.swift` — construction, start/shutdown, and pipeline-timer wiring for the controller, gesture monitor, and scheduler.
- `Tests/MaxMiActivityTests/OptionDoubleTapDetectorTests.swift`, `ReminderTimeValidatorTests.swift`, `ReminderSchedulerTests.swift`, and `HourlyAgentTests.swift` — deterministic Activity behavior and prompt goldens.
- `Tests/MaxMiStoreTests/AgentStoreTests.swift` and migration suites — v14 schema, Store reminder boundaries, action-row lifecycle, Store source lookup, migration-list, and recovery-head coverage.
- `Tests/MaxMiUITests/TodoPanelViewModelTests.swift` — fake-backed panel ordering, actions, selection, empty state, and header state.
- `docs/superpowers/plans/2026-09-22-maxmi-m9-live-verification.md` — post-build, human-only verification checklist.

### Task 1: Add the `OptionDoubleTapDetector` pure state machine

**Files:**

- Create: `Sources/MaxMiActivity/OptionDoubleTapDetector.swift`
- Create: `Tests/MaxMiActivityTests/OptionDoubleTapDetectorTests.swift`

**Interfaces:**

- Consumes: `EpochMs` from `MaxMiCore`.
- Produces:

```swift
public struct OptionDoubleTapDetector: Sendable {
    public static let maximumTapHoldMs: EpochMs = 400
    public static let maximumTapDownIntervalMs: EpochMs = 350

    public enum Event: Sendable, Equatable {
        case optionDown(EpochMs)
        case optionUp(EpochMs)
        case otherKeyOrModifier(EpochMs)
    }

    public init()
    public mutating func consume(_ event: Event) -> Bool
}
```

- Task 8 consumes `OptionDoubleTapDetector.Event` and calls `consume(_:)` from both AppKit event monitors. A `true` result means exactly one double tap fired and the detector has reset.

- [ ] **Step 1: Write the failing detector tests**

```swift
// Tests/MaxMiActivityTests/OptionDoubleTapDetectorTests.swift
import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class OptionDoubleTapDetectorTests: XCTestCase {
    func testTwoFastTapsFireOnce() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_300)))
        XCTAssertTrue(detector.consume(.optionUp(1_350)))
        XCTAssertFalse(detector.consume(.optionUp(1_360)))
    }

    func testSecondDownAtThreeHundredFiftyOneMillisecondsDoesNotFire() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_351)))
        XCTAssertFalse(detector.consume(.optionUp(1_400)))
    }

    func testHoldLongerThanFourHundredMillisecondsIsNotATap() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_401)))
        XCTAssertFalse(detector.consume(.optionDown(1_500)))
        XCTAssertFalse(detector.consume(.optionUp(1_550)))
    }

    func testOptionKeyChordResetsTheDetector() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.otherKeyOrModifier(1_050)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_200)))
        XCTAssertFalse(detector.consume(.optionUp(1_250)))
    }

    func testThreeTapsFireOnceThenReset() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_050)))
        XCTAssertFalse(detector.consume(.optionDown(1_200)))
        XCTAssertTrue(detector.consume(.optionUp(1_250)))
        XCTAssertFalse(detector.consume(.optionDown(1_400)))
        XCTAssertFalse(detector.consume(.optionUp(1_450)))
    }
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter OptionDoubleTapDetectorTests
```

Expected: FAIL because `OptionDoubleTapDetector` does not exist.

- [ ] **Step 3: Implement the state machine**

```swift
// Sources/MaxMiActivity/OptionDoubleTapDetector.swift
import MaxMiCore

public struct OptionDoubleTapDetector: Sendable {
    public static let maximumTapHoldMs: EpochMs = 400
    public static let maximumTapDownIntervalMs: EpochMs = 350

    public enum Event: Sendable, Equatable {
        case optionDown(EpochMs)
        case optionUp(EpochMs)
        case otherKeyOrModifier(EpochMs)
    }

    private var firstTapDownMs: EpochMs?
    private var activeTapDownMs: EpochMs?

    public init() {}

    public mutating func consume(_ event: Event) -> Bool {
        switch event {
        case .optionDown(let nowMs):
            guard activeTapDownMs == nil else {
                reset()
                activeTapDownMs = nowMs
                return false
            }
            if let firstTapDownMs,
               nowMs - firstTapDownMs > Self.maximumTapDownIntervalMs {
                self.firstTapDownMs = nil
            }
            activeTapDownMs = nowMs
            return false

        case .optionUp(let nowMs):
            guard let downMs = activeTapDownMs else {
                return false
            }
            activeTapDownMs = nil
            guard nowMs - downMs <= Self.maximumTapHoldMs else {
                firstTapDownMs = nil
                return false
            }
            if let firstTapDownMs,
               downMs - firstTapDownMs <= Self.maximumTapDownIntervalMs {
                reset()
                return true
            }
            firstTapDownMs = downMs
            return false

        case .otherKeyOrModifier:
            reset()
            return false
        }
    }

    private mutating func reset() {
        firstTapDownMs = nil
        activeTapDownMs = nil
    }
}
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter OptionDoubleTapDetectorTests
```

Expected: PASS. The boundary test proves 350 ms is accepted while 351 ms is not, and the third-tap test proves firing does not cascade.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiActivity/OptionDoubleTapDetector.swift Tests/MaxMiActivityTests/OptionDoubleTapDetectorTests.swift
git commit -m "Add Option double tap detector"
```

### Task 2: Add v14 reminder persistence and Store operations

**Files:**

- Modify: `Sources/MaxMiStore/Migrations.swift`
- Modify: `Sources/MaxMiStore/AgentStore.swift`
- Modify: `Tests/MaxMiStoreTests/AgentStoreTests.swift`
- Create: `Tests/MaxMiStoreTests/MigrationV14Tests.swift`
- Modify: `Tests/MaxMiStoreTests/MigrationV11Tests.swift`
- Modify: `Tests/MaxMiStoreTests/MigrationV12Tests.swift`
- Modify: `Tests/MaxMiStoreTests/MigrationV13Tests.swift`
- Modify: `Tests/MaxMiStoreTests/MemoryDataControlsTests.swift`

**Interfaces:**

- Consumes: existing `ActionItem`, `AgentOp`, `Store.actionItems(status:limit:)`, `Store.resolveActionItem(_:nowMs:)`, `Store.dismissActionItem(_:nowMs:)`, `MemoryDataControls.pruneMemory(olderThan:)`, `MemoryDataControls.deleteAllMemory()`, `Migrations.migrator`, and `DatabaseRecovery`’s migrator-derived known-migration set.
- Produces:

```swift
public enum ReminderWindow {
    public static let maximumPastDueMs: EpochMs = 24 * 60 * 60 * 1_000
}

public struct ActionItem: Sendable {
    public let id, kind, status, title: String
    public let details: String?
    public let sourceRefs: [String]
    public let detectedAtMs, updatedAtMs: EpochMs
    public let resolvedAtMs: EpochMs?
    public let remindAtMs: EpochMs?
    public let remindedAtMs: EpochMs?
}

extension Store {
    public func dueReminders(nowMs: EpochMs) throws -> [ActionItem]
    public func markReminded(_ id: String, nowMs: EpochMs) throws
    public func setReminder(_ id: String, remindAtMs: EpochMs?) throws
}
```

- Task 3 makes reminder-aware agent operations call the same `setReminder` SQL helper while processing a Store transaction. Task 7 consumes `ActionItem.remindAtMs` and `ActionItem.remindedAtMs` through `actionItems(status:limit:)` and `dueReminders(nowMs:)`.

- [ ] **Step 1: Write failing v14, due-boundary, resolution, and deletion tests**

```swift
// Tests/MaxMiStoreTests/MigrationV14Tests.swift
import XCTest
import GRDB
@testable import MaxMiStore

final class MigrationV14Tests: XCTestCase {
    func testReminderColumnsIndexAndMigrationHeadAreV14() throws {
        let db = try MaxMiDatabase.inMemory()

        try db.dbQueue.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(agent_action_items)")
            XCTAssertEqual(
                Set(columns.map { $0["name"] as String }),
                Set([
                    "id", "kind", "status", "title_ciphertext", "details_ciphertext",
                    "source_refs", "detected_at", "updated_at", "resolved_at",
                    "resolution_evidence_ciphertext", "idem_key", "remind_at_ms", "reminded_at_ms",
                ])
            )
            let indexes = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='agent_action_items'"
            )
            XCTAssertTrue(indexes.contains("idx_items_status_remind_at_ms"))
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                ),
                "v14"
            )
        }

        XCTAssertEqual(Migrations.currentIdentifier, "v14")
        XCTAssertTrue(Set(Migrations.migrator.migrations).isSuperset(of: ["v12", "v13", "v14"]))
        XCTAssertEqual(Array(Migrations.migrator.migrations.suffix(3)), ["v12", "v13", "v14"])
    }
}
```

```swift
// Add to Tests/MaxMiStoreTests/AgentStoreTests.swift
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
```

```swift
// Update exact v13-head expectations in the existing suites.
// Tests/MaxMiStoreTests/MigrationV11Tests.swift
func testCurrentIdentifierIsV14() {
    XCTAssertEqual(Migrations.currentIdentifier, "v14")
}

// In testV10DatabaseMigratesForwardWithoutDataLoss:
XCTAssertEqual(
    try String.fetchOne(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
    "v14"
)

// Tests/MaxMiStoreTests/MigrationV12Tests.swift
XCTAssertEqual(Migrations.currentIdentifier, "v14")
XCTAssertTrue(Set(Migrations.migrator.migrations).isSuperset(of: ["v12", "v13", "v14"]))
XCTAssertEqual(Array(Migrations.migrator.migrations.suffix(3)), ["v12", "v13", "v14"])

// Tests/MaxMiStoreTests/MigrationV13Tests.swift
XCTAssertEqual(
    try String.fetchOne(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
    "v14"
)
XCTAssertEqual(Migrations.currentIdentifier, "v14")

// Tests/MaxMiStoreTests/MemoryDataControlsTests.swift
XCTAssertEqual(result.migrationIdentifier, "v14")
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter MigrationV14Tests
swift test --filter AgentStoreTests
swift test --filter MigrationV11Tests
swift test --filter MigrationV12Tests
swift test --filter MigrationV13Tests
swift test --filter MemoryDataControlsTests
```

Expected: FAIL because v14, `ReminderWindow`, the two nullable columns, the due-reminder methods, and the revised migration head do not exist.

- [ ] **Step 3: Implement v14 and the Store methods**

```swift
// Sources/MaxMiStore/Migrations.swift
enum Migrations {
    static let currentIdentifier = "v14"

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // Keep existing v1 through v13 registrations unchanged.
        m.registerMigration("v14") { db in
            try db.execute(sql: """
                ALTER TABLE agent_action_items ADD COLUMN remind_at_ms INTEGER NULL;
                ALTER TABLE agent_action_items ADD COLUMN reminded_at_ms INTEGER NULL;
                CREATE INDEX idx_items_status_remind_at_ms
                  ON agent_action_items(status, remind_at_ms);
                """)
        }
        return m
    }
}
```

Do not edit `Sources/MaxMiStore/DatabaseRecovery.swift`: it already derives `knownIdentifiers` from `Set(Migrations.migrator.migrations)` and compares the migrated head to `Migrations.currentIdentifier`.

```swift
// Sources/MaxMiStore/AgentStore.swift
public enum ReminderWindow {
    public static let maximumPastDueMs: EpochMs = 24 * 60 * 60 * 1_000
}

public struct ActionItem: Sendable {
    public let id, kind, status, title: String
    public let details: String?
    public let sourceRefs: [String]
    public let detectedAtMs, updatedAtMs: EpochMs
    public let resolvedAtMs: EpochMs?
    public let remindAtMs: EpochMs?
    public let remindedAtMs: EpochMs?

    public init(
        id: String,
        kind: String,
        status: String,
        title: String,
        details: String?,
        sourceRefs: [String],
        detectedAtMs: EpochMs,
        updatedAtMs: EpochMs,
        resolvedAtMs: EpochMs?,
        remindAtMs: EpochMs?,
        remindedAtMs: EpochMs?
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.details = details
        self.sourceRefs = sourceRefs
        self.detectedAtMs = detectedAtMs
        self.updatedAtMs = updatedAtMs
        self.resolvedAtMs = resolvedAtMs
        self.remindAtMs = remindAtMs
        self.remindedAtMs = remindedAtMs
    }
}

extension Store {
    public func dueReminders(nowMs: EpochMs) throws -> [ActionItem] {
        try db.dbQueue.write { database in
            let oldestEligibleMs = nowMs - ReminderWindow.maximumPastDueMs
            try database.execute(
                sql: """
                    UPDATE agent_action_items
                    SET reminded_at_ms=?, updated_at=?
                    WHERE status='open'
                      AND remind_at_ms IS NOT NULL
                      AND remind_at_ms < ?
                      AND reminded_at_ms IS NULL
                    """,
                arguments: [nowMs, nowMs, oldestEligibleMs]
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                           detected_at, updated_at, resolved_at, remind_at_ms, reminded_at_ms
                    FROM agent_action_items
                    WHERE status='open'
                      AND remind_at_ms IS NOT NULL
                      AND remind_at_ms <= ?
                      AND remind_at_ms >= ?
                      AND reminded_at_ms IS NULL
                    ORDER BY remind_at_ms ASC, id ASC
                    """,
                arguments: [nowMs, oldestEligibleMs]
            )
            return rows.map(actionItem(from:))
        }
    }

    public func markReminded(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE agent_action_items
                    SET reminded_at_ms=?, updated_at=?
                    WHERE id=? AND status='open'
                      AND remind_at_ms IS NOT NULL AND reminded_at_ms IS NULL
                    """,
                arguments: [nowMs, nowMs, id]
            )
        }
    }

    public func setReminder(_ id: String, remindAtMs: EpochMs?) throws {
        try db.dbQueue.write { database in
            try setReminder(database, id: id, remindAtMs: remindAtMs, nowMs: epochNowMs())
        }
    }

    private func setReminder(
        _ database: Database,
        id: String,
        remindAtMs: EpochMs?,
        nowMs: EpochMs
    ) throws {
        try database.execute(
            sql: """
                UPDATE agent_action_items
                SET remind_at_ms=?, reminded_at_ms=NULL, updated_at=?
                WHERE id=? AND status='open'
                """,
            arguments: [remindAtMs, nowMs, id]
        )
    }

    public func resolveActionItem(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE agent_action_items
                    SET status='resolved', resolved_at=?, updated_at=?,
                        remind_at_ms=NULL, reminded_at_ms=NULL
                    WHERE id=? AND status='open'
                    """,
                arguments: [nowMs, nowMs, id]
            )
            if database.changesCount > 0 {
                let eventID = Ident.uuidv7(nowMs: nowMs)
                try database.execute(
                    sql: """
                        INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                        VALUES (?,?,?,NULL,?)
                        """,
                    arguments: [eventID, id, "resolved_user", nowMs]
                )
            }
        }
    }

    public func dismissActionItem(_ id: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE agent_action_items
                    SET status='dismissed', updated_at=?,
                        remind_at_ms=NULL, reminded_at_ms=NULL
                    WHERE id=? AND status='open'
                    """,
                arguments: [nowMs, id]
            )
            if database.changesCount > 0 {
                let eventID = Ident.uuidv7(nowMs: nowMs)
                try database.execute(
                    sql: """
                        INSERT INTO agent_action_item_events (id, item_id, event, run_id, at)
                        VALUES (?,?,?,NULL,?)
                        """,
                    arguments: [eventID, id, "dismissed_user", nowMs]
                )
            }
        }
    }

    public func actionItems(status: String, limit: Int) throws -> [ActionItem] {
        try db.dbQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, kind, status, title_ciphertext, details_ciphertext, source_refs,
                           detected_at, updated_at, resolved_at, remind_at_ms, reminded_at_ms
                    FROM agent_action_items
                    WHERE status=?
                    ORDER BY detected_at DESC
                    LIMIT ?
                    """,
                arguments: [status, limit]
            )
            return rows.map(actionItem(from:))
        }
    }

    private func actionItem(from row: Row) -> ActionItem {
        let sourceRefsJSON = row["source_refs"] as String?
        let sourceRefs = sourceRefsJSON.flatMap {
            try? JSONDecoder().decode([String].self, from: Data($0.utf8))
        } ?? []
        return ActionItem(
            id: row["id"],
            kind: row["kind"],
            status: row["status"],
            title: decryptOrMarker(row["title_ciphertext"]),
            details: (row["details_ciphertext"] as String?).map(decryptOrMarker),
            sourceRefs: sourceRefs,
            detectedAtMs: row["detected_at"],
            updatedAtMs: row["updated_at"],
            resolvedAtMs: row["resolved_at"],
            remindAtMs: row["remind_at_ms"],
            remindedAtMs: row["reminded_at_ms"]
        )
    }
}
```

Keep `MemoryDataControls.pruneMemory(olderThan:)` and `deleteAllMemory()` structurally unchanged: both already delete action-item rows, so reminder columns disappear with those rows. The tests above prove that existing ownership rather than adding a redundant reminder-table cleanup.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter MigrationV14Tests
swift test --filter AgentStoreTests
swift test --filter MigrationV11Tests
swift test --filter MigrationV12Tests
swift test --filter MigrationV13Tests
swift test --filter MemoryDataControlsTests
```

Expected: PASS. The recovery tests now report `v14`, proving `DatabaseRecovery` accepts and upgrades migration lists through the migrator without a hand-maintained list.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiStore/Migrations.swift Sources/MaxMiStore/AgentStore.swift Tests/MaxMiStoreTests/AgentStoreTests.swift Tests/MaxMiStoreTests/MigrationV14Tests.swift Tests/MaxMiStoreTests/MigrationV11Tests.swift Tests/MaxMiStoreTests/MigrationV12Tests.swift Tests/MaxMiStoreTests/MigrationV13Tests.swift Tests/MaxMiStoreTests/MemoryDataControlsTests.swift
git commit -m "Add action item reminders"
```

### Task 3: Add `remind_at` hourly-review validation and persistence wiring

**Files:**

- Create: `Sources/MaxMiActivity/ReminderTimeValidator.swift`
- Modify: `Sources/MaxMiActivity/HourlyAgent.swift`
- Modify: `Sources/MaxMiActivity/AgentPrompts.swift`
- Modify: `Sources/MaxMiStore/AgentStore.swift`
- Modify: `Sources/MaxMi/StoreAgentRepository.swift`
- Create: `Tests/MaxMiActivityTests/ReminderTimeValidatorTests.swift`
- Modify: `Tests/MaxMiActivityTests/HourlyAgentTests.swift`
- Modify: `Tests/MaxMiActivityTests/AgentPromptsTests.swift`
- Modify: `Tests/MaxMiStoreTests/AgentStoreTests.swift`

**Interfaces:**

- Consumes: Task 2’s `Store.setReminder(_:remindAtMs:)` transaction helper and `ReminderWindow`; existing `AgentGenerationRelay.reviewActivity(_:)`.
- Produces:

```swift
public enum ReminderTimeValidator {
    public static let maximumFutureMs: EpochMs = 48 * 60 * 60 * 1_000

    public static func accept(
        _ value: String?,
        nowMs: EpochMs,
        timeZone: TimeZone
    ) -> EpochMs?
}

public struct AgentOpDTO: Sendable, Codable {
    public let op: String
    public let id: String?
    public let kind: String?
    public let title: String?
    public let details: String?
    public let evidence: String?
    public let sourceRefs: [String]?
    public let remindAt: String?

    public init(
        op: String,
        id: String?,
        kind: String?,
        title: String?,
        details: String?,
        evidence: String?,
        sourceRefs: [String]?,
        remindAt: String? = nil
    )
}

public enum ReminderChange: Sendable, Equatable {
    case unchanged
    case set(EpochMs)
}

public enum ValidatedAgentOp: Sendable {
    case create(
        kind: String,
        title: String,
        details: String?,
        sourceRefs: [String],
        reminder: ReminderChange
    )
    case update(
        id: String,
        title: String?,
        details: String?,
        reminder: ReminderChange
    )
    case resolve(id: String, evidence: String)
}

public enum AgentOperationValidator {
    public static func validateAndMap(
        _ dtos: [AgentOpDTO],
        nowMs: EpochMs,
        timeZone: TimeZone
    ) throws -> [ValidatedAgentOp]
}

public protocol AgentRepository: Sendable {
    func claimNextPage() async -> AgentLeasedPage?
    func complete(runID: String, ops: [ValidatedAgentOp]) async throws
    func fail(runID: String, error: String) async
    func renew(runID: String) async
}
```

- Task 4 is independent of hourly review and only consumes Task 2’s Store API through a different protocol. Task 7 forwards `ValidatedAgentOp` unchanged through `StoreAgentRepository`; no XCTest target may be added for the executable.

- [ ] **Step 1: Write failing reminder-time, operation, Store, and prompt-golden tests**

```swift
// Tests/MaxMiActivityTests/ReminderTimeValidatorTests.swift
import Foundation
import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class ReminderTimeValidatorTests: XCTestCase {
func testReminderTimeValidatorAcceptsFutureTimeAndHonorsOffset() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
    let nowMs: EpochMs = 1_790_071_200_000

    let accepted = ReminderTimeValidator.accept(
        "2026-09-22T21:30:00+05:30",
        nowMs: nowMs,
        timeZone: zone
    )

    XCTAssertEqual(accepted, EpochMs(1_790_092_800_000))
}

func testReminderTimeValidatorRejectsPastTooFarAndMalformedValues() {
    let nowMs: EpochMs = 1_790_071_200_000
    let zone = TimeZone(secondsFromGMT: 0)!

    XCTAssertNil(ReminderTimeValidator.accept("2026-09-22T09:59:59Z", nowMs: nowMs, timeZone: zone))
    XCTAssertNil(ReminderTimeValidator.accept(
        "2026-09-24T10:00:01Z",
        nowMs: nowMs,
        timeZone: zone
    ))
    XCTAssertNil(ReminderTimeValidator.accept("tomorrow morning", nowMs: nowMs, timeZone: zone))
}
}
```

```swift
// Add to Tests/MaxMiActivityTests/HourlyAgentTests.swift

func testValidRemindAtReachesRepositoryAsAcceptedReminder() async {
    let repo = ReminderCapturingAgentRepository()
    let relay = ReminderCapturingAgentRelay(ops: [
        AgentOpDTO(
            op: "create",
            id: nil,
            kind: "todo",
            title: "Send report",
            details: nil,
            evidence: nil,
            sourceRefs: ["v1"],
            remindAt: "2026-09-22T12:30:00Z"
        ),
    ])
    await repo.setPage(leasedPage(runID: "reminder-run", versions: [reviewVersion(versionID: "v1")]))

    await HourlyAgent(
        repo: repo,
        relay: relay,
        clock: { 1_790_000_000_000 },
        timeZone: TimeZone(secondsFromGMT: 0)!
    ).runIfDue()

    let completed = await repo.completedOps()
    guard case .create(_, _, _, _, .set(let remindAtMs)) = try XCTUnwrap(completed.first?.first) else {
        return XCTFail("Expected a create operation with an accepted reminder.")
    }
    XCTAssertEqual(remindAtMs, 1_790_080_200_000)
}

func testInvalidRemindAtDropsOnlyReminderAndKeepsCreateOperation() async {
    let repo = ReminderCapturingAgentRepository()
    let relay = ReminderCapturingAgentRelay(ops: [
        AgentOpDTO(
            op: "create",
            id: nil,
            kind: "todo",
            title: "Keep the task",
            details: "The date text is malformed.",
            evidence: nil,
            sourceRefs: ["v1"],
            remindAt: "not-a-date"
        ),
    ])
    await repo.setPage(leasedPage(runID: "invalid-reminder-run", versions: [reviewVersion(versionID: "v1")]))

    await HourlyAgent(
        repo: repo,
        relay: relay,
        clock: { 1_790_000_000_000 },
        timeZone: TimeZone(secondsFromGMT: 0)!
    ).runIfDue()

    let completed = await repo.completedOps()
    guard case .create(let kind, let title, let details, let sourceRefs, let reminder)
        = try XCTUnwrap(completed.first?.first) else {
        return XCTFail("Expected the invalid reminder to leave the create operation intact.")
    }
    XCTAssertEqual(kind, "todo")
    XCTAssertEqual(title, "Keep the task")
    XCTAssertEqual(details, "The date text is malformed.")
    XCTAssertEqual(sourceRefs, ["v1"])
    XCTAssertEqual(reminder, .unchanged)
}
```

```swift
// Add to Tests/MaxMiActivityTests/AgentPromptsTests.swift
func testHourlyPromptAllowsRemindAtOnlyForConcreteEvidence() {
    let prompt = AgentPrompts.hourlyReview(input: AgentReviewInput(
        runID: "reminder-prompt",
        versions: [],
        timelineText: "",
        openItems: [],
        localTimeISO: "2026-09-22T10:00:00+05:30",
        timeRange: (0, 0)
    ))

    XCTAssertTrue(prompt.contains("\"remind_at\":\"2026-09-22T12:30:00+05:30\""))
    XCTAssertTrue(prompt.contains("concrete time or deadline"))
    XCTAssertTrue(prompt.contains("otherwise omit it"))
}
```

```swift
// Add to Tests/MaxMiStoreTests/AgentStoreTests.swift
func testAgentCreateAndUpdateApplyAcceptedReminderUsingStoreSetReminderPath() throws {
    let versionID = try seedVersion(sourceKey: "cursor:reminder", content: "Deadline is today at 15:00.")
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
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter ReminderTimeValidatorTests
swift test --filter HourlyAgentTests
swift test --filter AgentPromptsTests
swift test --filter AgentStoreTests
```

Expected: FAIL because `ReminderTimeValidator`, `remind_at`, `ReminderChange`, `ValidatedAgentOp`, and reminder-aware agent persistence do not exist.

- [ ] **Step 3: Move operation validation into `MaxMiActivity` and apply accepted reminders in Store**

```swift
// Sources/MaxMiActivity/ReminderTimeValidator.swift
import Foundation
import MaxMiCore

public enum ReminderTimeValidator {
    public static let maximumFutureMs: EpochMs = 48 * 60 * 60 * 1_000

    public static func accept(
        _ value: String?,
        nowMs: EpochMs,
        timeZone: TimeZone
    ) -> EpochMs? {
        guard let value else {
            return nil
        }
        guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            logRejected()
            return nil
        }

        let date = parse(value, timeZone: timeZone)
        guard let date else {
            logRejected()
            return nil
        }

        let acceptedMs = EpochMs(date.timeIntervalSince1970 * 1_000)
        guard acceptedMs > nowMs, acceptedMs <= nowMs + maximumFutureMs else {
            logRejected()
            return nil
        }
        return acceptedMs
    }

    private static func parse(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withColonSeparatorInTimeZone,
        ]
        return formatter.date(from: value)
    }

    private static func logRejected() {
        SafeLogger.shared.log(
            .debug,
            subsystem: .agent,
            event: .agentRunFailed,
            fields: SafeLogFields(operation: SafeLogToken(validating: "remind_at_rejected"))
        )
    }
}
```

```swift
// Replace AgentOpDTO, AgentRepository, and add the validator in Sources/MaxMiActivity/HourlyAgent.swift
public struct AgentOpDTO: Sendable, Codable {
    public let op: String
    public let id: String?
    public let kind: String?
    public let title: String?
    public let details: String?
    public let evidence: String?
    public let sourceRefs: [String]?
    public let remindAt: String?

    private enum CodingKeys: String, CodingKey {
        case op, id, kind, title, details, evidence, sourceRefs
        case remindAt = "remind_at"
    }

    public init(
        op: String,
        id: String?,
        kind: String?,
        title: String?,
        details: String?,
        evidence: String?,
        sourceRefs: [String]?,
        remindAt: String? = nil
    ) {
        self.op = op
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.evidence = evidence
        self.sourceRefs = sourceRefs
        self.remindAt = remindAt
    }
}

public enum ReminderChange: Sendable, Equatable {
    case unchanged
    case set(EpochMs)
}

public enum ValidatedAgentOp: Sendable {
    case create(
        kind: String,
        title: String,
        details: String?,
        sourceRefs: [String],
        reminder: ReminderChange
    )
    case update(
        id: String,
        title: String?,
        details: String?,
        reminder: ReminderChange
    )
    case resolve(id: String, evidence: String)
}

public enum AgentOperationValidator {
    public static func validateAndMap(
        _ dtos: [AgentOpDTO],
        nowMs: EpochMs,
        timeZone: TimeZone
    ) throws -> [ValidatedAgentOp] {
        try dtos.map { dto in
            let reminder: ReminderChange
            if let rawReminder = dto.remindAt,
               let accepted = ReminderTimeValidator.accept(
                   rawReminder,
                   nowMs: nowMs,
                   timeZone: timeZone
               ) {
                reminder = .set(accepted)
            } else {
                reminder = .unchanged
            }

            switch dto.op {
            case "create":
                guard let kind = dto.kind, !kind.isEmpty else {
                    throw ValidationError.missingField("create op requires non-empty 'kind'")
                }
                guard let title = dto.title, !title.isEmpty else {
                    throw ValidationError.missingField("create op requires non-empty 'title'")
                }
                guard title.count <= 500 else {
                    throw ValidationError.fieldTooLong("title exceeds 500 chars")
                }
                let details = dto.details.flatMap { $0.isEmpty ? nil : $0 }
                if let details, details.count > 2_000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }
                return .create(
                    kind: kind,
                    title: title,
                    details: details,
                    sourceRefs: dto.sourceRefs ?? [],
                    reminder: reminder
                )

            case "update":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("update op requires non-empty 'id'")
                }
                let title = dto.title.flatMap { $0.isEmpty ? nil : $0 }
                let details = dto.details.flatMap { $0.isEmpty ? nil : $0 }
                if let title, title.count > 500 {
                    throw ValidationError.fieldTooLong("title exceeds 500 chars")
                }
                if let details, details.count > 2_000 {
                    throw ValidationError.fieldTooLong("details exceeds 2000 chars")
                }
                guard title != nil || details != nil || reminder != .unchanged else {
                    throw ValidationError.missingField(
                        "update op requires title, details, or an accepted remind_at"
                    )
                }
                return .update(id: id, title: title, details: details, reminder: reminder)

            case "resolve":
                guard let id = dto.id, !id.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'id'")
                }
                guard let evidence = dto.evidence, !evidence.isEmpty else {
                    throw ValidationError.missingField("resolve op requires non-empty 'evidence'")
                }
                guard evidence.count <= 2_000 else {
                    throw ValidationError.fieldTooLong("evidence exceeds 2000 chars")
                }
                return .resolve(id: id, evidence: evidence)

            default:
                throw ValidationError.unknownOp("unknown op type: '\(dto.op)'")
            }
        }
    }

    public enum ValidationError: Error, LocalizedError {
        case unknownOp(String)
        case missingField(String)
        case fieldTooLong(String)

        public var errorDescription: String? {
            switch self {
            case .unknownOp(let message), .missingField(let message), .fieldTooLong(let message):
                return message
            }
        }
    }
}

public protocol AgentRepository: Sendable {
    func claimNextPage() async -> AgentLeasedPage?
    func complete(runID: String, ops: [ValidatedAgentOp]) async throws
    func fail(runID: String, error: String) async
    func renew(runID: String) async
}
```

Add `clock` and `timeZone` to `HourlyAgent` and validate the relay response before `repo.complete`:

```swift
private let clock: @Sendable () -> EpochMs
private let timeZone: TimeZone

public init(
    repo: any AgentRepository,
    relay: any AgentGenerationRelay,
    maxPagesPerTick: Int = 4,
    renewalSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    clock: @escaping @Sendable () -> EpochMs = epochNowMs,
    timeZone: TimeZone = .current
) {
    self.repo = repo
    self.relay = relay
    self.maxPagesPerTick = maxPagesPerTick
    self.renewalSleep = renewalSleep
    self.clock = clock
    self.timeZone = timeZone
}

let rawOps = try await relay.reviewActivity(input)
let validatedOps = try AgentOperationValidator.validateAndMap(
    rawOps,
    nowMs: clock(),
    timeZone: timeZone
)
try await repo.complete(runID: page.runID, ops: validatedOps)
```

Update the existing fake repository and its assertions in `Tests/MaxMiActivityTests/HourlyAgentTests.swift` to consume the new protocol rather than leaking raw JSON DTOs:

```swift
actor MockAgentRepo: AgentRepository {
    private var claimedPages: [AgentLeasedPage?] = []
    private var completeCalls: [(runID: String, ops: [ValidatedAgentOp])] = []
    private var failCalls: [(runID: String, error: String)] = []
    private var currentPageIndex = 0

    func setPages(_ pages: [AgentLeasedPage?]) {
        claimedPages = pages
        currentPageIndex = 0
    }

    func getCompleteCalls() -> [(runID: String, ops: [ValidatedAgentOp])] {
        completeCalls
    }

    func getFailCalls() -> [(runID: String, error: String)] {
        failCalls
    }

    func claimNextPage() async -> AgentLeasedPage? {
        guard currentPageIndex < claimedPages.count else { return nil }
        let page = claimedPages[currentPageIndex]
        currentPageIndex += 1
        return page
    }

    func complete(runID: String, ops: [ValidatedAgentOp]) async throws {
        completeCalls.append((runID, ops))
    }

    func fail(runID: String, error: String) async {
        failCalls.append((runID, error))
    }

    func renew(runID: String) async {}
}

// In testClaimPageCallsRelayAndCompletes:
guard case .create(let kind, let title, _, let sourceRefs, .unchanged)
    = try XCTUnwrap(completeCalls.first?.ops.first) else {
    return XCTFail("Expected the relay create operation to be validated.")
}
XCTAssertEqual(kind, "todo")
XCTAssertEqual(title, "New task")
XCTAssertEqual(sourceRefs, ["v1"])
guard case .resolve(let id, let evidence) = try XCTUnwrap(completeCalls.first?.ops.last) else {
    return XCTFail("Expected the relay resolve operation to be validated.")
}
XCTAssertEqual(id, "item1")
XCTAssertEqual(evidence, "done")
```

Change the `complete` method in `FailingTimelineAgentRepository` to the same `[ValidatedAgentOp]` signature. Keep `MockAgentRelay` and `ReminderCapturingAgentRelay` returning raw `[AgentOpDTO]`, because only `HourlyAgent` is allowed to validate relay JSON.

```swift
// Sources/MaxMiActivity/AgentPrompts.swift: replace only the operation section.
Operation types (return a JSON array of these):
- create: {"op":"create","kind":"todo","title":"Send the draft","details":"Email the final version","sourceRefs":["version_id"],"remind_at":"2026-09-22T12:30:00+05:30"}
- update: {"op":"update","id":"item_id","title":"Send the revised draft","details":"The deadline moved","remind_at":"2026-09-22T12:30:00+05:30"}
- resolve: {"op":"resolve","id":"item_id","evidence":"explicit evidence from the versions or timeline"}

Set `remind_at` only when the evidence states a concrete time or deadline for the item; otherwise omit it.
```

Keep every existing prompt instruction, fence, payload shape, and source-ref rule byte-for-byte outside that one additive reminder instruction and the two illustrative JSON fields.

```swift
// Sources/MaxMi/StoreAgentRepository.swift
func complete(runID: String, ops: [ValidatedAgentOp]) async throws {
    _ = try store.completeAgentRun(runID: runID, ops: ops, nowMs: epochNowMs())
}
```

Replace `AgentOp` with `ValidatedAgentOp` in `Sources/MaxMiStore/AgentStore.swift`. Preserve existing create/update/resolve validation at the Store boundary (open-only updates, source refs restricted to the rebuilt claimed page, idempotency, and event records), and add these reminder branches inside the existing write transaction:

```swift
case .create(let kind, let title, let details, let sourceRefs, let reminder):
    // Keep the existing item insertion, encrypted fields, idempotency check, and event creation.
    if database.changesCount > 0, case .set(let remindAtMs) = reminder {
        try setReminder(database, id: itemID, remindAtMs: remindAtMs, nowMs: nowMs)
    }

case .update(let id, let title, let details, let reminder):
    // Keep the existing open-status guard and title/details update construction.
    if case .set(let remindAtMs) = reminder {
        try setReminder(database, id: id, remindAtMs: remindAtMs, nowMs: nowMs)
    }
```

When a reminder-only update has `title == nil` and `details == nil`, skip the dynamic title/details SQL but still run the open-status guard, `setReminder`, and an `"updated"` action-item event. This is the exact path by which a valid `remind_at` reaches Task 2’s Store API. Do not edit `Tests/MaxMiTests/StoreAgentRepositoryTests.swift` or create an executable test target; its target is absent from `Package.swift`, and the moved validation is covered in `MaxMiActivityTests`.

Update every existing `Tests/MaxMiStoreTests/AgentStoreTests.swift` operation literal so it compiles against the Activity-owned enum:

```swift
// Existing create operations become:
.create(
    kind: "todo",
    title: "Review embedding",
    details: nil,
    sourceRefs: [versionID],
    reminder: .unchanged
)

// Existing title/details updates become:
.update(
    id: itemID,
    title: "Updated title",
    details: nil,
    reminder: .unchanged
)
```

Apply the same explicit `reminder: .unchanged` argument to all other existing `.create` and `.update` fixtures in that file. Existing `.resolve` fixtures remain `.resolve(id:evidence:)`.

Add these fake types to `Tests/MaxMiActivityTests/HourlyAgentTests.swift` so the tests above use only Activity contracts:

```swift
private actor ReminderCapturingAgentRepository: AgentRepository {
    private var page: AgentLeasedPage?
    private var didClaim = false
    private var completed: [[ValidatedAgentOp]] = []

    func setPage(_ page: AgentLeasedPage) {
        self.page = page
        didClaim = false
    }

    func claimNextPage() async -> AgentLeasedPage? {
        guard !didClaim else { return nil }
        didClaim = true
        return page
    }

    func complete(runID: String, ops: [ValidatedAgentOp]) async throws {
        _ = runID
        completed.append(ops)
    }

    func fail(runID: String, error: String) async {
        _ = runID
        _ = error
    }

    func renew(runID: String) async {
        _ = runID
    }

    func completedOps() -> [[ValidatedAgentOp]] {
        completed
    }
}

private actor ReminderCapturingAgentRelay: AgentGenerationRelay {
    private let ops: [AgentOpDTO]

    init(ops: [AgentOpDTO]) {
        self.ops = ops
    }

    func reviewActivity(_ input: AgentReviewInput) async throws -> [AgentOpDTO] {
        _ = input
        return ops
    }
}
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter ReminderTimeValidatorTests
swift test --filter HourlyAgentTests
swift test --filter AgentPromptsTests
swift test --filter AgentStoreTests
```

Expected: PASS. The valid value becomes a fixed epoch timestamp, malformed and out-of-window values retain the action item with `.unchanged`, and the prompt golden verifies no unrelated prompt rewrite.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiActivity/ReminderTimeValidator.swift Sources/MaxMiActivity/HourlyAgent.swift Sources/MaxMiActivity/AgentPrompts.swift Sources/MaxMiStore/AgentStore.swift Sources/MaxMi/StoreAgentRepository.swift Tests/MaxMiActivityTests/ReminderTimeValidatorTests.swift Tests/MaxMiActivityTests/HourlyAgentTests.swift Tests/MaxMiActivityTests/AgentPromptsTests.swift Tests/MaxMiStoreTests/AgentStoreTests.swift
git commit -m "Add hourly review reminders"
```

### Task 4: Add the consent-gated `ReminderScheduler` actor

**Files:**

- Create: `Sources/MaxMiActivity/ReminderScheduler.swift`
- Create: `Tests/MaxMiActivityTests/ReminderSchedulerTests.swift`

**Interfaces:**

- Consumes: Task 2’s reminder semantics through this Activity-owned abstraction:

```swift
public struct ReminderItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let sourceApp: String?
    public let detectedAtMs: EpochMs

    public init(id: String, title: String, sourceApp: String?, detectedAtMs: EpochMs)
}
```

- Produces:

```swift
public protocol ReminderRepository: Sendable {
    func dueReminders(nowMs: EpochMs) async -> [ReminderItem]
    func markReminded(_ id: String, nowMs: EpochMs) async
}

public protocol ReminderNotifier: Sendable {
    func post(id: String, title: String, body: String) async
}

public actor ReminderScheduler {
    public init(
        repository: any ReminderRepository,
        notifier: any ReminderNotifier,
        isActivitySynthesisEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> EpochMs = epochNowMs
    )

    public func tick() async
    public func tick(nowMs: EpochMs) async
}
```

- Task 7 implements both protocols. Task 8 constructs the scheduler and calls `tick(nowMs:)` immediately after `checkinTrigger.tick(nowMs:)`.

- [ ] **Step 1: Write failing fixed-clock scheduler tests**

```swift
// Tests/MaxMiActivityTests/ReminderSchedulerTests.swift
import XCTest
@testable import MaxMiActivity
import MaxMiCore

private actor ReminderSchedulerState {
    private var due: [ReminderItem] = []
    private var posted: [(String, String, String)] = []
    private var marked: [(String, EpochMs)] = []
    private var dueLookupCount = 0
    private var blocksDueLookup = false
    private var didStartLookup = false
    private var lookupStarted: CheckedContinuation<Void, Never>?
    private var lookupRelease: CheckedContinuation<Void, Never>?

    func setDue(_ items: [ReminderItem]) {
        due = items
    }

    func readDue(nowMs: EpochMs) async -> [ReminderItem] {
        _ = nowMs
        dueLookupCount += 1
        didStartLookup = true
        lookupStarted?.resume()
        lookupStarted = nil
        if blocksDueLookup {
            await withCheckedContinuation { lookupRelease = $0 }
        }
        let current = due
        due = []
        return current
    }

    func mark(id: String, nowMs: EpochMs) {
        marked.append((id, nowMs))
    }

    func post(id: String, title: String, body: String) {
        posted.append((id, title, body))
    }

    func setBlocksDueLookup(_ value: Bool) {
        blocksDueLookup = value
    }

    func waitForLookupStart() async {
        if didStartLookup {
            return
        }
        await withCheckedContinuation { lookupStarted = $0 }
    }

    func releaseLookup() {
        lookupRelease?.resume()
        lookupRelease = nil
    }

    func posts() -> [(String, String, String)] {
        posted
    }

    func marks() -> [(String, EpochMs)] {
        marked
    }

    func dueLookups() -> Int {
        dueLookupCount
    }
}

private struct ReminderSchedulerRepositoryFake: ReminderRepository {
    let state: ReminderSchedulerState

    func dueReminders(nowMs: EpochMs) async -> [ReminderItem] {
        await state.readDue(nowMs: nowMs)
    }

    func markReminded(_ id: String, nowMs: EpochMs) async {
        await state.mark(id: id, nowMs: nowMs)
    }
}

private struct ReminderSchedulerNotifierFake: ReminderNotifier {
    let state: ReminderSchedulerState

    func post(id: String, title: String, body: String) async {
        await state.post(id: id, title: title, body: body)
    }
}

final class ReminderSchedulerTests: XCTestCase {
    func testTickPostsOnceAndMarksReminderThenSecondTickDoesNothing() async {
        let state = ReminderSchedulerState()
        let nowMs: EpochMs = 1_800_000_000_000
        await state.setDue([
            ReminderItem(id: "r1", title: "Send report", sourceApp: "Mail", detectedAtMs: nowMs - 3 * 3_600_000),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { true },
            clock: { nowMs }
        )

        await scheduler.tick()
        await scheduler.tick()

        let posts = await state.posts()
        let marks = await state.marks()
        XCTAssertEqual(posts.map(\.0), ["r1"])
        XCTAssertEqual(posts.first?.1, "Send report")
        XCTAssertEqual(posts.first?.2, "Mail · 3h")
        XCTAssertEqual(marks.map(\.0), ["r1"])
        XCTAssertEqual(marks.map(\.1), [nowMs])
    }

    func testDeniedNotifierStillMarksReminder() async {
        let state = ReminderSchedulerState()
        let nowMs: EpochMs = 1_800_000_000_000
        await state.setDue([
            ReminderItem(id: "denied", title: "Review plan", sourceApp: nil, detectedAtMs: nowMs - 2 * 86_400_000),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: DeniedReminderNotifier(),
            isActivitySynthesisEnabled: { true },
            clock: { nowMs }
        )

        await scheduler.tick()

        let marks = await state.marks()
        XCTAssertEqual(marks.map(\.0), ["denied"])
        XCTAssertEqual(marks.map(\.1), [nowMs])
    }

    func testDisabledSynthesisDoesNoRepositoryOrNotifierWork() async {
        let state = ReminderSchedulerState()
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { false },
            clock: { 1 }
        )

        await scheduler.tick()

        let posts = await state.posts()
        let marks = await state.marks()
        let dueLookups = await state.dueLookups()
        XCTAssertTrue(posts.isEmpty)
        XCTAssertTrue(marks.isEmpty)
        XCTAssertEqual(dueLookups, 0)
    }

    func testInFlightGuardRejectsConcurrentTicks() async {
        let state = ReminderSchedulerState()
        await state.setBlocksDueLookup(true)
        await state.setDue([
            ReminderItem(id: "one", title: "One", sourceApp: "MaxMi", detectedAtMs: 0),
        ])
        let scheduler = ReminderScheduler(
            repository: ReminderSchedulerRepositoryFake(state: state),
            notifier: ReminderSchedulerNotifierFake(state: state),
            isActivitySynthesisEnabled: { true },
            clock: { 10 }
        )

        async let first: Void = scheduler.tick()
        await state.waitForLookupStart()
        async let second: Void = scheduler.tick()
        await Task.yield()
        await state.releaseLookup()
        await first
        await second

        let posts = await state.posts()
        XCTAssertEqual(posts.map(\.0), ["one"])
    }
}

private struct DeniedReminderNotifier: ReminderNotifier {
    func post(id: String, title: String, body: String) async {
        _ = id
        _ = title
        _ = body
    }
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter ReminderSchedulerTests
```

Expected: FAIL because the reminder protocols and `ReminderScheduler` do not exist.

- [ ] **Step 3: Implement the scheduler actor**

```swift
// Sources/MaxMiActivity/ReminderScheduler.swift
import MaxMiCore

public struct ReminderItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let sourceApp: String?
    public let detectedAtMs: EpochMs

    public init(id: String, title: String, sourceApp: String?, detectedAtMs: EpochMs) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.detectedAtMs = detectedAtMs
    }
}

public protocol ReminderRepository: Sendable {
    func dueReminders(nowMs: EpochMs) async -> [ReminderItem]
    func markReminded(_ id: String, nowMs: EpochMs) async
}

public protocol ReminderNotifier: Sendable {
    func post(id: String, title: String, body: String) async
}

public actor ReminderScheduler {
    private let repository: any ReminderRepository
    private let notifier: any ReminderNotifier
    private let isActivitySynthesisEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> EpochMs
    private var inFlight = false

    public init(
        repository: any ReminderRepository,
        notifier: any ReminderNotifier,
        isActivitySynthesisEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> EpochMs = epochNowMs
    ) {
        self.repository = repository
        self.notifier = notifier
        self.isActivitySynthesisEnabled = isActivitySynthesisEnabled
        self.clock = clock
    }

    public func tick() async {
        await tick(nowMs: clock())
    }

    public func tick(nowMs: EpochMs) async {
        guard isActivitySynthesisEnabled(), !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        for item in await repository.dueReminders(nowMs: nowMs) {
            await notifier.post(
                id: item.id,
                title: item.title,
                body: "\(item.sourceApp ?? "MaxMi") · \(Self.ageDescription(
                    detectedAtMs: item.detectedAtMs,
                    nowMs: nowMs
                ))"
            )
            await repository.markReminded(item.id, nowMs: nowMs)
        }
    }

    private static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let elapsedMs = max(0, nowMs - detectedAtMs)
        let elapsedHours = elapsedMs / 3_600_000
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }
        return "\(elapsedHours / 24)d"
    }
}
```

The Store performs the 24-hour expiry mark before it returns due work, so this actor only posts current due items and always marks each returned item after the notifier call, even when the notifier denied permission and did nothing.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter ReminderSchedulerTests
```

Expected: PASS. The fixed clock makes the notification body deterministic, and the continuation-backed test proves no second concurrent lookup begins.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiActivity/ReminderScheduler.swift Tests/MaxMiActivityTests/ReminderSchedulerTests.swift
git commit -m "Add reminder scheduler"
```

### Task 5: Add `TodoPanelItem`, repository protocol, and view model

**Files:**

- Create: `Sources/MaxMiUI/TodoPanelDTO.swift`
- Create: `Sources/MaxMiUI/TodoPanelViewModel.swift`
- Create: `Tests/MaxMiUITests/TodoPanelViewModelTests.swift`

**Interfaces:**

- Consumes: `EpochMs`, `Observation`, and `@MainActor`; no Store type or module.
- Produces:

```swift
public struct TodoPanelItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let detectedAtMs: EpochMs
    public let remindAtMs: EpochMs?
    public let remindedAtMs: EpochMs?
}

public protocol TodoPanelRepository: Sendable {
    func openItems(limit: Int) async -> [TodoPanelItem]
    func todayCheckinFirstLine(nowMs: EpochMs) async -> String?
    func markDone(id: String, nowMs: EpochMs) async
    func dismiss(id: String, nowMs: EpochMs) async
}

@MainActor
@Observable
public final class TodoPanelViewModel {
    public static let openItemLimit = 25

    public private(set) var items: [TodoPanelItem]
    public private(set) var checkinFirstLine: String?
    public private(set) var selectedIndex: Int?

    public init(
        repository: any TodoPanelRepository,
        now: @escaping @Sendable () -> EpochMs
    )

    public func refresh() async
    public func select(index: Int)
    public func moveSelection(by offset: Int)
    public func markSelectedDone() async
    public func dismissSelected() async
}
```

- Task 6 renders these public properties and calls the four public commands. Task 7 provides `StoreTodoPanelRepository`.

- [ ] **Step 1: Write fake-backed view-model tests**

```swift
// Tests/MaxMiUITests/TodoPanelViewModelTests.swift
import XCTest
@testable import MaxMiUI
import MaxMiCore

private actor TodoPanelRepositoryState {
    private var items: [TodoPanelItem]
    private var doneIDs: [String] = []
    private var dismissedIDs: [String] = []
    private let checkinLine: String?

    init(items: [TodoPanelItem], checkinLine: String?) {
        self.items = items
        self.checkinLine = checkinLine
    }

    func openItems() -> [TodoPanelItem] {
        items
    }

    func checkin() -> String? {
        checkinLine
    }

    func markDone(_ id: String) {
        doneIDs.append(id)
        items.removeAll { $0.id == id }
    }

    func dismiss(_ id: String) {
        dismissedIDs.append(id)
        items.removeAll { $0.id == id }
    }

    func reads() -> (done: [String], dismissed: [String]) {
        (doneIDs, dismissedIDs)
    }
}

private struct TodoPanelRepositoryFake: TodoPanelRepository {
    let state: TodoPanelRepositoryState

    func openItems(limit: Int) async -> [TodoPanelItem] {
        Array((await state.openItems()).prefix(limit))
    }

    func todayCheckinFirstLine(nowMs: EpochMs) async -> String? {
        _ = nowMs
        return await state.checkin()
    }

    func markDone(id: String, nowMs: EpochMs) async {
        _ = nowMs
        await state.markDone(id)
    }

    func dismiss(id: String, nowMs: EpochMs) async {
        _ = nowMs
        await state.dismiss(id)
    }
}

@MainActor
final class TodoPanelViewModelTests: XCTestCase {
    func testRefreshOrdersNewestFirstAndCapsAtTwentyFive() async {
        let items = (0..<30).map { offset in
            TodoPanelItem(
                id: "item-\(offset)",
                title: "Item \(offset)",
                details: nil,
                sourceApp: "Fixture",
                detectedAtMs: EpochMs(offset),
                remindAtMs: nil,
                remindedAtMs: nil
            )
        }
        let state = TodoPanelRepositoryState(items: items.shuffled(), checkinLine: nil)
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 10_000 }
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.items.count, TodoPanelViewModel.openItemLimit)
        XCTAssertEqual(viewModel.items.map(\.id), (5..<30).reversed().map { "item-\($0)" })
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testDoneAndDismissCallRepositoryAndRemoveRows() async {
        let state = TodoPanelRepositoryState(
            items: [
                item(id: "first", detectedAtMs: 2),
                item(id: "second", detectedAtMs: 1),
            ],
            checkinLine: nil
        )
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 100 }
        )
        await viewModel.refresh()

        await viewModel.markSelectedDone()
        viewModel.moveSelection(by: 1)
        await viewModel.dismissSelected()

        let calls = await state.reads()
        XCTAssertEqual(calls.done, ["first"])
        XCTAssertEqual(calls.dismissed, ["second"])
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.selectedIndex)
    }

    func testKeyboardSelectionWrapsInBothDirections() async {
        let state = TodoPanelRepositoryState(
            items: [item(id: "one", detectedAtMs: 3), item(id: "two", detectedAtMs: 2), item(id: "three", detectedAtMs: 1)],
            checkinLine: nil
        )
        let viewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: state),
            now: { 1 }
        )
        await viewModel.refresh()

        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testRefreshExposesEmptyStateAndCheckinHeaderLine() async {
        let emptyState = TodoPanelRepositoryState(items: [], checkinLine: "You reviewed the release plan.")
        let emptyViewModel = TodoPanelViewModel(
            repository: TodoPanelRepositoryFake(state: emptyState),
            now: { 50 }
        )
        await emptyViewModel.refresh()

        XCTAssertTrue(emptyViewModel.items.isEmpty)
        XCTAssertNil(emptyViewModel.selectedIndex)
        XCTAssertEqual(emptyViewModel.checkinFirstLine, "You reviewed the release plan.")
    }

    private func item(id: String, detectedAtMs: EpochMs) -> TodoPanelItem {
        TodoPanelItem(
            id: id,
            title: id,
            details: nil,
            sourceApp: "Fixture",
            detectedAtMs: detectedAtMs,
            remindAtMs: nil,
            remindedAtMs: nil
        )
    }
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter TodoPanelViewModelTests
```

Expected: FAIL because `TodoPanelItem`, `TodoPanelRepository`, and `TodoPanelViewModel` do not exist.

- [ ] **Step 3: Implement the portable panel DTO and view model**

```swift
// Sources/MaxMiUI/TodoPanelDTO.swift
import MaxMiCore

public struct TodoPanelItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let detectedAtMs: EpochMs
    public let remindAtMs: EpochMs?
    public let remindedAtMs: EpochMs?

    public init(
        id: String,
        title: String,
        details: String?,
        sourceApp: String?,
        detectedAtMs: EpochMs,
        remindAtMs: EpochMs?,
        remindedAtMs: EpochMs?
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.sourceApp = sourceApp
        self.detectedAtMs = detectedAtMs
        self.remindAtMs = remindAtMs
        self.remindedAtMs = remindedAtMs
    }
}

public protocol TodoPanelRepository: Sendable {
    func openItems(limit: Int) async -> [TodoPanelItem]
    func todayCheckinFirstLine(nowMs: EpochMs) async -> String?
    func markDone(id: String, nowMs: EpochMs) async
    func dismiss(id: String, nowMs: EpochMs) async
}
```

```swift
// Sources/MaxMiUI/TodoPanelViewModel.swift
import MaxMiCore
import Observation

@MainActor
@Observable
public final class TodoPanelViewModel {
    public static let openItemLimit = 25

    public private(set) var items: [TodoPanelItem] = []
    public private(set) var checkinFirstLine: String?
    public private(set) var selectedIndex: Int?

    private let repository: any TodoPanelRepository
    private let now: @Sendable () -> EpochMs

    public init(
        repository: any TodoPanelRepository,
        now: @escaping @Sendable () -> EpochMs
    ) {
        self.repository = repository
        self.now = now
    }

    public func refresh() async {
        async let loadedItems = repository.openItems(limit: Self.openItemLimit)
        async let headerLine = repository.todayCheckinFirstLine(nowMs: now())
        let ordered = await loadedItems.sorted {
            $0.detectedAtMs == $1.detectedAtMs ? $0.id > $1.id : $0.detectedAtMs > $1.detectedAtMs
        }
        items = Array(ordered.prefix(Self.openItemLimit))
        checkinFirstLine = await headerLine
        selectedIndex = items.isEmpty ? nil : 0
    }

    public func moveSelection(by offset: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex ?? 0
        selectedIndex = (current + offset % items.count + items.count) % items.count
    }

    public func select(index: Int) {
        selectedIndex = items.indices.contains(index) ? index : selectedIndex
    }

    public func markSelectedDone() async {
        guard let id = selectedItemID() else { return }
        await repository.markDone(id: id, nowMs: now())
        removeSelectedItem(id: id)
    }

    public func dismissSelected() async {
        guard let id = selectedItemID() else { return }
        await repository.dismiss(id: id, nowMs: now())
        removeSelectedItem(id: id)
    }

    private func selectedItemID() -> String? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return }
        return items[selectedIndex].id
    }

    private func removeSelectedItem(id: String) {
        guard let selectedIndex else { return }
        items.removeAll { $0.id == id }
        if items.isEmpty {
            self.selectedIndex = nil
        } else {
            self.selectedIndex = min(selectedIndex, items.count - 1)
        }
    }
}
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter TodoPanelViewModelTests
```

Expected: PASS. The fake records action calls after every `await` has completed, so no XCTest assertion evaluates an asynchronous expression.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiUI/TodoPanelDTO.swift Sources/MaxMiUI/TodoPanelViewModel.swift Tests/MaxMiUITests/TodoPanelViewModelTests.swift
git commit -m "Add todo panel view model"
```

### Task 6: Render the always-dark `TodoPanelView`

**Files:**

- Create: `Sources/MaxMiUI/TodoPanelView.swift`
- Modify: `Tests/MaxMiUITests/TodoPanelViewModelTests.swift`

**Interfaces:**

- Consumes: Task 5’s `TodoPanelItem`, `TodoPanelViewModel`, `TodoPanelViewModel.openItemLimit`, `Theme`, and `EpochMs`.
- Produces:

```swift
public enum TodoPanelRowState {
    public static func showsPendingReminder(for item: TodoPanelItem) -> Bool
    public static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String
}

public struct TodoPanelView: View {
    public init(
        viewModel: TodoPanelViewModel,
        onClose: @escaping @MainActor () -> Void
    )
}
```

- Task 8 creates `TodoPanelView(viewModel:onClose:)` inside an `NSHostingView`. The view calls `moveSelection(by:)`, `markSelectedDone()`, `dismissSelected()`, and `onClose()` only; it owns no persistence.

- [ ] **Step 1: Add a view-model-driven rendering-state test**

```swift
// Add to Tests/MaxMiUITests/TodoPanelViewModelTests.swift
func testRowRenderingStateShowsOnlyUnremindedClockAndFormatsAge() {
    let pending = TodoPanelItem(
        id: "reminder",
        title: "Prepare the customer migration proposal before the review meeting",
        details: "The row must render this as a title, not notification body content.",
        sourceApp: "Mail",
        detectedAtMs: 1_789_996_400_000,
        remindAtMs: 1_790_000_000_000,
        remindedAtMs: nil
    )
    let delivered = TodoPanelItem(
        id: "delivered",
        title: "A reminder already delivered",
        details: nil,
        sourceApp: "Mail",
        detectedAtMs: 1_789_827_200_000,
        remindAtMs: 1_789_900_000_000,
        remindedAtMs: 1_789_900_000_000
    )

    XCTAssertTrue(TodoPanelRowState.showsPendingReminder(for: pending))
    XCTAssertFalse(TodoPanelRowState.showsPendingReminder(for: delivered))
    XCTAssertEqual(
        TodoPanelRowState.ageDescription(
            detectedAtMs: pending.detectedAtMs,
            nowMs: 1_790_007_200_000
        ),
        "3h"
    )
    XCTAssertEqual(
        TodoPanelRowState.ageDescription(
            detectedAtMs: delivered.detectedAtMs,
            nowMs: 1_790_000_000_000
        ),
        "2d"
    )
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
swift test --filter TodoPanelViewModelTests/testRowRenderingStateShowsOnlyUnremindedClockAndFormatsAge
```

Expected: FAIL because `TodoPanelRowState` does not exist. Do not add snapshot tests or an executable test target.

- [ ] **Step 3: Implement the dark SwiftUI panel**

```swift
// Sources/MaxMiUI/TodoPanelView.swift
import SwiftUI
import MaxMiCore

public enum TodoPanelRowState {
    public static func showsPendingReminder(for item: TodoPanelItem) -> Bool {
        item.remindAtMs != nil && item.remindedAtMs == nil
    }

    public static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let elapsedHours = max(0, nowMs - detectedAtMs) / 3_600_000
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }
        return "\(elapsedHours / 24)d"
    }
}

public struct TodoPanelView: View {
    @Bindable private var viewModel: TodoPanelViewModel
    private let onClose: @MainActor () -> Void

    public init(
        viewModel: TodoPanelViewModel,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            header
            if viewModel.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            row(item: item, index: index)
                        }
                    }
                }
            }
        }
        .padding(Theme.spacing2)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onMoveCommand { direction in
            switch direction {
            case .up:
                viewModel.moveSelection(by: -1)
            case .down:
                viewModel.moveSelection(by: 1)
            default:
                break
            }
        }
        .onKeyPress(.return) {
            Task { await viewModel.markSelectedDone() }
            return .handled
        }
        .onKeyPress(.delete) {
            Task { await viewModel.dismissSelected() }
            return .handled
        }
        .onExitCommand {
            onClose()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.spacing0) {
            Text("\(viewModel.items.count) open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            if let checkinFirstLine = viewModel.checkinFirstLine {
                Text(checkinFirstLine)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Nothing open.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.text)
            if let checkinFirstLine = viewModel.checkinFirstLine {
                Text(checkinFirstLine)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.spacing3)
    }

    private func row(item: TodoPanelItem, index: Int) -> some View {
        let isSelected = viewModel.selectedIndex == index
        return HStack(alignment: .top, spacing: Theme.spacing2) {
            VStack(alignment: .leading, spacing: Theme.spacing0) {
                HStack(spacing: Theme.spacing1) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                    if TodoPanelRowState.showsPendingReminder(for: item) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                Text("\(item.sourceApp ?? "MaxMi") · \(ageDescription(item.detectedAtMs))")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.spacing1)
            HStack(spacing: Theme.spacing1) {
                Button("Done") {
                    viewModel.select(index: index)
                    Task { await viewModel.markSelectedDone() }
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    viewModel.select(index: index)
                    Task { await viewModel.dismissSelected() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.spacing2)
        .background(isSelected ? Theme.accent.opacity(0.55) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.select(index: index)
        }
    }

    private func ageDescription(_ detectedAtMs: EpochMs) -> String {
        TodoPanelRowState.ageDescription(detectedAtMs: detectedAtMs, nowMs: epochNowMs())
    }
}
```

Use the fixed `Theme` colors rather than system adaptive colors. The row’s buttons act on the selected item, so the tap gesture first selects the row; arrow/Return/Delete/Escape paths remain controlled entirely by the view model and `onClose`.

- [ ] **Step 4: Run the view-model-driven test to verify it passes**

Run:

```bash
swift test --filter TodoPanelViewModelTests
```

Expected: PASS. This task deliberately has no snapshot test; the XCTest contract verifies the DTO state that controls the title, source/age subtitle, and unreminded clock glyph.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiUI/TodoPanelView.swift Tests/MaxMiUITests/TodoPanelViewModelTests.swift
git commit -m "Add todo panel view"
```

### Task 7: Add Store adapters and the UserNotifications notifier

**Files:**

- Modify: `Sources/MaxMiStore/AgentStore.swift`
- Create: `Sources/MaxMi/StoreTodoPanelRepository.swift`
- Create: `Sources/MaxMi/StoreReminderRepository.swift`
- Create: `Sources/MaxMi/UNUserNotificationCenterNotifier.swift`
- Modify: `Tests/MaxMiStoreTests/AgentStoreTests.swift`

**Interfaces:**

- Consumes: Task 2’s `ActionItem`, `Store.actionItems(status:limit:)`, `Store.dueReminders(nowMs:)`, `Store.markReminded(_:nowMs:)`, and Task 4’s `ReminderRepository`/`ReminderNotifier`; Task 5’s `TodoPanelRepository`.
- Produces:

```swift
extension Store {
    public func sourceApps(forVersionIDs versionIDs: Set<String>) throws -> [String: String]
}

struct StoreTodoPanelRepository: TodoPanelRepository, @unchecked Sendable {
    init(
        store: Store,
        timeZone: TimeZone = .current
    )
}

struct StoreReminderRepository: ReminderRepository, @unchecked Sendable {
    init(store: Store)
}

@MainActor
final class UNUserNotificationCenterNotifier: NSObject, ReminderNotifier, UNUserNotificationCenterDelegate {
    init(onNotificationClick: @escaping @MainActor () -> Void)
    func post(id: String, title: String, body: String) async
}
```

- Task 8 constructs the two repositories and passes `TodoPanelController.show()` as `onNotificationClick`. `sourceApps(forVersionIDs:)` is the only Store lookup needed to derive `sourceApp` from the first source reference’s version and thread.

- [ ] **Step 1: Write failing Store source-app query tests**

```swift
// Add to Tests/MaxMiStoreTests/AgentStoreTests.swift
func testSourceAppsDerivesVersionSourceAppAndOmitsUnknownVersions() throws {
    let editorVersionID = try seedVersion(
        sourceApp: "Editor",
        sourceKey: "editor:workspace",
        content: "Draft the release note"
    )
    let mailVersionID = try seedVersion(
        sourceApp: "Mail",
        sourceKey: "mail:inbox",
        content: "Customer deadline"
    )

    let sourceApps = try store.sourceApps(
        forVersionIDs: [editorVersionID, mailVersionID, "missing-version"]
    )

    XCTAssertEqual(sourceApps[editorVersionID], "Editor")
    XCTAssertEqual(sourceApps[mailVersionID], "Mail")
    XCTAssertNil(sourceApps["missing-version"])
}

func testActionItemsExposeReminderFieldsForPanelAdapters() throws {
    try insertActionItem(
        id: "panel-item",
        status: "open",
        remindAtMs: t0 + 60_000,
        remindedAtMs: nil
    )

    let item = try XCTUnwrap(try store.actionItems(status: "open", limit: 1).first)

    XCTAssertEqual(item.id, "panel-item")
    XCTAssertEqual(item.remindAtMs, t0 + 60_000)
    XCTAssertNil(item.remindedAtMs)
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter AgentStoreTests
```

Expected: FAIL because `sourceApps(forVersionIDs:)` does not exist.

- [ ] **Step 3: Implement source resolution, both adapters, and notification behavior**

```swift
// Sources/MaxMiStore/AgentStore.swift
extension Store {
    public func sourceApps(forVersionIDs versionIDs: Set<String>) throws -> [String: String] {
        guard !versionIDs.isEmpty else { return [:] }
        return try db.dbQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT v.id AS version_id, t.source_app
                    FROM versions v
                    JOIN threads t ON t.id=v.thread_id
                    WHERE v.id IN (\(Self.placeholders(versionIDs.count)))
                    """,
                arguments: StatementArguments(versionIDs.sorted())
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["version_id"] as String, $0["source_app"] as String)
            })
        }
    }
}
```

```swift
// Sources/MaxMi/StoreTodoPanelRepository.swift
import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiUI

struct StoreTodoPanelRepository: TodoPanelRepository, @unchecked Sendable {
    let store: Store
    let timeZone: TimeZone

    init(store: Store, timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
    }

    func openItems(limit: Int) async -> [TodoPanelItem] {
        await Task.detached(priority: .userInitiated) {
            do {
                let items = try self.store.actionItems(status: "open", limit: limit)
                let sourceApps = try self.store.sourceApps(
                    forVersionIDs: Set(items.flatMap(\.sourceRefs))
                )
                return items.map { item in
                    TodoPanelItem(
                        id: item.id,
                        title: item.title,
                        details: item.details,
                        sourceApp: item.sourceRefs.first.flatMap { sourceApps[$0] },
                        detectedAtMs: item.detectedAtMs,
                        remindAtMs: item.remindAtMs,
                        remindedAtMs: item.remindedAtMs
                    )
                }
            } catch {
                return []
            }
        }.value
    }

    func todayCheckinFirstLine(nowMs: EpochMs) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                var calendar = Calendar.current
                calendar.timeZone = self.timeZone
                let dayBucket = Int64(
                    calendar.startOfDay(
                        for: Date(timeIntervalSince1970: Double(nowMs) / 1_000)
                    ).timeIntervalSince1970 * 1_000
                )
                guard let summary = try self.store.checkin(dayBucket: dayBucket)?.summary else {
                    return nil
                }
                guard let firstLine = summary.split(whereSeparator: \.isNewline).first else {
                    return nil
                }
                let trimmed = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                return nil
            }
        }.value
    }

    func markDone(id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .userInitiated) {
            try? self.store.resolveActionItem(id, nowMs: nowMs)
        }.value
    }

    func dismiss(id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .userInitiated) {
            try? self.store.dismissActionItem(id, nowMs: nowMs)
        }.value
    }
}
```

```swift
// Sources/MaxMi/StoreReminderRepository.swift
import MaxMiActivity
import MaxMiCore
import MaxMiStore

struct StoreReminderRepository: ReminderRepository, @unchecked Sendable {
    let store: Store

    init(store: Store) {
        self.store = store
    }

    func dueReminders(nowMs: EpochMs) async -> [ReminderItem] {
        await Task.detached(priority: .utility) {
            do {
                let items = try self.store.dueReminders(nowMs: nowMs)
                let sourceApps = try self.store.sourceApps(
                    forVersionIDs: Set(items.flatMap(\.sourceRefs))
                )
                return items.map {
                    ReminderItem(
                        id: $0.id,
                        title: $0.title,
                        sourceApp: $0.sourceRefs.first.flatMap { sourceApps[$0] },
                        detectedAtMs: $0.detectedAtMs
                    )
                }
            } catch {
                return []
            }
        }.value
    }

    func markReminded(_ id: String, nowMs: EpochMs) async {
        await Task.detached(priority: .utility) {
            try? self.store.markReminded(id, nowMs: nowMs)
        }.value
    }
}
```

```swift
// Sources/MaxMi/UNUserNotificationCenterNotifier.swift
import Foundation
import UserNotifications
import MaxMiActivity

@MainActor
final class UNUserNotificationCenterNotifier: NSObject, ReminderNotifier, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let onNotificationClick: @MainActor () -> Void
    private var authorizationRequested = false
    private var authorizationGranted = false

    init(
        center: UNUserNotificationCenter = .current(),
        onNotificationClick: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.onNotificationClick = onNotificationClick
        super.init()
        center.delegate = self
    }

    func post(id: String, title: String, body: String) async {
        if !authorizationRequested {
            authorizationRequested = true
            authorizationGranted = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
        }
        guard authorizationGranted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["actionItemID": id]
        let request = UNNotificationRequest(
            identifier: "maxmi-reminder-\(id)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        _ = center
        _ = response
        Task { @MainActor [onNotificationClick] in
            onNotificationClick()
        }
        completionHandler()
    }
}
```

The first reference in `sourceRefs` is the only reference used for the app label. An unresolvable first version deliberately produces `nil`, rendering as “MaxMi”; do not fall through to a later reference. Notification text contains only item title, source app, and age—never action-item `details` or capture text.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
swift test --filter AgentStoreTests
swift build --target MaxMi
```

Expected: PASS. The Store test proves the query backing both executable adapters; the executable build verifies the main-actor notification delegate and adapter protocol conformances without adding a prohibited executable test target.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiStore/AgentStore.swift Sources/MaxMi/StoreTodoPanelRepository.swift Sources/MaxMi/StoreReminderRepository.swift Sources/MaxMi/UNUserNotificationCenterNotifier.swift Tests/MaxMiStoreTests/AgentStoreTests.swift
git commit -m "Add todo panel reminder adapters"
```

### Task 8: Add the AppKit panel, Option monitor, and AppWiring integration

**Files:**

- Create: `Sources/MaxMi/TodoPanelController.swift`
- Create: `Sources/MaxMi/OptionDoubleTapMonitor.swift`
- Modify: `Sources/MaxMi/AppWiring.swift`

**Interfaces:**

- Consumes: Task 1’s `OptionDoubleTapDetector`; Task 4’s `ReminderScheduler`; Task 5’s `TodoPanelViewModel`; Task 6’s `TodoPanelView`; Task 7’s `StoreTodoPanelRepository`, `StoreReminderRepository`, and `UNUserNotificationCenterNotifier`.
- Produces:

```swift
@MainActor
final class TodoPanelController: NSObject {
    static let panelWidth: CGFloat = 520
    static let maximumScreenHeightFraction: CGFloat = 0.60
    static let cornerRadius: CGFloat = 14

    init(viewModel: TodoPanelViewModel)
    func show()
    func close()
    func toggle()
    func shutdown()
}

@MainActor
final class OptionDoubleTapMonitor {
    init(onDoubleTap: @escaping @Sendable @MainActor () -> Void)
    func start()
    func stop()
}
```

- `AppWiring.start()` starts the monitor after existing Accessibility-gated startup succeeds. `AppWiring.shutdown()` stops it and shuts down the panel. The existing pipeline timer awaits `checkinTrigger.tick(nowMs:)`, then awaits `reminderScheduler.tick(nowMs:)` in that order.

- [ ] **Step 1: Add an executable build gate before implementation**

There is intentionally no XCTest target for the `MaxMi` executable in `Package.swift`. Keep Tasks 1, 4, and 5 as the testable logic gates; use this build gate for AppKit integration:

```bash
swift build --target MaxMi
```

Expected: PASS before this task. Record any pre-existing warnings, but do not modify the existing `nonisolated(unsafe)` warning in `AppWiring.swift`.

- [ ] **Step 2: Implement the panel controller**

```swift
// Sources/MaxMi/TodoPanelController.swift
import AppKit
import SwiftUI
import MaxMiUI

@MainActor
final class TodoPanelController: NSObject {
    static let panelWidth: CGFloat = 520
    static let maximumScreenHeightFraction: CGFloat = 0.60
    static let cornerRadius: CGFloat = 14

    private let viewModel: TodoPanelViewModel
    private let panel: NSPanel
    private var hostingView: NSHostingView<TodoPanelView>?
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?

    init(viewModel: TodoPanelViewModel) {
        self.viewModel = viewModel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 1),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let root = TodoPanelView(viewModel: viewModel) { [weak self] in
            self?.close()
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = Self.cornerRadius
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        self.hostingView = hostingView

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.type == .keyDown, [123, 124, 125, 126, 36, 51].contains(event.keyCode),
               !self.panel.isKeyWindow {
                self.panel.makeKey()
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.panel.makeKey()
                } else {
                    self.close()
                }
            }
            return event
        }
    }

    func show() {
        Task { @MainActor in
            await viewModel.refresh()
            guard let screen = screenContainingMouse() else { return }
            resizeAndCenter(on: screen)
            installOutsideClickMonitor()
            panel.orderFront(nil)
        }
    }

    func close() {
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func shutdown() {
        removeOutsideClickMonitor()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        panel.orderOut(nil)
        hostingView = nil
    }

    private func resizeAndCenter(on screen: NSScreen) {
        guard let hostingView else { return }
        let maximumHeight = screen.visibleFrame.height * Self.maximumScreenHeightFraction
        let fittingHeight = hostingView.fittingSize.height
        let height = min(maximumHeight, fittingHeight)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - Self.panelWidth / 2,
            y: screen.visibleFrame.midY - height / 2
        )
        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)),
            display: false
        )
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.close()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
```

- [ ] **Step 3: Implement global and local Option-key monitoring**

```swift
// Sources/MaxMi/OptionDoubleTapMonitor.swift
import AppKit
import MaxMiActivity
import MaxMiCore

@MainActor
final class OptionDoubleTapMonitor {
    private let onDoubleTap: @Sendable @MainActor () -> Void
    private var detector = OptionDoubleTapDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var optionIsDown = false

    init(onDoubleTap: @escaping @Sendable @MainActor () -> Void) {
        self.onDoubleTap = onDoubleTap
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.consume(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        detector = OptionDoubleTapDetector()
        optionIsDown = false
    }

    private func consume(_ event: NSEvent) {
        let nowMs = EpochMs(event.timestamp * 1_000)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let otherModifierMask: NSEvent.ModifierFlags = [.command, .control, .shift, .function]

        if event.type == .keyDown {
            fireIfNeeded(detector.consume(.otherKeyOrModifier(nowMs)))
            return
        }
        if !flags.intersection(otherModifierMask).isEmpty {
            optionIsDown = flags.contains(.option)
            fireIfNeeded(detector.consume(.otherKeyOrModifier(nowMs)))
            return
        }

        let isOptionDown = flags.contains(.option)
        guard isOptionDown != optionIsDown else { return }
        optionIsDown = isOptionDown
        fireIfNeeded(detector.consume(
            isOptionDown ? .optionDown(nowMs) : .optionUp(nowMs)
        ))
    }

    private func fireIfNeeded(_ fired: Bool) {
        if fired {
            onDoubleTap()
        }
    }
}
```

This uses only `NSEvent` global and local monitors. Do not add Input Monitoring permission code, a `CGEventTap`, or a global keystroke capture abstraction.

- [ ] **Step 4: Wire all components into `AppWiring`**

Add these stored properties beside the existing check-in and panel state:

```swift
let reminderScheduler: ReminderScheduler
let todoPanelController: TodoPanelController
let optionDoubleTapMonitor: OptionDoubleTapMonitor
```

Construct them in `AppWiring.init()` after `checkinTrigger` and before the activity UI wiring:

```swift
let todoPanelRepository = StoreTodoPanelRepository(
    store: store,
    timeZone: checkinTimeZone
)
let todoPanelViewModel = TodoPanelViewModel(
    repository: todoPanelRepository,
    now: epochNowMs
)
let todoPanelController = TodoPanelController(viewModel: todoPanelViewModel)
self.todoPanelController = todoPanelController

nonisolated(unsafe) let reminderStore = store
let notifier = UNUserNotificationCenterNotifier { [weak todoPanelController] in
    todoPanelController?.show()
}
reminderScheduler = ReminderScheduler(
    repository: StoreReminderRepository(store: store),
    notifier: notifier,
    isActivitySynthesisEnabled: {
        do {
            return try reminderStore.activityConsent() == .granted
                && reminderStore.activityEnabled()
        } catch {
            return false
        }
    },
    clock: epochNowMs
)
optionDoubleTapMonitor = OptionDoubleTapMonitor { [weak todoPanelController] in
    todoPanelController?.toggle()
}
```

Start the monitor in `start()` after `PermissionGate.ensureAccessibility(menuBar:)` has succeeded:

```swift
optionDoubleTapMonitor.start()
```

Replace the existing detached check-in block in the 30-second pipeline timer with the ordered pair below, preserving all subsequent session-closing and synthesis code:

```swift
let checkinTrigger = self.checkinTrigger
let reminderScheduler = self.reminderScheduler
let nowMs = epochNowMs()
Task.detached {
    await checkinTrigger.tick(nowMs: nowMs)
    await reminderScheduler.tick(nowMs: nowMs)
}
```

Add this teardown before activity state is cleared in `shutdown()`:

```swift
optionDoubleTapMonitor.stop()
todoPanelController.shutdown()
```

Do not touch `cloudReviewInitialized()`.

- [ ] **Step 5: Run the integration build and focused logic regressions**

Run:

```bash
swift build --target MaxMi
swift test --filter OptionDoubleTapDetectorTests
swift test --filter ReminderSchedulerTests
swift test --filter TodoPanelViewModelTests
```

Expected: PASS. The build validates AppKit and UserNotifications integration; the three focused XCTest suites preserve all event, scheduling, and UI-state behavior that is testable outside the executable.

- [ ] **Step 6: Commit**

```bash
git add Sources/MaxMi/TodoPanelController.swift Sources/MaxMi/OptionDoubleTapMonitor.swift Sources/MaxMi/AppWiring.swift
git commit -m "Wire todo panel and reminders"
```

### Task 9: Run the regression gate and add the live verification ritual

**Files:**

- Create: `docs/superpowers/plans/2026-09-22-maxmi-m9-live-verification.md`

**Interfaces:**

- Consumes: Tasks 1–8, `./packaging/make-app.sh`, the installed `MaxMi.app`, and a manually created open action item.
- Produces: a verification-only checklist; it creates no production interface and modifies no source code.

- [ ] **Step 1: Write the live verification checklist**

```markdown
# MaxMi M9 Live Verification

Run this after the full XCTest gate passes. This is verification only; do not modify source while following it.

## Rebuild and relaunch

- [ ] Quit the running app with the exact command:

  ```bash
  pkill -9 -x MaxMi
  ```

- [ ] Build the application bundle:

  ```bash
  ./packaging/make-app.sh
  ```

  Expected: command exits 0 and produces `MaxMi.app`.

- [ ] Launch the freshly built application:

  ```bash
  open MaxMi.app
  ```

- [ ] Grant MaxMi Accessibility access if macOS asks. Do not grant Input Monitoring solely for this feature.

## Double-tap panel behavior

- [ ] Keep another app frontmost, then tap and release Option twice with each hold at most 400 ms and the two downs no more than 350 ms apart.
- [ ] Confirm the todo panel opens centered on the screen containing the mouse cursor and does not activate MaxMi or steal focus from the other app.
- [ ] Confirm an Option-plus-other-key chord, a hold longer than 400 ms, and a second tap beginning at least 351 ms after the first down do not open the panel.
- [ ] Confirm the panel is always dark, has a fixed 520-point width, and does not exceed 60% of the current screen’s visible height.
- [ ] Click inside the panel, then verify Up/Down wraps selection, Return resolves the selected row, Delete dismisses it, and Escape closes the panel.
- [ ] Reopen it, click outside it, and double-tap Option again; verify each closes it.

## Action-item and reminder behavior

- [ ] Ensure an open hourly-review action item exists. Open the panel and verify the newest items appear first, with at most 25 rows.
- [ ] Verify a row’s subtitle is `sourceApp · age`, and a row with `remind_at_ms` set but `reminded_at_ms` unset shows a clock glyph.
- [ ] Click **Done** on one row and verify it disappears on the next open.
- [ ] Click **Dismiss** on another row and verify it disappears on the next open.
- [ ] Stop MaxMi again, seed the most-recent existing open item one minute ahead while the database is closed, then relaunch:

  ```bash
  pkill -9 -x MaxMi
  MAXMI_DB="$HOME/Library/Application Support/MaxMi/maxmi.db"
  MAXMI_ITEM_ID="$(sqlite3 "$MAXMI_DB" "SELECT id FROM agent_action_items WHERE status='open' ORDER BY detected_at DESC, id ASC LIMIT 1;")"
  MAXMI_NOW_MS="$(( $(date +%s) * 1000 ))"
  test -n "$MAXMI_ITEM_ID"
  sqlite3 "$MAXMI_DB" "UPDATE agent_action_items SET remind_at_ms=$((MAXMI_NOW_MS + 60000)), reminded_at_ms=NULL WHERE id='$MAXMI_ITEM_ID' AND status='open';"
  open MaxMi.app
  ```

  Expected: `test -n` exits 0, one open action row receives a reminder exactly 60,000 ms ahead, and MaxMi relaunches.
- [ ] Wait through the next 30-second pipeline tick and confirm a notification appears with the action-item title and `sourceApp · age`, never item details or raw capture text.
- [ ] Click the notification and confirm the todo panel opens.
- [ ] Deny notifications in System Settings, seed another due reminder, and confirm no notification appears while the panel still shows its clock glyph.
```

- [ ] **Step 2: Run the full XCTest regression gate**

Run:

```bash
swift test
```

Expected: all tests PASS except only the two known-red cases named in Global Constraints:

```text
ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview
PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed
```

Expected: zero new compiler warnings. Do not treat either named known-red test as authorization to change `cloudReviewInitialized()`.

- [ ] **Step 3: Run the packaging build and live ritual**

Run:

```bash
pkill -9 -x MaxMi
./packaging/make-app.sh
open MaxMi.app
```

Expected: the process-stop command targets only the `MaxMi` executable, the bundle build exits 0, and the application opens. Follow every checkbox in `docs/superpowers/plans/2026-09-22-maxmi-m9-live-verification.md`; do not use `pkill -f`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-09-22-maxmi-m9-live-verification.md
git commit -m "Add todo panel verification ritual"
```
