# MaxMi

MaxMi is a self-built ambient-memory Mac menu bar app modeled after Minimi. It captures context from active browser and native-app windows, stores encrypted rolling context with versioning and deduplication, and generates concise capture summaries plus searchable facts. Browser capture supports Chromium, WebKit, and Gecko families with strict URL privacy gates and semantic profiles for high-value web apps.

## Build

```bash
./packaging/make-app.sh
```

This produces `MaxMi.app` in the repo root. The app bundle is gitignored.

## Setup

1. Create `~/Library/Application Support/MaxMi/.env` with your Gemini API key:
   ```
   GEMINI_API_KEY=<your-key>
   ```

2. Launch `MaxMi.app`. Grant Accessibility permission when prompted.

3. **Important:** MaxMi is signed with an Apple Development identity. Signed builds retain their Accessibility grant across rebuilds. ONE final re-grant is needed when upgrading from an ad-hoc build:
   ```bash
   tccutil reset Accessibility dev.mafex.maxmi
   ```
   Then launch the app again and grant the permission.

## Encryption

MaxMi encrypts memory content using AES-256-GCM (`enc:v1:` wire format). The encryption key is stored in the macOS login Keychain under service `dev.mafex.maxmi.dbkey`. The app and the bundled `maxmi-mcp` server share the key by service name — both are signed with the same identity, so each reads the same login-keychain item (the first read by each binary prompts once for "Always Allow", then stays silent). No keychain-access-group entitlement is used, since that requires a provisioning profile. Deleting the Keychain key makes old memories unrecoverable. Metadata, URLs, and embeddings remain cleartext by design for efficient search and deduplication. See `docs/superpowers/specs/2026-07-07-maxmi-m3-encryption-signing-design.md` §8 for the threat model.

## Connect to Claude (MCP)

The app bundles `maxmi-mcp`, a local, read-only MCP server that lets Claude search your memory.

The guided setup validates the MCP handshake first and defaults to a dry run:

```bash
tools/setup-mcp.sh --target claude-code
tools/setup-mcp.sh --target claude-code --apply

tools/setup-mcp.sh --target claude-desktop
tools/setup-mcp.sh --target claude-desktop --apply
```

Claude Desktop configuration is backed up before modification. Existing `maxmi` entries are
left untouched unless `--replace` is explicitly supplied; non-user-scoped Claude Code entries
are never removed automatically.

Manual **Claude Code** registration:
```bash
claude mcp add maxmi -- /path/to/MaxMi.app/Contents/MacOS/maxmi-mcp
```

Manual **Claude Desktop** registration — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{ "mcpServers": { "maxmi": { "command": "/path/to/MaxMi.app/Contents/MacOS/maxmi-mcp" } } }
```

Tools: `search_memory` (semantic facts), `list_active_threads` (recent sources),
`get_latest_context` (fresh full context without embedding), and `meeting_memory`
(meeting/voice-note list, search, and transcript context). All tools support exact app and time
filters; list/search tools return deterministic opaque cursors. Raw context can additionally be
filtered by thread and structured kind (`conversation`, `calendar`, `task`, and others).
Responses include a fixed `as_of` time and timezone. The server reads the DB read-only and never
interferes with capture. Semantic searches use the same `.env` Gemini key to embed queries.
Optional: `MAXMI_DB_PATH` env var overrides the DB location.

## Documentation

See `docs/MINIMI_MAXMI_PARITY_BLUEPRINT.md` for the parity roadmap,
`docs/PHASE2_BROWSER_COVERAGE.md` for browser coverage,
`docs/PHASE3_NATIVE_COVERAGE.md` for structured native-app coverage,
`docs/PHASE4_MEETINGS_VOICE.md` for meeting and voice-note verification,
`docs/PHASE5_RETRIEVAL_MCP.md` for retrieval filters, cursors, and Claude setup, and
`docs/superpowers/` for the original technical specifications and implementation plans.
