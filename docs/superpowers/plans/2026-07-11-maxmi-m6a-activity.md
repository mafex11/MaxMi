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

Task order (▲REV2 — Codex #1: segmenter FIRST, in MaxMiCore, so Store can use it): **1 SessionSegmenter (in MaxMiCore, pure)** → 2 migration+FK+ActivityStore → 3 FocusObserver hook + wiring (focus-generation token) → 4 DisplaySummarizer + Gemini generation/throttle → 5 dog logo → 6 SwiftUI Theme+ViewModel+ActivityView → 7 ActivityWindow + menu-bar dog + privacy sheet + wire → 8 live verify.

**▲REV2 — global active session + focus-generation token (Codex #2, the correctness core):** there is at most ONE globally-active eligible activity session at a time (not per-app). AppWiring holds a monotonic `focusGeneration: Int`, bumped on every focus transition; the active app+generation is the "current focus span". A capture carries the generation it was started under; when it completes (post-`Task.detached`), if its generation ≠ the current generation, its activity evidence is **discarded** (the normal memory capture still commits — only activity evidence is span-gated). On an app transition, AppWiring **closes** the prior active session immediately (via `closeActiveSession`); the first valid capture of the new span **opens** the new one. So `recordActivityCapture` operates on the single active span, not a per-app lookup.

**Consent (▲REV2 — Codex #4):** persisted `activityConsent` is a tri-state (`unset` | `granted` | `declined`), separate from `activityEnabled` (the on/off once granted). Gate all visits/sessions/evidence on `consent == .granted && activityEnabled`. `unset` → show the privacy window before any synthesis; `declined` → stay off, never re-prompt automatically.

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
    public func openVisit(appBundle: String, appLabel: String, nowMs: EpochMs) throws -> String
    public func closeOpenVisits(nowMs: EpochMs) throws                         // crash-repair + on-transition
    // ▲REV2 (Codex #1,#2): append evidence to the SINGLE globally-active session, opening it if none
    // is open for THIS app (the caller has already closed a prior different-app session via
    // closeActiveSession on transition, and has already discarded stale-generation captures). One
    // write txn: ensure an open session for appBundle exists (open if not), append evidence snapshot,
    // bump last_activity_at (even on coalesced dup). Returns the session id. No SessionSegmenter call
    // here — segmentation is the AppWiring focus-generation policy (Task 3); Store just persists.
    public func recordActivityCapture(appBundle: String, appLabel: String, versionID: String?,
                                      content: String, nowMs: EpochMs) throws -> String
    public func closeActiveSession(nowMs: EpochMs) throws        // close the one open session on app transition
    public func closeSession(_ id: String, nowMs: EpochMs) throws
    public func closeIdleSessions(idleGapMs: EpochMs, nowMs: EpochMs) throws -> [String]  // ▲REV #2: idle finalize; returns closed ids
    public func closeOpenSessions(nowMs: EpochMs) throws                       // ▲REV #2: startup crash-repair for sessions too
    // Summary + retry (▲REV #3: failed sessions must retry)
    public func setSessionSummary(_ id: String, summary: String, expectedSourceHash: String,
                                  modelID: String, promptVersion: String, nowMs: EpochMs) throws -> Bool // false = stale (no-op)
    public func markSessionSummaryFailed(_ id: String, error: String, nowMs: EpochMs) throws  // bumps attempts + backoff
    public func sessionSourceHash(_ id: String) throws -> String
    public func sessionsNeedingSummary(nowMs: EpochMs, limit: Int) throws -> [ActivitySession] // closed + (pending OR failed-and-due)
    // Queries
    public func recentSessions(limit: Int) throws -> [ActivitySession]
    public func sessionEvidence(_ id: String) throws -> [String]              // decrypted snapshots (expand-to-detail)
    // Settings + Privacy (▲REV2: tri-state consent separate from enable)
    public func activityConsent() throws -> ActivityConsent    // .unset | .granted | .declined
    public func setActivityConsent(_ c: ActivityConsent) throws
    public func activityEnabled() throws -> Bool; public func setActivityEnabled(_ on: Bool) throws
    public func activityExcludedApps() throws -> Set<String>; public func setActivityExcluded(_ bundle: String, _ excluded: Bool) throws
    public func deleteActivityForApp(_ appBundle: String) throws              // cascade visits/sessions/evidence
    public static func dayBucket(forMs ms: EpochMs, timeZone: TimeZone) -> Int64  // shared local-day helper
}
public enum ActivityConsent: String, Sendable { case unset, granted, declined }
```
`activity_sessions` also gets `summary_attempts INTEGER DEFAULT 0` + `summary_next_attempt_at INTEGER` (add to the v4 DDL — for summary retry/backoff).

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
        let s = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "did a thing", nowMs: t0)
        let s2 = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "did a thing", nowMs: t0+1000) // dup -> coalesced, same session
        XCTAssertEqual(s, s2)
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT content_ciphertext FROM activity_session_evidence WHERE session_id=?", arguments: [s])
            XCTAssertEqual(rows.count, 1, "duplicate content coalesced")
            XCTAssertTrue((rows[0]["content_ciphertext"] as String).hasPrefix("enc:v1:"))
        }
        XCTAssertEqual(try store.sessionEvidence(s), ["did a thing"])
    }
    func testCloseAndSummarizeWithStaleGuard() throws {
        let s = try store.recordActivityCapture(appBundle: "com.x", appLabel: "X", versionID: nil, content: "wrote the parser", nowMs: t0)
        try store.closeSession(s, nowMs: t0+60_000)
        let h = try store.sessionSourceHash(s)
        XCTAssertTrue(try store.setSessionSummary(s, summary: "Worked on the parser", expectedSourceHash: h, modelID: "gemini-2.5-flash-lite", promptVersion: "v1", nowMs: t0+61_000))
        XCTAssertFalse(try store.setSessionSummary(s, summary: "stale", expectedSourceHash: "WRONGHASH", modelID: "m", promptVersion: "v1", nowMs: t0+62_000), "stale hash must no-op")
        let recent = try store.recentSessions(limit: 10)
        XCTAssertEqual(recent.first?.summary, "Worked on the parser")
        XCTAssertEqual(recent.first?.summaryStatus, "summarized")
    }
    func testDeleteActivityForAppCascades() throws {
        let s = try store.recordActivityCapture(appBundle: "com.secret", appLabel: "S", versionID: nil, content: "x", nowMs: t0)
        try store.closeActiveSession(nowMs: t0+1)
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
- [ ] **Step 8: Implement ActivityStore.swift.** `recordActivityCapture` (one `db.dbQueue.write`): find THE single open session (`ended_at IS NULL`); if it exists and is this app → reuse; if it exists and is a DIFFERENT app → (shouldn't happen — AppWiring calls `closeActiveSession` on transition — but defensively close it) then open new; if none → insert provisional (uuidv7, `dayBucket`, status 'pending'). Then `INSERT OR IGNORE` evidence (`ContentHash.sha256Hex(content)`, encrypted via `cipher.encrypt`) and **bump `last_activity_at` even when coalesced** (same txn). Return session id. `closeActiveSession`: set ended_at on the one open session. `closeIdleSessions`: close open sessions with `last_activity_at < now - idleGapMs` → return closed ids. `closeOpenSessions`/`closeOpenVisits`: startup crash-repair. `setSessionSummary`: recompute source hash in-txn, **return false (no-op) if != expectedSourceHash**, else encrypt+store 'summarized'. `markSessionSummaryFailed`: 'failed', `summary_attempts+1`, `summary_next_attempt_at = now + backoff`. `sessionsNeedingSummary`: `ended_at IS NOT NULL AND (summary_status='pending' OR (summary_status='failed' AND summary_next_attempt_at<=now))`. `sessionSourceHash`: hash sorted evidence content_hashes. Consent/enabled/excluded via `settings`. `dayBucket`: local-calendar day from a documented TimeZone. `deleteActivityForApp`: delete sessions+visits (evidence cascades). Uses `SessionSegmenter` from MaxMiCore only if needed (segmentation policy lives in AppWiring, Task 3).
- [ ] **Step 9: Run — PASS.** Full suite green.
- [ ] **Step 10: Commit** `feat(store): v4 activity tables + FK enforcement + ActivityStore (sessions + immutable evidence)`

---

### Task 2: SessionSegmenter (deterministic finalization policy) — ▲REV2: BUILD THIS FIRST (before Task 1), IN MaxMiCore

**▲REV2 (Codex #1): execution order is 2→1** — SessionSegmenter is a pure function that ActivityStore (Task 1) and AppWiring (Task 3) both use, and `MaxMiStore` must not depend on `MaxMiActivity`. So put `SessionSegmenter` in **MaxMiCore** and implement it before Task 1.

**Files:** Create `Sources/MaxMiCore/SessionSegmenter.swift` (in MaxMiCore — no new module needed for it); Create `Tests/MaxMiCoreTests/SessionSegmenterTests.swift`. (The `MaxMiActivity` module is still added later in Task 4 for the summarizer.)

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
- [ ] **Step 1: (No new module — SessionSegmenter goes in the existing MaxMiCore target.)**
- [ ] **Step 2: Failing tests** (in `Tests/MaxMiCoreTests/SessionSegmenterTests.swift`, `@testable import MaxMiCore`) — same app within gap → no close/open (continue); different app → close+open; same app after gap → close+open (new session); no open session → open only. 
```swift
import XCTest; @testable import MaxMiCore
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
- [ ] **Step 2: Wire in AppWiring — the focus-generation mechanism (▲REV3 — Codex #2, spelled out explicitly; this IS the correctness core, not optional):**
  1. AppWiring holds `var focusGeneration: Int = 0` (@MainActor).
  2. On **every** focus transition (`onFocusChanged`): `focusGeneration += 1`; immediately `store.closeActiveSession(nowMs:)` + close the prior visit; then, if the NEW app is eligible (activity `consent==.granted && enabled`, not sensitive, not excluded) open a new visit. Do NOT open a session here.
  3. In `captureFrontmost`/`attemptCapture`, **capture `let gen = focusGeneration`** and thread it through `Task.detached` → `finishCapture(..., captureGeneration: gen)`.
  4. In `finishCapture`, after the normal capture `.committed` write (which is unconditional, unchanged): **only if `captureGeneration == focusGeneration`** AND the app is eligible, call `store.recordActivityCapture(appBundle: capApp.bundle, appLabel: capApp.label, versionID: vid, content: parsed.content, nowMs:)` (opens the session on first valid capture of the span, appends evidence).
  5. On **mismatch** (`captureGeneration != focusGeneration` — focus moved during the async capture): **discard only the activity evidence** (skip `recordActivityCapture`); the normal memory capture still committed. This kills the late-app-A-after-switch-to-B race.
  6. **Idle finalize + summary** on the 30s sweep: `store.closeIdleSessions(idleGapMs:5min, nowMs:)` then (Task 4) summarize. **Startup crash-repair:** `closeOpenVisits` + `closeOpenSessions`. **Sleep/lock** (`NSWorkspace.willSleepNotification`, screen-lock): close open visit + `closeActiveSession`.
- [ ] **Step 3: MANDATORY race test (▲REV3 — Codex, not "if feasible").** Unit-test the attribution rule with a seam: start a capture under `gen=N`, advance `focusGeneration` to `N+1` before the capture completes, assert the normal memory capture DID commit (a version exists) but NO activity session/evidence was written (mismatch discarded). Structure `finishCapture`'s activity-gate as a testable pure check `shouldRecordActivity(captureGen:currentGen:eligible:) -> Bool` if AppWiring itself is untestable glue. Build clean; full suite green.
- [ ] **Step 4: Commit** `feat(activity): FocusObserver onFocusChanged -> visits/sessions/evidence wiring`

---

### Task 4: DisplaySummarizer (Gemini summary of closed sessions)

**Files:** Create `Sources/MaxMiActivity/ActivityGenerationRelay.swift`, `Sources/MaxMiActivity/DisplaySummarizer.swift`, `Sources/MaxMiActivity/AgentPrompts.swift`; Create `Tests/MaxMiActivityTests/DisplaySummarizerTests.swift`; wire the run loop in AppWiring.

**▲REV (Codex #4,#5): add the `MaxMiActivity` target here (deps MaxMiCore only) in this task. MaxMiActivity must NOT depend on `Store` (module cycle/Sendability). It works over protocols; the app target provides the concrete impls.**

**Interfaces:**
```swift
// In MaxMiActivity (deps MaxMiCore only):
public struct PendingSession: Sendable { public let id, appLabel: String; public let evidence: [String]; public let expectedSourceHash: String }
public protocol ActivitySummaryRepository: Sendable {   // implemented in the app target over Store
    func sessionsNeedingSummary(nowMs: EpochMs) async -> [PendingSession]
    func saveSummary(sessionID: String, summary: String, expectedSourceHash: String, nowMs: EpochMs) async
    func markFailed(sessionID: String, error: String, nowMs: EpochMs) async
}
public protocol ActivityGenerationRelay: Sendable {
    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String
}
public struct DisplaySummarizer: Sendable {
    public init(repo: any ActivitySummaryRepository, relay: any ActivityGenerationRelay,
                maxEvidenceChars: Int = 12_000)
    public func summarizeDue(nowMs: EpochMs) async   // closed+pending OR failed-and-due; stale hash -> no-op
}
```
- [ ] **Step 1: Add the Gemini generation + throttle (concrete, must-fix #4).** In the relay layer (MaxMiRelay/wherever `GeminiClient` lives): add a generic `generateContent(model:prompt:)` for the pinned `gemini-2.5-flash-lite`, and a shared **rate-limiter/backoff actor** used by extraction + embedding + activity summarization (RPM/TPM/RPD-aware, 429 exponential backoff+jitter). Tests: URLProtocol mock for a normal response + a 429 (asserts backoff/retry). Commit this as its own step before the summarizer.
- [ ] **Step 2: Failing DisplaySummarizerTests** — a `MockRepo` (returns 1 pending session w/ evidence + expectedHash) + `MockRelay` (returns "Worked on X"): `summarizeDue` → repo.saveSummary called with "Worked on X" + the expected hash; a relay-throwing case → repo.markFailed called (not crash); a still-open session isn't returned by the repo so isn't summarized. **Delimit untrusted captured text** in the prompt (screen content can't override instructions) — assert the prompt wraps evidence in a fenced/labeled block.
- [ ] **Step 3: Run — FAIL. Step 4: Implement** DisplaySummarizer over the protocols + AgentPrompts (rewrite-for-display, evidence fenced as untrusted data, bounded to maxEvidenceChars).
- [ ] **Step 5: App-target impls + wiring** — `StoreActivitySummaryRepository` (over Store, `@unchecked Sendable` like the existing StoreAdapter) + `GeminiActivityRelay` (over the generation API from Step 1). Run `summarizeDue` on the 30s sweep, gated on activity-enabled + consent.
- [ ] **Step 6: Run — PASS; build; full suite green. Step 7: Commit** `feat(activity): DisplaySummarizer over repo/relay protocols + Gemini generation + shared throttle`

---

### Task 5: Dog logo (app icon + tray template)

**Files:** Create `packaging/assets/dog.svg`, generate `packaging/assets/AppIcon.iconset/` PNGs + `icon.icns`, `packaging/assets/tray/tray-default-{light,dark}.png` (template); Modify `packaging/make-app.sh`.

- [ ] **Step 1: Author `packaging/assets/dog.svg`** — a minimalist **white dog silhouette** (simple sitting/lying profile, same weight as Minimi's cat) on transparent bg. Hand-authored vector path (crisp), NOT an AI raster. Also a black-squircle-background variant for the app icon.
- [ ] **Step 2: Generate iconset + icns (▲REV — exact filenames, deterministic).** Render the dog-on-black-squircle SVG to a **1024×1024 master PNG** (prefer `rsvg-convert -w 1024 -h 1024`; if unavailable, `sips` from a checked-in 1024 master PNG — NOT `qlmanage`, unreliable). Then produce EXACTLY these iconset files with `sips -z <h> <w>`:
```
AppIcon.iconset/icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png
icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png
icon_512x512.png icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o icon.icns
```
**Check the generated `icon.icns` (and the 1024 master PNG) INTO the repo** so the build is reproducible without the render tool. Document the tool used in the commit.
- [ ] **Step 3: Tray template PNGs** — white dog silhouette on transparent, 16pt @1x/@2x, saved as template (the app sets `NSImage.isTemplate=true` in Task 7).
- [ ] **Step 4: make-app.sh** — `cp packaging/assets/icon.icns "$APP/Contents/Resources/icon.icns"` + set **`CFBundleIconFile` = `icon`** in Info.plist (▲REV: do NOT add `CFBundleIconName` — that needs an asset catalog we don't have). Copy tray PNGs into Resources with **known filenames** and load them in Task 7 via `Bundle.main.url(forResource:)`, NOT `NSImage(named:)` (▲REV: named-lookup isn't guaranteed for copied PNGs).
- [ ] **Step 5: Build the app** (`./packaging/make-app.sh`), confirm `icon.icns` present + the app shows the dog in Finder. **Commit** `feat(brand): MaxMi dog app icon + template tray icon (Minimi-style, black squircle)`

---

### Task 6: SwiftUI Theme + ActivityViewModel + ActivityView

**Files:** add `MaxMiUI` target (deps **MaxMiCore only** — ▲REV #5: NOT MaxMiStore; UI takes a Sendable DTO) to Package.swift; Create `Sources/MaxMiUI/Theme.swift`, `Sources/MaxMiUI/ActivityViewModel.swift`, `Sources/MaxMiUI/ActivityView.swift`; Create `Tests/MaxMiUITests/ActivityViewModelTests.swift`.

**Interfaces (▲REV — plain DTO boundary, no Store dependency):**
```swift
public struct TimelineSessionDTO: Identifiable, Sendable {   // the app target builds these from ActivitySession
    public let id, appLabel: String; public let summary: String?; public let startedAtMs: Int64
    public let evidence: [String]        // for expand/"why am I seeing this"
}
public struct SessionRow: Identifiable, Sendable {           // precomputed for the view (no decrypt/format in body)
    public let id, appLabel, timeAgo, dayGroup: String; public let summary: String; public let evidence: [String]
}
@MainActor @Observable public final class ActivityViewModel {
    public private(set) var groups: [(day: String, rows: [SessionRow])]
    public init(load: @escaping @Sendable () async -> [TimelineSessionDTO], now: @escaping () -> Int64)
    public func refresh() async
}
```
- [ ] **Step 1: Package.swift** — add MaxMiUI target + test target.
- [ ] **Step 2: Failing ViewModelTests** — inject a `load` returning synthetic `TimelineSessionDTO`s across two days; `refresh()`; assert `groups` has "Today"/"Yesterday", timeAgo ("20m ago"), newest first, and a nil-summary DTO renders a neutral fallback row (not crash). (Pure — no SwiftUI.)
- [ ] **Step 3: Run — FAIL. Step 4: Implement** Theme (dark tokens), ActivityViewModel (DTO→rows: group by local day, relative-time — all precomputed), ActivityView (SwiftUI `List`/`LazyVStack` sectioned by day; row = app glyph + summary + timeAgo; **tap expands to show `evidence` / "Why am I seeing this?"** — ▲REV, the provenance UI the spec promised; `.animation(.spring, value:)`; always-dark Theme; empty state). **M6a shows Activity only; Action Items tab shows "Coming soon" (M6b)** — ▲REV. ActivityView compile-checked; ViewModel tested.
- [ ] **Step 5: Run — PASS; build; full suite green. Step 6: Commit** `feat(ui): SwiftUI activity timeline (Theme + @Observable view model + view)`

---

### Task 7: ActivityWindow + dog menu-bar + privacy sheet + wiring

**Files:** Create `Sources/MaxMi/ActivityWindow.swift`, `Sources/MaxMi/ActivityPrivacySheet.swift`; Modify `Sources/MaxMi/MenuBarController.swift`, `Sources/MaxMi/AppWiring.swift`.

- [ ] **Step 1: ActivityWindow** — a retained manager owning a closable `NSWindow` hosting `NSHostingController(rootView: ActivityView(viewModel:))`; `show()` = `NSApp.activate(ignoringOtherApps:true)` + `makeKeyAndOrderFront`; refreshes the view model on show.
- [ ] **Step 2: MenuBarController (▲REV — correct click handling)** — set status button image from the dog tray PNG via `Bundle.main.url(forResource:)` → `NSImage` → `isTemplate=true`. **Set `statusItem.menu = nil`**, install a target/action on `statusItem.button` with `sendAction(on: [.leftMouseUp, .rightMouseUp])`; in the handler branch on `NSApp.currentEvent?.type`: left → `ActivityWindow.show()`, right → `statusItem.popUpMenu(statusMenu)`. Menu has "Open MaxMi", "Activity Privacy…", plus the existing pause items.
- [ ] **Step 3: ActivityPrivacySheet (▲REV — needs a host window)** — a **retained privacy-window presenter** (a small `NSWindow`+`NSHostingController`, since a SwiftUI `.sheet` can't present without a host in a menu-bar `.accessory` app). Content: Gemini-consent disclosure + global "Enable activity synthesis" toggle (writes `activityEnabled`) + per-app exclusion list (writes `activityExcludedApps`; excluding calls `store.deleteActivityForApp`). Shown before first synthesis (consent unset) or via the menu item.
- [ ] **Step 4: Wire in AppWiring** — construct ActivityWindow with a view model whose `load` = `store.recentSessions`; gate all activity capture (Task 3) + summarization (Task 4) on the global-enable setting + consent. First run with consent unset → show the privacy sheet before any synthesis.
- [ ] **Step 5: Build clean; full suite green. Step 6: Commit** `feat(ui): Activity window + dog menu-bar (left-open/right-menu) + activity privacy sheet`

---

### Task 8: Live verification (controller/human — closes M6a)

**Files:** none. Do NOT run as a subagent.

- [ ] **Step 1: Rebuild + relaunch** (grant persists): `./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"; sleep 2; open MaxMi.app`. Confirm the **dog icon** in the menu bar + Finder.
- [ ] **Step 2: Consent + privacy** — on first run the Activity Privacy sheet appears; enable synthesis; exclude one app and confirm no rows appear for it.
- [ ] **Step 3: Generate activity** — use several apps (Cursor, Chrome, Slack) for a few minutes each with gaps between. A session summary needs the session to CLOSE (app switch or 5-min idle) THEN the 30s sweep + a Gemini round-trip — so **wait/poll** (up to ~2 min) before expecting summaries, don't check instantly.
- [ ] **Step 4: Open the window** — left-click the dog → Activity window opens showing a timeline grouped by Today, rows like "Cursor · <summary> · Xm ago"; smooth scroll/animation; tap a row → evidence/"why am I seeing this"; right-click → menu. Poll until summarized:
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -header -column "$DB" "SELECT app_label, summary_status, (ended_at IS NOT NULL) AS closed, datetime(started_at/1000,'unixepoch','localtime') FROM activity_sessions ORDER BY started_at DESC LIMIT 8;"
sqlite3 "$DB" "SELECT substr(content_ciphertext,1,10) FROM activity_session_evidence LIMIT 2;"  # enc:v1:
```
- [ ] **Step 5: Privacy — three assertions (▲REV):** (a) with an app **excluded**, use it → NO new visits/sessions/evidence for it appear; (b) **global-disable** → no new activity rows for ANY app; (c) exclude an app that already has sessions → its `activity_sessions`+evidence rows are cascade-deleted.
- [ ] **Step 6: Declare M6a complete** when 1-5 hold. Then M6b (agent) + M6c (settings/polish).

---

## Self-Review (at plan-writing time)
**Spec coverage:** §8 schema+FK+cascade → T1; deterministic lifecycle (provisional open/evidence/close) → T1+T2+T3; FocusObserver onFocusChanged + sensitive/excluded skip + crash-repair → T3; Gemini summary of closed sessions only, pinned model, consent-gated → T4; dog logo → T5; SwiftUI always-dark timeline, stable IDs, no-decrypt-in-body → T6; window left-open/right-menu + privacy sheet (M6a) → T7; exit criteria → T8. Privacy controls in M6a (not deferred) → T7. Encrypted evidence/summary → T1.
**Placeholders:** T5 flags the icon-render tool as environment-dependent (rsvg vs sips) — genuine, documented. Everything else concrete.
**Type consistency:** `ActivitySession`/`SessionRow` fields consistent T1↔T6; `ActivityGenerationRelay.summarizeSession` used T4; `SessionSegmenter.decide` T2↔T3; store methods (recordActivityCapture/closeActiveSession/closeIdleSessions/closeOpenSessions/setSessionSummary(expectedSourceHash:)/markSessionSummaryFailed/sessionsNeedingSummary/recentSessions/sessionEvidence/consent+enabled+excluded/deleteActivityForApp) consistent across T2(store)/T3/T4/T7; SessionSegmenter in MaxMiCore used by store+AppWiring; MaxMiActivity over repo/relay protocols; MaxMiUI over TimelineSessionDTO.
