# MaxMi M6a Implementation Plan — Activity Timeline + Sessions + SwiftUI Window + Dog Logo + Privacy

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship M6a — the deterministic activity-session layer (immutable evidence + Gemini display summaries), the SwiftUI Activity window opened from a dog menu-bar icon, and the activity-privacy sheet — per `docs/superpowers/specs/2026-07-11-maxmi-m6-activity-agent-ui-design.md` (Codex gpt-5.6-terra: GO after 4 spec rounds).

**Architecture:** FocusObserver gains `onFocusChanged`; `ActivityStore` opens a provisional session on first eligible capture, appends immutable encrypted evidence snapshots per commit, `SessionSegmenter` finalizes (closes) on app-change/idle, `DisplaySummarizer` (Gemini via `ActivityGenerationRelay`) summarizes closed sessions. A SwiftUI Activity window (always-dark Theme, `@MainActor @Observable` view model) renders the timeline, opened by left-click on the dog `NSStatusItem`. Privacy sheet gates synthesis (global + per-app exclusion). Dog app/tray icons ship.

**Tech Stack:** Swift 6, GRDB (v4 migration + PRAGMA foreign_keys), MaxMiCore (FieldCipher/ContentHash/Ident/HourBucket), Gemini relay, SwiftUI + NSHostingController, iconutil.

## Global Constraints

- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings in our code.
- Derived text (session `summary_ciphertext`, evidence `content_ciphertext`) encrypted via existing `FieldCipher.encrypt` (`enc:v1:`). Cleartext-for-index: app_bundle, app_label, timestamps, buckets, status.
- **PRAGMA foreign_keys = ON** in `MaxMiDatabase` config.prepareDatabase (currently off); v4 tables use `REFERENCES` + `ON DELETE CASCADE`.
- Session lifecycle: provisional open on first eligible capture → append immutable evidence per non-dedup commit (coalesce by `(session_id, content_hash)`) → `SessionSegmenter` closes on app-change/inactivity-gap. Summaries read evidence snapshots, NOT mutable `versions`.
- Sensitive-denylist apps AND user-excluded apps (`activity.disabled_app_bundle_ids` setting) + global-disable produce NO visits/sessions/evidence. Excluding an app deletes its existing activity rows.
- Gemini: pinned model `gemini-2.5-flash-lite`; shared throttle + backoff with the existing extraction path; summaries only for closed/idle sessions guarded by `source_hash`; explicit consent before first synthesis.
- UI: always-dark branded Theme tokens (NOT auto light/dark); stable session IDs; no decrypt/date-format in SwiftUI `body` (precompute in view model); left-click opens window via `NSStatusBarButton` action, right-click `popUpMenu`.
- Commit messages conventional; NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `m6-activity` (already on it).

## File Structure

```
Sources/MaxMiStore/Database.swift            MODIFY: PRAGMA foreign_keys = ON
Sources/MaxMiStore/Migrations.swift          MODIFY: v4 — 6 activity/agent tables (M6a uses the activity ones)
Sources/MaxMiStore/ActivityStore.swift        NEW: visits, provisional sessions, evidence, timeline queries
Sources/MaxMiActivity/SessionSegmenter.swift  NEW module: deterministic close policy (pure)
Sources/MaxMiActivity/DisplaySummarizer.swift  NEW: Gemini summary of a closed session (via relay proto)
Sources/MaxMiActivity/ActivityGenerationRelay.swift NEW: protocol { summarizeSession(...) }
Sources/MaxMiCapture/FocusObserver.swift       MODIFY: add onFocusChanged(app,isCapturable,pid)
Sources/MaxMiUI/ActivityViewModel.swift        NEW module: @MainActor @Observable; Store rows -> view state
Sources/MaxMiUI/ActivityView.swift             NEW: SwiftUI timeline (grouped, animated, always-dark)
Sources/MaxMiUI/Theme.swift                    NEW: dark palette + spacing + animation tokens
Sources/MaxMi/ActivityWindow.swift             NEW: NSWindow + NSHostingController manager
Sources/MaxMi/ActivityPrivacySheet.swift       NEW: SwiftUI consent + global/per-app exclusion
Sources/MaxMi/MenuBarController.swift          MODIFY: dog icon; left-click opens window, right-click menu
Sources/MaxMi/AppWiring.swift                  MODIFY: wire focus->ActivityStore, segmenter, summarizer, window
packaging/assets/dog.svg                        NEW: dog silhouette source
packaging/assets/AppIcon.iconset/*             NEW: generated PNGs -> icon.icns
packaging/assets/tray/*.png                     NEW: template tray icons
packaging/make-app.sh                          MODIFY: install icon.icns + tray assets
Tests/MaxMiStoreTests/ActivityStoreTests.swift  NEW
Tests/MaxMiActivityTests/*                       NEW: SegmenterTests, SummarizerTests
Tests/MaxMiUITests/ActivityViewModelTests.swift  NEW
Tests/MaxMiStoreTests/MigrationTests.swift       MODIFY: assert v4 tables + FK on
```

