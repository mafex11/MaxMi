# MaxMi M9 — Double-tap Option todo panel with reminders

**Status:** approved by the user on 2026-09-22 (design reviewed in chat; spec review waived).
**Depends on:** M8 Phase C (hourly review action items, daily check-in, `CheckinTrigger` tick, shared `SourceCloudEligibility` policy). Phase D is independent.

## 1. Goal

Double-tapping the Option key anywhere on the Mac opens a floating, always-dark panel listing the open action items the hourly review already produces. The user marks items done or dismisses them from the panel. Items the hourly review associates with a concrete time get a `remind_at`; MaxMi posts a macOS notification at that time and clicking it opens the panel.

Non-goals: user-authored todos, editing item text, snooze/manual scheduling, syncing to Reminders.app. Nothing new leaves the machine.

## 2. Existing pieces this builds on

- `MaxMiStore/AgentStore.swift`: `ActionItem { id, kind, status, title, details, sourceRefs, detectedAtMs, updatedAtMs, resolvedAtMs, atMs, sessionID }`, `actionItems(status:limit:)`, `resolveActionItem(_:nowMs:)`, `dismissActionItem(_:nowMs:)`.
- `MaxMiActivity/HourlyAgent.swift`: review output operations (`op, id, kind, title, details, evidence, sourceRefs`), validated against version IDs; `AgentPrompts.hourlyReview` with nonce-fenced untrusted text.
- `MaxMiActivity/CheckinSchedule.swift`: `CheckinTrigger` actor ticked from AppWiring after `pipeline.tick()`; the reminder scheduler follows the same pattern.
- `MaxMi/RightLanePanel.swift`: existing non-activating `NSPanel` (meetings) — precedent for window level, activation policy and SwiftUI hosting.
- `MaxMiUI/TodayCardView.swift`: always-dark palette and view-model/repository-protocol pattern (UI module never imports MaxMiStore; adapters live in `Sources/MaxMi`).
- Migrations head is v13; `MemoryDataControls.pruneMemory/deleteAllMemory` already cover `agent_action_items`.

## 3. Components

### 3a. `OptionDoubleTapMonitor` (Sources/MaxMi)
- Exactly one `NSEvent.addGlobalMonitorForEvents` and one `NSEvent.addLocalMonitorForEvents`, both with the `.flagsChanged` mask only, live in `Sources/MaxMi/OptionDoubleTapMonitor.swift`; the global monitor requires the Accessibility grant MaxMi already holds. No Input Monitoring, `.keyDown`, `.keyUp`, or CGEvent tap is used.
- Pure `OptionEventMapper` and `OptionDoubleTapDetector` live in `Sources/MaxMiActivity` and are unit-tested. The mapper converts flags-only AppKit events into `optionDown(t)`, `optionUp(t)`, or `otherKeyOrModifier(t)`; it resets on shift, control, command, or function flags. A *tap* is Option down→up with hold ≤ `maxTapHoldMs` (250 ms). Two taps whose downs are 40–350 ms apart inclusive fire once; the detector then resets. Because the monitor cannot observe non-modifier keys, typing an Option+letter chord twice quickly can toggle the panel; this is accepted.
- Callback: `onDoubleTap: @Sendable @MainActor () -> Void` → `TodoPanelController.toggle()`.

### 3b. `TodoPanelController` + `TodoPanel` (Sources/MaxMi)
- `NSPanel` with `.nonactivatingPanel`, `.borderless`, level `.floating`, `hidesOnDeactivate = false`, `isMovableByWindowBackground = true`, transparent titlebar, corner radius 14, fixed width 520, height fits content up to 60% of screen height.
- Centered on the screen containing the mouse cursor. Opens without activating the app; the first arrow key, Return, Delete or click inside makes the panel key (`makeKey()`), Escape / click outside / another double-tap closes it. Click-outside uses a global mouse-down monitor active only while the panel is visible.
- Hosts `TodoPanelView` (SwiftUI, MaxMiUI) via `NSHostingView`. Reloads items every time it opens.

