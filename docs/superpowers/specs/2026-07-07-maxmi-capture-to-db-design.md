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
NSWorkspace frontmost-app change / AX focus change / periodic re-capture tick
  (a 30-60s timer while a browser is frontmost — focus events alone miss
   scrolling and streamed-in content; tree-hash dedup makes idle ticks free)
  -> FocusObserver fires, debounced ~1000ms (coalesce rapid switches)
  -> is frontmost app a browser? (bundle-id allowlist)   no -> ignore
  -> BrowserTabExtractor reads AX tree of the focused window:
       - source_key = full canonical URL from the web area (AXWebArea's AXURL /
         Chromium's AXDocument); address-bar element is FALLBACK only (§5)
       - source_title = window/tab title
       - content = visible text, collected in visual order
  -> is source_key on the sensitive-domain denylist?     yes -> drop
  -> tree_hash = hash(content); unchanged vs thread.last_tree_hash? -> drop (dedup)
  -> Store.commitCapture(thread, content):               [one transaction]
       - upsert thread by (source_app, source_key)
       - freeze any mutable version of this thread with a past hour_bucket
       - upsert the (thread, current hour_bucket) version (mutable):
         REPLACE content/hash/word_count, reset extract_status = 'pending'
  -> CapturePipeline (async, decoupled — runs on freeze/idle/sweeper, §3a):
       - previous_content = this thread's latest frozen version (self-join, §4)
       - Relay.extract(new_content, previous_content) -> [fact sentences]
       - store each fact as a derivative, deduped by (thread_id, content_hash)
       - for each NEW derivative: Relay.embed(fact) -> vector; store embedding
       - mark version extract_status = 'completed', guarded by the content_hash
         read at extract time (§3a)
```

**Content overwrite policy:** a re-capture within the hour *replaces* the version's `content` with what the AX tree currently shows. On virtualized pages (feeds, long docs) text that scrolled out of the AX tree is therefore lost from the version — accepted for M1; facts already extracted from earlier states survive as derivatives.

Capture (fast, synchronous-ish) is decoupled from the network pipeline (slow, async, retryable) via the version's `extract_status` and a retry queue — so a failed/offline Gemini call never blocks or loses a capture.

### 3a. Extraction triggers & the capture↔pipeline race

Extraction does **not** run on every capture — that would re-extract the same facts all hour (each within-hour capture would diff against the same frozen baseline) and re-pay Gemini for duplicates. A version becomes extract work when:

1. **It freezes** — the next capture after hour rollover.
2. **It goes idle** — no content change for ~5 min while still mutable (keeps the demo/verify loop fast; you don't wait an hour to see derivatives).
3. **The sweeper finds it** — a periodic worker treats `extract_status='pending' AND hour_bucket < current` as work. This covers pages never revisited after their hour: freezing is lazy, so such rows keep `is_frozen=0` forever. Rule: `is_frozen=0 ∧ past hour_bucket` means **implicitly frozen** — readers (and M2 retrieval) must treat it as sealed.

**Race guard (lost-update):** the pipeline records the `content_hash` it read before calling Gemini. Completion is `UPDATE versions SET extract_status='completed' WHERE id=? AND content_hash=<hash read>`. Zero rows updated → the content moved mid-flight → the version stays `pending` and re-runs on the next trigger. Symmetrically, `commitCapture` always resets `extract_status='pending'` whenever content changes. Extraction is idempotent because derivatives are hash-deduped (§4), so a re-run — including a retry after a crash between extract and embed — never stores duplicate facts.

## 4. Data model (SQLite)

Mirrors Minimi's verified schema (we confirmed this from the live DB). Timestamps are epoch-ms integers.

```sql
CREATE TABLE threads (
  id            TEXT PRIMARY KEY,          -- UUIDv7 (time-sortable)
  source_app    TEXT NOT NULL,             -- "Web" for milestone 1
  source_key    TEXT NOT NULL,             -- full canonical tab URL (web-area AXURL, §5)
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
  content_hash  TEXT NOT NULL,             -- also the optimistic-concurrency guard (§3a)
  word_count    INTEGER NOT NULL DEFAULT 0,
  is_frozen     INTEGER NOT NULL DEFAULT 0,-- 0 = current hour, mutable; 1 = sealed.
                                            -- Freezing is LAZY: 0 with a past hour_bucket
                                            -- means implicitly frozen (§3a).
  committed_at  INTEGER NOT NULL,
  extract_status TEXT NOT NULL DEFAULT 'pending',  -- pending | completed | failed
  UNIQUE(thread_id, hour_bucket)            -- the versioning invariant, enforced
);
CREATE INDEX idx_versions_thread ON versions(thread_id);
-- No previous_content column: the extract baseline is the thread's latest frozen
-- version, fetched by self-join at extract time. Denormalizing it would double the
-- plaintext footprint and add a consistency invariant for zero read savings.

CREATE TABLE derivatives (
  id            TEXT PRIMARY KEY,          -- UUIDv7
  thread_id     TEXT NOT NULL REFERENCES threads(id),
  version_id    TEXT NOT NULL REFERENCES versions(id),
  content       TEXT NOT NULL,             -- one atomic fact sentence (third person)
  content_hash  TEXT NOT NULL,             -- dedup: extract re-runs must be idempotent (§3a)
  committed_at  INTEGER NOT NULL,
  embedding_status TEXT NOT NULL DEFAULT 'pending',
  UNIQUE(thread_id, content_hash)
);
CREATE INDEX idx_derivatives_version ON derivatives(version_id);

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
CREATE INDEX idx_retry_due ON retry_queue(next_attempt_at);

CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE schema_migrations (id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL);
```

**Status semantics (two stages, not one):** `versions.extract_status` covers only the extract call; per-fact embedding progress lives on `derivatives.embedding_status`. "This version is fully processed" = `extract_status='completed'` AND all its derivatives `embedding_status='completed'` — computed by query, never stored, so there is exactly one definition.

**The per-hour versioning rule (the core design, confirmed from Minimi's DB):** a thread gets at most one *mutable* version per clock hour (`UNIQUE(thread_id, hour_bucket)` enforces it). While you're on a page during the current hour, its version is rewritten in place as content changes. On the first capture after hour rollover, `commitCapture` runs **freeze-then-create in one transaction**: seal the old mutable version (`is_frozen=1`), then upsert the new hour's mutable version. This gives an hourly time-series of how each page evolved at fixed storage cost; extraction diffs against the latest frozen version (fetched by self-join) so we only extract genuinely new facts.

Clock edge cases: `hour_bucket` is epoch-hours, so it is timezone- and DST-proof (note for IST: buckets roll over at :30 local — harmless, just don't be surprised in a demo). If the clock steps *backwards* across an hour boundary (NTP) and a capture's bucket lands on an already-frozen row, the rule is: **write into the frozen row anyway** (un-freeze it) — the invariant is one row per bucket, not monotonic time.

## 5. Capture layer (MaxMiCapture)

- **Frontmost-app + focus detection:** `NSWorkspace.didActivateApplicationNotification` plus an AX `kAXFocusedUIElementChangedNotification` observer on the active app, coalesced through a ~1000ms debounce (matches Minimi's observed 1s debounce). Focus events alone miss scrolling and streamed-in content on a page the user just sits on, so a **30–60s re-capture timer runs while a browser is frontmost** (§3); tree-hash dedup makes it free when nothing changed.
- **Browser detection:** bundle-id allowlist — Chrome (`com.google.Chrome`), Arc (`company.thebrowser.Browser`), Zen (`app.zen-browser.zen`), Safari (`com.apple.Safari`), Brave, Edge. Non-browser frontmost app → ignore in milestone 1.
- **Chromium AX tree kick:** Chromium browsers (Chrome/Arc/Brave/Edge) build their renderer accessibility tree **lazily** — until an assistive client announces itself, the web-content subtree is empty. On first attach, set `AXManualAccessibility = true` on the app's AX element (Chromium-specific; prefer it over `AXEnhancedUserInterface`, which is known to break window managers' resize/positioning). The tree materializes asynchronously (can take >1s on heavy pages), so the first read after the kick may find nothing — that is a **"retry shortly" state, not a failed capture** (see §10).
- **Tab URL (`source_key`) — web area first, address bar fallback:** the primary locator is the **web-content area's URL attribute**: `AXWebArea`'s `AXURL` (WebKit/Gecko) or `AXDocument` (Chromium). This is the document's actual location — full canonical URL with scheme, immune to UI state. The address-bar element is only a fallback, because it is presentation, not identity: Safari shows just the domain by default (which would collapse every page on a site into one thread and corrupt diffing), browsers strip the scheme (verified live on Zen: the `AXComboBox` value is `meet.google.com/…`, no `https://`), and mid-typing its value is the user's half-typed string (a phantom thread per capture). If only the fallback is available, normalize (add scheme) and skip the capture entirely while the address field has keyboard focus.
- **Body extraction (`BrowserTabExtractor`):** title from the window; body text by collecting `AXStaticText` values in visual order (top→bottom, left→right) — the same technique Minimi's `runtime.js` uses. We are re-implementing that traversal in Swift (`AXUIElementCopyAttributeValue` over `kAXChildrenAttribute`, reading `kAXRoleAttribute`/`kAXValueAttribute`/`kAXFrameAttribute`).
- **Permissions:** requires macOS Accessibility permission. On launch, check `AXIsProcessTrustedWithOptions`; if not granted, the menu-bar UI shows a "Grant Accessibility" prompt that deep-links to System Settings. (This is the same TCC dance as Yuki — note [[project_yuki_signing]]: ad-hoc signed apps need re-grant after each rebuild.)
- **Sensitive-domain denylist:** hard-coded set of hosts/URL patterns never captured — banks, `*.bitwarden.com`, `1password.com`, `accounts.google.com`, `okta.com`, `/reset-password`, etc. Seeded from the list we pulled out of Minimi's binary.

## 6. Storage layer (MaxMiStore)

- **Library:** GRDB.swift (mature, synchronous, migration support) as the SQLite layer.
- **sqlite-vec — statically linked, NOT a runtime dylib.** Apple compiles the system `libsqlite3.dylib` with `SQLITE_OMIT_LOAD_EXTENSION`: `sqlite3_load_extension` / `sqlite3_enable_load_extension` are absent from both the library and the SDK header (verified on this machine — a call site doesn't even compile). The plan is therefore: vendor `sqlite-vec.c` as a C target in the SwiftPM package and register it via `sqlite3_auto_extension(sqlite3_vec_init)` before opening the DB — `sqlite3_auto_extension` *is* exported by the system lib. This also sidesteps dylib-loading inside a codesigned `.app` (fine ad-hoc, breaks under hardened runtime later).
- **DB location:** `~/Library/Application Support/MaxMi/maxmi.db` (WAL mode). `chmod 600` the db/`-wal`/`-shm` files at creation, and exclude the directory from Time Machine (`NSURLIsExcludedFromBackupKey`) while content is plaintext (§9).
- **Responsibilities:** schema + migrations, `commitCapture` (the freeze-then-create transaction from §3/§4), the hash-guarded `markExtracted` (§3a), derivative + embedding inserts, retry-queue operations, and vector insert/search helpers (search unused in milestone 1 but implemented + tested so the next milestone is a drop-in).
- **All versioning + status logic lives here** behind a small API (`commitCapture`, `pendingWork`, `markExtracted(versionID:contentHashRead:)`, `enqueueRetry`) so `MaxMiCore` can drive it without touching SQL. Store owns the state machine; Core owns only orchestration (this settles which module the versioning tests belong to — §11).

## 7. Relay layer (MaxMiRelay)

`GeminiClient`, talking directly to Google's Generative Language API with a key from `.env` (see §8). Two operations behind a `MemoryRelay` protocol (so tests inject a mock):

- **`extract(newContent:previousContent:) -> [String]`** — calls a Gemini flash-lite–tier model (`gemini-flash-lite-latest`; we pin the concrete id in code and note the fallback). **We write our own extraction prompt** (Minimi's is server-side and not needed): instruct the model to return a JSON array of atomic, self-contained, third-person fact sentences describing what the user did/read, naming the user by first name; when `previousContent` is provided, extract only facts new since it. This exactly reproduces the input/output contract we captured: `{new_content, previous_content, metadata}` → `["fact", "fact", …]`. `previousContent` is the thread's **latest frozen version** (§4) — and because extraction runs on freeze/idle rather than per capture (§3a), plus hash-dedup on derivatives, within-hour re-extraction can't multiply facts.
- **`embed(text:) -> [Float]`** — Gemini `gemini-embedding-001` with `outputDimensionality: 1536`, embedding each fact sentence whole (no chunking — confirmed from intercept). Only the full 3072-dim output is pre-normalized by Google; at 1536 we **re-normalize client-side** (one line) so M2's similarity thresholds are stable. Returns the 1536-float vector. TODO (not M1): `batchEmbedContents` — one call per fact mimics Minimi but a busy hour can produce dozens of facts against per-request flash-tier rate limits; the retry queue absorbs this for now.

Errors (offline, rate-limit, 5xx) throw; the pipeline catches them and routes the item to `retry_queue` with backoff. Nothing is lost.

## 8. Config & secrets (MaxMiCore)

- `.env` file in the app's Application Support dir (and, for dev, the repo root), loaded at startup. Keys: `GEMINI_API_KEY`, optional `MAXMI_EXTRACT_MODEL`, `MAXMI_EMBED_MODEL`, `MAXMI_EMBED_DIMS` (default 1536).
- `.env` is gitignored. We chose `.env` over Keychain deliberately for this milestone — matches the Yuki-on-Gemini learning that Keychain causes repeated password prompts during dev (note [[project_yuki_gemini3]]).

## 9. Encryption decision (reviewed — plaintext stands for M1)

Milestone 1 stores captured `content` and derivative facts as **plaintext** in SQLite. Reviewed and accepted as a defensible boundary *for a single-user dev build that never leaves this machine*, with the threat model stated honestly:

- TCC does not protect `~/Library/Application Support`; any non-sandboxed process running as the user can already read the DB — exactly as it can read the browser profile's history/cookies next door. At-rest encryption here defends against **backup leakage and casual file access**, not against malware running as you.
- Perspective: M1 ships every captured page to Gemini's cloud in plaintext by design. The local DB is not the biggest exposure surface.

Cheap mitigations we DO take now (all ~free): `chmod 600` on db/wal/shm at creation; exclude the DB dir from Time Machine (§6); no `previous_content` denormalization (§4 — halves the stored plaintext); and the operational rule that capture stays paused during sensitive work, because the hard-coded denylist (§5) is inherently leaky.

Minimi's real design is per-field AES-256-GCM (`enc:v1:` prefix, scrypt-derived Keychain key) over a plaintext SQLite file — we add that as M3, **before** any real/shared use, reusing the exact scheme we documented.

## 10. Error handling

- **Capture failures** (AX read returns nothing, permission revoked): logged, skipped; never crash. Missing Accessibility permission surfaces as a persistent menu-bar warning. **Exception:** an empty read from a Chromium browser right after the `AXManualAccessibility` kick (§5) is *not* terminal for that cycle — "no windows", "tree not built yet", and "browser minimized" are indistinguishable to a naive reader, so the extractor schedules a short retry (~2s, a couple of attempts) before giving up.
- **Network failures**: item → `retry_queue` with exponential backoff; a periodic worker drains it when a key is present and the network is up. Version stays `pending` until extract completes (per-fact embedding state is on the derivative, §4).
- **Malformed Gemini output** (extract not valid JSON array): one reparse attempt (strip code fences, first-`[`-to-last-`]`), then mark `failed` and enqueue retry; never store garbage.
- **Concurrency**: completion writes are hash-guarded (§3a) so a capture landing while extract is in flight can never be marked completed-but-unextracted; extract re-runs are idempotent via derivative hash-dedup (§4), so a crash between extract and embed cannot duplicate facts on retry.
- **DB**: all multi-step commits (upsert thread + freeze + version) run in one transaction.

## 11. Testing strategy

- **MaxMiCoreTests** — orchestration only, with mocked Store + Relay (Store owns the versioning state machine, §6): given Store reports pending work, the pipeline extracts, stores derivatives, embeds each; a new page produces thread→version→N derivatives→N embeddings; a re-capture with identical content produces nothing. Plus hour-bucket math and dedup-hash utilities (pure functions in Core).
- **MaxMiStoreTests** — schema/migrations apply, the "one mutable version per thread per hour + freeze-then-create on rollover" rule against real SQLite (including the UNIQUE(thread_id, hour_bucket) constraint and the clock-stepped-backwards un-freeze rule, §4), vector insert + nearest-neighbor round-trip via sqlite-vec. **Explicit lost-update interleaving test:** commit C1 → pipeline reads C1 → commit C2 (resets to pending) → `markExtracted(hash(C1))` must update zero rows and leave the version pending. And idempotency: running extract-completion twice for the same content stores no duplicate derivatives.
- **MaxMiCaptureTests** — `BrowserTabExtractor` against a few recorded AX-tree fixtures (captured as JSON from real browser windows) → asserts correct URL/title/text extraction (web-area `AXURL` preferred over address bar; scheme-less fallback normalized) and denylist filtering. No live browser needed in CI.
- **Relay** — mocked HTTP; assert request shape matches the captured contract and response parsing handles the JSON-array and fenced-JSON cases.
- Verify end-to-end manually per the `verify` skill before calling the milestone done: run the app, browse 3-4 pages, confirm the DB has correct threads/versions/derivatives/embeddings.

## 12. Milestone exit criteria

1. App launches as a menu-bar item, requests/holds Accessibility permission.
2. Browsing distinct pages creates one thread per **full canonical URL** with correct titles — including in Safari with "Show full website address" off, and in a freshly-launched Chromium browser (tree kick works).
3. Re-viewing an unchanged page creates no new version (dedup works); viewing it in a later hour freezes the prior version and starts a new one.
4. Each version yields extracted third-person fact sentences (via the idle/freeze trigger, §3a) and a 1536-dim normalized embedding per fact, stored locally. Re-capturing a page several times within one hour does **not** duplicate its facts.
5. Killing the network mid-capture loses no data — items retry and complete when back online. A capture landing while an extract is in flight leaves the version `pending` (hash guard), and the newer content is extracted on the next trigger.
6. Menu bar shows a live capture count. Sensitive domains are never stored. DB files are mode 600 and excluded from Time Machine.

## 13. Later milestones (not now)

M2: MCP server exposing `search_memory` / `list_threads` (markdown output, 20-item cap) so Claude can query the DB. M3: per-field AES-GCM encryption + Keychain key. M4: chat-app + document parsers. M5: meetings (system-audio capture + transcription). M6: hourly agent + activity timeline. M7: team sharing.
