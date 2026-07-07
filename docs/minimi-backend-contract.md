# Minimi Backend API Contract (captured via Node inspector, 2026-07-07)

Captured by attaching to Minimi's Electron main process (`--inspect`) and hooking
`globalThis.fetch`. All calls go to `https://backend.projectminimi.com`. Bodies below
are STRUCTURE ONLY — private page content redacted.

## POST /api/memory/extract
Turns a captured page/thread into atomic memory facts.

Request:
```json
{
  "new_content": "(From: <source>)(sent <ISO8601>): <raw captured text, newline-joined>",
  "previous_content": null,            // prior version's content for diffing; null if new
  "metadata": { "source_app": "Web", "source_key": "<url-or-thread-id>" }
}
```

Response:
```json
{ "success": true, "data": { "memories": [ "<fact sentence>", "<fact sentence>", ... ] } }
```
- `memories` = array of **plain english third-person fact sentences** ("<User> viewed X", "The plot of X involves Y").
- Count scales with content richness (observed 2-5 per page). Each fact is one self-contained sentence naming the user by first name.
- These strings become rows in `memory_derivatives` (then embedded individually).

## POST /api/memory/embed
Request: `{ "text": "<full text of one memory/derivative>" }`
Response: `{ "success": true, "data": { "embedding": [ <floats> ] } }`  (1536-dim, per DB schema)
- Embeds the FULL text of each item whole — NO chunking. One call per derivative.

## POST /api/memory/rewrite-for-display  [CONFIRMED via intercept]
Converts stored third-person facts to second-person for the app UI.
Request:  `{ "memories": [ "<User> accessed X on Y." ] }`
Response: `{ "success": true, "data": { "rewritten": [ "You accessed X on Y." ] } }`
- Insight: memories are STORED third-person (good for Claude context) but DISPLAYED second-person.

## POST /api/activity/detect-conversation  [INFERRED from binary strings — NOT seen in this intercept]
Classifies an activity episode (chat vs website vs document). Feeds activity_conversations.
Payload shape unconfirmed; did not fire during this capture session. Documented from main.jsc only.
Other endpoints known from binary but NOT captured live: /api/memory/extract-meeting,
/api/memory/extract-voice-note, /api/activity/hourly-review, /api/activity/summarize-meeting,
/auth/google/*, /api/billing/*. Fire only on meetings/voice-notes/hourly-agent/auth/billing.

## POST /api/posthog/events
Analytics, proxied through their backend (very frequent). Ignore for cloning.

## Key takeaways for MaxMi
1. **Extraction prompt is server-side** — we design our own. Input/output contract is what matters:
   raw text (+ optional previous version) -> array of atomic fact sentences.
2. **Facts are third-person-named english sentences** (stored), not JSON objects. Simple + embeddable.
   Rewritten to second-person only for display.
3. **Embed each fact whole** (no chunking); store 1536-dim vector. `{text} -> {embedding}`.
4. Diffing: they pass `previous_content` so the model only extracts NEW facts vs the last version.
   ⚠ RESOLVED (inconclusively): checked the raw intercept — all 6 extract calls in the session had
   `previous_content = null` because each was a first capture of a distinct URL. No same-thread
   re-extract was captured, so the log CANNOT disambiguate "last stored row" vs "last extraction
   snapshot". Moot for MaxMi: our design extracts only on freeze/idle and diffs against the latest
   FROZEN version (spec §3a), so there is never a competing within-hour baseline. Do not re-grep the
   log expecting an answer — capture a same-URL re-extract if this ever needs confirming for parity.
