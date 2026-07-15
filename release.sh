#!/usr/bin/env bash
# MaxMi release pipeline: build (hardened, Developer-ID signed) → DMG → notarize → staple.
#
# PREREQUISITES (one-time, require a paid Apple Developer Program membership — the only steps
# a human must do; everything else here is automated):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +Developer ID Application).
#   2. Notary credentials stored once as a keychain profile named "maxmi-notary":
#        xcrun notarytool store-credentials maxmi-notary \
#          --apple-id "you@example.com" --team-id "3DL5T4M53M" --password "<app-specific-password>"
#      (app-specific password from appleid.apple.com → Sign-In & Security → App-Specific Passwords)
#
# Then: ./release.sh   → produces dist/MaxMi-<version>.dmg, notarized + stapled, ready to ship.
# Without the prereqs it still builds the DMG and tells you exactly what's missing (no fake success).
set -euo pipefail
cd "$(dirname "$0")"

APP="MaxMi.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist 2>/dev/null || echo 0.0.0)"
DMG="dist/MaxMi-${VERSION}.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-maxmi-notary}"
RELEASE_URL="${RELEASE_URL:-https://github.com/mafex11/MaxMi/releases/tag/v${VERSION}}"

if [ -n "$(git status --porcelain)" ]; then
  echo "STOP: release requires a clean git working tree." >&2
  exit 1
fi

echo "==> Verifying version alignment"
./tools/check-version-sync.sh

echo "==> Running the complete test suite"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test

echo "==> Building signed app (make-app.sh handles hardened-runtime Developer-ID signing if available)"
./packaging/make-app.sh

echo "==> Scanning the bundle for reusable provider credentials"
./tools/check-bundle-secrets.sh "$APP"

echo "==> Verifying app and bundled helper signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
for binary in MaxMi maxmi-mcp maxmi-recovery; do
  codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/$binary"
done

# Gate distribution on a real Developer ID signature (make-app.sh only hardened-signs when it finds one).
if ! codesign -dvvv "$APP" 2>&1 | grep -q "Developer ID Application"; then
  echo ""
  echo "STOP: $APP is not signed with a 'Developer ID Application' certificate, so it cannot be" >&2
  echo "      notarized/distributed. It IS a working local build. To ship to other people:" >&2
  echo "      1) get a Developer ID Application cert (paid Apple Developer Program), then re-run." >&2
  echo "      (This is the one gap that needs your Apple account — the rest of the pipeline is ready.)" >&2
  exit 1
fi

DEVID_IDENTITY="$(security find-identity -v -p codesigning | grep -oE 'Developer ID Application: [^"]+' | head -1)"
if ! codesign -dvvv "$APP/Contents/MacOS/MaxMi" 2>&1 | grep -q 'flags=.*runtime'; then
  echo "STOP: hardened runtime is missing from the main executable." >&2
  exit 1
fi
ENTITLEMENTS_DUMP="$(mktemp)"
codesign -d --entitlements :- "$APP/Contents/MacOS/MaxMi" >"$ENTITLEMENTS_DUMP" 2>/dev/null
for entitlement in com.apple.security.automation.apple-events com.apple.security.device.audio-input; do
  if [ "$(plutil -extract "$entitlement" raw "$ENTITLEMENTS_DUMP" 2>/dev/null || true)" != "true" ]; then
    echo "STOP: required entitlement is missing: $entitlement" >&2
    rm -f "$ENTITLEMENTS_DUMP"
    exit 1
  fi
done
rm -f "$ENTITLEMENTS_DUMP"

echo "==> Building DMG: $DMG"
mkdir -p dist
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install affordance
hdiutil create -volname "MaxMi" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --force --sign "$DEVID_IDENTITY" "$DMG"

echo "==> Notarizing $DMG (profile: $NOTARY_PROFILE)"
if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>/tmp/maxmi-notary.log; then
  echo "==> Stapling the notarization ticket"
  xcrun stapler staple "$APP"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

  CHECKSUM_FILE="$DMG.sha256"
  MANIFEST="dist/MaxMi-${VERSION}.json"
  MANIFEST_SIGNATURE="$MANIFEST.cms"
  checksum="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$(basename "$DMG")" >"$CHECKSUM_FILE"
  printf '{\n  "version": "%s",\n  "build": "%s",\n  "artifact": "%s",\n  "sha256": "%s",\n  "releaseURL": "%s"\n}\n' \
    "$VERSION" \
    "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' packaging/Info.plist)" \
    "$(basename "$DMG")" \
    "$checksum" \
    "$RELEASE_URL" >"$MANIFEST"
  security cms -S -N "$DEVID_IDENTITY" -i "$MANIFEST" -o "$MANIFEST_SIGNATURE"
  security cms -D -i "$MANIFEST_SIGNATURE" >/dev/null
  echo "SHIP-READY: $DMG (notarized, stapled, Gatekeeper-assessed, checksummed)."
  echo "Signed manifest: $MANIFEST_SIGNATURE"
else
  echo "" >&2
  echo "Notarization did not complete. The signed DMG exists at $DMG but is NOT stapled." >&2
  echo "Most likely: notary profile '$NOTARY_PROFILE' not configured (see prereqs at top). Log: /tmp/maxmi-notary.log" >&2
  echo "Once credentials are set: xcrun notarytool submit \"$DMG\" --keychain-profile $NOTARY_PROFILE --wait && xcrun stapler staple \"$DMG\"" >&2
  exit 1
fi
