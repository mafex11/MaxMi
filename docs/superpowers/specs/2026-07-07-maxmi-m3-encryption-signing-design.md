# MaxMi — Milestone 3: At-Rest Encryption + Real Code Signing

**Date:** 2026-07-07
**Status:** Approved design
**Depends on:** M1 (capture→DB) and M2 (MCP server), both merged to main and live-verified.

## 1. What we're building

Two tightly-coupled hardening changes:

1. **Per-field AES-256-GCM encryption** of the sensitive text columns (`versions.content`, `derivatives.content`), stored as `enc:v1:<base64(nonce ‖ ciphertext ‖ tag)>` in the same TEXT columns — Minimi's documented on-disk format, verified from their live DB. Metadata (URLs, titles, hashes, timestamps) and embeddings stay cleartext, exactly like Minimi.
2. **Code signing with the existing Apple Development identity** (`Apple Development: esskayhd@outlook.com`, team `6B7UDKRDH2` — already valid in the login keychain) instead of ad-hoc. This permanently ends the TCC re-grant-after-every-rebuild pain AND is the prerequisite for Keychain-held keys: Keychain ACLs bind to the code signature, so ad-hoc (unstable) signatures would re-prompt on every rebuild.

They ship together because the encryption key lives in the Keychain, shared by both binaries via a keychain access group — which only works with a stable signing identity.

**Success test:** `strings maxmi.db | grep -i <anything you read today>` finds nothing; capture→extract→embed→search still works end-to-end with facts decrypting transparently; two consecutive rebuilds produce zero TCC prompts and zero Keychain prompts.

## 2. Non-goals for Milestone 3

- **No embedding encryption.** Vectors must be plaintext blobs for sqlite-vec KNN. Residual leak acknowledged in §8.
- **No metadata encryption** (`source_key`, `source_title`, hashes). URLs are thread identity (UNIQUE constraint); titles are needed for display/indexing. Minimi makes the same call. Residual leak acknowledged in §8.
- **No whole-file / SQLCipher encryption.** Minimi's file is plain SQLite; per-field is the scheme we're matching, and it keeps `sqlite3` usable for debugging metadata.
- **No Gemini API key migration to Keychain.** `.env` stays (decided: dev iteration convenience; the API key is lower-value than the DB key; revisit at distribution time).
- **No scrypt/password derivation.** Minimi derives via scrypt because Electron's safeStorage forces it; we generate a random `SymmetricKey(size: .bits256)` with CryptoKit — simpler, equally strong, identical on-disk format.
- **No notarization / Developer ID.** Apple Development identity is enough for a personal build; distribution signing is a later concern.
- **No key rotation / multi-key support.** The `v1` in the prefix is the versioning hook if ever needed.

## 3. Architecture

Encryption lives at the **Store boundary** — nothing above it changes:

```
MaxMiCore/
  FieldCipher.swift        protocol FieldCipher { encrypt(String)->String; decrypt(String)->String }
                           + AESGCMFieldCipher (CryptoKit, enc:v1: format)
                           + FixedKeyCipher for tests (init(keyData:)) — same math, no Keychain
MaxMiStore/
  Store gains `cipher: any FieldCipher` (init param).
    WRITE paths encrypt:  commitCapture (versions.content), insertDerivatives (derivatives.content)
    READ paths decrypt:   pendingWork (content + previousFrozenContent), factHits (content),
                          recentThreads (recentFacts), pendingDerivatives (content)
  Migration v2:           one-time in-place encryption of existing plaintext rows
MaxMi (app) + MaxMiMCP:
  KeychainKeyStore.swift   get-or-create the 256-bit key as kSecClassGenericPassword,
                           service "dev.mafex.maxmi.dbkey", keychain access group
                           "3DL5T4M53M.dev.mafex.maxmi", kSecAttrAccessibleAfterFirstUnlock
packaging/
  MaxMi.entitlements       keychain-access-groups: ["3DL5T4M53M.dev.mafex.maxmi"]
  make-app.sh              sign both binaries with the Apple Development identity + entitlements
```

**Invariants preserved (the reason this design is low-risk):**
- `content_hash` is computed over **plaintext** BEFORE encryption, unchanged. Dedup (`last_tree_hash`), the §3a race guard (`markExtracted ... AND content_hash=?`), and derivative idempotency (`UNIQUE(thread_id, content_hash)`) all keep working byte-for-byte as today.
- AES-GCM with a fresh random 12-byte nonce per encryption is non-deterministic — same plaintext encrypts differently every time. That's fine everywhere because **no code compares ciphertexts**; all equality goes through hashes.
- The pipeline, extractor, GeminiClient, MemoryQueries, and MCP protocol layer are untouched — they see plaintext through the Store API exactly as before. Gemini still receives plaintext content (cloud-relay exposure is unchanged from M1 by design).

