# MaxMi

MaxMi is a self-built ambient-memory Mac menu bar app modeled after Minimi. It captures browsing context from active browser windows (Safari and Zen), storing full page snapshots with versioning, deduplication, and automatic fact extraction. Captured data is embedded locally via Gemini, enabling context-aware retrieval. The M1 milestone delivers the full capture-to-database pipeline with offline queue handling and privacy protections.

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

MaxMi encrypts memory content using AES-256-GCM (`enc:v1:` wire format). The encryption key is stored in macOS Keychain under service `dev.mafex.maxmi.dbkey`, shared with the `maxmi-mcp` server via keychain-access-groups entitlements. Deleting the Keychain key makes old memories unrecoverable. Metadata, URLs, and embeddings remain cleartext by design for efficient search and deduplication. See `docs/superpowers/specs/2026-07-07-maxmi-m3-encryption-signing-design.md` §8 for the threat model.

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
(recent pages), `meeting_memory` (stub until meetings ship). Reads the DB read-only;
never interferes with capture. Uses the same `.env` Gemini key to embed queries.
Optional: `MAXMI_DB_PATH` env var overrides the DB location.

## Documentation

See `docs/superpowers/specs/` for technical specifications and `docs/superpowers/plans/` for implementation plans.
