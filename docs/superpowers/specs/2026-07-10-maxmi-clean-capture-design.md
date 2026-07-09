# MaxMi — Clean Capture by Design (Central Keying + Fingerprint Dedup)

**Date:** 2026-07-10
**Status:** Approved design
**Motivation:** After M4, the DB accumulated fracture noise — 38 stale Google Maps threads (coords in URL), Google Docs `/u/N/` account-index splits, garbage terminal keys (`terminal:warp/inspect2.mjs`, `terminal:warp/maxmi.app).`), and near-duplicate message re-commits. Every fix so far was reactive (patch a parser after it dirtied the DB). Goal: **capture cleanly from the start**, so the DB stays a high-signal memory for future Claude sessions.
**Grounding:** Reverse-engineered from Minimi's actual code (`/Applications/Minimi.app` app.asar + main.jsc). This spec adopts Minimi's proven separation. See [[project_minimi_reverse_engineering]], [[project_maxmi]], [[project_maxmi_ax_capture]].

## 1. Root cause

Fracture has one root cause: **key derivation is freelanced inside each parser, with no shared validation before commit.** A parser grabs a token that looks like identity but is volatile (map coords, a file arg, a doc `/u/N/`, a transient title fragment), writes it straight into `source_key`, and `commitCapture` stores it unquestioned. There is no chokepoint guaranteeing a clean, stable key regardless of which parser produced it — so each new parser can (and did) invent a new fracture.

## 2. How Minimi solves it (evidence, from its code)

1. **Parsers return content + a human title/channel — never a key.** `notion.js`/`mail.js`/etc. return `{app, title, content}` (chat: `{channel: subject}`). Key derivation is centralized downstream. A parser structurally *cannot* create a fracturing key because it doesn't create keys.
2. **Thread identity is built from SEMANTIC fields**, not raw volatile strings: Slack via regex `^(.+?)\s*\((?:Channel|DM|…)\)\s*-\s*(.+?)\s*-\s*Slack$` → workspace/channel; Mail keyed by **subject**. Never coordinates/query-strings/file-paths.
3. **Two-level dedup:** `last_tree_hash` (tree unchanged → skip) AND a `message_fingerprints` table (`fingerprint TEXT PRIMARY KEY`, `INSERT OR IGNORE`, only novel fingerprints stored) for per-item dedup so the same message never re-commits.
4. **GenericWeb normalizes URLs and logs `unparseable URL`** rather than storing garbage.

MaxMi already has #3-partial (`last_tree_hash`) and a start on #4 (`URLKeyNormalizer`). It lacks the **central keyer** (#1/#2) and **per-item fingerprint dedup** (#3-full).

## 3. What we're building

Three changes, adopting Minimi's separation of *content* (parser) / *identity* (central keyer) / *novelty* (fingerprint dedup):

### 3a. Central `ThreadKeyDeriver` — the single keying chokepoint
A new pure component that turns a parser's raw output into a clean, stable `source_key`. Parsers stop being trusted to produce final keys; every capture passes through the deriver before `commitCapture`.

- Parsers keep returning `ParsedCapture`, but its `sourceKey` becomes an **identity hint** (a proposed key or the semantic fields), not the final stored key.
- `ThreadKeyDeriver.derive(_ capture:) -> String` applies, in order:
  1. **Per-app semantic rules** (moved OUT of parsers): Slack workspace/channel, Mail subject/mailbox, Notion page, Obsidian vault/note, Notes title, Terminal cwd, Web via `URLKeyNormalizer`.
  2. **Universal hygiene** (applies to ALL keys, present and future parsers): strip trailing punctuation/brackets/`…`; collapse whitespace/newlines; lowercase; length-bound; if the last path segment looks like a filename (has a short alpha/num extension) coarsen to the parent.
  3. **Degenerate-key fallback:** if hygiene leaves the key empty or garbage, coarsen to the **app-level key** (`terminal:warp`, `web:<host>`) — **never drop the capture.** Principle: *coarse-but-stable always beats fine-but-volatile.*
- Keying rules live in one file with one test suite — a new parser inherits hygiene + fallback for free and only adds its semantic rule.

### 3b. `message_fingerprints` table — per-item dedup
New table + logic mirroring Minimi, so near-identical content doesn't create redundant facts.

```sql
CREATE TABLE message_fingerprints (
  fingerprint  TEXT PRIMARY KEY,     -- sha256 of normalized item text
  thread_id    TEXT NOT NULL REFERENCES threads(id),
  seen_at      INTEGER NOT NULL
);
CREATE INDEX idx_fingerprints_thread ON message_fingerprints(thread_id);
```

- On commit, split content into items (lines for chat/mail/terminal; whole-doc for documents), hash each (normalized: trim, collapse whitespace, lowercase), and keep only fingerprints NOT already present (`INSERT OR IGNORE`, filter to `novelFingerprints`).
- If NO novel items → treat as `.deduplicated` (skip version creation). This complements `last_tree_hash`: tree-hash catches "nothing changed at all"; fingerprints catch "only chrome/order changed, no new messages."
- Fingerprints are content-only (already-encrypted DB; fingerprint is a hash, stores no plaintext).

