# MaxMi — M6: Activity Timeline + Hourly Agent + Minimi-style UI (+ Dog Logo)

**Date:** 2026-07-11
**Status:** Draft for review (Codex gpt-5.6-terra)
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

**Agent (from strings):** `[Agent] next hourly fire in …`, `/api/activity/hourly-review`, `/api/activity/detect-conversation`, `/api/memory/rewrite-for-display`. So: a periodic (hourly) timer fires a review over the window's new versions (`new_chars`/`before_chars` track delta), which detect-conversation groups into sessions + hourly-review produces action-item deltas (new/resolved/updated), stored in `agent_action_items` with the run recorded in `agent_runs`.

**UI (React views):** `index.html` (main window — recent activity timeline), `inbox.html`, `actionItems.html` (`action-items:open-window`, `actionItems.pinned`), plus `rightLane`/`voiceNote`/`claudeOverlay` (M5-adjacent). Tray/menu has: Pause/Resume ("Capture Paused", `capture.paused_until`), Launch at Login (`[LaunchAtLogin] reconciling`), Check for Updates, per-app conversation disable (`conversations.disabled_app_bundle_ids`), account/sign-in (we skip — no accounts in MaxMi).

**Logo:** `assets/minimi_appicon.png` = white cat (lying, tail curled) on a black rounded-square with a subtle top-light gradient; `assets/tray/tray-icon-*-{light,dark}-mode.png` = monochrome white silhouette template, with default/audio/error states.

## 3. MaxMi adaptation (what differs, and why)

- **SwiftUI, not React/Electron.** MaxMi is all-Swift. The Activity window + Action Items are **SwiftUI** in the app target (rendered in an `NSWindow`/`NSPanel`), giving native, GPU-smooth animations. This is the "clean/animated/smooth" the goal wants, done the native way.
- **Local Gemini, not a cloud `/api/activity/*` backend.** MaxMi already relays to Gemini for extraction (M1). M6's `detect-conversation`/`hourly-review`/`rewrite-for-display` become **local pipeline steps that call Gemini** with purpose-built prompts, reusing the existing `MemoryRelay`. No new backend.
- **No accounts / sign-in / billing.** Minimi has auth+billing; MaxMi is single-user local — those menu items are dropped.
- **Reuse existing capture.** `activity_app_visits` is fed by the **FocusObserver** MaxMi already has (it already knows frontmost app + transitions); we just persist visits. `activity_conversations` summaries are derived from the `threads`/`versions`/`derivatives` MaxMi already stores.
- **Dog logo** replaces the cat, same visual language (white silhouette, black squircle, subtle gradient; monochrome template tray icon).

## 4. Scope split (M6 is big — three sub-projects, shipped in order)

Per brainstorming discipline, M6 is decomposed into three sub-specs, each independently shippable, in this order (value-first — the user wants to SEE activity):

- **M6a — Activity layer + summaries + Activity window UI + dog logo.** Tables (`activity_app_visits`, `activity_conversations`), detect-conversation + rewrite-for-display pipeline, the SwiftUI Activity window, the dog app/tray icons. This alone delivers the "menu shows what I did per app" the user asked for.
- **M6b — Hourly agent + Action Items.** `agent_runs`, `agent_action_items`, the hourly review job, the Action Items SwiftUI inbox (resolve/dismiss).
- **M6c — Menu/Settings polish + ship-readiness.** Settings window (Launch at Login, pause controls, per-app disable, Check for Updates, model/keys status), animation/interaction polish across all windows, final ship pass.

This spec covers all three at design level; each gets its own implementation plan. (M6c = the "after M6, polish" phase from the goal.)

## 5. Architecture / components

