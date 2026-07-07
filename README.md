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

3. **Important:** MaxMi is ad-hoc signed. After every rebuild, you must reset and re-grant Accessibility:
   ```bash
   tccutil reset Accessibility dev.mafex.maxmi
   ```
   Then launch the app again and grant the permission.

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