## 4. Wire format (Minimi parity)

```
enc:v1:BASE64( nonce[12] ‖ ciphertext ‖ tag[16] )
```
- AES-256-GCM via CryptoKit (`AES.GCM.seal(_:using:nonce:)`; `combined` already yields nonce‖ct‖tag).
- No AAD (Minimi uses none observable; keeps v1 simple).
- `decrypt` on a string **without** the `enc:v1:` prefix returns it unchanged (passthrough). This single rule makes the migration idempotent, keeps old backups readable, and means read paths never need to know whether a row predates M3.
- `decrypt` on a string WITH the prefix that fails to authenticate throws `CipherError.integrityFailure` — surfaced per-row as `[unreadable memory]` in tool output rather than crashing a whole query (a tampered/corrupt row must not take down search).

## 5. Key management

- **Creation:** first launch of either binary calls `KeychainKeyStore.getOrCreate()` — `SecItemCopyMatching` for service `dev.mafex.maxmi.dbkey`; on `errSecItemNotFound`, generate `SymmetricKey(size: .bits256)`, `SecItemAdd` with `kSecAttrAccessGroup = "3DL5T4M53M.dev.mafex.maxmi"`, `kSecAttrAccessibleAfterFirstUnlock`. Race-safe: on add-collision (`errSecDuplicateItem`), re-read.
- **AfterFirstUnlock caveat (expected, not a bug):** if Claude spawns `maxmi-mcp` before the user's first unlock since boot (e.g. auto-launched connector at login), the key is unreadable and tools return the §9 "Memory is locked" message until unlock. Correct degraded behavior — do not chase it as a defect.
- **Sharing:** the access group + stable signing identity is what lets MaxMi.app (writer) and maxmi-mcp (reader) use one key without prompts. Both binaries get the same entitlements file.
- **Never on disk:** the key exists only in Keychain and process memory. It is NOT in `.env`, not in the DB, not in UserDefaults.
- **Loss semantics (documented, accepted):** if the Keychain item is deleted, encrypted rows are unrecoverable ciphertext; the app keeps running (passthrough reads show `enc:v1:` blobs as unreadable, new captures encrypt under a new key). No recovery mechanism in M3 — this is a personal build with the browsing history equivalent of a cache.
- **Test seam:** all crypto/tests use `FixedKeyCipher(keyData: 32 bytes)` — Keychain is touched ONLY in the two `main.swift` files, never in library code or tests.

## 6. Migration of existing data (in-place, idempotent)

New GRDB migration `v2-encrypt-content` does NOT do the encryption itself (migrations run under the migrator without the cipher). Instead: schema migration `v2` is a no-op marker; the **encryption backfill** runs at app startup after Store init, gated on a `settings` row:

```
IF settings['content_encrypted'] != 'true':
    batches of 200 rows per transaction:
        UPDATE versions SET content = encrypt(content) WHERE content NOT LIKE 'enc:v1:%'
        UPDATE derivatives SET content = encrypt(content) WHERE content NOT LIKE 'enc:v1:%'
        (SELECT then UPDATE by id — encrypt() is Swift-side, not SQL)
    settings['content_encrypted'] = 'true'
```
- Idempotent two ways: the prefix check skips done rows; the settings flag skips the whole pass.
- Interrupt-safe: batched transactions; a crash mid-batch rolls back that batch only; next launch resumes.
- Runs in the app only (the writer). `maxmi-mcp` never migrates (read-only) — the passthrough decrypt rule means it reads mixed states correctly during the window.
- **Capture is paused until the backfill completes** (same mechanism as the §9 Keychain-unavailable pause). GRDB would serialize the writes anyway, but pausing removes the backfill-vs-new-capture interleaving entirely; at ~260 rows the pause is imperceptible.
- **Startup ordering is explicit: key available → backfill → normal operation.** The backfill is gated on the same key check as everything else — if the Keychain is unavailable at first M3 launch, both capture AND the backfill wait (plaintext stays at rest until the keychain unlocks; passthrough reads keep everything functional in the interim).
- Backfill logs progress to stderr; ~260 rows ≈ instant.

## 7. Signing & packaging

- `packaging/MaxMi.entitlements`:
  ```xml
  <dict><key>keychain-access-groups</key>
        <array><string>3DL5T4M53M.dev.mafex.maxmi</string></array></dict>
  ```
