# MaxMi release checklist

**Channel:** explicit manual GitHub release  
**Official releases:** https://github.com/mafex11/MaxMi/releases

## One-time prerequisites

- Paid Apple Developer Program membership.
- A Developer ID Application certificate installed in the login Keychain.
- A `maxmi-notary` notarytool Keychain profile, or `NOTARY_PROFILE` pointing to another
  locally configured profile.
- A production HTTPS MaxMi relay with install registration, scoped tokens, revocation,
  rate limits, quotas, provider-key isolation, and a published privacy policy.
- A fresh macOS user account or second Mac for clean-install and N-1 upgrade acceptance.

Never paste signing, notarization, provider, or relay credentials into source, chat,
release notes, or the app bundle.

## Release preparation

1. Update `MaxMiVersion.current`, `CFBundleShortVersionString`, `CFBundleVersion`, and
   release notes together.
2. Update the database migration manifest and N-1 fixture if schema changed.
3. Confirm the git worktree is clean and all intended commits are pushed.
4. Run `./release.sh`. It performs the full tests, version check, release build, bundle
   secret scan, inner/helper signatures, hardened runtime, required entitlements,
   Developer ID identity, DMG creation/signing, notarization, stapling, Gatekeeper
   assessment, SHA-256 checksum, and detached CMS-signed JSON manifest.
5. Publish the DMG, `.sha256`, JSON manifest, and `.json.cms` signature together on the
   official HTTPS GitHub release.

## Fresh-install acceptance

1. Download from the official release page and verify the checksum and signed manifest.
2. Open the DMG and drag MaxMi to Applications.
3. Confirm Gatekeeper opens it without bypass instructions.
4. Grant Accessibility and microphone only when prompted. Grant Screen Recording only
   when testing meeting system audio.
5. Verify capture, tray summaries, settings-in-popover, a controlled voice note, MCP
   registration, quit/relaunch, and login-item behavior.
6. Confirm the app bundle contains no dotenv file or reusable Gemini credential.

## Upgrade and rollback

1. On the fresh user/second Mac, install the previous signed release and create only
   controlled test memory.
2. Create a private backup, install the new release, and verify migration/integrity,
   encrypted contexts/facts, settings, recordings, search, and MCP.
3. Run the restore workflow using a copied controlled backup and confirm the previous
   current database is preserved under `Backups`.
4. Roll back the application only together with a schema-compatible restored backup;
   never point older code at a database migrated beyond its supported version.

## Data and Keychain locations

- Database, logs, models, backups, and recovery results:
  `~/Library/Application Support/MaxMi/`
- Encryption key and hosted-relay install token: login Keychain services owned by MaxMi.
- The database is excluded from Time Machine by design; use MaxMi's private backups.

## Uninstall

1. Quit MaxMi and disable Launch at Login.
2. Remove MaxMi from Applications.
3. If deleting all memory is intended, remove `~/Library/Application Support/MaxMi/`.
4. Remove the MaxMi database-key and relay-token Keychain items only when permanent data
   loss and install revocation are intended. Without the database key, encrypted memory
   cannot be recovered.

## Release evidence to retain

- Commit and version/build.
- Full test result and clean-worktree check.
- Bundle-secret scan and `codesign`/entitlement output.
- Notary submission identifier, stapler validation, and Gatekeeper assessment.
- DMG SHA-256 and signed-manifest verification.
- Content-free clean-install, N-1 upgrade, permission, restore, and rollback results.
