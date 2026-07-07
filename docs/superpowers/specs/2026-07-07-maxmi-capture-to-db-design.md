# MaxMi — Milestone 1: Ambient Capture → Local Memory DB

**Date:** 2026-07-07
**Status:** Draft for review
**Scope:** First working milestone only. Later milestones (MCP server, retrieval UI, meetings, team-sharing, encryption) are out of scope and noted at the end.

## 1. What we're building

MaxMi is a standalone native macOS menu-bar app that ambiently captures what you read on screen and turns it into a local, searchable memory — a self-built equivalent of Minimi (Shram), which we reverse-engineered from the installed app, its live SQLite DB, and a live network intercept (see `docs/minimi-backend-contract.md`).

**Milestone 1 delivers one complete vertical slice:** the active **browser tab's** content is captured via the macOS Accessibility (AX) tree, versioned into a local SQLite database, sent to Gemini to extract atomic memory facts, embedded, and stored as vectors — all on device except the Gemini API calls. No retrieval, no MCP, no Claude integration yet. The success test is: browse a few pages, then inspect the DB and see correctly-versioned threads with extracted fact sentences and their embeddings.

This proves the hardest and most foundational part (capture + storage + the extract/embed pipeline). Everything later (MCP server exposing `search_memory` to Claude) sits on top of this DB unchanged.

## 2. Non-goals for Milestone 1

- No MCP server / Claude connector (next milestone).
- No search/retrieval or query UI.
- No meeting audio / transcription / voice notes.
- No chat-app parsers (Slack/WhatsApp/etc.) — browser tabs only.
- No team sharing.
- No at-rest encryption — content stored as **plaintext** for now (see §9). Hardening pass later.
- No own backend — the app calls Gemini's API directly. (A relay backend is a later concern.)

## 3. Architecture

Native Swift, built exactly like the existing `burnt/` project: a SwiftPM package (`swift-tools-version: 6.0`, `.macOS(.v14)`), assembled into a `.app` by a `packaging/make-app.sh` and ad-hoc codesigned. Menu-bar app (`LSUIElement`), no Dock icon.

The app is one process. Work is split into focused SwiftPM targets so each piece is independently testable:

```
Sources/
  MaxMiCore/      Models, config (.env loader), hour-bucket + hashing utils, the
                  CapturePipeline orchestrator. Pure logic, no AppKit, fully unit-testable.
  MaxMiCapture/   AX-tree reading (AXUIElement), focus/window-change observer,
                  BrowserTabExtractor (URL + visible text from the frontmost browser window).
  MaxMiStore/     SQLite access (schema, migrations, versioning rules), sqlite-vec
                  vector tables, all queries. No knowledge of capture or network.
  MaxMiRelay/     GeminiClient: extract(newContent, previousContent?) -> [String],
                  embed(text) -> [Float]. Only talks to Gemini. Mockable via a protocol.
  MaxMi/          Executable: menu-bar UI (status, capture count, pause toggle,
                  permission prompts), wires the other modules together.
Tests/
  MaxMiCoreTests/     versioning rules, hour-bucketing, dedup hash, pipeline logic (mocked deps)
  MaxMiStoreTests/    schema, upsert/freeze behavior, vector round-trip
  MaxMiCaptureTests/  AX extraction against recorded fixture trees
```

**Data flow (one capture cycle):**

```
NSWorkspace frontmost-app change / AX focus change
  -> FocusObserver fires, debounced ~1000ms (coalesce rapid switches)
  -> is frontmost app a browser? (bundle-id allowlist)   no -> ignore
  -> BrowserTabExtractor reads AX tree of the focused window:
       - source_key = tab URL (from the address-bar AX element)
       - source_title = window/tab title
       - content = visible text, collected in visual order
  -> is source_key on the sensitive-domain denylist?     yes -> drop
  -> tree_hash = hash(content); unchanged vs thread.last_tree_hash? -> drop (dedup)
  -> Store.commitCapture(thread, content):
       - upsert thread by (source_app, source_key)
       - upsert the (thread, current hour_bucket) version (mutable), set content/hash/word_count
       - freeze any older mutable versions of this thread
  -> CapturePipeline (async, off the capture path):
       - Relay.extract(new_content, previous_content) -> [fact sentences]
       - for each new fact: Relay.embed(fact) -> vector; store derivative + embedding
       - mark version embedding_status = completed
```

Capture (fast, synchronous-ish) is decoupled from the network pipeline (slow, async, retryable) via the version's `embedding_status` and a retry queue — so a failed/offline Gemini call never blocks or loses a capture.

## 4. Data model (SQLite)

Mirrors Minimi's verified schema (we confirmed this from the live DB). Timestamps are epoch-ms integers.