```
Sources/MaxMiStore/Migrations.swift        MODIFY: v4 — activity_app_visits, activity_conversations,
                                                        agent_runs, agent_action_items
Sources/MaxMiStore/ActivityStore.swift      NEW: record app-visits, upsert conversations, query timeline
Sources/MaxMiStore/AgentStore.swift          NEW: agent_runs + agent_action_items CRUD + status transitions
Sources/MaxMiActivity/                        NEW module (synthesis logic, non-UI)
  ConversationDetector.swift  group recent versions -> sessions (per app, time-gap heuristic)
  DisplaySummarizer.swift     Gemini rewrite-for-display: derivatives -> clean session summary
  HourlyAgent.swift           scheduled review: new-version delta -> action-item new/resolved/updated
  AgentPrompts.swift          the Gemini prompts (detect-conversation, hourly-review, rewrite)
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
**Interaction quality (the "polish" bar):** 60fps list scrolling, spring animations on insert/resolve, subtle vibrancy/blur background, consistent 8pt spacing grid, SF Symbols, respects light/dark mode, no jank. Opens from the menu-bar dog (left-click opens window; right-click = the menu).
**Menu (right-click / status menu):** Open MaxMi, Pause/Resume Capture (+ per-app submenu, already exists), Settings…, Check for Updates…, Quit. (M6c expands Settings.)

## 7. Logo / brand (dog, Minimi-style)

- **App icon** (`icon.icns`): a **white dog silhouette** (simple, friendly, lying or sitting — same minimalist weight as Minimi's cat) centered on a **black rounded-square** with a subtle top-down light gradient. Same visual language as `minimi_appicon.png`, dog instead of cat. Generated at all required sizes (16–1024).
- **Tray icon:** monochrome white dog silhouette **template image** (so macOS tints it for light/dark menu bars), with default + recording (audio, M5) + error variants, matching Minimi's tray-state set.
- **How produced:** an SVG dog silhouette → rendered to PNGs (iconset) → `iconutil` to `.icns`; tray PNGs marked template. The SVG lives in `packaging/assets/` so it's regenerable. (Implementation plan pins how the dog art is created — hand-authored SVG path, not an AI image, so it's crisp/vector.)

## 8. Storage & schema (v4 migration, additive)

```sql
CREATE TABLE activity_app_visits (
  id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
  started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL);
CREATE INDEX idx_visits_day ON activity_app_visits(day_bucket DESC, started_at DESC);

CREATE TABLE activity_conversations (
  id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
  sub_kind TEXT, sub_key TEXT, sub_label TEXT,
  summary TEXT,                       -- encrypted (it's derived content)
  started_at INTEGER NOT NULL, detected_at INTEGER NOT NULL, day_bucket INTEGER NOT NULL);
CREATE INDEX idx_conv_day ON activity_conversations(day_bucket DESC, detected_at DESC);
CREATE UNIQUE INDEX idx_conv_key ON activity_conversations(app_bundle, sub_key);

CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL,
  started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL,
  new_chars INTEGER, before_chars INTEGER, versions_in_snapshot INTEGER,
  new_count INTEGER, resolved_count INTEGER, updated_count INTEGER,
  new_item_ids TEXT, resolved_item_ids TEXT, updated_item_ids TEXT);

CREATE TABLE agent_action_items (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open',
  title TEXT NOT NULL,               -- encrypted
  details TEXT,                       -- encrypted
  detected_at INTEGER NOT NULL, resolved_at INTEGER, resolution_evidence TEXT);
CREATE INDEX idx_items_status ON agent_action_items(status, detected_at DESC);
```
Derived text (`summary`, item `title`/`details`) is **encrypted at rest** like all content (they can quote what you did). Metadata (app_bundle, times, buckets, status) cleartext for indexing — consistent with the existing policy.

## 9. Privacy / consent
- All summaries/action-items are derived from already-captured, already-consented content; encrypted at rest.
- Gemini sees the same plaintext it already sees for extraction (unchanged trust model).
- Per-app conversation disable (`conversations.disabled_app_bundle_ids`, M6c) lets the user exclude apps from the activity timeline without disabling capture.
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
- **ActivityStore/AgentStore/migration v4:** CRUD + status transitions (open→resolved/dismissed); visit open/close; conversation upsert-by-key; encrypted summary round-trip; MigrationTests asserts the 4 tables.
- **ConversationDetector:** grouping logic (time-gap + per-app) over synthetic version sets — pure/testable.
- **DisplaySummarizer / HourlyAgent:** prompt-building + delta logic (new/resolved/updated) with a mock relay returning canned JSON — the Gemini call is mocked; delta math is asserted.
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
M6a spec-section → **Codex gpt-5.6-terra review** → revise → M6a plan → **Codex review (same chat)** → revise → subagent build → **Codex review of the implementation (same chat)** → revise → live. Then M6b, then M6c (settings + final polish). Dog logo lands in M6a (it's the brand the UI ships with). End state: MaxMi ~99% ship-ready.