Task order: 1 migration+FK+ActivityStore → 2 SessionSegmenter → 3 FocusObserver hook + wiring (visits/sessions/evidence) → 4 DisplaySummarizer → 5 dog logo → 6 SwiftUI Theme+ViewModel+ActivityView → 7 ActivityWindow + menu-bar dog + privacy sheet + wire → 8 live verify.

---

### Task 1: v4 migration + FK enforcement + ActivityStore

**Files:** Modify `Sources/MaxMiStore/Database.swift`, `Sources/MaxMiStore/Migrations.swift`; Create `Sources/MaxMiStore/ActivityStore.swift`; Create `Tests/MaxMiStoreTests/ActivityStoreTests.swift`; Modify `Tests/MaxMiStoreTests/MigrationTests.swift`.

**Interfaces:**
```swift
public struct ActivitySession: Sendable {
    public let id, appBundle, appLabel: String
    public let startedAtMs: EpochMs; public let endedAtMs: EpochMs?; public let lastActivityAtMs: EpochMs
    public let summary: String?          // decrypted (nil if pending/failed)
    public let summaryStatus: String
}
extension Store {
    // Visit lifecycle
    public func openVisit(appBundle: String, appLabel: String, nowMs: EpochMs) throws -> String   // visit id
    public func closeOpenVisits(nowMs: EpochMs) throws                                              // crash-repair + on-transition
    // Session lifecycle (provisional open -> evidence -> close)
    public func openOrCurrentSession(appBundle: String, appLabel: String, nowMs: EpochMs) throws -> String  // session id
    public func appendEvidence(sessionID: String, versionID: String?, content: String, nowMs: EpochMs) throws // encrypts + coalesces by content_hash
    public func closeSession(_ id: String, nowMs: EpochMs) throws
    public func setSessionSummary(_ id: String, summary: String, sourceHash: String, modelID: String, promptVersion: String, nowMs: EpochMs) throws
    public func sessionSourceHash(_ id: String) throws -> String     // hash over evidence snapshots
    // Queries
    public func recentSessions(limit: Int) throws -> [ActivitySession]
    public func sessionsPendingSummary(limit: Int) throws -> [ActivitySession]  // closed + pending
    public func sessionEvidence(_ id: String) throws -> [String]     // decrypted snapshots (expand-to-detail)
    // Privacy
    public func deleteActivityForApp(_ appBundle: String) throws     // cascade visits/sessions/evidence
}
```

