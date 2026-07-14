#!/usr/bin/env bash
set -euo pipefail

DB="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"

if [ ! -f "$DB" ]; then
  printf 'No MaxMi database found at the configured path.\n'
  exit 0
fi

printf 'Schema and integrity:\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT identifier AS latest_migration
FROM grdb_migrations
ORDER BY rowid DESC
LIMIT 1;
PRAGMA integrity_check;
SQL

printf '\nRecording totals (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT CASE WHEN capture_mode LIKE 'voice-note%' THEN 'voice_note' ELSE 'meeting' END AS kind,
       app, capture_mode, transcription_status, state, COUNT(*) AS recordings
FROM meetings
GROUP BY kind, app, capture_mode, transcription_status, state
ORDER BY kind, app, capture_mode;
SQL

printf '\nRecording context and summary state (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT content_kind, parser_id, summary_status, COUNT(*) AS contexts,
       SUM(CASE WHEN content_ciphertext LIKE 'enc:v1:%' THEN 1 ELSE 0 END) AS encrypted_contexts
FROM latest_contexts
WHERE content_kind IN ('meeting','voiceNote')
GROUP BY content_kind, parser_id, summary_status
ORDER BY content_kind, parser_id, summary_status;
SQL

printf '\nEncrypted recording versions (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT COUNT(*) AS total,
       SUM(CASE WHEN v.content LIKE 'enc:v1:%' THEN 1 ELSE 0 END) AS encrypted
FROM meetings m
JOIN versions v ON v.id = m.version_id;
SQL