```sql
CREATE TABLE threads (
  id            TEXT PRIMARY KEY,          -- UUIDv7 (time-sortable)
  source_app    TEXT NOT NULL,             -- "Web" for milestone 1
  source_key    TEXT NOT NULL,             -- the tab URL
  source_title  TEXT,
  last_tree_hash TEXT,                      -- dedup guard: hash of last captured content
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE(source_app, source_key)
);

CREATE TABLE versions (
  id            TEXT PRIMARY KEY,          -- UUIDv7
  thread_id     TEXT NOT NULL REFERENCES threads(id),
  hour_bucket   INTEGER NOT NULL,          -- committed_at / 3600000  (epoch hours)
  content       TEXT NOT NULL,             -- captured text (plaintext, milestone 1)
  content_hash  TEXT NOT NULL,
  word_count    INTEGER NOT NULL DEFAULT 0,
  is_frozen     INTEGER NOT NULL DEFAULT 0,-- 0 = current hour, mutable; 1 = past hour, sealed
  previous_content TEXT,                    -- prior frozen version's content, for extract diffing
  committed_at  INTEGER NOT NULL,
  embedding_status TEXT NOT NULL DEFAULT 'pending'  -- pending | completed | failed
);
-- Versioning invariant: at most one row per (thread_id, hour_bucket).

CREATE TABLE derivatives (
  id            TEXT PRIMARY KEY,          -- UUIDv7
  thread_id     TEXT NOT NULL REFERENCES threads(id),
  version_id    TEXT NOT NULL REFERENCES versions(id),
  content       TEXT NOT NULL,             -- one atomic fact sentence (third person)
  committed_at  INTEGER NOT NULL,
  embedding_status TEXT NOT NULL DEFAULT 'pending'
);

-- sqlite-vec virtual table; 1536-dim to match Minimi's choice.
CREATE VIRTUAL TABLE derivative_embeddings USING vec0(
  derivative_id TEXT PRIMARY KEY,
  embedding     FLOAT[1536]
);

CREATE TABLE retry_queue (            -- decouples capture from flaky/offline network
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,        -- 'extract' | 'embed'
  version_id    TEXT,
  derivative_id TEXT,
  attempts      INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_error    TEXT
);

CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE schema_migrations (id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL);
```