### 3c. `TodoPanelView` + `TodoPanelViewModel` (Sources/MaxMiUI)
- Always dark: fixed palette (reuse Today card's colors), `.preferredColorScheme(.dark)`.
- Header: "N open" and, when today's check-in exists, its first line (single line, truncated).
- Rows (newest `detectedAtMs` first, cap 25): title (2 lines max), `sourceApp · age` subtitle (age: "3h", "2d"), clock glyph when `remindAtMs != nil && remindedAtMs == nil`. Row actions: **Done** (→ resolve) and **Dismiss** (→ dismiss). Selected row highlighted; ↑/↓ move, Return = Done, Delete = Dismiss, Esc = close.
- Empty state: "Nothing open." plus the check-in line if any.
- `TodoPanelViewModel` is `@MainActor`, drives a `TodoPanelRepository` protocol (MaxMiUI):
  ```swift
  public struct TodoPanelItem: Sendable, Equatable, Identifiable { id, title, details, sourceApp: String?, detectedAtMs, remindAtMs: EpochMs?, remindedAtMs: EpochMs? }
  public protocol TodoPanelRepository: Sendable {
      func openItems(limit: Int) async -> [TodoPanelItem]
      func todayCheckinFirstLine(nowMs: EpochMs) async -> String?
      func markDone(id: String, nowMs: EpochMs) async
      func dismiss(id: String, nowMs: EpochMs) async
  }
  ```
  `StoreTodoPanelRepository` (Sources/MaxMi) adapts `Store`. `sourceApp` is derived from the item's first `sourceRefs` version → thread `source_app` (nil when unresolvable). Store work runs off the main actor.

### 3d. Reminder schema (Sources/MaxMiStore)
- Migration **v14**: `ALTER TABLE agent_action_items ADD COLUMN remind_at_ms INTEGER NULL; ADD COLUMN reminded_at_ms INTEGER NULL;` index on `(status, remind_at_ms)`. `DatabaseRecovery` derives the migration set from the migrator (no hand-edited lists). `ActionItem` gains `remindAtMs: EpochMs?`, `remindedAtMs: EpochMs?`.
- New Store API: `dueReminders(nowMs:) -> [ActionItem]` (status open, `remind_at_ms <= now`, `reminded_at_ms IS NULL`, and `remind_at_ms >= now - 24h`), `markReminded(_ id:, nowMs:)`, `setReminder(_ id:, remindAtMs: EpochMs?)`. `resolveActionItem`/`dismissActionItem` also clear `remind_at_ms`.
- Prune/delete-all need no change (rows live in `agent_action_items`); a test asserts the new columns are gone with the row.

### 3e. Hourly review `remind_at` (Sources/MaxMiActivity)
- Review operation gains optional `remind_at: String?` (ISO-8601 with offset). The prompt adds one instruction: set `remind_at` only when the evidence states a concrete time or deadline for the item; otherwise omit it. A malformed or out-of-window value is debug-logged and drops only `remind_at`; the create or update still applies and the agent run completes. Nothing else in the prompt changes; fencing and validation stay as they are. `HourlyAgent` receives the injected `checkinTimeZone` from `AppWiring`; new pure reminder logic does not use `.current`.
- Validation (pure function `ReminderTimeValidator.accept(_:nowMs:timeZone:) -> EpochMs?`): parse; accept only `now < t <= now + 48h`; reject past, too-far, or malformed values (log at debug, drop the field, keep the item). On `create`/`update` ops with an accepted time → `setReminder`.

### 3f. `ReminderScheduler` (Sources/MaxMiActivity) + notifications (Sources/MaxMi)
- Actor `ReminderScheduler(repository: ReminderRepository, notifier: ReminderNotifier, clock:)` with `tick(nowMs:)`; AppWiring calls it right after `checkinTrigger.tick()` on the same pipeline timer. `inFlight` guard like `CheckinTrigger`.
- Each tick: `dueReminders(nowMs)` → for each, `notifier.post(id:title:body:)` then `markReminded`. Body = `"\(sourceApp ?? "MaxMi") · \(age)"`. Items due more than 24 h ago are never posted (the Store predicate excludes them) but are marked reminded so they do not linger.
- `UNUserNotificationCenterNotifier` (Sources/MaxMi) requests authorization lazily on first post; if denied, `post` is a no-op and the panel's clock glyph remains the only signal. Notification click → `TodoPanelController.show()`.
- Gate: reminders run only when `isActivitySynthesisEnabled()` is true (same consent as the hourly review that creates the items).

## 4. Privacy
- No new network calls. `remind_at` travels inside the existing hourly-review response.
- Notification text is the item title (already model output derived from eligible captures) plus source app and age; never raw capture text, never `details`.
- Items originate only from captures the shared `SourceCloudEligibility` policy allowed; the panel adds no new read path over raw content (it reads `agent_action_items` and the check-in summary only).

## 5. Testing (XCTest only)
- `OptionDoubleTapDetectorTests` and `OptionEventMapperTests`: two fast taps fire once; 39 ms and 351 ms down-to-down gaps do not fire; a hold > 250 ms is not a tap; other modifier flags reset; three taps fire once then reset; flags-only mapping never observes letter keys. `TypingObserverTests` source-greps that the sole global/local monitor pair is confined to `OptionDoubleTapMonitor.swift`, uses `.flagsChanged` only, and that `.keyDown`, `.keyUp`, `CGEvent.tapCreate`, and `CGEventTapCreate` appear nowhere in `Sources/`.
- `TodoPanelViewModelTests` (MaxMiUITests, fakes): load orders newest first and caps at 25; done/dismiss call the repository and remove the row; keyboard selection wraps correctly; empty state; check-in header line. `TodoPanelPlacementTests` and `OutsideClickPolicyTests` cover centered frame calculation and inside/outside close decisions.
- `AgentStoreTests`: v14 columns; `dueReminders` boundaries (due, not yet, already reminded, older than 24 h excluded); resolve/dismiss clear `remind_at_ms`; delete-all/prune remove rows.
- `ReminderTimeValidatorTests`: valid future time accepted; past, >48 h, malformed rejected; timezone offsets honored.
- `ReminderSchedulerTests`: fixed clock; posts once and marks reminded; second tick posts nothing; denied notifier still marks reminded; synthesis disabled → no work; inFlight guard under concurrent ticks.
- `HourlyAgentTests`: op with valid `remind_at` sets the reminder; malformed and out-of-window reminder-only updates drop the field but still complete; a nonce-stripped deterministic golden covers the modified prompt and a byte-stability assertion covers the prompt with the new line removed.
- Live ritual (`pkill -9 -x MaxMi`, rebuild via `packaging/make-app.sh`, `open MaxMi.app`): double-tap from another app opens the panel without stealing focus; Done removes a row; a seeded reminder 1 minute ahead fires a notification whose click opens the panel.

## 6. Global constraints
- Swift 6 strict concurrency; XCTest only; all existing tests stay green except the two known-red cases (`ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`, `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`). `cloudReviewInitialized()` stays `{ false }`.
- MaxMiUI never imports MaxMiStore; adapters live in Sources/MaxMi. No new SwiftPM test target for the executable; testable logic lives in MaxMiActivity/MaxMiUI.
- Fixtures hand-invented; commit messages plain, no AI attribution; process stop is `pkill -9 -x MaxMi`.
