#!/usr/bin/env bash
set -euo pipefail

DB="${MAXMI_DB_PATH:-$HOME/Library/Application Support/MaxMi/maxmi.db}"

printf 'Installed canonical browsers:\n'
for app in /Applications/*.app "$HOME"/Applications/*.app; do
  [ -d "$app" ] || continue
  bundle_id="$(mdls -raw -name kMDItemCFBundleIdentifier "$app" 2>/dev/null || true)"
  case "$bundle_id" in
    com.google.Chrome|com.google.Chrome.canary|org.chromium.Chromium|org.mozilla.firefox|org.mozilla.firefoxdeveloperedition|org.mozilla.nightly|company.thebrowser.Browser|company.thebrowser.Browser.beta|company.thebrowser.dia|com.apple.Safari|com.apple.SafariTechnologyPreview|com.brave.Browser|com.brave.Browser.beta|com.brave.Browser.nightly|com.microsoft.edgemac|com.microsoft.edgemac.Beta|com.microsoft.edgemac.Dev|com.microsoft.edgemac.Canary|ai.perplexity.comet|io.comet.Comet|com.operasoftware.Opera|com.operasoftware.OperaGX|com.vivaldi.Vivaldi|app.zen-browser.zen|app.zen-browser.twilight|com.kagi.kagimacOS|com.openai.atlas)
      printf '  %-48s %s\n' "$bundle_id" "$(basename "$app" .app)"
      ;;
  esac
done | sort -u

if [ ! -f "$DB" ]; then
  printf '\nNo MaxMi database found at the configured path.\n'
  exit 0
fi

printf '\nRecent browser capture outcomes (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT app_label, trigger, parser, outcome, COALESCE(reason, '-') AS reason,
       character_count, duration_ms
FROM capture_health_events
WHERE app_bundle IN (
  'com.google.Chrome','com.google.Chrome.canary','org.chromium.Chromium',
  'org.mozilla.firefox','org.mozilla.firefoxdeveloperedition','org.mozilla.nightly',
  'company.thebrowser.Browser','company.thebrowser.Browser.beta','company.thebrowser.dia',
  'com.apple.Safari','com.apple.SafariTechnologyPreview','com.brave.Browser',
  'com.brave.Browser.beta','com.brave.Browser.nightly','com.microsoft.edgemac',
  'com.microsoft.edgemac.Beta','com.microsoft.edgemac.Dev','com.microsoft.edgemac.Canary',
  'ai.perplexity.comet','io.comet.Comet','com.operasoftware.Opera',
  'com.operasoftware.OperaGX','com.vivaldi.Vivaldi','app.zen-browser.zen',
  'app.zen-browser.twilight','com.kagi.kagimacOS','com.openai.atlas'
)
ORDER BY at_ms DESC, id DESC
LIMIT 30;
SQL

printf '\nPhase 2 parser totals (content-free):\n'
sqlite3 -readonly "$DB" <<'SQL'
.headers on
.mode column
SELECT parser, outcome, COUNT(*) AS events
FROM capture_health_events
WHERE parser LIKE 'BrowserWeb.v2/%'
GROUP BY parser, outcome
ORDER BY parser, outcome;
SQL