- [ ] **Step 1: Enable FK.** In `Sources/MaxMiStore/Database.swift`, inside `config.prepareDatabase { db in ... }` add `try db.execute(sql: "PRAGMA foreign_keys = ON")`.
- [ ] **Step 2: Failing migration test** — add to `MigrationTests.swift`:
```swift
    func testV4AddsActivityTables() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            for t in ["activity_app_visits","activity_sessions","activity_session_evidence","agent_runs","agent_action_items","agent_action_item_events"] {
                XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", arguments: [t]), 1, "missing \(t)")
            }
            XCTAssertEqual(try Int.fetchOne(d, sql: "PRAGMA foreign_keys"), 1, "FK must be ON")
        }
    }
```
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Add v4 migration** — copy the exact CREATE TABLE DDL from spec §8 (all 6 tables incl. ON DELETE CASCADE + CHECK constraints + the coalesce/dedup indexes) into a `m.registerMigration("v4")` block after v3.
- [ ] **Step 5: Run — migration test PASS.**
- [ ] **Step 6: Failing ActivityStore tests** — `ActivityStoreTests.swift`:
```swift
import XCTest; import GRDB; @testable import MaxMiStore; import MaxMiCore
final class ActivityStoreTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws { db = try .inMemory(); store = Store(db: db, cipher: AESGCMFieldCipher.testCipher) }
    let t0 = EpochMs(496_000) * 3_600_000
    func testEvidenceEncryptedAndCoalesced() throws {
        let s = try store.openOrCurrentSession(appBundle: "com.x", appLabel: "X", nowMs: t0)
        try store.appendEvidence(sessionID: s, versionID: nil, content: "did a thing", nowMs: t0)
        try store.appendEvidence(sessionID: s, versionID: nil, content: "did a thing", nowMs: t0+1000) // dup -> coalesced
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT content_ciphertext FROM activity_session_evidence WHERE session_id=?", arguments: [s])
            XCTAssertEqual(rows.count, 1, "duplicate content coalesced")
            XCTAssertTrue((rows[0]["content_ciphertext"] as String).hasPrefix("enc:v1:"))
        }
        XCTAssertEqual(try store.sessionEvidence(s), ["did a thing"])
    }
    func testCloseAndSummarize() throws {
        let s = try store.openOrCurrentSession(appBundle: "com.x", appLabel: "X", nowMs: t0)
        try store.appendEvidence(sessionID: s, versionID: nil, content: "wrote the parser", nowMs: t0)
        try store.closeSession(s, nowMs: t0+60_000)
        let h = try store.sessionSourceHash(s)
        try store.setSessionSummary(s, summary: "Worked on the parser", sourceHash: h, modelID: "gemini-2.5-flash-lite", promptVersion: "v1", nowMs: t0+61_000)
        let recent = try store.recentSessions(limit: 10)
        XCTAssertEqual(recent.first?.summary, "Worked on the parser")
        XCTAssertEqual(recent.first?.summaryStatus, "summarized")
    }
    func testDeleteActivityForAppCascades() throws {
        let s = try store.openOrCurrentSession(appBundle: "com.secret", appLabel: "S", nowMs: t0)
        try store.appendEvidence(sessionID: s, versionID: nil, content: "x", nowMs: t0)
        try store.deleteActivityForApp("com.secret")
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_sessions WHERE app_bundle='com.secret'"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_session_evidence"), 0, "evidence cascade-deleted")
        }
    }
    func testCrashRepairClosesDanglingVisits() throws {
        _ = try store.openVisit(appBundle: "com.x", appLabel: "X", nowMs: t0)
        try store.closeOpenVisits(nowMs: t0+5000)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_app_visits WHERE ended_at IS NULL"), 0)
        }
    }
}
```
- [ ] **Step 7: Run — FAIL.**
- [ ] **Step 8: Implement ActivityStore.swift.** `openOrCurrentSession`: if an open (ended_at null) session for this app exists and is recent, return it; else insert a provisional row (Ident.uuidv7, summary_status 'pending'). `appendEvidence`: `ContentHash.sha256Hex(content)`, `INSERT OR IGNORE` into evidence (unique index coalesces), encrypt content, bump session `last_activity_at`. `closeSession`: set ended_at. `sessionSourceHash`: hash the sorted evidence content_hashes. `setSessionSummary`: encrypt summary, set summary_ciphertext/status='summarized'/source_hash/model/prompt. `recentSessions`/`sessionsPendingSummary`: query + decrypt summary. `sessionEvidence`: decrypt snapshots. `deleteActivityForApp`: delete sessions+visits for the bundle (evidence cascades via FK). Use `db.dbQueue.write`.
- [ ] **Step 9: Run — PASS.** Full suite green.
- [ ] **Step 10: Commit** `feat(store): v4 activity tables + FK enforcement + ActivityStore (sessions + immutable evidence)`

---

### Task 2: SessionSegmenter (deterministic finalization policy)

**Files:** Create `Sources/MaxMiActivity/SessionSegmenter.swift` (+ add `MaxMiActivity` target to Package.swift, dep MaxMiCore); Create `Tests/MaxMiActivityTests/SessionSegmenterTests.swift`.

