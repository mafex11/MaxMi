# MaxMi — Distribution & Release

MaxMi is locally runnable today. This document covers the existing Apple signing and
notarization path. The artifact pipeline needs three one-time inputs that require a
**paid Apple Developer Program membership** ($99/yr), but successful notarization alone
does not complete the reliability, secure AI distribution, clean-install, upgrade, and
soak gates in [`PHASE7_RELIABILITY_PARITY_PLAN.md`](PHASE7_RELIABILITY_PARITY_PLAN.md).

## What's already done (code + tooling)
- **Hardened runtime + entitlements** (`packaging/MaxMi.entitlements`: microphone + Apple-events automation; no sandbox — Accessibility capture is incompatible with it). `packaging/make-app.sh` auto-uses hardened signing **when a Developer ID cert is present**, else falls back to the dev "Apple Development" cert (current state) or ad-hoc.
- **`release.sh`** — one command: build → hardened Developer-ID sign → DMG (with drag-to-Applications) → notarize (`notarytool --wait`) → staple → validate. It **fails honestly** if the Developer ID cert or notary profile is missing (no fake success).
- Stable versioning via `CFBundleShortVersionString` in `packaging/Info.plist` (currently `0.2.0`).

## The 3 human steps (need your Apple Developer account)
1. **Developer ID Application certificate** — Xcode → Settings → Accounts → your team → Manage Certificates → **+ → Developer ID Application**. (`make-app.sh` auto-detects it.)
2. **Notary credentials** stored once:
   ```
   xcrun notarytool store-credentials maxmi-notary \
     --apple-id "<you@example.com>" --team-id "3DL5T4M53M" \
     --password "<app-specific-password>"
   ```
   (app-specific password: appleid.apple.com → Sign-In & Security → App-Specific Passwords)
3. Run **`./release.sh`** → `dist/MaxMi-<version>.dmg`, notarized + stapled, ready to hand to anyone.

## Required before a wide release
- Clean-install test on a second Mac / fresh user (Accessibility + Mic + Screen-Recording grants, Keychain key creation, Login Item).
- Upgrade test (install vN over vN-1: migrations v1→v9 apply, encrypted data intact).
- The live end-to-end verifications tracked in the plans (M5 meeting capture; M6 activity timeline + agent populating from real usage).
- Complete the Phase 7 recovery, resource-bounds, and seven-day soak gates.
- Route distributed Gemini traffic through a controlled relay or scoped-token service;
  do not embed a reusable provider key in the public app.

## Honest status
Local/developer build: **done**. The script can produce a notarized artifact once the
Apple credentials exist. Product-wide release readiness remains **incomplete** until the
Phase 7 implementation and live acceptance gates pass.
