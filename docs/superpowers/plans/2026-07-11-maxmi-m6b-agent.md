# MaxMi M6b Implementation Plan — Hourly Agent + Action Items

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Ship M6b — a durable-cursor hourly agent that reviews new activity and surfaces/updates **action items** (open/resolved/dismissed), plus the Action Items inbox in the Activity window — per the M6 spec (`docs/superpowers/specs/2026-07-11-maxmi-m6-activity-agent-ui-design.md`, agent design in §2, Codex-approved) and building on M6a's v4 tables (agent_runs/agent_action_items/agent_action_item_events already exist).

**Architecture:** `AgentStore` (Store extension) owns the durable cursor (agent_runs.input_from/to) + action-item ID-op transitions + events audit. `HourlyAgent` (in MaxMiActivity, over a repo + generation-relay protocol like DisplaySummarizer) reviews activity-session summaries committed since the last cursor, calls Gemini with structured-output ID-ops (create/update/resolve), applies them transactionally: never-resolve-on-absence, dismissal-terminal, bounded input + backfill. Idle-gated + hourly-fallback trigger via NSBackgroundActivityScheduler + launch/foreground catch-up. Action Items tab in the existing SwiftUI ActivityView becomes real.

**Tech Stack:** Swift 6, GRDB, MaxMiActivity (protocols), Gemini generateContent (structured output) + shared GeminiThrottle, SwiftUI, NSBackgroundActivityScheduler.

## Global Constraints
- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings; keep the 294 baseline green.
- Cursor is source of truth (agent_runs.input_from/input_to = committed_at window); advance ONLY after the run's transaction commits. Serialized (one actor/lease) — no concurrent runs.
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

**Files:** Create `Sources/MaxMiStore/AgentStore.swift`, `Tests/MaxMiStoreTests/AgentStoreTests.swift`.

**Interfaces:**
```swift
public struct ActionItem: Sendable {
    public let id, kind, status, title: String; public let details: String?
    public let sourceRefs: [String]; public let detectedAtMs: EpochMs; public let updatedAtMs: EpochMs
    public let resolvedAtMs: EpochMs?
}
public enum AgentOp: Sendable {                         // what the model returns (validated)
    case create(kind: String, title: String, details: String?, sourceRefs: [String])
    case update(id: String, title: String?, details: String?)
    case resolve(id: String, evidence: String)
}
public struct AgentRunResult: Sendable { public let newCount, resolvedCount, updatedCount: Int }
extension Store {
    public func lastAgentCursor() throws -> EpochMs?                 // input_to of the last completed run (nil = none)
    public func beginAgentRun(kind: String, inputFrom: EpochMs?, inputTo: EpochMs, nowMs: EpochMs) throws -> String  // run id, status 'running'
    public func openActionItems(limit: Int) throws -> [ActionItem]   // decrypted, for feeding the model
    // Apply validated ops in ONE txn: create/update/resolve; ignore ops on dismissed items (terminal);
    // ignore unknown ids; write events; finalize the run row (status completed + counts + item-id arrays).
    public func applyAgentOps(runID: String, ops: [AgentOp], nowMs: EpochMs) throws -> AgentRunResult
    public func failAgentRun(_ runID: String, error: String, nowMs: EpochMs) throws
    // User actions (from the UI):
    public func resolveActionItem(_ id: String, nowMs: EpochMs) throws     // user-resolved
    public func dismissActionItem(_ id: String, nowMs: EpochMs) throws     // TERMINAL
    public func actionItems(status: String, limit: Int) throws -> [ActionItem]   // for the inbox
}
```

