#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift_version="$(sed -nE 's/.*current = "([^"]+)".*/\1/p' "$ROOT/Sources/MaxMiCore/Version.swift")"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ROOT/packaging/Info.plist")"

if [ -z "$swift_version" ] || [ "$swift_version" != "$plist_version" ]; then
  printf 'version_sync=fail\n'
  printf 'swift_version=%s\n' "${swift_version:-missing}"
  printf 'plist_version=%s\n' "$plist_version"
  exit 2
fi

case "$plist_version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'version_sync=fail\nreason=invalid_semver\n'; exit 2 ;;
esac
case "$build_version" in
  ''|*[!0-9]*) printf 'version_sync=fail\nreason=invalid_build\n'; exit 2 ;;
esac

printf 'version_sync=pass\n'
printf 'version=%s\n' "$plist_version"
printf 'build=%s\n' "$build_version"
