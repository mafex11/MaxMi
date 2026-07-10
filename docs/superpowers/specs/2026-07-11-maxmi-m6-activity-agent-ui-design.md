# MaxMi — M6: Activity Timeline + Hourly Agent + Minimi-style UI (+ Dog Logo)

**Date:** 2026-07-11
**Status:** Revised after Codex gpt-5.6-terra review #1 (5 Critical + should-fixes addressed; marked ▲REV). Original draft copied Minimi's schema too literally; this revision fixes the session-model, segmentation, agent-cursor, and privacy gaps.
**Milestone:** M6 — the synthesis + presentation milestone. M1-M5 captured raw content; M6 turns it into a **sessionized, summarized activity timeline**, an **hourly agent that surfaces action items**, and the **first real user-facing UI** (a proper window, not just a menu), plus MaxMi's **dog brand icon**. This is the milestone that makes MaxMi feel like a finished ambient-memory app.
**North star:** match Minimi's behaviour + UI/UX (reverse-engineered from the installed app: activity/agent SQLite schema in `main.jsc`, the `index.html`/`inbox.html`/`actionItems.html` React views, the tray/menu, and the white-cat-on-black logo). MaxMi adapts React→**SwiftUI** (native, animated, smooth). See [[project_minimi_reverse_engineering]], [[project_maxmi]], [[project_maxmi_roadmap]], [[project_maxmi_m5_meetings]].

## 1. What we're building

1. **Activity layer** — group raw captures into time-bucketed, per-app **sessions** each with a human **summary** ("what you did in this app"), plus an **app-visit timeline**.
2. **Hourly agent** — a scheduled job that reviews the last window's memory and produces/updates **action items** (open / resolved / dismissed), recording each run.
3. **Rewrite-for-display** — turn raw Gemini `derivatives` into clean, presentable per-session summaries.
4. **UI (SwiftUI, Minimi-style)** — a main **Activity window** (timeline grouped by app/time, each row = app + summary + time-ago), an **Action Items inbox**, opened from the menu-bar icon; clean, animated, smooth.
5. **Dog logo** — app icon (white dog silhouette on black squircle, Minimi-style) + monochrome template tray icon.

**Success test:** after using the Mac for a while, clicking the menu-bar dog opens a window showing a scrollable timeline — "Cursor · *worked on the MaxMi meeting parser* · 20m ago", "Chrome · *researched whisper.cpp streaming* · 1h ago" — grouped sensibly; an Action Items tab lists agent-surfaced to-dos you can resolve/dismiss; the hourly agent runs on schedule and adds items; the app icon and menu-bar icon are the MaxMi dog.

## 2. How Minimi does it (reverse-engineered evidence — the reference to match)

**Schema (from `main.jsc`):**
- `activity_app_visits` (`id, user_id, app_bundle, app_label, started_at, ended_at, day_bucket`) — raw app-visit timeline.
- `activity_conversations` (`id, user_id, app_bundle, app_label, sub_kind, sub_key, sub_label, summary, started_at, detected_at, day_bucket`) — sessionized activity with a **summary**; keyed by `(user_id, app_bundle, sub_key)`, queried `ORDER BY detected_at DESC` and by `day_bucket`.
- `agent_runs` (`id, kind, status, started_at, ended_at, day_bucket, new_chars, before_chars, versions_in_snapshot, new_count, resolved_count, updated_count, new_item_ids, resolved_item_ids, updated_item_ids`) — one row per hourly review.
- `agent_action_items` (`id, user_id, kind, status, title, details, detected_at, resolved_at, resolution_evidence`); `status IN ('open','resolved','dismissed')`, indexed `(user_id, status, detected_at DESC)`.

**Agent (from strings):** `[Agent] next hourly fire in …`, `/api/activity/hourly-review`, `/api/activity/detect-conversation`, `/api/memory/rewrite-for-display`, action-item deltas in `agent_runs`.

