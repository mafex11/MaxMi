#!/usr/bin/env bash
# Read-only, content-free Phase 7 runtime and budget snapshot.
set -euo pipefail

DB_PATH="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"
APP_SUPPORT_DIR="${MAXMI_APP_SUPPORT_DIR:-$(dirname "$DB_PATH")}"
ASSERT=0
if [ "${1:-}" = "--assert" ]; then ASSERT=1; fi

if [ ! -f "$DB_PATH" ]; then
  printf 'error=database_not_found\n'
  exit 1
fi

sql_value() {
  sqlite3 -readonly -noheader "$DB_PATH" "PRAGMA query_only=ON; $1"
}

file_bytes() {
  if [ -f "$1" ]; then stat -f '%z' "$1"; else printf '0\n'; fi
}

count_processes() {
  local matches
  matches="$(pgrep -f "$1" 2>/dev/null || true)"
  if [ -z "$matches" ]; then printf '0\n'; else printf '%s\n' "$matches" | wc -l | tr -d ' '; fi
}

pid="$(pgrep -f '/MaxMi.app/Contents/MacOS/MaxMi$' 2>/dev/null | head -1 || true)"
app_processes="$(count_processes '/MaxMi.app/Contents/MacOS/MaxMi$')"
mcp_processes="$(count_processes '/MaxMi.app/Contents/MacOS/maxmi-mcp')"

rss_kb=0
cpu_percent=0
thread_count=0
open_files=0
if [ -n "$pid" ]; then
  rss_kb="$(ps -p "$pid" -o rss= | tr -d ' ')"
  cpu_percent="$(ps -p "$pid" -o %cpu= | tr -d ' ')"
  thread_count="$(ps -M "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  if command -v lsof >/dev/null 2>&1; then
    open_files="$(lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  fi
fi

capture_events="$(sql_value 'SELECT count(*) FROM capture_health_events;')"
capture_captured="$(sql_value "SELECT count(*) FROM capture_health_events WHERE outcome='captured';")"
capture_deduplicated="$(sql_value "SELECT count(*) FROM capture_health_events WHERE outcome='deduplicated';")"
capture_skipped="$(sql_value "SELECT count(*) FROM capture_health_events WHERE outcome='skipped';")"
capture_failed="$(sql_value "SELECT count(*) FROM capture_health_events WHERE outcome='failed';")"
capture_avg_duration_ms="$(sql_value 'SELECT coalesce(round(avg(duration_ms)),0) FROM capture_health_events;')"
capture_max_duration_ms="$(sql_value 'SELECT coalesce(max(duration_ms),0) FROM capture_health_events;')"
retry_total="$(sql_value 'SELECT count(*) FROM retry_queue;')"
retry_overdue="$(sql_value "SELECT count(*) FROM retry_queue WHERE next_attempt_at <= (strftime('%s','now') * 1000);")"
summary_pending="$(sql_value "SELECT count(*) FROM latest_contexts WHERE summary_status='pending';")"
agent_running="$(sql_value "SELECT count(*) FROM agent_runs WHERE status='running';")"
database_bytes="$(file_bytes "$DB_PATH")"
wal_bytes="$(file_bytes "$DB_PATH-wal")"
application_support_bytes="$(( $(du -sk "$APP_SUPPORT_DIR" | awk '{print $1}') * 1024 ))"
recording_temp_files="$(find "$APP_SUPPORT_DIR" -maxdepth 2 -type f \( -name '*.wav' -o -name '*.caf' -o -name '*.m4a' -o -name '*.pcm' -o -name '*.tmp' \) -print | wc -l | tr -d ' ')"
if [ -d "$APP_SUPPORT_DIR/Logs" ]; then
  log_files="$(find "$APP_SUPPORT_DIR/Logs" -maxdepth 1 -type f -name '*.log*' -print | wc -l | tr -d ' ')"
  log_bytes="$(find "$APP_SUPPORT_DIR/Logs" -maxdepth 1 -type f -name '*.log*' -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
else
  log_files=0
  log_bytes=0
fi

printf 'runtime_health_version=1\n'
printf 'generated_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'app_processes=%s\n' "$app_processes"
printf 'mcp_processes=%s\n' "$mcp_processes"
printf 'rss_kb=%s\n' "$rss_kb"
printf 'cpu_percent=%s\n' "$cpu_percent"
printf 'thread_count=%s\n' "$thread_count"
printf 'open_files=%s\n' "$open_files"
printf 'wakeups=unavailable_without_privileged_sampler\n'
printf 'capture_events=%s\n' "$capture_events"
printf 'capture_captured=%s\n' "$capture_captured"
printf 'capture_deduplicated=%s\n' "$capture_deduplicated"
printf 'capture_skipped=%s\n' "$capture_skipped"
printf 'capture_failed=%s\n' "$capture_failed"
printf 'capture_avg_duration_ms=%s\n' "$capture_avg_duration_ms"
printf 'capture_max_duration_ms=%s\n' "$capture_max_duration_ms"
printf 'retry_total=%s\n' "$retry_total"
printf 'retry_overdue=%s\n' "$retry_overdue"
printf 'summary_pending=%s\n' "$summary_pending"
printf 'agent_running=%s\n' "$agent_running"
printf 'database_bytes=%s\n' "$database_bytes"
printf 'wal_bytes=%s\n' "$wal_bytes"
printf 'application_support_bytes=%s\n' "$application_support_bytes"
printf 'recording_temp_files=%s\n' "$recording_temp_files"
printf 'runtime_log_files=%s\n' "$log_files"
printf 'runtime_log_bytes=%s\n' "$log_bytes"

if [ "$ASSERT" -eq 1 ]; then
  failed=0
  [ "$app_processes" -eq 1 ] || failed=1
  [ "$mcp_processes" -le 1 ] || failed=1
  [ "$rss_kb" -le 524288 ] || failed=1
  [ "$thread_count" -le 128 ] || failed=1
  [ "$open_files" -le 256 ] || failed=1
  [ "$capture_events" -le 500 ] || failed=1
  [ "$retry_total" -le 1000 ] || failed=1
  [ "$retry_overdue" -le 100 ] || failed=1
  [ "$summary_pending" -le 1000 ] || failed=1
  [ "$agent_running" -le 1 ] || failed=1
  [ "$database_bytes" -le 5368709120 ] || failed=1
  [ "$application_support_bytes" -le 10737418240 ] || failed=1
  [ "$recording_temp_files" -eq 0 ] || failed=1
  [ "$log_files" -le 5 ] || failed=1
  [ "$log_bytes" -le 26214400 ] || failed=1
  if [ "$failed" -eq 0 ]; then
    printf 'budget_status=pass\n'
  else
    printf 'budget_status=fail\n'
    exit 3
  fi
fi
