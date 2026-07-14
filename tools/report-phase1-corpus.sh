#!/usr/bin/env bash
# Read-only corpus migration report. Never selects captured content, titles, URLs,
# source keys, facts, embeddings, or raw errors.
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
if [ "$(sqlite3 -readonly "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='latest_contexts';")" != "1" ]; then
  echo "Phase 1 migration is not initialized yet. Launch the current MaxMi build once."
  exit 2
fi

echo "Phase 1 corpus report: $DB_PATH"
echo "Only aggregate, content-free metadata is queried below."

sqlite3 -readonly -header -column "$DB_PATH" <<'SQL'
PRAGMA query_only = ON;

SELECT 'threads' AS metric, count(*) AS value FROM threads
UNION ALL SELECT 'versions', count(*) FROM versions
UNION ALL SELECT 'facts', count(*) FROM derivatives
UNION ALL SELECT 'latest_contexts', count(*) FROM latest_contexts
UNION ALL SELECT 'legacy_contexts', count(*) FROM latest_contexts WHERE parser_id='legacy'
UNION ALL SELECT 'self_system_threads', count(*) FROM threads
  WHERE lower(source_app) IN ('maxmi','minimi','loginwindow','securityagent','notification center');

SELECT content_kind, parser_id, parser_version, accumulation_policy, count(*) AS contexts
FROM latest_contexts
GROUP BY content_kind, parser_id, parser_version, accumulation_policy
ORDER BY contexts DESC, content_kind, parser_id;

SELECT count(*) AS normalized_key_collision_groups
FROM (
  SELECT source_app, lower(trim(source_key)) AS normalized_key
  FROM threads
  GROUP BY source_app, normalized_key
  HAVING count(*) > 1
);
SQL
