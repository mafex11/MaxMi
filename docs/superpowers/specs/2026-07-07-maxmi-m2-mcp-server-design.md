# MaxMi — Milestone 2: MCP Memory Server

**Date:** 2026-07-07
**Status:** Approved design
**Depends on:** M1 (merged to main 2026-07-07, live-verified: 44 threads / 225 embedded facts at time of writing).

## 1. What we're building

A local MCP server, `maxmi-mcp`, that lets Claude (Claude Code and Claude Desktop) query the memory database M1 populates. This is the payoff milestone: M1 writes memory; M2 makes it readable by the assistant.

We match **Minimi's externally observable MCP contract** (verified via reverse-engineering — binary strings + the leaked tool schema): tool names `search_memory`, `list_active_threads`, `meeting_memory`; **markdown output, not JSON**; **20-item cap**; facts returned in stored **third-person** form (Minimi's second-person rewrite is a display-UI concern, not an MCP one). We deliberately do NOT copy Minimi's plumbing: their MCP path routes through their cloud backend over WebSocket because their product has an account layer; ours is a local stdio process reading the same SQLite file directly — faster, private, and no relay to build.

**Success test:** from a fresh Claude Code session (and from Claude Desktop), "what anime was I watching on Netflix?" returns the stored Gin Tama facts via `search_memory`, and "what have I been reading recently?" surfaces recent threads via `list_active_threads`.

## 2. Non-goals for Milestone 2

- No claude.ai (browser) support — that is the one consumer that genuinely needs a remote transport; deferred until wanted.
- No real meeting data — `meeting_memory` ships as a **schema-parity stub** (decided: exact tool-list parity with Minimi, honest "not yet" answer).
- No second-person rewrite endpoint.
- No keyword/FTS fallback — search is vector-only, exactly like Minimi (verified: no FTS index anywhere in their schema). Offline search returns a clear error message, not degraded results.
- No writes to the DB from the MCP server, ever.
- No Windows. (Considered: Electron/Node for portability. Rejected: capture — the actual product — is macOS AX-bound; a portable query layer over a Mac-only DB ships nothing on Windows, and the stdio contract makes the server trivially replaceable if a Windows capture app ever exists.)

## 3. Architecture

New executable target in the existing SwiftPM package — no new repo, no new toolchain:

```
Sources/
  MaxMiMCP/       maxmi-mcp executable
    MCPServer.swift      stdio JSON-RPC 2.0 loop: initialize, tools/list, tools/call,
                         notifications handling, protocol version 2025-06-18. No SDK;
                         MCP's stdio framing is newline-delimited JSON-RPC (~250 lines).
    Tools.swift          tool schemas (names/descriptions/inputSchema) + dispatch
    MemoryQueries.swift  search/list logic -> markdown strings. Pure functions over
                         Store + MemoryRelay; unit-testable against in-memory DB.
Tests/
  MaxMiMCPTests/         framing, schemas, query->markdown, caps, offline errors
```

