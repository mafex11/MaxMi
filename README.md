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

The app bundles `maxmi-mcp`, a local MCP server that lets Claude search your memory.

**Claude Code:**
```bash
claude mcp add maxmi -- /path/to/MaxMi.app/Contents/MacOS/maxmi-mcp
```

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{ "mcpServers": { "maxmi": { "command": "/path/to/MaxMi.app/Contents/MacOS/maxmi-mcp" } } }
```

Tools: `search_memory` (semantic search over captured facts), `list_active_threads`
(recent pages), `get_latest_context` (fresh encrypted raw context without embedding), and
`meeting_memory` (meeting list/search/context). Reads the DB read-only;
never interferes with capture. Uses the same `.env` Gemini key to embed queries.
Optional: `MAXMI_DB_PATH` env var overrides the DB location.

## Documentation

See `docs/MINIMI_MAXMI_PARITY_BLUEPRINT.md` for the parity roadmap,
`docs/PHASE2_BROWSER_COVERAGE.md` for browser coverage, and `docs/superpowers/`
for the original technical specifications and implementation plans.
