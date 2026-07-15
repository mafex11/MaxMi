#!/usr/bin/env bash
# Fails if a built app contains an obvious reusable provider credential or dotenv file.
set -euo pipefail

APP_PATH="${1:-MaxMi.app}"
if [ ! -d "$APP_PATH" ]; then
  printf 'error=app_not_found\n'
  exit 1
fi

if find "$APP_PATH" -type f \( -name '.env' -o -name '*.env' \) -print -quit | grep -q .; then
  printf 'bundle_secret_check=fail\nreason=dotenv_file\n'
  exit 2
fi

# Google API keys use the AIza prefix followed by 35 URL-safe characters.
if LC_ALL=C grep -E -R -a -l 'AIza[0-9A-Za-z_-]{35}' "$APP_PATH" >/dev/null 2>&1; then
  printf 'bundle_secret_check=fail\nreason=provider_key_pattern\n'
  exit 2
fi

printf 'bundle_secret_check=pass\n'
