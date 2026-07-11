# MaxMi — Distribution & Release

MaxMi is **feature-complete and locally runnable** today. This doc covers shipping it to *other* people (signed + notarized DMG). The release pipeline is built and automated — it needs three one-time inputs that require a **paid Apple Developer Program membership** ($99/yr); nothing else is missing.

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

## Still recommended before a wide release (not blocking a first share)
- Clean-install test on a second Mac / fresh user (Accessibility + Mic + Screen-Recording grants, Keychain key creation, Login Item).
- Upgrade test (install vN over vN-1: migrations v1→v5 apply, encrypted data intact).
- The live end-to-end verifications tracked in the plans (M5 meeting capture; M6 activity timeline + agent populating from real usage).

## Honest status
Local/developer build: **done**. Distributable notarized artifact: **one `./release.sh` away** once the Apple Developer account + the 3 inputs above are in place — that's the only remaining gap, and it's inherently gated on your Apple credentials, not on code.