**MaxMi's agent design (▲REV — Codex critical, hardened beyond Minimi's sketch):**
- **Durable cursor, not a wall-clock timer as truth.** `agent_runs.input_from/input_to` (committed_at window) IS the source of truth. Trigger = **idle-gated + threshold + hourly-fallback** via `NSBackgroundActivityScheduler` (advisory) + run-on-launch/foreground-when-overdue — NOT a bare `Timer` (which dies on sleep/quit). The cursor advances only after the run's transaction commits.
- **Serialized runs (one actor/DB lease).** Timer fire, retry, launch-catch-up, foreground-trigger must not review the same window concurrently.
- **ID-based operations, not title matching.** The model is given existing open items with stable opaque IDs and must return `create`/`update(id)`/`resolve(id, evidence)` ops (Gemini structured output + strict local schema validation). Applied transactionally; unknown IDs rejected.
- **Never auto-resolve on absence.** An item is resolved ONLY with affirmative evidence in a response — never because it's missing from a later one. A user **dismissal is terminal** (agent can't resurrect it).
- **Bounded input + backfill.** Cap input by token/version count; a week offline is processed in batches, not one giant prompt. `source_refs` on each item for provenance/audit; `agent_action_item_events` records each change.

**UI (React views):** `index.html` (main window — recent activity timeline), `inbox.html`, `actionItems.html` (`action-items:open-window`, `actionItems.pinned`), plus `rightLane`/`voiceNote`/`claudeOverlay` (M5-adjacent). Tray/menu has: Pause/Resume ("Capture Paused", `capture.paused_until`), Launch at Login (`[LaunchAtLogin] reconciling`), Check for Updates, per-app conversation disable (`conversations.disabled_app_bundle_ids`), account/sign-in (we skip — no accounts in MaxMi).

**Logo:** `assets/minimi_appicon.png` = white cat (lying, tail curled) on a black rounded-square with a subtle top-light gradient; `assets/tray/tray-icon-*-{light,dark}-mode.png` = monochrome white silhouette template, with default/audio/error states.

## 3. MaxMi adaptation (what differs, and why)

