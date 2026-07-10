# MaxMi M6b Implementation Plan — Hourly Agent + Action Items

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Ship M6b — a durable-cursor hourly agent that reviews new activity and surfaces/updates **action items** (open/resolved/dismissed), plus the Action Items inbox in the Activity window — per the M6 spec (`docs/superpowers/specs/2026-07-11-maxmi-m6-activity-agent-ui-design.md`, agent design in §2, Codex-approved) and building on M6a's v4 tables (agent_runs/agent_action_items/agent_action_item_events already exist).

**Architecture:** `AgentStore` (Store extension) owns the durable cursor (agent_runs.input_from/to) + action-item ID-op transitions + events audit. `HourlyAgent` (in MaxMiActivity, over a repo + generation-relay protocol like DisplaySummarizer) reviews activity-session summaries committed since the last cursor, calls Gemini with structured-output ID-ops (create/update/resolve), applies them transactionally: never-resolve-on-absence, dismissal-terminal, bounded input + backfill. Idle-gated + hourly-fallback trigger via NSBackgroundActivityScheduler + launch/foreground catch-up. Action Items tab in the existing SwiftUI ActivityView becomes real.

**Tech Stack:** Swift 6, GRDB, MaxMiActivity (protocols), Gemini generateContent (structured output) + shared GeminiThrottle, SwiftUI, NSBackgroundActivityScheduler.