- [ ] **Step 1: Failing tests** — `AgentStoreTests.swift`:
```swift
import XCTest; import GRDB; @testable import MaxMiStore; import MaxMiCore
final class AgentStoreTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws { db = try .inMemory(); store = Store(db: db, cipher: AESGCMFieldCipher.testCipher) }
    let t0 = EpochMs(497_000) * 3_600_000
    func testCursorAdvancesOnlyOnCompletedRun() throws {
        XCTAssertNil(try store.lastAgentCursor())
        let r = try store.beginAgentRun(kind: "hourly", inputFrom: nil, inputTo: t0, nowMs: t0)
        XCTAssertNil(try store.lastAgentCursor(), "running run doesn't advance cursor")
        _ = try store.applyAgentOps(runID: r, ops: [], nowMs: t0+1)
        XCTAssertEqual(try store.lastAgentCursor(), t0, "completed run advances cursor")
    }
    func testCreateAndResolveAndDismiss() throws {
        let r = try store.beginAgentRun(kind: "hourly", inputFrom: nil, inputTo: t0, nowMs: t0)
        let res = try store.applyAgentOps(runID: r, ops: [
            .create(kind: "todo", title: "Reply to Alice", details: "re: deploy", sourceRefs: ["v1"])], nowMs: t0)
        XCTAssertEqual(res.newCount, 1)
        let items = try store.actionItems(status: "open", limit: 10)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].title, "Reply to Alice")
        // title encrypted at rest
        try db.dbQueue.read { d in
            XCTAssertTrue((try String.fetchOne(d, sql: "SELECT title_ciphertext FROM agent_action_items")!).hasPrefix("enc:v1:")) }
        let id = items[0].id
        try store.dismissActionItem(id, nowMs: t0+10)
        // a later agent resolve op on a DISMISSED item is IGNORED (terminal)
        let r2 = try store.beginAgentRun(kind: "hourly", inputFrom: t0, inputTo: t0+100, nowMs: t0+100)
        let res2 = try store.applyAgentOps(runID: r2, ops: [.resolve(id: id, evidence: "done")], nowMs: t0+100)
        XCTAssertEqual(res2.resolvedCount, 0, "dismissed item is terminal — resolve ignored")
        XCTAssertEqual(try store.actionItems(status: "dismissed", limit: 10).count, 1)
    }
    func testUnknownIdOpIgnored() throws {
        let r = try store.beginAgentRun(kind: "hourly", inputFrom: nil, inputTo: t0, nowMs: t0)
        let res = try store.applyAgentOps(runID: r, ops: [.resolve(id: "nope", evidence: "x")], nowMs: t0)
        XCTAssertEqual(res.resolvedCount, 0)
    }
    func testNeverResolveOnAbsence() throws {
        let r = try store.beginAgentRun(kind: "hourly", inputFrom: nil, inputTo: t0, nowMs: t0)
        _ = try store.applyAgentOps(runID: r, ops: [.create(kind:"todo",title:"X",details:nil,sourceRefs:[])], nowMs: t0)
        // a subsequent run that simply doesn't mention the item must NOT resolve it
        let r2 = try store.beginAgentRun(kind: "hourly", inputFrom: t0, inputTo: t0+100, nowMs: t0+100)
        _ = try store.applyAgentOps(runID: r2, ops: [], nowMs: t0+100)
        XCTAssertEqual(try store.actionItems(status: "open", limit: 10).count, 1, "absence != resolution")
    }
}
```
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement AgentStore.swift.** `lastAgentCursor`: `SELECT max(input_to) FROM agent_runs WHERE status='completed'`. `beginAgentRun`: insert row status 'running'. `applyAgentOps` (one write txn): for each op — create → insert open item (encrypt title/details, uuidv7, source_refs JSON) + event; update(id) → only if item exists AND status='open' (encrypt changed fields) + event; resolve(id,evidence) → only if exists AND status='open' (set resolved + encrypt evidence) + event; ops on non-open/dismissed/unknown ids IGNORED; then UPDATE the run row status='completed' + counts + *_item_ids JSON. `failAgentRun`: status='failed' + error. `resolveActionItem`/`dismissActionItem`: user transitions (+ event); dismiss sets 'dismissed' (terminal). `actionItems(status:)`/`openActionItems`: query + decrypt. All encryption via `cipher`.
- [ ] **Step 4: Run — PASS.** Full suite green.
- [ ] **Step 5: Commit** `feat(store): AgentStore — durable cursor + action-item ID-ops (never-resolve-on-absence, dismissal-terminal)`

---

### Task 2: HourlyAgent (review logic + prompt)

**Files:** Create `Sources/MaxMiActivity/HourlyAgent.swift`; Modify `Sources/MaxMiActivity/AgentPrompts.swift`; Create `Tests/MaxMiActivityTests/HourlyAgentTests.swift`.

**Interfaces (over protocols, MaxMiActivity deps MaxMiCore only):**
```swift
public struct AgentReviewInput: Sendable { public let sessionSummaries: [String]; public let openItems: [(id: String, title: String)] }
public protocol AgentRepository: Sendable {
    func cursorAndNewSummaries(maxSessions: Int) async -> (from: Int64?, to: Int64, summaries: [String])?  // nil = nothing new
    func openItemsForReview(limit: Int) async -> [(id: String, title: String)]
    func runReview(from: Int64?, to: Int64, ops: [AgentOpDTO]) async     // begins+applies+finalizes a run
    func failRun(from: Int64?, to: Int64, error: String) async
}
public struct AgentOpDTO: Sendable, Codable { public let op: String; public let id: String?; public let kind: String?; public let title: String?; public let details: String?; public let evidence: String?; public let sourceRefs: [String]? }
public protocol AgentGenerationRelay: Sendable { func reviewActivity(_ input: AgentReviewInput) async throws -> [AgentOpDTO] }  // structured output, validated
public struct HourlyAgent: Sendable {
    public init(repo: any AgentRepository, relay: any AgentGenerationRelay, maxSessions: Int = 50)
    public func runIfDue() async     // pulls new summaries since cursor (backfill-bounded); if none -> no-op; else review + apply; on throw -> failRun
}
```
- [ ] **Step 1: Failing HourlyAgentTests** — MockRepo (returns 2 new summaries + 1 open item) + MockRelay (returns [create, resolve(open-item-id, "done")]) → repo.runReview called with those ops; MockRepo(nothing new) → no runReview; relay throws → failRun called. Assert the prompt (AgentPrompts.hourlyReview) FENCES summaries as untrusted + lists open items with their ids.
- [ ] **Step 2: Run — FAIL. Step 3: Implement** HourlyAgent (cursorAndNewSummaries → if nil no-op; else build AgentReviewInput with openItemsForReview, relay.reviewActivity, repo.runReview; catch → failRun) + AgentPrompts.hourlyReview (structured-output instruction: return ops JSON; open items listed with opaque ids; summaries fenced untrusted; instruction to only resolve with evidence, never invent resolutions).
- [ ] **Step 4: Run — PASS. Step 5: Commit** `feat(activity): HourlyAgent review logic over repo/relay protocols`