**Interfaces:**
```swift
public struct SegmentDecision: Sendable, Equatable { public let closePrevious: Bool; public let openNew: Bool }
public enum SessionSegmenter {
    // Pure: given the current open session's app + last-activity time, and the new event's app + time,
    // decide whether to close the old session and/or open a new one. gapMs = inactivity threshold.
    public static func decide(openApp: String?, lastActivityMs: EpochMs?, eventApp: String,
                              eventMs: EpochMs, gapMs: EpochMs = 5*60_000) -> SegmentDecision
}
```
- [ ] **Step 1: Package.swift** — add `.target(name: "MaxMiActivity", dependencies: ["MaxMiCore"])` + `.testTarget(name: "MaxMiActivityTests", dependencies: ["MaxMiActivity"])`.
- [ ] **Step 2: Failing tests** — same app within gap → no close/open (continue); different app → close+open; same app after gap → close+open (new session); no open session → open only. 
```swift
import XCTest; @testable import MaxMiActivity; import MaxMiCore
final class SessionSegmenterTests: XCTestCase {
    func testContinueSameAppWithinGap() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "a", eventMs: 2000),
                       SegmentDecision(closePrevious: false, openNew: false))
    }
    func testAppChangeClosesAndOpens() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "b", eventMs: 2000),
                       SegmentDecision(closePrevious: true, openNew: true))
    }
    func testSameAppAfterGapIsNewSession() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: "a", lastActivityMs: 1000, eventApp: "a", eventMs: 1000 + 6*60_000),
                       SegmentDecision(closePrevious: true, openNew: true))
    }
    func testNoOpenSessionOpens() {
        XCTAssertEqual(SessionSegmenter.decide(openApp: nil, lastActivityMs: nil, eventApp: "a", eventMs: 1000),
                       SegmentDecision(closePrevious: false, openNew: true))
    }
}
```
- [ ] **Step 3: Run — FAIL. Step 4: Implement** the pure decision. **Step 5: Run — PASS.**
- [ ] **Step 6: Commit** `feat(activity): SessionSegmenter deterministic finalization policy`

---

### Task 3: FocusObserver onFocusChanged + wire activity capture

**Files:** Modify `Sources/MaxMiCapture/FocusObserver.swift`, `Sources/MaxMi/AppWiring.swift`.

**Interfaces:** FocusObserver gains `var onFocusChanged: (@MainActor (AppInfo, _ isCapturable: Bool, pid_t) -> Void)?` fired on every frontmost change (before the capturable gate). AppWiring uses it + the existing commit path to drive ActivityStore + SessionSegmenter.

- [ ] **Step 1: Add the callback** to FocusObserver: in `frontmostChanged`, after computing the app, call `onFocusChanged?(appInfo, isCapturable(bid), pid)` regardless of capturability (so visits are tracked; the existing onCapture still gates content capture).
- [ ] **Step 2: Wire in AppWiring** (behind the activity-enabled + not-sensitive + not-excluded gate): on `onFocusChanged`, apply `SessionSegmenter.decide(...)` against the current open session → close old / open new via `ActivityStore`; record the visit (open new, close prior). On each successful `commitCapture` that returns `.committed` (not dedup), call `store.appendEvidence(sessionID: currentSession, versionID: vid, content: parsed.content, ...)`. Skip entirely if the app is sensitive (`Denylist.isSensitiveApp`) or in `activity.disabled_app_bundle_ids` or global-disabled. On app launch, call `store.closeOpenVisits` (crash repair). On `NSWorkspace.willSleepNotification`/screen-lock, close the open session+visit.
- [ ] **Step 3: Build clean; full suite green** (FocusObserver/AppWiring are glue — verified by build + existing tests + Task 1 store tests).
- [ ] **Step 4: Commit** `feat(activity): FocusObserver onFocusChanged -> visits/sessions/evidence wiring`

---

### Task 4: DisplaySummarizer (Gemini summary of closed sessions)

**Files:** Create `Sources/MaxMiActivity/ActivityGenerationRelay.swift`, `Sources/MaxMiActivity/DisplaySummarizer.swift`, `Sources/MaxMiActivity/AgentPrompts.swift`; Create `Tests/MaxMiActivityTests/DisplaySummarizerTests.swift`; wire the run loop in AppWiring.

**Interfaces:**
```swift
public protocol ActivityGenerationRelay: Sendable {
    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String
}
public struct DisplaySummarizer: Sendable {
    public init(relay: any ActivityGenerationRelay)
    // For each closed + pending + (source_hash changed) session: summarize, store. Skips still-open.
    public func summarizePending(store: Store, nowMs: EpochMs) async
}
```
- [ ] **Step 1: Failing test** — `DisplaySummarizerTests`: seed a closed pending session with evidence, run `summarizePending` with a `MockRelay` returning "Worked on X", assert the session becomes `summarized` with that summary and a source_hash. A still-open session is NOT summarized.
- [ ] **Step 2: Run — FAIL. Step 3: Implement** — query `sessionsPendingSummary`, for each: fetch decrypted evidence, call `relay.summarizeSession`, `store.setSessionSummary` with the computed source_hash + pinned model id. Bound evidence size (token cap). On relay error → mark session summary_status 'failed' (retry next tick), never crash. AgentPrompts holds the rewrite-for-display prompt.
- [ ] **Step 4: Wire the real relay** in AppWiring: an `ActivityGenerationRelay` impl over the existing Gemini MemoryRelay (pinned model, shared throttle/backoff). Run `summarizePending` on the idle sweep (reuse the existing 30s pipeline tick, gated on activity-enabled + consent).
- [ ] **Step 5: Run — PASS; build; full suite green. Step 6: Commit** `feat(activity): DisplaySummarizer (Gemini display summaries for closed sessions)`