Reused unchanged: `MaxMiStore` (DB, vector KNN via `nearestDerivatives` — already implemented and tested in M1 for exactly this), `MaxMiRelay` (GeminiClient embeds the query), `MaxMiCore` (EnvConfig). One small Store addition: a **read-only open mode** (`MaxMiDatabase(path:readOnly:)` using SQLITE_OPEN_READONLY through GRDB's Configuration).

**Concurrency with the menu-bar app:** the app holds the DB in WAL mode; WAL is designed for concurrent readers alongside one writer. `maxmi-mcp` opens read-only; no coordination, no IPC. (Considered: routing through the app over a socket, Minimi-style. Rejected: their WS hop exists for their cloud entry point, not for correctness.)

**Data flow (search_memory):**

```
Claude -> tools/call search_memory {query, limit?}
  -> GeminiClient.embed(query)            gemini-embedding-001, 1536 dims, normalized
                                          (same model+dims+normalization as stored facts)
  -> Store.nearestDerivatives(vector, k)  sqlite-vec KNN, k = min(limit ?? 10, 20)
  -> join derivative -> thread            fact text, source_title, source_key, committed_at
  -> markdown                             bullet per hit: fact, source line, relative time
```

## 4. Tool contract

Registered names, order, and shapes mirror Minimi's tool list exactly.

### `search_memory`
- Input: `{ query: string (required), limit?: number (default 10, max 20) }`
- Behavior: embed → KNN → markdown. Results ordered by ascending vector distance.
- Output (markdown, one block):
  ```
  ## Memory search: "<query>"

  - <fact sentence (third person, verbatim as stored)>
    — <source_title> (<source_key>), <relative time, e.g. "2 hours ago">
  ...
  _<n> results (of <total facts> memories)_
  ```
- Empty result → `No memories matched "<query>".`
- No API key / network failure → tool result with `isError: true` and text
  `Memory search needs the Gemini API key and network access (vector search embeds the query). Capture and browsing history are unaffected.`

### `list_active_threads`
- Input: `{ limit?: number (default 10, max 20) }`
- Behavior: threads ordered by `updated_at` DESC; for each, its 2–3 most recent facts (by `committed_at`). Threads with zero facts still listed (title + URL + last-seen) — recent captures may not have extracted yet.
- Output (markdown): `### <source_title>` + URL + last-seen line + fact bullets per thread.

### `meeting_memory` (stub)
- Input: `{ action: "list" | "get_context" | "search", query?: string }` — schema matches Minimi's leaked shape.
- Every action returns (not an error):
  `No meetings captured yet — meeting capture is a later MaxMi milestone. Use search_memory for everything read on screen.`

## 5. Server behavior details

- **Transport:** stdio. stdout carries ONLY protocol JSON; all logging to stderr.
- **Protocol:** JSON-RPC 2.0; `initialize` returns protocolVersion `2025-06-18`, capabilities `{tools: {}}`, serverInfo `{name: "maxmi", version: <CFBundleShortVersionString-equivalent constant>}`. Handles `notifications/initialized` (ignore), `ping` (empty result), unknown methods → `-32601`.
- **DB path:** `~/Library/Application Support/MaxMi/maxmi.db`, read-only. Missing DB → tools return friendly "MaxMi hasn't captured anything yet — is the menu-bar app running?" rather than crashing at startup (server must start cleanly even before first capture; it re-checks per call).
- **Config:** same `.env` search as the app (AppSupport/MaxMi/.env, then CWD/.env) via EnvConfig.
- **Per-call DB open vs long-lived handle:** long-lived read-only GRDB DatabaseQueue opened lazily on first tool call (WAL readers see committed writes without reopening).

## 6. Install & registration (decided: documented manual, no auto-config)

- `packaging/make-app.sh` additionally copies `.build/release/maxmi-mcp` to `MaxMi.app/Contents/MacOS/maxmi-mcp` (rides inside the bundle; stable path) — and the script prints the registration one-liner.
- README section:
  - Claude Code: `claude mcp add maxmi -- /Applications/…/MaxMi.app/Contents/MacOS/maxmi-mcp` (or repo-local path during dev)
  - Claude Desktop: the `mcpServers` JSON snippet for `claude_desktop_config.json`.
- No TCC/Accessibility involvement — the MCP server never touches AX, so it survives rebuilds without re-grants.

## 7. Error handling

- Gemini errors (offline, 429, 5xx, keyless): caught per call → `isError: true` tool result with the §4 message. Never enqueued to the app's retry queue (that queue belongs to the capture pipeline; a failed *query* should fail fast, not retry later).
- Malformed tool arguments → JSON-RPC error `-32602` with what was wrong.
- DB read errors → `isError: true` tool result; the server keeps serving.
- The server must never write to stdout outside JSON-RPC frames (would corrupt the transport) and must never crash on bad input — fuzz-ish tests cover truncated/garbage frames.

## 8. Testing strategy

- **MaxMiMCPTests** (all against in-memory or temp-file DBs; Gemini mocked via the existing `MemoryRelay` protocol):
  - JSON-RPC framing: initialize handshake, tools/list returns exactly 3 tools with expected schemas, unknown method, garbage line → no crash + error response.
  - `search_memory`: known fixture facts with hand-built orthogonal embeddings → correct ordering, limit honored, 20 cap enforced, empty-result text, offline error text (mock relay throws), third-person text passes through verbatim.
  - `list_active_threads`: recency order, fact sub-bullets, zero-fact thread included, cap.
  - `meeting_memory`: all three actions → stub text.
  - Read-only mode: writes through the read-only handle fail; reads succeed while a second writable connection commits (WAL concurrency smoke test).
- **Live exit test** (manual, per §1): register in Claude Code + Claude Desktop, ask the two golden questions against the real 225-fact DB.

## 9. Milestone exit criteria

1. `maxmi-mcp` builds from the same package; `make-app.sh` bundles it.
2. `claude mcp add` registration works; `tools/list` shows the 3 Minimi-parity tools.
3. The Gin Tama question returns the stored facts through real embed→KNN, in markdown, ≤20 items, third-person.
4. `list_active_threads` shows genuinely recent browsing with facts.
5. Server survives: no key, no network, no DB, garbage stdin — always a clean protocol-level answer, never a crash, never a DB write.
6. Same behavior from Claude Desktop.

## 10. Later milestones (unchanged roadmap)

M3: per-field AES-GCM encryption + Keychain key (+ real signing identity to end the TCC re-grant pain). M4: chat-app + document parsers. M5: meetings (then `meeting_memory` becomes real). M6: hourly agent + timeline. M7: team sharing.
