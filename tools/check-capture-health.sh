#!/usr/bin/env bash
# Read-only Phase 0 diagnostics. This script never queries captured content,
# source keys, page titles, URLs, memories, derivatives, or embeddings.
set -euo pipefail

DB_PATH="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required."
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "MaxMi database not found: $DB_PATH"
  exit 1
fi

if [ "$(sqlite3 -readonly "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='capture_health_events';")" != "1" ]; then
  echo "Capture Health is not initialized yet. Build and launch the Phase 0 MaxMi app once."
  exit 2
fi

echo "Capture Health database: $DB_PATH"
echo "Only content-free diagnostic columns are queried below."

sqlite3 -readonly -header -column "$DB_PATH" <<'SQL'
PRAGMA query_only = ON;

SELECT outcome, count(*) AS attempts
FROM capture_health_events
GROUP BY outcome
ORDER BY outcome;

SELECT
  datetime(at_ms / 1000, 'unixepoch', 'localtime') AS local_time,
  app_label,
  trigger,
  parser,
  outcome,
  coalesce(reason, '-') AS reason,
  character_count,
  duration_ms,
  truncated
FROM capture_health_events
ORDER BY at_ms DESC, id DESC
LIMIT 20;
SQL