- `make-app.sh` changes: hardened runtime stays OFF for M3 (it adds library-validation friction with zero benefit for a local build). Sign inner-to-outer — first `Contents/MacOS/maxmi-mcp`, then the `.app` bundle — each with:
  `codesign --force --sign "Apple Development: esskayhd@outlook.com (6B7UDKRDH2)" --entitlements packaging/MaxMi.entitlements` (replaces the old `--deep --sign -`; `--deep` is dropped because inner-first explicit signing is the correct order).
- The identity string goes in a `SIGN_IDENTITY` variable defaulting to that cert, overridable via env for future machines.
- **One final TCC re-grant** is required when the signature changes ad-hoc→identity (document in README + echo from make-app.sh). After that, rebuilds keep the same signing identity → TCC and Keychain ACLs persist. Exit criterion: two consecutive rebuilds, zero prompts.
- maxmi-mcp keeps needing no TCC at all; it gains only the keychain entitlement.

## 8. Threat model (honest residuals)

Protects against: casual file reading, backups/Time Machine leakage, other-user access, DB exfiltration without Keychain access. Does NOT protect against: malware running as the user with Keychain access (can read the key), Gemini cloud exposure (unchanged by design), metadata analysis (URLs + titles readable — someone with the DB knows *what pages* you visited, not what they said), and **embedding inversion** (vectors are plaintext for KNN; embeddings of short facts can leak content to a determined attacker with model access — same residual Minimi accepts). The `chmod 600` + Time Machine exclusion from M1 remain in force.

## 9. Error handling

- Keychain unavailable at startup (locked keychain, denied): app shows a menu-bar warning "Memory encryption unavailable" and **pauses capture** (never writes plaintext once M3 ships); maxmi-mcp returns tool `isError` "Memory is locked — open the MaxMi app once to unlock." Neither crashes.
- `CipherError.integrityFailure` on read: that row renders as `[unreadable memory]`; query continues; stderr log with row id.
- Migration failure (e.g. disk full): batch rolls back, flag stays unset, capture continues (mixed state is safe via passthrough), retry next launch.
- Signing failure in make-app.sh (identity missing): fall back to ad-hoc with a loud warning echo, so the build never hard-fails on another machine.

## 10. Testing strategy

- **MaxMiCoreTests/FieldCipherTests:** round-trip; format shape (`enc:v1:` prefix, base64 decodes, len = 12+n+16); non-determinism (two encrypts of same plaintext differ); passthrough on unprefixed input; integrity failure on tampered ciphertext/wrong key; empty-string round-trip; unicode round-trip.
- **MaxMiStoreTests:** existing suite runs with `FixedKeyCipher` — proves invariants survived (dedup, race guard, idempotency use plaintext hashes). New: `content` column physically contains `enc:v1:` after commitCapture/insertDerivatives (raw SQL peek); pendingWork/factHits/recentThreads return decrypted plaintext; mixed-state read (one plaintext row + one encrypted row both readable); backfill test — seed plaintext rows, run backfill, assert all prefixed + flag set + second run is a no-op; corrupt-row read yields the `[unreadable memory]` marker, not a throw.
- **MaxMiMCPTests:** unchanged suite green with FixedKeyCipher injected (search returns decrypted facts).
- **Keychain/signing:** NOT unit-tested (requires the real keychain + identity). Verified live per §11.

## 11. Milestone exit criteria

1. `sqlite3 maxmi.db "SELECT content FROM derivatives LIMIT 3"` shows only `enc:v1:…` strings; `strings maxmi.db` reveals no captured page text or facts (URLs/titles still visible — by design).
2. Existing history (260+ facts) migrated in place; search_memory still returns them decrypted.
3. Fresh capture → extract → embed → search round-trips end-to-end with encryption on.
4. Both binaries signed with the Apple Development identity; `codesign -dv` shows the team ID; **rebuild twice → zero TCC prompts, zero Keychain prompts** (after the one documented final re-grant).
5. maxmi-mcp (separate process) decrypts via the shared Keychain key with no prompt.
6. Full test suite green with `FixedKeyCipher` (no Keychain dependency in CI); tests prove ciphertext-at-rest and decrypted reads.
7. Kill the Keychain item deliberately → app degrades per §9 (no plaintext writes, no crash). Key restoration/recovery is out of scope and untested — loss semantics are documented in §5, not exercised.

## 12. Later milestones (unchanged)

M4: chat-app + document parsers. M5: meetings (meeting_memory becomes real). M6: hourly agent + timeline. M7: team sharing (would force the key-management story to grow up: per-user keys, rotation, `v2` format).