- **SwiftUI, not React/Electron.** MaxMi is all-Swift. The Activity window + Action Items are **SwiftUI** (a normal closable `NSWindow` hosting `NSHostingController`, app is `.accessory`), giving native, GPU-smooth animations. View model is `@MainActor @Observable`; DB/Gemini work happens off-main and publishes a prebuilt view state back. Window manager is retained in AppWiring (doesn't deallocate on close). "60fps" is a *performance target measured in Instruments*, not an acceptance criterion (Codex).
- **Deterministic segmentation; Gemini ONLY for display summary (▲REV — Codex critical).** The store is hour-bucketed and mutable, so Gemini cannot "detect" sessions from data never stored as events. Instead: a **`SessionSegmenter`** deterministically cuts sessions from `activity_app_visits` (app change + configurable inactivity gap) and attaches the versions committed during each span. Gemini's ONLY job is `DisplaySummarizer` — writing a display summary for a **closed/idle** session from its member derivatives + bounded source snippets (with version-id provenance). No Gemini "detect-conversation" pass.
- **Gemini is a cloud call — explicit consent (▲REV — Codex critical).** "Local Gemini" was inaccurate; the app POSTs to Google's Gemini API. M6 sends synthesized summaries + open-item history. This needs **explicit user-facing consent** (a first-run/Settings disclosure that activity synthesis sends content to Gemini), not "unchanged trust model". Reuses the relay but via a dedicated `ActivityGenerationRelay` extension (`MemoryRelay` today only has `extract`/`embed`).
- **No accounts / sign-in / billing.** Minimi has auth+billing; MaxMi is single-user local — dropped.
- **FocusObserver gains a transition callback (▲REV — Codex critical).** It currently only exposes `onCapture` and drops state on non-capturable apps. M6 adds `onFocusChanged(app, isCapturable)` so `ActivityStore.recordVisit` can open/close visits. Open visits are **closed** on: app switch, sleep/screen-lock (`NSWorkspace` notifications), termination, and **startup crash-repair** (close any dangling open visit). **Sensitive apps (denylist) produce NO visit** — we don't even record their app name.
- **Dog logo** replaces the cat, same visual language (white silhouette, black squircle, subtle gradient; monochrome template tray icon).

## 4. Scope split (M6 is big — three sub-projects, shipped in order)

Per brainstorming discipline, M6 is decomposed into three sub-specs, each independently shippable, in this order (value-first — the user wants to SEE activity):

- **M6a — Activity layer + summaries + Activity window UI + dog logo + privacy controls.** Tables (`activity_app_visits`, `activity_sessions`, `activity_session_versions`), deterministic `SessionSegmenter` + `DisplaySummarizer` (Gemini for summary only), the SwiftUI Activity window + menu-bar click-to-open plumbing, the dog app/tray icons, AND (▲REV — Codex) the **activity privacy controls** (global activity-synthesis enable/disable + per-app exclusion + Gemini-consent disclosure) — these MUST be in M6a, not deferred, so no session is ever summarized from an app the user meant to exclude. This slice delivers the "menu shows what I did per app" the user asked for. Reduced Gemini work: deterministic sessionization + summarize only closed sessions + read-only window.
- **M6b — Hourly agent + Action Items.** `agent_runs`, `agent_action_items`, the hourly review job, the Action Items SwiftUI inbox (resolve/dismiss).
- **M6c — Menu/Settings polish + ship-readiness.** Settings window (Launch at Login, pause controls, per-app disable, Check for Updates, model/keys status), animation/interaction polish across all windows, final ship pass.

This spec covers all three at design level; each gets its own implementation plan. (M6c = the "after M6, polish" phase from the goal.)

## 5. Architecture / components

```
Sources/MaxMiStore/Migrations.swift        MODIFY: v4 — activity_app_visits, activity_sessions,
                                                        activity_session_versions, agent_runs,
                                                        agent_action_items, agent_action_item_events
Sources/MaxMiStore/ActivityStore.swift      NEW: open/close visits, create sessions + member versions,
                                                  set summary (source_hash guard), query timeline
Sources/MaxMiStore/AgentStore.swift          NEW: agent_runs cursor + action_items ID-op transitions
                                                  (create/update/resolve/dismiss) + events audit
Sources/MaxMiActivity/                        NEW module (synthesis logic, non-UI; owns orchestration,
                                              depends on a narrow ActivityGenerationRelay protocol, NOT GRDB/Store directly)
  SessionSegmenter.swift      DETERMINISTIC: visits + gap -> sessions + member version-ids (no Gemini)
  DisplaySummarizer.swift     Gemini: closed/idle session's derivatives+snippets -> encrypted summary
  HourlyAgent.swift           cursor-based review (actor, ID-ops, never-resolve-on-absence, backfill)
  AgentPrompts.swift          the Gemini prompts (hourly-review, rewrite-for-display) — structured output
Sources/MaxMi/AppWiring.swift                 MODIFY: feed FocusObserver visits -> ActivityStore;
                                                       schedule HourlyAgent; own the windows
Sources/MaxMi/ActivityWindow.swift            NEW: NSWindow hosting SwiftUI ActivityView
Sources/MaxMiUI/                               NEW module (SwiftUI views, testable view-models)
  ActivityView.swift          timeline: sessions grouped by day/app, animated
  ActionItemsView.swift       inbox: open/resolved/dismissed, resolve/dismiss actions
  ActivityViewModel.swift     @Observable; loads from Store; pure-ish, testable
  Theme.swift                 colors/spacing/animations (Minimi-like dark, smooth)
Sources/MaxMiMCP/...                           MODIFY: optional activity_timeline MCP tool (stretch)
packaging/assets/                              NEW: dog app icon (icon.icns) + tray templates
packaging/make-app.sh                          MODIFY: install icon.icns + tray assets
```

Data flow: FocusObserver app-switch → `ActivityStore.recordVisit` (timeline). Idle/periodic → `ConversationDetector` groups new versions into sessions → `DisplaySummarizer` (Gemini) writes each session `summary` → `activity_conversations`. Hourly timer → `HourlyAgent` reviews the window's new versions → Gemini hourly-review → action-item deltas → `AgentStore`. Menu-bar dog click → `ActivityWindow` (SwiftUI) loads `ActivityViewModel` → renders timeline + action items.

## 6. UI/UX spec (SwiftUI, Minimi-style — clean/animated/smooth)

**Activity window** (main): a dark, rounded, ~380×560 window. Top: a search field + "Activity / Action Items" segmented tabs. Body = a **timeline** grouped by **Today / Yesterday / earlier** (day_bucket), each group a list of **session rows**: app glyph + `app_label` + one-line **summary** + relative time ("20m ago"). Rows animate in (fade+slide), hover highlight, tap → expands to show the underlying captured detail / opens the thread. Empty state: friendly "Nothing captured yet".
**Action Items tab:** list of open items (title + details + time), each with resolve ✓ / dismiss ✕ (swipe or hover buttons), animated removal; a segment to view resolved/dismissed.
**Interaction quality (the "polish" bar):** smooth (60fps *target*, measured in Instruments — not an acceptance gate) list scrolling via `List`/`LazyVStack` with **stable session IDs** (no full-collection rebuild on refetch; no date-formatting or decryption in `body` — precompute in the view model), spring animations on insert/resolve, subtle vibrancy/blur, 8pt grid, SF Symbols. **Branding decision (▲REV — Codex):** MaxMi's surface is an **intentional always-dark branded palette** (matching Minimi's dark aesthetic) defined via **semantic Theme tokens** — NOT default system colors and NOT auto-light/dark (avoids the "dark Minimi-style" vs "respects light/dark" contradiction). The tray *template* icon still adapts to the menu bar. **"Why am I seeing this?"** disclosure on each session/item reveals its source version-ids (provenance). Opens from the menu-bar dog — **left mouse-up opens the window** (via `NSStatusBarButton` action + event type), **right mouse-up calls `popUpMenu`** (don't assign `NSStatusItem.menu`, which would hijack left-click).
**Menu (right-click / status menu):** Open MaxMi, Pause/Resume Capture (+ per-app submenu, already exists), Settings…, Check for Updates…, Quit. (M6c expands Settings.)

## 7. Logo / brand (dog, Minimi-style)

- **App icon** (`icon.icns`): a **white dog silhouette** (simple, friendly, lying or sitting — same minimalist weight as Minimi's cat) centered on a **black rounded-square** with a subtle top-down light gradient. Same visual language as `minimi_appicon.png`, dog instead of cat. Generated at all required sizes (16–1024).
- **Tray icon:** monochrome white dog silhouette **template image** (so macOS tints it for light/dark menu bars), with default + recording (audio, M5) + error variants, matching Minimi's tray-state set.
- **How produced:** an SVG dog silhouette → rendered to PNGs (iconset) → `iconutil` to `.icns`; tray PNGs marked template. The SVG lives in `packaging/assets/` so it's regenerable. (Implementation plan pins how the dog art is created — hand-authored SVG path, not an AI image, so it's crisp/vector.)

## 8. Storage & schema (v4 migration, additive) — ▲REV (proper session model)

Original draft copied Minimi's `activity_conversations` verbatim; Codex correctly flagged it can't work over MaxMi's **hour-bucketed, mutable** version store (versions overwrite within an hour — NOT an event stream) and lacks provenance. Replaced with a real **`activity_sessions` + membership** model, deterministic segmentation, and processing state.

```sql
-- Raw focus telemetry (from FocusObserver transitions). One row per app foreground span.
CREATE TABLE activity_app_visits (
  id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
  started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL);
CREATE INDEX idx_visits_day ON activity_app_visits(day_bucket DESC, started_at DESC);
CREATE INDEX idx_visits_open ON activity_app_visits(ended_at) WHERE ended_at IS NULL;

-- A coherent work session: deterministically segmented (app change + inactivity gap), summarized
-- from its member versions. NOT keyed by url/title (avoids overwrite-on-revisit + cleartext leak).
CREATE TABLE activity_sessions (
  id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
  started_at INTEGER NOT NULL, ended_at INTEGER, last_activity_at INTEGER NOT NULL,
  day_bucket INTEGER NOT NULL,
  summary_ciphertext TEXT,                 -- encrypted display summary (enc:v1:), null until summarized
  summary_status TEXT NOT NULL DEFAULT 'pending'
    CHECK(summary_status IN ('pending','summarized','failed','skipped')),
  source_hash TEXT,                        -- hash of the exact member-version set summarized (stale-guard)
  model_id TEXT, prompt_version TEXT,      -- provenance: which model/prompt produced the summary
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX idx_sessions_day ON activity_sessions(day_bucket DESC, started_at DESC);
CREATE INDEX idx_sessions_summ ON activity_sessions(summary_status) WHERE summary_status='pending';

-- Immutable provenance: which versions belong to a session (enables "expand to detail").
CREATE TABLE activity_session_versions (
  session_id TEXT NOT NULL REFERENCES activity_sessions(id),
  version_id TEXT NOT NULL REFERENCES versions(id),
  PRIMARY KEY(session_id, version_id));

-- One row per agent review, with a DURABLE CURSOR (source of truth, survives restart/sleep).
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
  input_from INTEGER, input_to INTEGER,   -- the committed_at window this run covered (the cursor)
  model_id TEXT, prompt_version TEXT,
  started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL,
  new_count INTEGER, resolved_count INTEGER, updated_count INTEGER,
  new_item_ids TEXT, resolved_item_ids TEXT, updated_item_ids TEXT,   -- JSON arrays (observability)
  error TEXT);
CREATE INDEX idx_runs_started ON agent_runs(started_at DESC);

CREATE TABLE agent_action_items (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','dismissed')),
  title_ciphertext TEXT NOT NULL,          -- encrypted
  details_ciphertext TEXT,                  -- encrypted
  source_refs TEXT,                          -- JSON version-ids provenance ("why am I seeing this")
  detected_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  resolved_at INTEGER, resolution_evidence_ciphertext TEXT);   -- encrypted (Codex: was plaintext)
CREATE INDEX idx_items_status ON agent_action_items(status, detected_at DESC);

-- Audit trail of item changes (create/update/resolve/dismiss) — bounded, for "auditable updates".
CREATE TABLE agent_action_item_events (
  id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES agent_action_items(id),
  event TEXT NOT NULL, run_id TEXT, at INTEGER NOT NULL);
```

**Encryption:** all derived text — `summary_ciphertext`, item `title/details/resolution_evidence` — is **encrypted at rest** (`enc:v1:`). Cleartext-for-indexing: `app_bundle`, `app_label`, timestamps, buckets, status. NOTE (▲REV, honest): unlike the original draft there is NO `sub_key`/url/title column — that removes a cleartext leak *and* the overwrite-on-revisit bug. `app_label` is the only human-ish cleartext (an app name, low-sensitivity), documented.

**Session identity & staleness (▲REV):** sessions are identified by their own UUID (never by app+url), so revisiting a page next week creates a NEW session. `source_hash` = hash of the member `version_id`+`content_hash` set; a session is (re)summarized only when it's closed/idle AND its `source_hash` changed — never while a current-hour version is still mutating. This prevents stale/duplicate summaries over the mutable store.

## 9. Privacy / consent / cost (▲REV)
- All summaries/action-items encrypted at rest (`enc:v1:`), including `resolution_evidence`.
- **Explicit Gemini consent** (Codex critical): activity synthesis sends summaries + open-item history to Google's Gemini API. A first-run/Settings disclosure states this clearly; if declined, capture still works but no activity synthesis runs. Not "unchanged trust model."
- **Activity privacy controls in M6a** (not M6c): global activity-synthesis toggle + per-app exclusion (`activity.disabled_app_bundle_ids` in settings) applied BEFORE any session is written. Sensitive-denylist apps never produce visits or sessions.
- **Cost (real numbers, Codex):** pin an explicit model ID (e.g. `gemini-2.5-flash-lite`, $0.10/M in, $0.40/M out — NOT the moving `-latest` alias). ~24 reviews/day @ 8k in + 500 out ≈ **$0.72/mo**; @ 50k in ≈ **$3.75/mo** before display summaries. Settings shows an estimated-usage note.
- **Rate limits (Codex):** Gemini is limited per project across RPM/TPM/RPD; a 429 on any dimension. M6 shares one throttle with extraction/embedding + exponential backoff with jitter.
- **Timezone:** store epoch-ms UTC; derive `day_bucket` from one documented local-timezone policy (avoids DST/travel grouping surprises).
- Nothing new leaves the Mac beyond the existing Gemini relay.

## 10. Error handling
- Detector/summarizer/agent failures are logged + retried (reuse the existing retry_queue pattern); a failed summary leaves the session with a null summary (UI shows a neutral fallback), never crashes.
- Hourly agent never blocks capture; runs off-main; a failed run is recorded `status='failed'` in agent_runs and retried next tick.
- UI loads defensively: missing summary → "…"; empty DB → empty state.

## 11. Non-goals (M6)
- No accounts/sign-in/billing (Minimi has them; MaxMi is single-user local).
- No team features (M7 dropped — see [[project_maxmi_roadmap]]).
- No new capture modality (capture is M1-M5; M6 only synthesizes + presents).
- No cloud activity backend (local pipeline calling the existing Gemini relay).

## 12. Testing
- **ActivityStore/AgentStore/migration v4:** visit open/close (+ crash-repair of dangling opens); session create + member-version links; summary set with `source_hash` stale-guard (re-summarize only on hash change); action-item ID-op transitions (create/update/resolve/dismiss) + CHECK-constraint enforcement + events audit; encrypted round-trip for summary/title/details/evidence; MigrationTests asserts all 6 tables.
- **SessionSegmenter:** deterministic grouping (app change + inactivity gap) over synthetic visit+version sets — pure/testable; revisiting same app later = NEW session (no overwrite).
- **HourlyAgent:** cursor advance only after commit; ID-based ops applied transactionally; **never-resolve-on-absence** (item absent from a later response stays open); dismissal terminal; backfill batching caps input. Mock relay returns canned structured-output ops; delta math + cursor asserted.
- **DisplaySummarizer:** prompt-building + provenance (version-ids) with a mock relay.
- **ActivityViewModel:** loads Store rows → view state (grouping by day, time-ago formatting) — pure/testable.
- SwiftUI views + windows + the icon are manual/live (UI glue, per precedent); view-models + logic are CI-tested.

## 13. Exit criteria (M6 = M6a+M6b+M6c)
1. App-visit timeline recorded; sessions grouped with Gemini summaries ("what you did in <app>").
2. Menu-bar **dog** icon; clicking opens the SwiftUI Activity window showing the timeline, grouped by day/app, animated + smooth.
3. Hourly agent runs on schedule, surfaces action items; Action Items inbox lists them; resolve/dismiss works + persists.
4. Derived text encrypted at rest; per-app disable works (M6c).
5. Settings window (Launch at Login, pause, per-app disable, Check for Updates, status) — M6c.
6. UI is clean/animated/smooth (spring insert/resolve, 60fps, vibrancy, light/dark) — the ship-readiness bar.
7. Full fixture suite green; no regressions; synthesis logic isolated in MaxMiActivity, views in MaxMiUI.

## 14. Rollout
Per user goal: **spec → Codex gpt-5.6-terra review → revise → implementation plan → Codex review (same chat) → revise → implement subagent-driven → Codex review of the IMPLEMENTATION (same chat) → revise.** Order: M6a (activity + summaries + window + dog logo + privacy controls), then M6b (hourly agent + action items), then M6c (settings + final ship polish: clean/animated/smooth pass, Launch-at-Login, Check-for-Updates, per-app disable UI). Dog logo lands in M6a. End state: MaxMi ~99% ship-ready.