### 3c. Golden-fixtures regression harness — lock cleanliness in
Recorded real captured samples per app (sanitized), run through parser → deriver, asserting:
- the derived key is **clean** (no punctuation/coords/file-ext/whitespace), and
- the key is **stable across repeated/varied captures** of the same logical entity (two map pans → one key; two doc tabs → one key; two terminal ticks in the same cwd → one key).
- A new parser cannot merge without a fixture proving its keys are clean+stable. This is what makes it clean *from the start* — fracture is caught in CI, not in the DB days later.

## 4. Non-goals

- **No two-tier schema redesign** (thread=coarse identity + version-metadata=volatile detail). Considered; deferred. The central keyer + fingerprint dedup gets ~90% of the benefit without a schema-wide migration and parser rework. Revisit only if fracture persists.
- **No historical data rewrite in THIS spec.** A separate one-time cleanup (re-key the 38 maps threads, merge `/u/N/` docs, drop garbage terminal keys) is tracked but out of scope here — this spec is about capturing clean *going forward*, per the user's explicit priority. (Cleanup becomes trivial once the deriver exists: replay keys through it.)
- No change to encryption, MCP, extraction, or the capture trigger cadence.
- No new capture modality (meetings = M5).

## 5. Architecture / where things change

```
FocusObserver → captureFrontmost → attemptCapture (off-main AX read)
  → parser.parse() → ParsedCapture{ sourceApp, sourceKey(HINT), sourceTitle, content }
  → ThreadKeyDeriver.derive(capture) → clean stable source_key         ← NEW (3a)
  → CaptureDispatch.shouldCommit (denylist + pause) [unchanged]
  → store.commitCapture(input, nowMs)
        ├ last_tree_hash dedup [unchanged]
        ├ fingerprint dedup: novel items only, no-novel → deduplicated ← NEW (3b)
        └ version upsert [unchanged]
```

- **New:** `Sources/MaxMiCapture/ThreadKeyDeriver.swift` (+ per-app semantic rules consolidated from the parsers), `message_fingerprints` migration in `Migrations.swift`, fingerprint logic in `StoreAPI.commitCapture`.
- **Changed:** each parser's key method becomes a semantic-hint provider (or moves its rule into the deriver); `AppWiring` inserts the derive step; `commitCapture` gains the fingerprint pass.
- **Fixtures:** `Tests/MaxMiCaptureTests/Fixtures/keys/*` recorded samples + `ThreadKeyDeriverTests`, `FingerprintDedupTests`.

## 6. Migration & compatibility

- New migration `v2` adds `message_fingerprints` (additive; existing threads/versions untouched).
- Existing threads keep their (possibly dirty) keys until the separate cleanup pass — new captures of the same entity will derive the CLEAN key and thus may create one new clean thread alongside the old dirty one. Accepted: the dirty ones age out / get cleaned separately. Documented, not silent.
- `DatabaseMigrator` runs `v2` idempotently on launch (same pattern as `v1`).

## 7. Error handling

- Deriver is pure and total: it always returns a non-empty key (worst case, the app-level fallback). It cannot throw or return empty → no capture is ever dropped for a keying failure.
- Fingerprint dedup failure (DB error) fails **open** for capture safety: on error, treat all items as novel (commit) rather than silently dropping — a redundant fact is better than lost memory. Logged.
- No-silent-fallback for parsers unchanged.

## 8. Testing

- **ThreadKeyDeriverTests:** hygiene (punctuation/ellipsis/whitespace/case/length), file-ext coarsening, degenerate→app-fallback, and each per-app semantic rule (Slack/Mail/Notion/Obsidian/Notes/Terminal/Web) — using the real dirty keys from the live DB as inputs (`terminal:warp/maxmi.app).` → `terminal:warp`, maps-coord URL → `web:.../maps`, `/u/N/` docs → one key).
- **FingerprintDedupTests:** novel-only commit; no-novel → deduplicated; whitespace/order-only change → deduplicated; genuinely new line → commits.
- **Golden fixtures:** per-app recorded sample → clean+stable key assertions; a new-parser fixture template.
- **CommitCapture integration:** fingerprint pass composes correctly with last_tree_hash + freeze-then-create.
- All fixture-driven; no live apps in CI.

## 9. Exit criteria

1. All parsers route through `ThreadKeyDeriver`; no parser writes a final `source_key` directly.
2. Every derived key is clean (no punctuation/coords/file-ext/whitespace/uppercase) and app-fallback-safe — proven by the deriver suite over the live dirty-key corpus.
3. `message_fingerprints` live; recapturing an unchanged/whitespace-only-changed thread creates NO new facts; a genuinely new message does.
4. Golden-fixtures harness green; adding a parser requires a passing key fixture.
5. Live: browse Maps (pans → one `web:.../maps` thread), edit a Notion page over minutes (one thread, novel facts only), work in one terminal cwd (one `terminal:warp/<cwd>` thread). DB shows no new fracture.
6. Full suite green, zero warnings.

## 10. Rollout

Spec → plan → subagent-driven build (per M4 workflow) → live verify → then the separate historical-cleanup pass (replay existing keys through the deriver, merge collisions). Discord/Telegram parsers come AFTER this lands, so they are born clean.