---

### Task 5: Dog logo (app icon + tray template)

**Files:** Create `packaging/assets/dog.svg`, generate `packaging/assets/AppIcon.iconset/` PNGs + `icon.icns`, `packaging/assets/tray/tray-default-{light,dark}.png` (template); Modify `packaging/make-app.sh`.

- [ ] **Step 1: Author `packaging/assets/dog.svg`** — a minimalist **white dog silhouette** (simple sitting/lying profile, same weight as Minimi's cat) on transparent bg. Hand-authored vector path (crisp), NOT an AI raster. Also a black-squircle-background variant for the app icon.
- [ ] **Step 2: Generate iconset + icns:**
```bash
cd packaging/assets
# render dog-on-black-squircle to the required sizes (use rsvg-convert or qlmanage/sips from a 1024 master PNG)
# produce AppIcon.iconset/icon_{16,32,128,256,512}x{,@2x}.png then:
iconutil -c icns AppIcon.iconset -o icon.icns
```
(Implementer: if `rsvg-convert` unavailable, render the SVG to a 1024 PNG via `qlmanage`/an available tool, then `sips -z` for each size. Document the tool used.)
- [ ] **Step 3: Tray template PNGs** — white dog silhouette on transparent, 16pt @1x/@2x, saved as template (the app sets `NSImage.isTemplate=true` in Task 7).
- [ ] **Step 4: make-app.sh** — `cp packaging/assets/icon.icns "$APP/Contents/Resources/icon.icns"` + add `CFBundleIconFile`/`CFBundleIconName` to Info.plist; copy tray PNGs into Resources.
- [ ] **Step 5: Build the app** (`./packaging/make-app.sh`), confirm `icon.icns` present + the app shows the dog in Finder. **Commit** `feat(brand): MaxMi dog app icon + template tray icon (Minimi-style, black squircle)`

---

### Task 6: SwiftUI Theme + ActivityViewModel + ActivityView

**Files:** add `MaxMiUI` target (deps MaxMiStore, MaxMiCore) to Package.swift; Create `Sources/MaxMiUI/Theme.swift`, `Sources/MaxMiUI/ActivityViewModel.swift`, `Sources/MaxMiUI/ActivityView.swift`; Create `Tests/MaxMiUITests/ActivityViewModelTests.swift`.

**Interfaces:**
```swift
public struct SessionRow: Identifiable, Sendable {   // precomputed — no decrypt/format in body
    public let id: String; public let appLabel: String; public let summary: String
    public let timeAgo: String; public let dayGroup: String   // "Today"/"Yesterday"/date
}
@MainActor @Observable public final class ActivityViewModel {
    public private(set) var groups: [(day: String, rows: [SessionRow])]
    public init(load: @escaping @Sendable () async -> [ActivitySession], now: @escaping () -> EpochMs)
    public func refresh() async     // loads off-main, maps to rows (timeAgo/dayGroup precomputed), publishes
}
```
- [ ] **Step 1: Package.swift** — add MaxMiUI target + test target.
- [ ] **Step 2: Failing ViewModelTests** — inject a `load` returning synthetic ActivitySessions across two days; `refresh()`; assert `groups` has "Today"/"Yesterday" with correct rows, timeAgo formatted ("20m ago"), newest first. (Pure — no SwiftUI.)
- [ ] **Step 3: Run — FAIL. Step 4: Implement** Theme (dark palette/spacing/animation tokens), ActivityViewModel (map + group by day-bucket, relative-time format — all precomputed off `body`), ActivityView (SwiftUI: `List`/`LazyVStack`, sectioned by day, `SessionRow` with app glyph + summary + timeAgo, `.animation(.spring, value:)` on the collection, always-dark Theme, empty state). ActivityView is compile-checked; ViewModel is tested.
- [ ] **Step 5: Run — PASS; build; full suite green. Step 6: Commit** `feat(ui): SwiftUI activity timeline (Theme + @Observable view model + view)`

---

### Task 7: ActivityWindow + dog menu-bar + privacy sheet + wiring

**Files:** Create `Sources/MaxMi/ActivityWindow.swift`, `Sources/MaxMi/ActivityPrivacySheet.swift`; Modify `Sources/MaxMi/MenuBarController.swift`, `Sources/MaxMi/AppWiring.swift`.

- [ ] **Step 1: ActivityWindow** — a retained manager owning a closable `NSWindow` hosting `NSHostingController(rootView: ActivityView(viewModel:))`; `show()` = `NSApp.activate(ignoringOtherApps:true)` + `makeKeyAndOrderFront`; refreshes the view model on show.
- [ ] **Step 2: MenuBarController** — set the status button image to the dog template (`NSImage(named:)` + `isTemplate=true`); handle **left mouse-up → ActivityWindow.show()**, **right mouse-up → popUpMenu(statusMenu)** via `NSStatusBarButton` action + `sendAction(on: [.leftMouseUp,.rightMouseUp])`; add "Activity Privacy…" + "Open MaxMi" menu items.
- [ ] **Step 3: ActivityPrivacySheet** — SwiftUI sheet: Gemini-consent copy + a global "Enable activity synthesis" toggle + a per-app exclusion list (reads recent app_bundles, toggles write `activity.disabled_app_bundle_ids` setting; excluding calls `store.deleteActivityForApp`). Shown on first synthesis (or via the menu item).
- [ ] **Step 4: Wire in AppWiring** — construct ActivityWindow with a view model whose `load` = `store.recentSessions`; gate all activity capture (Task 3) + summarization (Task 4) on the global-enable setting + consent. First run with consent unset → show the privacy sheet before any synthesis.
- [ ] **Step 5: Build clean; full suite green. Step 6: Commit** `feat(ui): Activity window + dog menu-bar (left-open/right-menu) + activity privacy sheet`

---

### Task 8: Live verification (controller/human — closes M6a)

**Files:** none. Do NOT run as a subagent.

- [ ] **Step 1: Rebuild + relaunch** (grant persists): `./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"; sleep 2; open MaxMi.app`. Confirm the **dog icon** in the menu bar + Finder.
- [ ] **Step 2: Consent + privacy** — on first run the Activity Privacy sheet appears; enable synthesis; exclude one app and confirm no rows appear for it.
- [ ] **Step 3: Generate activity** — use several apps (Cursor, Chrome, Slack) for a few minutes each with gaps between.
- [ ] **Step 4: Open the window** — left-click the dog → Activity window opens showing a timeline grouped by Today, rows like "Cursor · <summary> · Xm ago"; smooth scroll/animation; right-click → menu. Verify sessions closed + summarized:
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -header -column "$DB" "SELECT app_label, summary_status, (ended_at IS NOT NULL) AS closed, datetime(started_at/1000,'unixepoch','localtime') FROM activity_sessions ORDER BY started_at DESC LIMIT 8;"
sqlite3 "$DB" "SELECT substr(content_ciphertext,1,10) FROM activity_session_evidence LIMIT 2;"  # enc:v1:
```
- [ ] **Step 5: Privacy delete** — exclude an app that has sessions; confirm its `activity_sessions`+evidence rows are gone (cascade).
- [ ] **Step 6: Declare M6a complete** when 1-5 hold. Then M6b (agent) + M6c (settings/polish).

---

## Self-Review (at plan-writing time)
**Spec coverage:** §8 schema+FK+cascade → T1; deterministic lifecycle (provisional open/evidence/close) → T1+T2+T3; FocusObserver onFocusChanged + sensitive/excluded skip + crash-repair → T3; Gemini summary of closed sessions only, pinned model, consent-gated → T4; dog logo → T5; SwiftUI always-dark timeline, stable IDs, no-decrypt-in-body → T6; window left-open/right-menu + privacy sheet (M6a) → T7; exit criteria → T8. Privacy controls in M6a (not deferred) → T7. Encrypted evidence/summary → T1.
**Placeholders:** T5 flags the icon-render tool as environment-dependent (rsvg vs sips) — genuine, documented. Everything else concrete.
**Type consistency:** `ActivitySession`/`SessionRow` fields consistent T1↔T6; `ActivityGenerationRelay.summarizeSession` used T4; `SessionSegmenter.decide` T2↔T3; store methods (openOrCurrentSession/appendEvidence/closeSession/setSessionSummary/recentSessions/deleteActivityForApp) consistent T1↔T3↔T4↔T7.
