#!/usr/bin/env bash
# Samples content-free runtime health repeatedly. Defaults to a short 60-second profile;
# use --samples 480 --interval 60 for the eight-hour acceptance run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLES=12
INTERVAL=5

while [ "$#" -gt 0 ]; do
  case "$1" in
    --samples) SAMPLES="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) printf 'error=invalid_argument\n'; exit 2 ;;
  esac
done

case "$SAMPLES:$INTERVAL" in
  *[!0-9:]*|0:*|*:0) printf 'error=invalid_interval\n'; exit 2 ;;
esac

for ((sample = 1; sample <= SAMPLES; sample++)); do
  printf 'sample=%s\n' "$sample"
  "$ROOT/tools/check-runtime-health.sh"
  if [ "$sample" -lt "$SAMPLES" ]; then sleep "$INTERVAL"; fi
done
