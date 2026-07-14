#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: tools/setup-mcp.sh [--target claude-code|claude-desktop] [--mcp PATH] [--apply] [--replace]' \
    '' \
    'Without --apply, prints status and the planned change only.' \
    '--replace permits replacing an existing maxmi entry in the selected target.'
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MCP_PATH="${MAXMI_MCP_PATH:-$ROOT/MaxMi.app/Contents/MacOS/maxmi-mcp}"
TARGET=""
APPLY=0
REPLACE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    --mcp)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MCP_PATH="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$TARGET" in
  claude-code|claude-desktop) ;;
  "")
    printf 'Choose --target claude-code or --target claude-desktop.\n' >&2
    exit 2
    ;;
  *)
    printf 'Unsupported target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac

if [ ! -x "$MCP_PATH" ]; then
  printf 'MCP executable is missing or not executable: %s\n' "$MCP_PATH" >&2
  printf 'Build the app first with ./packaging/make-app.sh, or pass --mcp PATH.\n' >&2
  exit 1
fi
MCP_PATH="$(cd "$(dirname "$MCP_PATH")" && pwd)/$(basename "$MCP_PATH")"

printf 'MaxMi MCP executable: %s\n' "$MCP_PATH"
HEALTH_OUTPUT="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"maxmi-setup","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$MCP_PATH" 2>/dev/null)"
for expected in '"name":"search_memory"' '"name":"list_active_threads"' '"name":"get_latest_context"' '"name":"meeting_memory"'; do
  if ! printf '%s' "$HEALTH_OUTPUT" | grep -Fq "$expected"; then
    printf 'MCP health check failed: bundled tool list is incomplete. Rebuild MaxMi before registration.\n' >&2
    exit 1
  fi
done
printf 'MCP handshake and tool-list health check passed.\n'

if [ "$TARGET" = "claude-code" ]; then
  command -v claude >/dev/null 2>&1 || { printf 'Claude Code CLI was not found in PATH.\n' >&2; exit 1; }
  EXISTING_DETAILS="$(claude mcp get maxmi 2>/dev/null || true)"
  if [ -n "$EXISTING_DETAILS" ]; then
    printf 'Claude Code already has an MCP server named maxmi.\n'
    if [ "$APPLY" -eq 1 ] && [ "$REPLACE" -ne 1 ]; then
      printf 'Re-run with --replace to replace the user-scoped entry.\n' >&2
      exit 1
    fi
  else
    printf 'Claude Code has no MCP server named maxmi.\n'
  fi
  if [ "$APPLY" -ne 1 ]; then
    printf 'Dry run. Planned user-scoped registration:\n  claude mcp add --scope user maxmi -- %q\n' "$MCP_PATH"
    exit 0
  fi
  if [ "$REPLACE" -eq 1 ] && [ -n "$EXISTING_DETAILS" ]; then
    if ! printf '%s' "$EXISTING_DETAILS" | grep -Fq 'Scope: User'; then
      printf 'The existing entry is not user-scoped; refusing to remove it automatically.\n' >&2
      printf 'Review "claude mcp get maxmi" and remove its exact scope manually if replacement is intended.\n' >&2
      exit 1
    fi
    claude mcp remove --scope user maxmi
  fi
  claude mcp add --scope user maxmi -- "$MCP_PATH"
  claude mcp get maxmi
  exit 0
fi

CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
EXISTING=""
if [ -f "$CONFIG" ]; then
  plutil -convert xml1 -o /dev/null -- "$CONFIG"
  EXISTING="$(plutil -extract mcpServers.maxmi.command raw "$CONFIG" 2>/dev/null || true)"
fi
if [ -n "$EXISTING" ]; then
  printf 'Claude Desktop already has maxmi configured at: %s\n' "$EXISTING"
  if [ "$APPLY" -eq 1 ] && [ "$REPLACE" -ne 1 ]; then
    printf 'Re-run with --replace to replace that entry.\n' >&2
    exit 1
  fi
else
  printf 'Claude Desktop has no MCP server named maxmi.\n'
fi
if [ "$APPLY" -ne 1 ]; then
  printf 'Dry run. Planned config file: %s\n' "$CONFIG"
  printf 'The existing file will be backed up before modification.\n'
  exit 0
fi

mkdir -p "$(dirname "$CONFIG")"
if [ -f "$CONFIG" ]; then
  BACKUP="$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONFIG" "$BACKUP"
  printf 'Backup created: %s\n' "$BACKUP"
else
  touch "$CONFIG"
  plutil -create xml1 -- "$CONFIG"
fi
plutil -convert xml1 -- "$CONFIG"
if ! plutil -extract mcpServers raw -expect dictionary "$CONFIG" >/dev/null 2>&1; then
  plutil -insert mcpServers -dictionary "$CONFIG"
fi
if plutil -extract mcpServers.maxmi raw -expect dictionary "$CONFIG" >/dev/null 2>&1; then
  plutil -remove mcpServers.maxmi "$CONFIG"
fi
plutil -insert mcpServers.maxmi -dictionary "$CONFIG"
plutil -insert mcpServers.maxmi.command -string "$MCP_PATH" "$CONFIG"
plutil -convert json -- "$CONFIG"
chmod 600 "$CONFIG"
plutil -convert xml1 -o /dev/null -- "$CONFIG"
printf 'Claude Desktop registration written successfully. Restart Claude Desktop to connect.\n'
