#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release
APP="MaxMi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MaxMi "$APP/Contents/MacOS/MaxMi"
cp packaging/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc codesign AFTER assembly (project_yuki_signing: deep-sign post-assembly,
# and expect to re-grant Accessibility after every rebuild — tccutil reset Accessibility dev.mafex.maxmi).
codesign --force --deep --sign - "$APP"
echo "Built $APP"
