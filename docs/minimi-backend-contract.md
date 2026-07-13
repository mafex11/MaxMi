# Minimi Backend API Contract (HTTP Toolkit + Node inspector, 2026-07-07)

## Capture methodology

This contract came from a two-part reverse-engineering effort:

1. **HTTP Toolkit interception.** Minimi was launched through HTTP Toolkit with both
   interception layers enabled: HTTP Toolkit's Node `NODE_OPTIONS` require hook for
   Node-side requests, and Electron's `--proxy-server` flag for Chromium's network
   service. The HTTP Toolkit CA was supplied through `NODE_EXTRA_CA_CERTS`, and the
   standard/global-agent proxy variables were pointed at its local proxy. This was
   necessary because Minimi uses more than one network stack. The reproducible launcher
   is `tools/launch-minimi-intercepted.sh`; `tools/scrub-har.mjs` safely redacts and
   truncates any HTTP Toolkit HAR export before it is shared.
2. **Node-inspector fetch hook.** Minimi was also launched with `--inspect`, then
   `tools/inspect-minimi-net.mjs` attached to its Electron main process and wrapped
   `globalThis.fetch`. This captured the request/response bodies for the Minimi backend
   calls that mattered to the memory contract when proxy-only inspection was incomplete.

The preserved private capture is `captures/minimi-net-2026-07-07.log` (gitignored because
it contains real browsing content). It contains 70 JSONL records: 1 capture-note record and
69 successful requests—6 memory extracts, 26 memory embeddings, 1 display rewrite, and 36
PostHog proxy events. No raw private content is reproduced here. All calls below go to
`https://backend.projectminimi.com`; bodies are STRUCTURE ONLY.

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