---

### Task 3: App-target repo/relay + AppWiring scheduling

**Files:** Create `Sources/MaxMi/StoreAgentRepository.swift`, `Sources/MaxMi/GeminiAgentRelay.swift`; Modify `Sources/MaxMi/AppWiring.swift`.

- [ ] **Step 1: StoreAgentRepository** (@unchecked Sendable over Store, like StoreActivitySummaryRepository): `cursorAndNewSummaries` = lastAgentCursor + query activity_sessions summaries with detected/updated in (cursor, now], bounded to maxSessions (backfill); `openItemsForReview` = openActionItems; `runReview` = beginAgentRun + applyAgentOps(map AgentOpDTO→AgentOp, validating); `failRun` = failAgentRun. Map/validate DTO→AgentOp (drop malformed).
- [ ] **Step 2: GeminiAgentRelay** — `reviewActivity` builds AgentPrompts.hourlyReview, calls `geminiClient.generateContent(model: "gemini-2.5-flash-lite", prompt:, responseMimeType: "application/json")`, decodes `[AgentOpDTO]` with strict JSONDecoder (throw on malformed → HourlyAgent calls failRun). Uses the shared throttle (already in generateContent).
- [ ] **Step 3: Schedule in AppWiring** — an `NSBackgroundActivityScheduler` (interval ~1h, tolerant) + run-on-launch-if-overdue + a foreground/idle trigger on the existing 30s sweep when enough new sessions accumulated; all call `hourlyAgent.runIfDue()`; **serialized** (a simple `isAgentRunning` flag / actor so no concurrent runs). Gate on consent==.granted && enabled.
- [ ] **Step 4: Build clean; full suite green. Step 5: Commit** `feat(agent): Store/Gemini agent impls + idle-gated hourly scheduling`

---

### Task 4: Action Items SwiftUI inbox

**Files:** Create `Sources/MaxMiUI/ActionItemsViewModel.swift`, `Sources/MaxMiUI/ActionItemsView.swift`; Modify `Sources/MaxMiUI/ActivityView.swift`; Create `Tests/MaxMiUITests/ActionItemsViewModelTests.swift`.

**Interfaces:**
```swift
public struct ActionItemDTO: Identifiable, Sendable { public let id, title: String; public let details: String?; public let status: String; public let timeAgo: String }
@MainActor @Observable public final class ActionItemsViewModel {
    public private(set) var open: [ActionItemDTO]; public private(set) var archived: [ActionItemDTO]
    public init(load: @escaping @Sendable () async -> (open: [ActionItemDTO], archived: [ActionItemDTO]),
                onResolve: @escaping @Sendable (String) async -> Void, onDismiss: @escaping @Sendable (String) async -> Void, now: @escaping () -> Int64)
    public func refresh() async; public func resolve(_ id: String) async; public func dismiss(_ id: String) async
}
```
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
- [ ] **Step 4: Cursor** — confirm agent_runs advances input_to across runs and a run with no new sessions is a no-op.
- [ ] **Step 5: Declare M6b complete** when 1-4 hold. Then M6c (settings + final polish).

## Self-Review (at plan-writing time)
**Spec coverage:** agent design §2 (durable cursor, ID-ops, never-resolve-on-absence, dismissal-terminal, bounded/backfill, idle+hourly trigger) → T1(store)+T2(logic)+T3(schedule); action-item encryption + events → T1; inbox UI → T4; exit → T5. Reuses M6a v4 tables (no new migration) + DisplaySummarizer's protocol pattern + GeminiThrottle.
**Placeholders:** none — AgentOp/AgentOpDTO/ActionItem signatures concrete; the one judgment (backfill batch size) has a default (maxSessions:50).
**Type consistency:** AgentOp (store) ↔ AgentOpDTO (relay, Codable) mapped in T3; ActionItem (store) → ActionItemDTO (UI) in T4; AgentRepository/AgentGenerationRelay used T2↔T3; cursor methods T1↔T3.
