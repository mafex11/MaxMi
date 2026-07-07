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

# Sign with a real identity so TCC grants and Keychain ACLs survive rebuilds (spec §7).
# Inner binary first, then the bundle. Falls back to ad-hoc with a loud warning.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: esskayhd@outlook.com (6B7UDKRDH2)}"
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" --entitlements packaging/MaxMi.entitlements \
    "$APP/Contents/MacOS/maxmi-mcp"
  codesign --force --sign "$SIGN_IDENTITY" --entitlements packaging/MaxMi.entitlements "$APP"
  echo "Signed with: $SIGN_IDENTITY"
else
  echo "WARNING: signing identity not found — falling back to AD-HOC signing." >&2
  echo "         TCC grants and Keychain access will break on every rebuild." >&2
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
echo "MCP server bundled. Register with:"
echo "  claude mcp add maxmi -- \"$PWD/$APP/Contents/MacOS/maxmi-mcp\""
