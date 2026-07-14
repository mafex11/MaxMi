# Phase 5 retrieval and MCP parity

Date: 2026-07-14

## Outcome

Phase 5 separates four retrieval jobs instead of treating semantic fact search as a universal answer:

| Question | MCP tool | Evidence returned |
|---|---|---|
| What was I just doing? | `get_latest_context` | Fresh full captured context |
| What did I learn about X? | `search_memory` | Semantically matching extracted facts |
| What sources was I using? | `list_active_threads` | Recent threads and their latest facts |
| What happened in a meeting/voice note? | `meeting_memory` | Recording metadata, transcript, and facts |

The MCP process remains a local stdio child. It opens SQLite read-only, never runs migrations, never writes a cursor to the database, and never participates in capture transactions.

## Shared filters

The four tools accept these shared optional arguments where applicable:

| Argument | Contract |
|---|---|
| `source_apps` | Exact, case-insensitive source-app names |
| `lookback_minutes` | Positive duration measured back from the response's fixed `as_of` |
| `start_time` / `end_time` | Inclusive RFC3339 timestamps with timezone; cannot be combined with lookback |
| `timezone` | IANA identifier used to render response metadata; defaults to the Mac timezone |
| `cursor` | Opaque next cursor from the same tool, query, and filter set |
| `limit` | Page size, bounded to 20 |

Every result includes an absolute timestamp, a relative timestamp, timezone, and `as_of`. A cursor contains only version, tool/scope hashes, offset, and `as_of`; it contains no captured text, query text, API key, or database secret. Changing the query, app, range, kind, thread, timezone, or tool invalidates the cursor instead of silently mixing result sets.

## Tool-specific behavior

### `search_memory`

Embeds `query`, then applies exact source/time filters to encrypted facts joined to their source threads. Results above the existing cosine-distance noise floor are omitted. Responses expose the source app/key and thread ID so Claude can ask for the supporting raw context.

### `list_active_threads`

Lists current threads by `updated_at DESC, id ASC` and includes each thread's own three newest facts at or before `as_of`. App/time filters and cursors are supported.

### `get_latest_context`

Does not call Gemini or require network access. It decrypts only the selected latest contexts and marks captured text as untrusted source material. In addition to shared filters it accepts:

- `source`: legacy fuzzy match across app, title, and source key;
- `thread_id`: exact per-thread lookup;
- `content_kinds`: any of `webpage`, `conversation`, `document`, `terminal`, `email`, `calendar`, `task`, `meeting`, `voiceNote`, or `generic`.

This is the structured retrieval path for recent conversations, tasks, and calendar events.

### `meeting_memory`

Actions remain `list`, `search`, and `get_context`. List/search accept shared filters and cursors. `get_context` accepts explicit `meeting_id` or `thread_id`; the older meeting ID in `query` remains compatible. Meeting and voice-note results include both IDs. Transcript text is marked untrusted, and semantic meeting results are deduplicated per recording.

## Safe Claude registration

The helper performs an MCP initialize/tool-list handshake before proposing any registration. Its default is a dry run:

```bash
tools/setup-mcp.sh --target claude-code
tools/setup-mcp.sh --target claude-desktop
```

Apply only after reviewing the discovered executable and destination:

```bash
tools/setup-mcp.sh --target claude-code --apply
tools/setup-mcp.sh --target claude-desktop --apply
```

An existing `maxmi` entry is not changed unless `--replace` is supplied. Claude Code registration is user-scoped, and an existing local/project entry is never removed automatically. Claude Desktop's JSON is validated, backed up with a timestamp, modified through `plutil`, converted back to JSON, set to mode `0600`, and validated again. The helper never copies the encryption key or Gemini key into either Claude configuration.

## Acceptance

The full suite passes 420 tests. Automated coverage verifies:

- exact app and time isolation;
- lookback/RFC3339 validation and IANA timezone validation;
- cursor continuation, fixed `as_of`, malformed-cursor errors, and cross-scope rejection;
- structured task/calendar raw context without an embedding call;
- meeting lookup by explicit thread ID and meeting app/time filtering;
- stdio handshake/tool schema behavior;
- isolated Desktop config create, backup, replace, permissions, and parseability.

Live acceptance remains:

1. Ask Claude, “What was I just doing?” and confirm it selects `get_latest_context`.
2. Ask about a known topic and confirm it selects `search_memory` with evidence-backed facts.
3. Ask what happened in a controlled recording and confirm it uses `meeting_memory`.
4. Repeat an app/time-filtered query through at least two cursor pages and confirm no duplicates.

Do not paste the returned private context into an issue or commit it as a fixture. Record only tool choice, result count, cursor presence, and whether the answer was supported.

## Content-free live status

The signed `MaxMi.app` was rebuilt and relaunched with the Phase 5 binary. Its bundled `maxmi-mcp` passed initialize and tool-list preflight. The installed Claude Code CLI reports the existing project-local `maxmi` registration as connected and pointing at this exact bundled executable. No retrieval tool was called against the live database, so no title, URL, fact, context, transcript, or summary was read during this verification.