## Global Constraints
- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings; keep the 294 baseline green.
- **▲REV (Codex plan-review #1 — 3 must-fixes baked in):**
  - **Keyset cursor tuple, never skip on backfill:** the cursor is `(updated_at, session_id)`, NOT a bare timestamp. Paging query orders by `(updated_at ASC, id ASC)` with predicate `updated_at > :curAt OR (updated_at = :curAt AND id > :curID)`; the run commits the cursor tuple of the **last INCLUDED row**, never `now`. So 500 offline sessions across 50-row pages process fully in 10 runs with no skip/dup. (v5 migration adds `agent_runs.input_to_at` + `input_to_session_id`.)
  - **Run lease (claim before Gemini):** `claimNextAgentRun` inserts a `running` row + a `lease_expires_at` and returns the page + cursor BEFORE any Gemini call; the network call happens with NO open SQLite txn; `completeAgentRun(runID:ops:)` applies ops + advances cursor only if the run is still `running`; stale `running` rows past their lease are recovered at claim time. Only one active lease. A crash mid-request leaves a durable `running` row that's reclaimed, not a lost window.
  - **Run + create idempotency:** `completeAgentRun` no-ops unless `status='running'` (conditional UPDATE); each create carries an idempotency key `(runID, opIndex)` stored in a UNIQUE index so a recovered/retried run can't duplicate items.
- Gemini ID-ops: model given open items with opaque IDs, returns create/update(id)/resolve(id,evidence) via structured output + strict local schema validation; unknown IDs rejected; applied transactionally.
- **Never resolve on absence** (only affirmative evidence resolves); **dismissal is terminal** (agent can't reopen); bounded input (token/session cap) + backfill batches (a week offline ≠ one giant prompt).
- Action-item title/details/resolution_evidence encrypted at rest (already `_ciphertext` columns). source_refs JSON provenance. Events audit each change.
- Trigger: idle-gated + threshold + hourly fallback (NSBackgroundActivityScheduler advisory + run-on-launch/foreground-when-overdue). Gated on activity consent==.granted && enabled.
- Reuse M6a: DisplaySummarizer's repo/relay protocol pattern, GeminiThrottle.shared, the ActivityView Action Items tab (currently "coming soon").
- Commit conventional; NO Co-Authored-By/AI trailers. Branch `m6-agent` off main.

## File Structure
```
Sources/MaxMiStore/AgentStore.swift            NEW: cursor (last run window), action-item ID-op transitions, events
Sources/MaxMiActivity/HourlyAgent.swift         NEW: review logic over AgentRepository + AgentGenerationRelay protocols
Sources/MaxMiActivity/AgentPrompts.swift        MODIFY: add hourly-review prompt (structured ID-ops, fenced input)
Sources/MaxMi/StoreAgentRepository.swift        NEW: app-target AgentRepository over Store (@unchecked Sendable)
Sources/MaxMi/GeminiAgentRelay.swift            NEW: app-target relay: generateContent -> validated ops
Sources/MaxMi/AppWiring.swift                   MODIFY: schedule HourlyAgent (idle+hourly), gate on consent+enabled
Sources/MaxMiUI/ActionItemsView.swift           NEW: SwiftUI inbox (open/resolved/dismissed + resolve/dismiss)
Sources/MaxMiUI/ActivityView.swift              MODIFY: wire the real Action Items tab
Sources/MaxMiUI/ActionItemsViewModel.swift      NEW: @MainActor @Observable over an ActionItemDTO
Tests/MaxMiStoreTests/AgentStoreTests.swift      NEW
Tests/MaxMiActivityTests/HourlyAgentTests.swift  NEW
Tests/MaxMiUITests/ActionItemsViewModelTests.swift NEW
```

Task order: 1 AgentStore (cursor + item ops) → 2 HourlyAgent (review logic + prompt) → 3 app-target repo/relay + AppWiring scheduling → 4 Action Items SwiftUI inbox → 5 live verify.

---

### Task 1: AgentStore (durable cursor + action-item ID-ops + events)

**Files:** Modify `Sources/MaxMiStore/Migrations.swift` (v5 — cursor tuple + lease + idempotency); Create `Sources/MaxMiStore/AgentStore.swift`, `Tests/MaxMiStoreTests/AgentStoreTests.swift`.

**v5 migration (additive):**
```sql
ALTER TABLE agent_runs ADD COLUMN input_to_at INTEGER;          -- cursor tuple: last-included updated_at (persisted AT CLAIM)
ALTER TABLE agent_runs ADD COLUMN input_to_session_id TEXT;      -- cursor tuple: last-included session id (persisted AT CLAIM)
ALTER TABLE agent_runs ADD COLUMN lease_expires_at INTEGER;      -- for stale-running recovery
ALTER TABLE agent_action_items ADD COLUMN idem_key TEXT;         -- (runID:opIndex) create idempotency
CREATE UNIQUE INDEX idx_items_idem ON agent_action_items(idem_key) WHERE idem_key IS NOT NULL;
-- ▲REV2 (Codex must-fix #2): at most ONE unexpired running lease, enforced at the DB level.
CREATE UNIQUE INDEX idx_one_running ON agent_runs(status) WHERE status='running';
```

**Interfaces (▲REV — lease flow, keyset cursor, idempotency):**
```swift
public struct ActionItem: Sendable {
    public let id, kind, status, title: String; public let details: String?
    public let sourceRefs: [String]; public let detectedAtMs, updatedAtMs: EpochMs; public let resolvedAtMs: EpochMs?
}
public struct SessionCursor: Sendable, Equatable { public let atMs: EpochMs; public let sessionID: String }
public struct AgentPage: Sendable {                 // returned by claim, fed to the model
    public let runID: String
    public let summaries: [String]                  // this page's session summaries (decrypted)
    public let sourceIDs: [String]                  // the session ids in this page (valid source_refs)
    public let openItems: [(id: String, title: String)]
    // (the page's cursor tuple is persisted into the run row at claim — not passed back to completeAgentRun)
}
public enum AgentOp: Sendable {
    case create(kind: String, title: String, details: String?, sourceRefs: [String])
    case update(id: String, title: String?, details: String?)
    case resolve(id: String, evidence: String)
}
public struct AgentRunResult: Sendable { public let newCount, resolvedCount, updatedCount: Int }
extension Store {
    // Claim a run BEFORE Gemini: recover stale 'running' leases; if new sessions exist beyond the last
    // completed cursor, insert a 'running' agent_runs row w/ lease, return the page (keyset-paged,
    // maxSessions) + its advanceTo cursor tuple. nil if nothing new. Holds NO txn over the later network call.
    // ▲REV2: recovers expired leases; returns nil if an UNEXPIRED running lease exists (single-lease,
    // DB-enforced by idx_one_running); else atomically inserts a 'running' row that PERSISTS the page's
    // (input_to_at, input_to_session_id) cursor tuple AT CLAIM. The tuple only takes effect once the
    // run is 'completed'. Returns the page. Holds NO txn over the later network call.
    public func claimNextAgentRun(maxSessions: Int, leaseMs: EpochMs, nowMs: EpochMs) throws -> AgentPage?
    // ▲REV2: cursor is NOT passed in — it was persisted at claim. Reads the run's own tuple; conditional
    // on status='running' (idempotent no-op otherwise); creates keyed by (runID:opIndex) idem_key UNIQUE.
    // Ignores ops on dismissed/unknown/non-open ids; never-resolve-on-absence; source_refs ⊆ the run's page.
    public func completeAgentRun(runID: String, ops: [AgentOp], nowMs: EpochMs) throws -> AgentRunResult
    public func renewAgentRunLease(runID: String, leaseMs: EpochMs, nowMs: EpochMs) throws  // ▲REV2: extend during a slow call
    public func failAgentRun(runID: String, error: String, nowMs: EpochMs) throws     // status 'failed' (frees the lease)
    // User actions (run_id NULL events):
    public func resolveActionItem(_ id: String, nowMs: EpochMs) throws
    public func dismissActionItem(_ id: String, nowMs: EpochMs) throws     // TERMINAL
    public func actionItems(status: String, limit: Int) throws -> [ActionItem]
}
```

- [ ] **Step 1: Failing tests** — `AgentStoreTests.swift` (needs helper to seed closed activity_sessions with summaries; the tests cover Codex's required cases):
```swift
import XCTest; import GRDB; @testable import MaxMiStore; import MaxMiCore
final class AgentStoreTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws { db = try .inMemory(); store = Store(db: db, cipher: AESGCMFieldCipher.testCipher) }
    let t0 = EpochMs(497_000) * 3_600_000
    // helper: seed N closed+summarized sessions at ascending updated_at (via recordActivityCapture+closeSession+setSessionSummary)
    func seedSessions(_ n: Int) throws { /* insert activity_sessions rows summarized, updated_at t0..t0+n */ }

    func testClaimCompleteAdvancesKeysetCursorNoSkipAcrossPages() throws {
        try seedSessions(120)                       // 120 summarized sessions
        var runs = 0
        while let page = try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0 + EpochMs(runs)) {
            _ = try store.completeAgentRun(runID: page.runID, ops: [], nowMs: t0 + EpochMs(runs))
            runs += 1; if runs > 10 { break }
        }
        XCTAssertEqual(runs, 3, "120 sessions / 50 per page = 3 runs, none skipped")
        XCTAssertNil(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+999), "nothing new -> nil")
    }
    func testStaleLeaseRecovered() throws {
        try seedSessions(10)
        let p1 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 1000, nowMs: t0))
        // crash: never complete p1. After the lease expires, a new claim recovers the SAME window.
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 1000, nowMs: t0 + 5000))
        XCTAssertEqual(p1.summaries, p2.summaries, "stale lease reclaimed, window not lost")
    }
    func testCreateResolveDismissAndTerminalAndIdempotency() throws {
        try seedSessions(2)
        let p = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        let res = try store.completeAgentRun(runID: p.runID,
            ops: [.create(kind:"todo", title:"Reply to Alice", details:"re: deploy", sourceRefs: p.sourceIDs)], nowMs: t0)
        XCTAssertEqual(res.newCount, 1)
        let id = try store.actionItems(status:"open", limit:10)[0].id
        try db.dbQueue.read { d in XCTAssertTrue((try String.fetchOne(d, sql:"SELECT title_ciphertext FROM agent_action_items")!).hasPrefix("enc:v1:")) }
        // re-completing the SAME run must NOT duplicate the create (idempotency)
        let res2 = try store.completeAgentRun(runID: p.runID, ops: [.create(kind:"todo",title:"Reply to Alice",details:nil,sourceRefs:p.sourceIDs)], nowMs: t0+1)
        XCTAssertEqual(res2.newCount, 0, "already-completed run is a no-op")
        try store.dismissActionItem(id, nowMs: t0+10)
        let p2 = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+100)) // (would be nil if no new sessions; seed more if needed)
        let res3 = try store.completeAgentRun(runID: p2.runID, ops: [.resolve(id: id, evidence:"done")], nowMs: t0+100)
        XCTAssertEqual(res3.resolvedCount, 0, "dismissed is terminal")
    }
    func testNeverResolveOnAbsenceAndUnknownIgnored() throws {
        // create an item, then a run that doesn't mention it -> stays open; resolve unknown -> ignored
    }
    func testSourceRefsMustBelongToPage() throws {
        // a create with source_refs NOT in page.sourceIDs -> the invalid refs dropped (or op rejected)
    }
    func testUnexpiredLeaseBlocksSecondClaim() throws {
        try seedSessions(10)
        _ = try XCTUnwrap(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0))
        XCTAssertNil(try store.claimNextAgentRun(maxSessions: 50, leaseMs: 60_000, nowMs: t0+1), "unexpired running lease blocks a second claim")
    }
}
```
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement v5 migration + AgentStore.swift.** `claimNextAgentRun` (one write txn, NO network): recover stale — `UPDATE agent_runs SET status='failed' WHERE status='running' AND lease_expires_at < now`; if an unexpired `running` run still exists → return nil (single-lease, also DB-enforced by idx_one_running); read last COMPLETED cursor `(input_to_at, input_to_session_id)`; keyset-page activity_sessions `WHERE summary_status='summarized' AND (updated_at > curAt OR (updated_at=curAt AND id>curID)) ORDER BY updated_at,id LIMIT maxSessions`; if empty → nil; else insert a `running` run with `lease_expires_at=now+leaseMs` AND persist the page's last-row `(input_to_at, input_to_session_id)` INTO that run row (takes effect only when completed); return AgentPage(runID, decrypted summaries, sourceIDs, decrypted openItems). `completeAgentRun(runID:ops:nowMs:)` (one write txn): `guard` the run is still `status='running'` (else zero result — idempotent); read the run's OWN persisted `(input_to_at, input_to_session_id)` + its page source ids; for each op at index i — create → `INSERT ... ON CONFLICT(idem_key) DO NOTHING` with `idem_key='<runID>:<i>'`, encrypt, validate source_refs ⊆ the run's page (drop invalid) + event; update/resolve → only open items + event; then conditional `UPDATE agent_runs SET status='completed', new_count=?,... WHERE id=? AND status='running'` (the cursor tuple is ALREADY in the row from claim — completing just flips status so it becomes the effective cursor). `renewAgentRunLease`: `UPDATE ... SET lease_expires_at=now+leaseMs WHERE id=? AND status='running'`. `failAgentRun`: status='failed'. `resolveActionItem`/`dismissActionItem`: user transitions (run_id NULL event). `actionItems`: query+decrypt.
- [ ] **Step 4: Run — PASS.** Full suite green.
- [ ] **Step 5: Commit** `feat(store): AgentStore — durable cursor + action-item ID-ops (never-resolve-on-absence, dismissal-terminal)`

---

### Task 2: HourlyAgent (review logic + prompt)

**Files:** Create `Sources/MaxMiActivity/HourlyAgent.swift`; Modify `Sources/MaxMiActivity/AgentPrompts.swift`; Create `Tests/MaxMiActivityTests/HourlyAgentTests.swift`.

**Interfaces (▲REV — lease flow; over protocols, MaxMiActivity deps MaxMiCore only):**
```swift
public struct AgentLeasedPage: Sendable {   // what the repo hands the agent after claiming
    public let runID: String; public let summaries: [String]; public let sourceIDs: [String]
    public let openItems: [(id: String, title: String)]
}
public struct ReviewSession: Sendable { public let id: String; public let summary: String }
public struct AgentReviewInput: Sendable { public let sessions: [ReviewSession]; public let openItems: [(id: String, title: String)] }
public protocol AgentRepository: Sendable {
    func claimNextPage() async -> AgentLeasedPage?                        // nil = nothing new (recovers stale leases)
    func complete(runID: String, ops: [AgentOpDTO]) async     // cursor was persisted at claim
    func fail(runID: String, error: String) async
}
public struct AgentOpDTO: Sendable, Codable { public let op: String; public let id, kind, title, details, evidence: String?; public let sourceRefs: [String]? }
public protocol AgentGenerationRelay: Sendable { func reviewActivity(_ input: AgentReviewInput) async throws -> [AgentOpDTO] }
public struct HourlyAgent: Sendable {
    public init(repo: any AgentRepository, relay: any AgentGenerationRelay)
    public func runIfDue() async     // claim page (no txn held); if nil -> no-op; relay.reviewActivity; repo.complete; on throw -> repo.fail(runID). Loops while more pages remain (drains backfill), bounded per tick.
}
```
- [ ] **Step 1: Failing HourlyAgentTests** — MockRepo (first claim returns a page w/ 2 summaries+1 open item, second returns nil) + MockRelay (returns [create, resolve(open-item-id,"done")]) → repo.complete called with those ops + the page's runID/advanceTo; MockRepo(nothing new) → no complete; relay throws → repo.fail(runID) called (NOT complete). Assert AgentPrompts.hourlyReview FENCES summaries as untrusted, lists open items with ids, and instructs: only resolve with evidence / never invent resolutions / source_refs must be from the provided session ids.
- [ ] **Step 2: Run — FAIL. Step 3: Implement** HourlyAgent (`runIfDue`: loop — `claimNextPage`; nil → stop; build AgentReviewInput; `relay.reviewActivity`; `repo.complete(runID:ops:)`; catch → `repo.fail(runID:)` and stop; cap iterations per tick to bound backfill drain) + AgentPrompts.hourlyReview.
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(activity): HourlyAgent review logic over repo/relay protocols`

---

### Task 3: App-target repo/relay + AppWiring scheduling

**Files:** Create `Sources/MaxMi/StoreAgentRepository.swift`, `Sources/MaxMi/GeminiAgentRelay.swift`; Modify `Sources/MaxMi/AppWiring.swift`.

- [ ] **Step 1: StoreAgentRepository** (@unchecked Sendable over Store): `claimNextPage` = `store.claimNextAgentRun(maxSessions:50, leaseMs:120_000, nowMs:)` mapped to AgentLeasedPage; `complete` = validate/map `[AgentOpDTO]`→`[AgentOp]` (▲REV Codex should-fix: reject unknown op strings, require the right fields per op, non-empty bounded title/details/evidence, drop a create+resolve of the same new item, drop source_refs not in the page) then `store.completeAgentRun(runID:ops:)`; `fail` = `store.failAgentRun(runID:error:)`.
- [ ] **Step 2: GeminiAgentRelay** — `reviewActivity` builds AgentPrompts.hourlyReview, calls `geminiClient.generateContent(model: "gemini-2.5-flash-lite", prompt:, responseMimeType: "application/json")`, decodes `[AgentOpDTO]` with strict JSONDecoder (throw on malformed → HourlyAgent calls failRun). Uses the shared throttle (already in generateContent).
- [ ] **Step 3: AgentScheduler actor + schedule in AppWiring (▲REV2 — concrete actor + backoff).** A dedicated `actor AgentScheduler` serializes all in-process triggers (its single entry `tick()` runs `hourlyAgent.runIfDue()` and returns early if already running); cross-process/crash correctness is the DB lease (Task 1). Triggers: `NSBackgroundActivityScheduler` (~1h tolerant) + run-on-launch-if-overdue + the 30s sweep when ≥ a threshold of new summarized sessions exist. **Retry backoff:** a failed run must NOT be immediately re-attempted by the 30s sweep — the scheduler tracks a `nextRetryAt` after a failure (exponential, separate from the immediate lease-recovery path). Gate everything on consent==.granted && enabled. maxSessionsPerTick/maxPagesPerTick are explicit constants (e.g. 50 sessions/page, ≤4 pages/tick) — a large catch-up drains over several ticks, not one burst.
- [ ] **Step 4: Build clean; full suite green. Step 5: Commit** `feat(agent): Store/Gemini agent impls + idle-gated hourly scheduling`

---

### Task 4: Action Items SwiftUI inbox

**Files:** Create `Sources/MaxMiUI/ActionItemsViewModel.swift`, `Sources/MaxMiUI/ActionItemsView.swift`; Modify `Sources/MaxMiUI/ActivityView.swift`, **`Sources/MaxMi/ActivityWindow.swift`, `Sources/MaxMi/AppWiring.swift`** (▲REV2 — Codex#4: these construct/inject the ActionItemsViewModel + Store-backed load/resolve/dismiss closures; without them the tab has no view model); Create `Tests/MaxMiUITests/ActionItemsViewModelTests.swift`.

**Interfaces:**
```swift
public struct ActionItemDTO: Identifiable, Sendable { public let id, title: String; public let details: String?; public let status: String; public let timeAgo: String }
@MainActor @Observable public final class ActionItemsViewModel {
    public private(set) var open: [ActionItemDTO]; public private(set) var archived: [ActionItemDTO]
    public init(load: @escaping @Sendable () async -> (open: [ActionItemDTO], archived: [ActionItemDTO]),
                onResolve: @escaping @Sendable (String) async throws -> Void, onDismiss: @escaping @Sendable (String) async throws -> Void, now: @escaping () -> Int64)
    public func refresh() async; public func resolve(_ id: String) async; public func dismiss(_ id: String) async
}
```
▲REV (Codex should-fix): `onResolve`/`onDismiss` are `async throws`; the view model **refreshes from the store on success** (or restores the item on failure) — it does NOT optimistically animate the item away before persistence confirms.
- [ ] **Step 1: Failing ViewModelTests** — inject load returning 2 open + 1 archived; refresh → open.count==2; resolve(id) → calls onResolve + item leaves open list (animated removal); dismiss similar. Pure.
- [ ] **Step 2: Run — FAIL. Step 3: Implement** ActionItemsViewModel + ActionItemsView (SwiftUI: open list with title/details/timeAgo + resolve ✓ / dismiss ✕ buttons, spring removal animation, a segment for archived (resolved/dismissed), empty state, Theme tokens) + wire ActivityView's Action Items tab (was "coming soon") to it. App target provides the load/onResolve/onDismiss closures over Store (actionItems(status:), resolveActionItem, dismissActionItem).
- [ ] **Step 4: Run — PASS; build; full suite green. Step 5: Commit** `feat(ui): Action Items inbox (resolve/dismiss, animated) wired into the activity window`

---

### Task 5: Live verification (controller/human — closes M6b)

- [ ] **Step 1: Rebuild + relaunch** (grant persists). Use the Mac normally with activity synthesis enabled so sessions + summaries accumulate.
- [ ] **Step 2: Force/await an agent run** — either wait for the hourly/idle trigger or (dev) confirm run-on-launch-when-overdue fires; check:
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -header -column "$DB" "SELECT kind, status, new_count, resolved_count, datetime(started_at/1000,'unixepoch','localtime') FROM agent_runs ORDER BY started_at DESC LIMIT 3;"
sqlite3 -header -column "$DB" "SELECT status, count(*) FROM agent_action_items GROUP BY status;"
sqlite3 "$DB" "SELECT substr(title_ciphertext,1,10) FROM agent_action_items LIMIT 2;"  # enc:v1:
```
- [ ] **Step 3: Inbox UI** — open the Activity window → Action Items tab lists agent items; resolve one (✓) and dismiss one (✕); confirm they move to archived + persist across reopen; confirm a later agent run does NOT reopen the dismissed one.
- [ ] **Step 4: Cursor + backfill** — confirm agent_runs advances the `(input_to_at, input_to_session_id)` tuple across runs; a run with no new sessions is a no-op; and (unit-covered in Task 1) 120 sessions across 50-row pages process in 3 runs with no skip/dup.
- [ ] **Step 4b: Concurrency (unit-covered in Task 1):** unexpired-lease blocks a 2nd claim; a slow call renews the lease; completion can't advance to a cursor other than the one persisted at claim; two racing triggers → exactly one run.
- [ ] **Step 5: Declare M6b complete** when 1-4 hold. Then M6c (settings + final polish).

## Self-Review (at plan-writing time)
**Spec coverage:** agent design §2 (durable cursor, ID-ops, never-resolve-on-absence, dismissal-terminal, bounded/backfill, idle+hourly trigger) → T1(store)+T2(logic)+T3(schedule); action-item encryption + events → T1; inbox UI → T4; exit → T5. Reuses M6a v4 tables (no new migration) + DisplaySummarizer's protocol pattern + GeminiThrottle.
**Placeholders:** none — AgentOp/AgentOpDTO/ActionItem signatures concrete; the one judgment (backfill batch size) has a default (maxSessions:50).
**Type consistency:** AgentOp (store) ↔ AgentOpDTO (relay, Codable) mapped in T3; ActionItem (store) → ActionItemDTO (UI) in T4; AgentRepository/AgentGenerationRelay used T2↔T3; cursor methods T1↔T3.
