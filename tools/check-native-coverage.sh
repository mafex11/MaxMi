#!/usr/bin/env bash
set -euo pipefail

DB="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"

printf 'Installed Phase 3 applications:\n'
find /System/Applications /Applications "$HOME/Applications" -maxdepth 2 -type d -name '*.app' 2>/dev/null |
while IFS= read -r app; do
  bundle_id="$(mdls -raw -name kMDItemCFBundleIdentifier "$app" 2>/dev/null || true)"
  case "$bundle_id" in
    net.whatsapp.WhatsApp|com.microsoft.teams2|com.microsoft.teams|com.apple.mail|com.microsoft.Outlook|com.readdle.smartemail-Mac|com.readdle.SparkDesktop|com.apple.iCal|com.flexibits.fantastical2.mac|com.apple.reminders|com.microsoft.to-do-mac|com.todoist.mac.Todoist|com.omnigroup.OmniFocus3|com.omnigroup.OmniFocus4|com.toggl.toggldesktop|com.microsoft.Word|com.apple.iWork.Pages)
      printf '  %-44s %s\n' "$bundle_id" "$(basename "$app" .app)"
      ;;
  esac
done | sort -u

if [ ! -f "$DB" ]; then
  printf '\nNo MaxMi database found at the configured path.\n'
  exit 0
fi

printf '\nRecent Phase 3 capture outcomes (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT app_label, trigger, parser, outcome, COALESCE(reason, '-') AS reason,
       character_count, duration_ms
FROM capture_health_events
WHERE app_bundle IN (
  'net.whatsapp.WhatsApp','com.microsoft.teams2','com.microsoft.teams',
  'com.apple.mail','com.microsoft.Outlook','com.readdle.smartemail-Mac',
  'com.readdle.SparkDesktop','com.apple.iCal','com.flexibits.fantastical2.mac',
  'com.apple.reminders','com.microsoft.to-do-mac','com.todoist.mac.Todoist',
  'com.omnigroup.OmniFocus3','com.omnigroup.OmniFocus4','com.toggl.toggldesktop',
  'com.microsoft.Word','com.apple.iWork.Pages'
)
ORDER BY at_ms DESC, id DESC
LIMIT 40;
SQL

printf '\nStructured latest-context totals (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT content_kind, parser_id, COUNT(*) AS contexts
FROM latest_contexts
WHERE content_kind IN ('conversation','email','calendar','task','document')
  AND parser_id IN (
    'WhatsAppParser','TeamsParser','MailParser','CalendarParser','FantasticalParser',
    'RemindersParser','MicrosoftToDoParser','TodoistParser','OmniFocusParser','TogglParser',
    'WordParser','PagesParser','OutlookParser','SparkParser'
  )
GROUP BY content_kind, parser_id
ORDER BY content_kind, parser_id;
SQL
