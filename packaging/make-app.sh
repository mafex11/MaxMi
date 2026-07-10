#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release
APP="MaxMi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MaxMi "$APP/Contents/MacOS/MaxMi"
cp .build/release/MaxMiMCP "$APP/Contents/MacOS/maxmi-mcp"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Brand assets: dog app icon (.icns) + monochrome template tray icons (M6a).
cp packaging/assets/icon.icns "$APP/Contents/Resources/icon.icns"
cp packaging/assets/tray/tray-dog.png "$APP/Contents/Resources/tray-dog.png"
cp packaging/assets/tray/tray-dog@2x.png "$APP/Contents/Resources/tray-dog@2x.png"

# Sign with a real identity so TCC grants and Keychain ACLs survive rebuilds (spec §7).
# Inner binary first, then the bundle. Falls back to ad-hoc with a loud warning.
# No entitlements needed — login keychain sharing works by service name + same identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: esskayhd@outlook.com (6B7UDKRDH2)}"
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/maxmi-mcp"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with: $SIGN_IDENTITY"
else
  echo "WARNING: signing identity not found — falling back to AD-HOC signing." >&2
  echo "         TCC grants and Keychain access will break on every rebuild." >&2
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
echo ""
echo "Relaunch ritual (grant PERSISTS across rebuilds — do NOT run tccutil reset):"
echo "  pkill -9 -f \"$APP/Contents/MacOS/MaxMi\"; sleep 2; open $APP"
echo "  ('open' won't replace a running instance — must pkill first.)"
echo "MCP server bundled. Register with:"
echo "  claude mcp add maxmi -- \"$PWD/$APP/Contents/MacOS/maxmi-mcp\""