**The per-hour versioning rule (the core design, confirmed from Minimi's DB):** a thread gets at most one *mutable* version per clock hour. While you're on a page during the current hour, its version is rewritten in place as content changes. When the hour rolls over and the page is seen again, the old version freezes (`is_frozen=1`) and a new mutable version starts. This gives an hourly time-series of how each page evolved at fixed storage cost, and `previous_content` lets extraction diff against the last frozen state so we only extract genuinely new facts.

## 5. Capture layer (MaxMiCapture)

- **Frontmost-app + focus detection:** `NSWorkspace.didActivateApplicationNotification` plus an AX `kAXFocusedUIElementChangedNotification` observer on the active app, coalesced through a ~1000ms debounce (matches Minimi's observed 1s debounce).
- **Browser detection:** bundle-id allowlist — Chrome (`com.google.Chrome`), Arc (`company.thebrowser.Browser`), Zen, Safari (`com.apple.Safari`), Brave, Edge. Non-browser frontmost app → ignore in milestone 1.
- **Tab extraction (`BrowserTabExtractor`):** walk the frontmost window's AX tree. Get the URL from the address-bar element (`AXTextField` in the toolbar; role/identifier differs per browser, so a tiny per-browser locator with a generic fallback), the title from the window, and the body text by collecting `AXStaticText` values in visual order (top→bottom, left→right) — the same technique Minimi's `runtime.js` uses. We are re-implementing that traversal in Swift (`AXUIElementCopyAttributeValue` over `kAXChildrenAttribute`, reading `kAXRoleAttribute`/`kAXValueAttribute`/`kAXFrameAttribute`).
- **Permissions:** requires macOS Accessibility permission. On launch, check `AXIsProcessTrustedWithOptions`; if not granted, the menu-bar UI shows a "Grant Accessibility" prompt that deep-links to System Settings. (This is the same TCC dance as Yuki — note [[project_yuki_signing]]: ad-hoc signed apps need re-grant after each rebuild.)
- **Sensitive-domain denylist:** hard-coded set of hosts/URL patterns never captured — banks, `*.bitwarden.com`, `1password.com`, `accounts.google.com`, `okta.com`, `/reset-password`, etc. Seeded from the list we pulled out of Minimi's binary.

## 6. Storage layer (MaxMiStore)

- **Library:** GRDB.swift (mature, synchronous, migration support) as the SQLite layer. sqlite-vec loaded as a runtime extension (bundle the `vec0.dylib` for arm64 in `Resources/`, load via `sqlite3_load_extension` at open).
- **DB location:** `~/Library/Application Support/MaxMi/maxmi.db` (WAL mode).
- **Responsibilities:** schema + migrations, `commitCapture` (the upsert/freeze transaction from §3), derivative + embedding inserts, retry-queue operations, and vector insert/search helpers (search unused in milestone 1 but implemented + tested so the next milestone is a drop-in).
- All versioning logic lives here behind a small API (`commitCapture`, `pendingWork`, `markCompleted`, `enqueueRetry`) so `MaxMiCore` can drive it without touching SQL.

## 7. Relay layer (MaxMiRelay)

`GeminiClient`, talking directly to Google's Generative Language API with a key from `.env` (see §8). Two operations behind a `MemoryRelay` protocol (so tests inject a mock):

- **`extract(newContent:previousContent:) -> [String]`** — calls a Gemini flash-lite–tier model (`gemini-flash-lite-latest`; we pin the concrete id in code and note the fallback). **We write our own extraction prompt** (Minimi's is server-side and not needed): instruct the model to return a JSON array of atomic, self-contained, third-person fact sentences describing what the user did/read, naming the user by first name; when `previousContent` is provided, extract only facts new since it. This exactly reproduces the input/output contract we captured: `{new_content, previous_content, metadata}` → `["fact", "fact", …]`.
- **`embed(text:) -> [Float]`** — Gemini `gemini-embedding-001` with `outputDimensionality: 1536`, embedding each fact sentence whole (no chunking — confirmed from intercept). Returns the 1536-float vector.

Errors (offline, rate-limit, 5xx) throw; the pipeline catches them and routes the item to `retry_queue` with backoff. Nothing is lost.

## 8. Config & secrets (MaxMiCore)

- `.env` file in the app's Application Support dir (and, for dev, the repo root), loaded at startup. Keys: `GEMINI_API_KEY`, optional `MAXMI_EXTRACT_MODEL`, `MAXMI_EMBED_MODEL`, `MAXMI_EMBED_DIMS` (default 1536).
- `.env` is gitignored. We chose `.env` over Keychain deliberately for this milestone — matches the Yuki-on-Gemini learning that Keychain causes repeated password prompts during dev (note [[project_yuki_gemini3]]).

## 9. Encryption decision (flagged for your review)

Milestone 1 stores captured `content` and derivative facts as **plaintext** in SQLite. Rationale: far easier to build, inspect, and debug the capture/versioning logic; the DB is already file-permission-protected in your user Library. Minimi's real design is per-field AES-256-GCM (`enc:v1:` prefix, scrypt-derived Keychain key) over a plaintext SQLite file — we will add that as a dedicated hardening pass **before** any real/shared use, reusing the exact scheme we documented. **If you'd rather encrypt from day one, say so and I'll fold it into this milestone** (adds crypto + Keychain friction to the first build).

## 10. Error handling

- **Capture failures** (AX read returns nothing, permission revoked): logged, skipped; never crash. Missing Accessibility permission surfaces as a persistent menu-bar warning.
- **Network failures**: item → `retry_queue` with exponential backoff; a periodic worker drains it when a key is present and the network is up. Version stays `pending` until embedded.
- **Malformed Gemini output** (extract not valid JSON array): one reparse attempt (strip code fences, first-`[`-to-last-`]`), then mark `failed` and enqueue retry; never store garbage.
- **DB**: all multi-step commits (upsert thread + version + freeze) run in one transaction.

## 11. Testing strategy

- **MaxMiCoreTests** — the logic that matters most: hour-bucket math, the "one mutable version per thread per hour + freeze on rollover" rule, dedup-by-hash, and the pipeline orchestration with mocked Store + Relay (assert a new page produces a thread→version→N derivatives→N embeddings; a re-capture with identical content produces nothing; a re-capture next hour freezes the old version).
- **MaxMiStoreTests** — schema/migrations apply, `commitCapture` upsert/freeze behavior, vector insert + nearest-neighbor round-trip via sqlite-vec.
- **MaxMiCaptureTests** — `BrowserTabExtractor` against a few recorded AX-tree fixtures (captured as JSON from real browser windows) → asserts correct URL/title/text extraction and denylist filtering. No live browser needed in CI.
- **Relay** — mocked HTTP; assert request shape matches the captured contract and response parsing handles the JSON-array and fenced-JSON cases.
- Verify end-to-end manually per the `verify` skill before calling the milestone done: run the app, browse 3-4 pages, confirm the DB has correct threads/versions/derivatives/embeddings.

## 12. Milestone exit criteria

1. App launches as a menu-bar item, requests/holds Accessibility permission.
2. Browsing distinct pages creates one thread per URL with correct titles.
3. Re-viewing an unchanged page creates no new version (dedup works); viewing it in a later hour freezes the prior version and starts a new one.
4. Each version yields extracted third-person fact sentences and a 1536-dim embedding per fact, stored locally.
5. Killing the network mid-capture loses no data — items retry and complete when back online.
6. Menu bar shows a live capture count. Sensitive domains are never stored.

## 13. Later milestones (not now)

M2: MCP server exposing `search_memory` / `list_threads` (markdown output, 20-item cap) so Claude can query the DB. M3: per-field AES-GCM encryption + Keychain key. M4: chat-app + document parsers. M5: meetings (system-audio capture + transcription). M6: hourly agent + activity timeline. M7: team sharing.
