#!/usr/bin/env bash
# Read-only Phase 7 baseline. Output is limited to versions, aggregate counts,
# file sizes, schema state, and process counts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"
APP_PATH="${MAXMI_APP_PATH:-$ROOT/MaxMi.app}"
APP_SUPPORT_DIR="${MAXMI_APP_SUPPORT_DIR:-$(dirname "$DB_PATH")}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'error=sqlite3_required\n'
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  printf 'error=database_not_found\n'
  exit 1
fi

required_tables=(
  threads versions derivatives retry_queue meetings activity_sessions agent_runs
  agent_action_items capture_health_events latest_contexts grdb_migrations
)

for table_name in "${required_tables[@]}"; do
  present="$(sqlite3 -readonly "$DB_PATH" \
    "PRAGMA query_only=ON; SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$table_name';")"
  if [ "$present" != "1" ]; then
    printf 'error=unsupported_schema\n'
    printf 'missing_table=%s\n' "$table_name"
    exit 2
  fi
done

sql_value() {
  sqlite3 -readonly -noheader "$DB_PATH" "PRAGMA query_only=ON; $1"
}

file_bytes() {
  if [ -f "$1" ]; then
    stat -f '%z' "$1"
  else
    printf '0\n'
  fi
}

count_processes() {
  local pattern="$1"
  local matches
  matches="$(pgrep -f "$pattern" 2>/dev/null || true)"
  if [ -z "$matches" ]; then
    printf '0\n'
  else
    printf '%s\n' "$matches" | wc -l | tr -d ' '
  fi
}

current_ms="$(( $(date +%s) * 1000 ))"

printf 'phase7_baseline_version=1\n'
printf 'generated_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'git_commit=%s\n' "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unavailable')"
printf 'git_branch=%s\n' "$(git -C "$ROOT" branch --show-current 2>/dev/null || printf 'unavailable')"

if [ -f "$APP_PATH/Contents/Info.plist" ]; then
  printf 'app_version=%s\n' "$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
  printf 'app_build=%s\n' "$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
else
  printf 'app_version=not_built\n'
  printf 'app_build=not_built\n'
fi

printf 'latest_migration=%s\n' "$(sql_value "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1;")"
printf 'migration_count=%s\n' "$(sql_value "SELECT count(*) FROM grdb_migrations;")"
printf 'integrity=%s\n' "$(sql_value "PRAGMA integrity_check;")"
printf 'database_mode=%s\n' "$(stat -f '%Lp' "$DB_PATH")"
printf 'database_bytes=%s\n' "$(file_bytes "$DB_PATH")"
printf 'wal_bytes=%s\n' "$(file_bytes "$DB_PATH-wal")"
printf 'shm_bytes=%s\n' "$(file_bytes "$DB_PATH-shm")"

printf 'threads=%s\n' "$(sql_value "SELECT count(*) FROM threads;")"
printf 'versions=%s\n' "$(sql_value "SELECT count(*) FROM versions;")"
printf 'facts=%s\n' "$(sql_value "SELECT count(*) FROM derivatives;")"
printf 'latest_contexts=%s\n' "$(sql_value "SELECT count(*) FROM latest_contexts;")"
printf 'recordings=%s\n' "$(sql_value "SELECT count(*) FROM meetings;")"
printf 'capture_health_events=%s\n' "$(sql_value "SELECT count(*) FROM capture_health_events;")"

printf 'retry_total=%s\n' "$(sql_value "SELECT count(*) FROM retry_queue;")"
printf 'retry_overdue=%s\n' "$(sql_value "SELECT count(*) FROM retry_queue WHERE next_attempt_at <= $current_ms;")"
printf 'retry_max_attempts=%s\n' "$(sql_value "SELECT coalesce(max(attempts), 0) FROM retry_queue;")"
printf 'retry_oldest_overdue_seconds=%s\n' "$(sql_value "SELECT coalesce(max(0, ($current_ms - min(next_attempt_at)) / 1000), 0) FROM retry_queue WHERE next_attempt_at <= $current_ms;")"

printf 'context_summaries_pending=%s\n' "$(sql_value "SELECT count(*) FROM latest_contexts WHERE summary_status='pending';")"
printf 'context_summaries_failed=%s\n' "$(sql_value "SELECT count(*) FROM latest_contexts WHERE summary_status='failed';")"
printf 'activity_summaries_pending=%s\n' "$(sql_value "SELECT count(*) FROM activity_sessions WHERE summary_status='pending';")"
printf 'activity_summaries_failed=%s\n' "$(sql_value "SELECT count(*) FROM activity_sessions WHERE summary_status='failed';")"
printf 'agent_runs_running=%s\n' "$(sql_value "SELECT count(*) FROM agent_runs WHERE status='running';")"
printf 'agent_runs_failed=%s\n' "$(sql_value "SELECT count(*) FROM agent_runs WHERE status='failed';")"
printf 'action_items_open=%s\n' "$(sql_value "SELECT count(*) FROM agent_action_items WHERE status='open';")"

if [ -d "$APP_SUPPORT_DIR" ]; then
  printf 'application_support_bytes=%s\n' "$(( $(du -sk "$APP_SUPPORT_DIR" | awk '{print $1}') * 1024 ))"
  printf 'recording_temp_files=%s\n' "$(find "$APP_SUPPORT_DIR" -maxdepth 2 -type f \( -name '*.wav' -o -name '*.caf' -o -name '*.m4a' -o -name '*.pcm' -o -name '*.tmp' \) -print | wc -l | tr -d ' ')"
  log_directory="$APP_SUPPORT_DIR/Logs"
  if [ -d "$log_directory" ]; then
    printf 'runtime_log_files=%s\n' "$(find "$log_directory" -maxdepth 1 -type f -name '*.log*' -print | wc -l | tr -d ' ')"
    printf 'runtime_log_bytes=%s\n' "$(find "$log_directory" -maxdepth 1 -type f -name '*.log*' -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
  else
    printf 'runtime_log_files=0\n'
    printf 'runtime_log_bytes=0\n'
  fi
else
  printf 'application_support_bytes=0\n'
  printf 'recording_temp_files=0\n'
  printf 'runtime_log_files=0\n'
  printf 'runtime_log_bytes=0\n'
fi

if [ "${MAXMI_SKIP_PROCESS_CHECK:-0}" = "1" ]; then
  printf 'app_processes=skipped\n'
  printf 'mcp_processes=skipped\n'
else
  printf 'app_processes=%s\n' "$(count_processes '/MaxMi.app/Contents/MacOS/MaxMi$')"
  printf 'mcp_processes=%s\n' "$(count_processes '/MaxMi.app/Contents/MacOS/maxmi-mcp')"
fi
