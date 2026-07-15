#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release
APP="MaxMi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MaxMi "$APP/Contents/MacOS/MaxMi"
cp .build/release/MaxMiMCP "$APP/Contents/MacOS/maxmi-mcp"
cp .build/release/MaxMiRecovery "$APP/Contents/MacOS/maxmi-recovery"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Brand assets: dog app icon (.icns) + monochrome template tray icons (M6a).
cp packaging/assets/icon.icns "$APP/Contents/Resources/icon.icns"
cp packaging/assets/tray/tray-dog.png "$APP/Contents/Resources/tray-dog.png"
cp packaging/assets/tray/tray-dog@2x.png "$APP/Contents/Resources/tray-dog@2x.png"

# Signing. Prefers a "Developer ID Application" cert (for notarized DISTRIBUTION) if present;
# otherwise the local "Apple Development" cert (dev builds — TCC grants persist across rebuilds).
# Ad-hoc is the last resort (loud warning). For distribution builds we sign with HARDENED RUNTIME
# + entitlements + a secure timestamp so the artifact is notarizable. Inner binary(ies) first.
ENTITLEMENTS="packaging/MaxMi.entitlements"
DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE 'Developer ID Application: [^"]+' | head -1 || true)"
DEV_IDENTITY="${SIGN_IDENTITY:-Apple Development: esskayhd@outlook.com (6B7UDKRDH2)}"

if [ -n "$DEVID_IDENTITY" ]; then
  # DISTRIBUTION build: hardened runtime + entitlements + timestamp (notarization-ready).
  echo "Signing for DISTRIBUTION with: $DEVID_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/maxmi-mcp"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/maxmi-recovery"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_IDENTITY" "$APP/Contents/MacOS/MaxMi"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP" && echo "Distribution signature verified. Run ./release.sh to notarize + build a DMG."
elif security find-identity -v -p codesigning | grep -qF "$DEV_IDENTITY"; then
  # DEV build: Apple Development identity (grants persist across rebuilds).
  codesign --force --sign "$DEV_IDENTITY" "$APP/Contents/MacOS/maxmi-mcp"
  codesign --force --sign "$DEV_IDENTITY" "$APP/Contents/MacOS/maxmi-recovery"
  codesign --force --sign "$DEV_IDENTITY" "$APP"
  echo "Signed with: $DEV_IDENTITY (dev — not notarizable; add a Developer ID cert for distribution)"
else
  echo "WARNING: no signing identity found — falling back to AD-HOC signing." >&2
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
