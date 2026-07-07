# MaxMi Milestone 3: At-Rest Encryption + Real Code Signing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-field AES-256-GCM encryption of `versions.content` and `derivatives.content` (`enc:v1:` format, Keychain key shared app↔MCP via login keychain by service name) plus signing both binaries with the existing Apple Development identity — per the spec at `docs/superpowers/specs/2026-07-07-maxmi-m3-encryption-signing-design.md`.

**Architecture:** A `FieldCipher` protocol in MaxMiCore (AESGCMFieldCipher for real use, FixedKeyCipher for tests) injected into `Store`; write paths encrypt, read paths decrypt, hashes stay computed over plaintext so every M1/M2 invariant survives unchanged. A startup backfill (app only, gated key→backfill→capture) encrypts existing rows in place. Keychain access happens ONLY in the two executables' wiring, never in library code or tests.

**Tech Stack:** CryptoKit (AES.GCM, SymmetricKey), Security.framework (SecItem*), existing GRDB/SwiftPM stack, codesign with identity `Apple Development: esskayhd@outlook.com (6B7UDKRDH2)`.

## Global Constraints

- Wire format verbatim: `enc:v1:` + base64 of AES-GCM `combined` (nonce[12] ‖ ciphertext ‖ tag[16]). No AAD.
- `decrypt` passthrough rule: input without the `enc:v1:` prefix returns unchanged. Prefixed-but-unauthenticatable input throws `CipherError.integrityFailure`; Store read paths render such rows as `[unreadable memory]` (verbatim string), never crash a query.
- Hashes (`ContentHash.sha256Hex`) ALWAYS over plaintext, computed BEFORE encryption. `word_count` from plaintext. Encrypted columns: `versions.content`, `derivatives.content` ONLY.
- Keychain: `kSecClassGenericPassword`, service `dev.mafex.maxmi.dbkey`, login keychain (no access group, no entitlement needed), `kSecAttrAccessibleAfterFirstUnlock`; duplicate-add → re-read. Keychain touched only in `Sources/MaxMi/` and `Sources/MaxMiMCP/main.swift`/wiring — never in MaxMiCore/MaxMiStore/tests. Both binaries signed with same identity → up to 2 one-time "Always Allow" keychain prompts, then silent.
- Backfill: batches of 200 per transaction, `WHERE content NOT LIKE 'enc:v1:%'`, gated on `settings['content_encrypted'] != 'true'`, capture paused until complete, ordering key→backfill→capture.
- Signing: `SIGN_IDENTITY` env var defaulting to `Apple Development: esskayhd@outlook.com (6B7UDKRDH2)`; inner binary (`maxmi-mcp`) first, then the .app; no entitlements file needed; fall back to ad-hoc with a loud warning if the identity is missing. Hardened runtime OFF.
- Build/test with `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"`; zero new warnings in our targets.
- Commit messages conventional, NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `m3-encryption` off main.

## File Structure

```
Sources/MaxMiCore/FieldCipher.swift        protocol + CipherError + AESGCMFieldCipher + FixedKeyCipher
Sources/MaxMiStore/StoreAPI.swift          Store gains cipher; encrypt writes, decrypt reads
Sources/MaxMiStore/QueryAPI.swift          decrypt reads (factHits, recentThreads)
Sources/MaxMiStore/Backfill.swift          encryptExistingContent(batchSize:) on Store
Sources/MaxMi/KeychainKeyStore.swift       getOrCreate() -> Data (32 bytes)   [app target]
Sources/MaxMiMCP/KeychainKeyStore.swift    (same file content — see Task 4 note on duplication)
Sources/MaxMi/AppWiring.swift              cipher wiring, key→backfill→capture ordering, menu warning
Sources/MaxMiMCP/LazyTools.swift           cipher wiring, "Memory is locked" path
Sources/MaxMi/MenuBarController.swift      "Memory encryption unavailable" warning item
packaging/make-app.sh                      identity signing, inner-first, ad-hoc fallback (no entitlements)
Tests/MaxMiCoreTests/FieldCipherTests.swift
Tests/MaxMiStoreTests/*                    existing suites get FixedKeyCipher; new EncryptionAtRestTests, BackfillTests
README.md                                  signing note + final-re-grant note
```

Task order: 1 cipher → 2 Store integration (all call sites) → 3 backfill → 4 Keychain + wiring both binaries → 5 signing/packaging + live verification.

---

### Task 1: FieldCipher — protocol, AES-GCM impl, fixed-key test cipher

**Files:**
- Create: `Sources/MaxMiCore/FieldCipher.swift`
- Test: `Tests/MaxMiCoreTests/FieldCipherTests.swift`

**Interfaces:**
- Produces (later tasks rely on these EXACT signatures):
```swift
public enum CipherError: Error, Equatable { case integrityFailure, malformedCiphertext }
public protocol FieldCipher: Sendable {
    func encrypt(_ plaintext: String) throws -> String
    func decrypt(_ stored: String) throws -> String     // passthrough on unprefixed input
}
public struct AESGCMFieldCipher: FieldCipher {
    public init(keyData: Data)          // 32 bytes; used by BOTH real (Keychain-fed) and test paths
}
public typealias FixedKeyCipher = AESGCMFieldCipher    // test alias per spec naming
public extension AESGCMFieldCipher {
    static var testCipher: AESGCMFieldCipher { AESGCMFieldCipher(keyData: Data(repeating: 7, count: 32)) }
}
```
(Design note: spec names "FixedKeyCipher for tests" — same math as the real cipher, only the key source differs, so one struct + a typealias + a `testCipher` convenience is the DRY shape. The Keychain feeds `keyData` in Task 4.)

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCoreTests/FieldCipherTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class FieldCipherTests: XCTestCase {
    let cipher = AESGCMFieldCipher.testCipher

    func testRoundTrip() throws {
        let pt = "The user is watching episode 18 of Gin Tama."
        let ct = try cipher.encrypt(pt)
        XCTAssertEqual(try cipher.decrypt(ct), pt)
    }
    func testWireFormatShape() throws {
        let ct = try cipher.encrypt("hello")
        XCTAssertTrue(ct.hasPrefix("enc:v1:"))
        let blob = Data(base64Encoded: String(ct.dropFirst("enc:v1:".count)))
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.count, 12 + 5 + 16, "nonce(12) + ct(len(pt)) + tag(16)")
    }
    func testNonDeterministic() throws {
        XCTAssertNotEqual(try cipher.encrypt("same"), try cipher.encrypt("same"),
                          "fresh nonce per encryption")
    }
    func testPassthroughOnUnprefixedInput() throws {
        XCTAssertEqual(try cipher.decrypt("plain old text"), "plain old text")
        XCTAssertEqual(try cipher.decrypt(""), "")
    }
    func testTamperedCiphertextThrowsIntegrityFailure() throws {
        let ct = try cipher.encrypt("secret")
        var blob = Data(base64Encoded: String(ct.dropFirst(7)))!
        blob[blob.count - 1] ^= 0xff
        let tampered = "enc:v1:" + blob.base64EncodedString()
        XCTAssertThrowsError(try cipher.decrypt(tampered)) {
            XCTAssertEqual($0 as? CipherError, .integrityFailure)
        }
    }
    func testWrongKeyThrowsIntegrityFailure() throws {
        let other = AESGCMFieldCipher(keyData: Data(repeating: 9, count: 32))
        let ct = try cipher.encrypt("secret")
        XCTAssertThrowsError(try other.decrypt(ct)) {
            XCTAssertEqual($0 as? CipherError, .integrityFailure)
        }
    }
    func testMalformedBase64Throws() {
        XCTAssertThrowsError(try cipher.decrypt("enc:v1:!!!not-base64!!!")) {
            XCTAssertEqual($0 as? CipherError, .malformedCiphertext)
        }
        XCTAssertThrowsError(try cipher.decrypt("enc:v1:AAAA")) {   // too short for nonce+tag
            XCTAssertEqual($0 as? CipherError, .malformedCiphertext)
        }
    }
    func testEmptyAndUnicodeRoundTrip() throws {
        XCTAssertEqual(try cipher.decrypt(try cipher.encrypt("")), "")
        let uni = "日本語 🧠 emoji — dashes"
        XCTAssertEqual(try cipher.decrypt(try cipher.encrypt(uni)), uni)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`AESGCMFieldCipher` undefined).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter FieldCipherTests`

- [ ] **Step 3: Implement** — `Sources/MaxMiCore/FieldCipher.swift`:

```swift
import CryptoKit
import Foundation

public enum CipherError: Error, Equatable {
    case integrityFailure       // authentication failed: tampered data or wrong key
    case malformedCiphertext    // prefixed but not decodable as nonce+ct+tag
}

/// Encrypts/decrypts individual TEXT column values. Minimi-parity wire format:
/// "enc:v1:" + base64(nonce[12] ‖ ciphertext ‖ tag[16]), AES-256-GCM, no AAD.
public protocol FieldCipher: Sendable {
    func encrypt(_ plaintext: String) throws -> String
    func decrypt(_ stored: String) throws -> String
}

public struct AESGCMFieldCipher: FieldCipher {
    static let prefix = "enc:v1:"
    let key: SymmetricKey

    public init(keyData: Data) {
        precondition(keyData.count == 32, "AES-256 needs a 32-byte key")
        self.key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ plaintext: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        // .combined is nonce ‖ ciphertext ‖ tag for the default 12-byte nonce.
        return Self.prefix + sealed.combined!.base64EncodedString()
    }

    public func decrypt(_ stored: String) throws -> String {
        guard stored.hasPrefix(Self.prefix) else { return stored }   // passthrough: pre-M3 rows
        guard let blob = Data(base64Encoded: String(stored.dropFirst(Self.prefix.count))),
              blob.count >= 12 + 16,
              let box = try? AES.GCM.SealedBox(combined: blob) else {
            throw CipherError.malformedCiphertext
        }
        guard let plain = try? AES.GCM.open(box, using: key) else {
            throw CipherError.integrityFailure
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

public typealias FixedKeyCipher = AESGCMFieldCipher

public extension AESGCMFieldCipher {
    /// Deterministic key for tests. Never used outside test targets.
    static var testCipher: AESGCMFieldCipher { AESGCMFieldCipher(keyData: Data(repeating: 7, count: 32)) }
}
```

- [ ] **Step 4: Run — PASS** (8 tests). Full suite still green (97 existing untouched).
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiCore/FieldCipher.swift Tests/MaxMiCoreTests/FieldCipherTests.swift
git commit -m "feat(core): FieldCipher protocol with AES-256-GCM enc:v1 implementation"
```

---

### Task 2: Store integration — encrypt writes, decrypt reads, update every call site

**Files:**
- Modify: `Sources/MaxMiStore/StoreAPI.swift` (init + commitCapture + insertDerivatives + pendingWork + pendingDerivatives), `Sources/MaxMiStore/QueryAPI.swift` (factHits, recentThreads), `Sources/MaxMi/AppWiring.swift:68`, `Sources/MaxMiMCP/LazyTools.swift:49`, and ALL test call sites of `Store(db:)` (12 sites — CommitCaptureTests, MarkExtractedTests, VectorIndexTests ×2, QueryAPITests, MigrationTests ×2, ToolsTests, LazyToolsTests, MemoryQueriesTests).
- Test: `Tests/MaxMiStoreTests/EncryptionAtRestTests.swift` (new)

**Interfaces:**
- Consumes: `FieldCipher`, `AESGCMFieldCipher.testCipher` (Task 1).
- Produces: `public init(db: MaxMiDatabase, cipher: any FieldCipher)` on Store — REQUIRED parameter, no default (spec: encryption is not optional once M3 lands). Every read path returns decrypted plaintext; an integrity-failing row yields the literal string `[unreadable memory]` for its content and the query continues.

- [ ] **Step 1: Failing tests** — `Tests/MaxMiStoreTests/EncryptionAtRestTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class EncryptionAtRestTests: XCTestCase {
    var db: MaxMiDatabase!
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    @discardableResult
    func commit(_ content: String, url: String = "https://e.com/p") throws -> (vid: String, tid: String) {
        guard case .committed(let vid, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: "T", content: content), nowMs: t0)
        else { fatalError() }
        return (vid, try store.threadID(forKey: url))
    }

    func testVersionContentIsCiphertextAtRest() throws {
        try commit("secret page text")
        let raw = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT content FROM versions")! }
        XCTAssertTrue(raw.hasPrefix("enc:v1:"))
        XCTAssertFalse(raw.contains("secret"))
    }

    func testDerivativeContentIsCiphertextAtRest() throws {
        let (vid, tid) = try commit("x")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["A secret fact."], nowMs: t0)
        let raw = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT content FROM derivatives")! }
        XCTAssertTrue(raw.hasPrefix("enc:v1:"))
        XCTAssertFalse(raw.contains("secret"))
    }

    func testHashesAndWordCountFromPlaintext() throws {
        try commit("two words")
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT content_hash, word_count FROM versions")!
            XCTAssertEqual(row["content_hash"] as String, ContentHash.sha256Hex("two words"))
            XCTAssertEqual(row["word_count"] as Int, 2)
        }
    }

    func testDedupStillWorksAcrossNonDeterministicEncryption() throws {
        try commit("same content")
        let second = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: "https://e.com/p", sourceTitle: "T", content: "same content"),
            nowMs: t0 + 1000)
        XCTAssertEqual(second, .deduplicated)
    }

    func testReadPathsDecrypt() throws {
        let (vid, tid) = try commit("readable content")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["Readable fact."], nowMs: t0)
        let work = try store.pendingWork(nowMs: t0 + 400_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.first?.content, "readable content")
        XCTAssertEqual(try store.pendingDerivatives(versionID: vid).first?.content, "Readable fact.")
        let threads = try store.recentThreads(limit: 5)
        XCTAssertEqual(threads.first?.recentFacts.first, "Readable fact.")
    }

    func testMixedStateReads() throws {
        // simulate a pre-M3 plaintext row next to an encrypted one
        let (vid, tid) = try commit("encrypted era")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["New fact."], nowMs: t0)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                VALUES ('legacy', ?, ?, 'Legacy plaintext fact.', 'h-legacy', ?, 'completed')
                """, arguments: [tid, vid, t0 - 1000])
        }
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("New fact."))
        XCTAssertTrue(threads.first!.recentFacts.contains("Legacy plaintext fact."), "passthrough decrypt")
    }

    func testCorruptRowYieldsMarkerNotThrow() throws {
        let (vid, tid) = try commit("x")
        _ = try store.insertDerivatives(versionID: vid, threadID: tid, facts: ["Good fact."], nowMs: t0)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                VALUES ('corrupt', ?, ?, 'enc:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'h-c', ?, 'completed')
                """, arguments: [tid, vid, t0 + 5000])
        }
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("[unreadable memory]"))
        XCTAssertTrue(threads.first!.recentFacts.contains("Good fact."), "query continues past corrupt row")
    }
}
```

- [ ] **Step 2: Run — FAIL** (Store has no `cipher:` init).

- [ ] **Step 3: Implement**

In `Sources/MaxMiStore/StoreAPI.swift`:
```swift
public final class Store {
    let db: MaxMiDatabase
    let cipher: any FieldCipher
    public init(db: MaxMiDatabase, cipher: any FieldCipher) {
        self.db = db; self.cipher = cipher
    }

    /// Decrypt for reads; integrity/malformed failures become a marker, never a throw.
    func decryptOrMarker(_ stored: String) -> String {
        (try? cipher.decrypt(stored)) ?? "[unreadable memory]"
    }
    ...
```
- `commitCapture`: hash + word_count from plaintext as today; then `let storedContent = try cipher.encrypt(input.content)` and bind `storedContent` in BOTH the UPDATE and INSERT arms. Everything else unchanged.
- `insertDerivatives`: `content_hash` from plaintext fact; bind `try cipher.encrypt(fact)` as content. Returned `PendingDerivative(id:content:)` keeps the PLAINTEXT fact (callers embed it).
- `pendingWork`: map `content: decryptOrMarker(r["content"])`, `previousFrozenContent: (r["previous_frozen_content"] as String?).map(decryptOrMarker)`.
- `pendingDerivatives`: `content: decryptOrMarker(...)`.

In `Sources/MaxMiStore/QueryAPI.swift`:
- `factHits`: `content: decryptOrMarker(row["content"])`.
- `recentThreads`: `recentFacts: facts.map(decryptOrMarker)`.

Call-site updates (mechanical): app/MCP wiring temporarily pass `AESGCMFieldCipher.testCipher` with a `// TODO(Task 4): Keychain key` comment (replaced next tasks — the build must stay green between tasks); all 12 test sites pass `cipher: AESGCMFieldCipher.testCipher`.

- [ ] **Step 4: Run full suite — PASS.** Existing 97 + Task 1's 8 + these 7 all green: proves the invariants (dedup, race guard, idempotency) survived encryption because they hash plaintext.
- [ ] **Step 5: Commit**
```bash
git add Sources Tests
git commit -m "feat(store): encrypt content columns at rest, decrypt at the read boundary"
```

---

### Task 3: Startup backfill — encrypt existing plaintext rows in place

**Files:**
- Create: `Sources/MaxMiStore/Backfill.swift`
- Test: `Tests/MaxMiStoreTests/BackfillTests.swift`

**Interfaces:**
- Consumes: `Store` with cipher (Task 2).
- Produces:
```swift
extension Store {
    /// One-time in-place encryption of pre-M3 plaintext rows. Idempotent (prefix check
    /// + settings flag). Returns number of rows encrypted this run.
    @discardableResult
    public func encryptExistingContent(batchSize: Int = 200, nowMs: EpochMs) throws -> Int
    public func isContentEncrypted() throws -> Bool     // settings['content_encrypted'] == 'true'
}
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiStoreTests/BackfillTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class BackfillTests: XCTestCase {
    var db: MaxMiDatabase!
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    /// Seed pre-M3 state: plaintext rows written with raw SQL (bypassing the encrypting Store).
    func seedPlaintext(rows: Int) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://e.com','T',NULL,?,?)",
                          arguments: [t0, t0])
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v1','t1',495442,'plain page text','h1',3,1,?,'completed')
                """, arguments: [t0])
            for i in 0..<rows {
                try d.execute(sql: """
                    INSERT INTO derivatives (id,thread_id,version_id,content,content_hash,committed_at,embedding_status)
                    VALUES (?, 't1','v1', ?, ?, ?, 'completed')
                    """, arguments: ["d\(i)", "Plain fact \(i).", "h-d\(i)", t0 + EpochMs(i)])
            }
        }
    }

    func testBackfillEncryptsEverythingAndSetsFlag() throws {
        try seedPlaintext(rows: 450)   // > 2 batches of 200
        XCTAssertFalse(try store.isContentEncrypted())
        let n = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(n, 451)         // 450 derivatives + 1 version
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql:
                "SELECT count(*) FROM derivatives WHERE content NOT LIKE 'enc:v1:%'"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql:
                "SELECT count(*) FROM versions WHERE content NOT LIKE 'enc:v1:%'"), 0)
        }
        XCTAssertTrue(try store.isContentEncrypted())
    }

    func testBackfillPreservesReadability() throws {
        try seedPlaintext(rows: 3)
        _ = try store.encryptExistingContent(nowMs: t0)
        let threads = try store.recentThreads(limit: 5)
        XCTAssertTrue(threads.first!.recentFacts.contains("Plain fact 2."))
    }

    func testSecondRunIsNoOp() throws {
        try seedPlaintext(rows: 5)
        _ = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(try store.encryptExistingContent(nowMs: t0), 0, "flag short-circuits")
    }

    func testInterruptedRunResumes() throws {
        try seedPlaintext(rows: 10)
        // encrypt only some rows manually to simulate a crash mid-run (flag unset)
        let c = AESGCMFieldCipher.testCipher
        try db.dbQueue.write { d in
            let enc = try c.encrypt("Plain fact 0.")
            try d.execute(sql: "UPDATE derivatives SET content=? WHERE id='d0'", arguments: [enc])
        }
        let n = try store.encryptExistingContent(nowMs: t0)
        XCTAssertEqual(n, 10, "9 remaining derivatives + 1 version; d0 skipped by prefix check")
        XCTAssertTrue(try store.isContentEncrypted())
    }

    func testHashesUntouchedByBackfill() throws {
        try seedPlaintext(rows: 1)
        _ = try store.encryptExistingContent(nowMs: t0)
        try db.dbQueue.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT content_hash FROM versions"), "h1",
                           "backfill must not recompute hashes")
        }
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** — `Sources/MaxMiStore/Backfill.swift`:

```swift
import Foundation
import GRDB
import MaxMiCore

extension Store {
    public func isContentEncrypted() throws -> Bool {
        try db.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='content_encrypted'") == "true"
        }
    }

    /// Spec §6: batches of 200 per transaction; prefix check makes each row idempotent;
    /// the settings flag makes the whole pass idempotent. Caller (app wiring) pauses
    /// capture until this returns — spec ordering: key -> backfill -> capture.
    @discardableResult
    public func encryptExistingContent(batchSize: Int = 200, nowMs: EpochMs) throws -> Int {
        guard try !isContentEncrypted() else { return 0 }
        var total = 0
        for table in ["versions", "derivatives"] {
            while true {
                let encrypted: Int = try db.dbQueue.write { d in
                    let rows = try Row.fetchAll(d, sql:
                        "SELECT id, content FROM \(table) WHERE content NOT LIKE 'enc:v1:%' LIMIT ?",
                        arguments: [batchSize])
                    for r in rows {
                        let enc = try cipher.encrypt(r["content"])
                        try d.execute(sql: "UPDATE \(table) SET content=? WHERE id=?",
                                      arguments: [enc, r["id"] as String])
                    }
                    return rows.count
                }
                total += encrypted
                FileHandle.standardError.write(Data("MaxMi backfill: \(table) +\(encrypted)\n".utf8))
                if encrypted < batchSize { break }
            }
        }
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('content_encrypted','true',?)",
                          arguments: [nowMs])
        }
        return total
    }
}
```

- [ ] **Step 4: Run — PASS** (5 tests). Full suite green.
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiStore/Backfill.swift Tests/MaxMiStoreTests/BackfillTests.swift
git commit -m "feat(store): idempotent in-place encryption backfill for pre-M3 rows"
```

---

### Task 4: Keychain key store + wiring both binaries

**Files:**
- Create: `Sources/MaxMi/KeychainKeyStore.swift`, `Sources/MaxMiMCP/KeychainKeyStore.swift` (identical content — a 40-line file duplicated across two executable targets beats creating a new shared target with a Security dependency for one function; note the duplication in a header comment in both)
- Modify: `Sources/MaxMi/AppWiring.swift` (key→backfill→capture ordering, pause + menu warning on failure), `Sources/MaxMi/MenuBarController.swift` (warning item), `Sources/MaxMiMCP/LazyTools.swift` ("Memory is locked" path)
- Test: none automated for Keychain itself (spec §10: Keychain/signing verified live). LazyTools' locked path IS unit-testable via injection — one new test.

**Interfaces:**
- Consumes: `AESGCMFieldCipher(keyData:)` (Task 1), `Store(db:cipher:)` (Task 2), `encryptExistingContent` (Task 3).
- Produces (identical in both files):
```swift
enum KeychainKeyStore {
    enum KeyError: Error { case unavailable(OSStatus) }
    /// Get-or-create the 32-byte DB key. Spec §5: kSecClassGenericPassword,
    /// service dev.mafex.maxmi.dbkey, login keychain (shared by service name,
    /// no access group entitlement), AfterFirstUnlock. Duplicate-add race -> re-read.
    static func getOrCreate() throws -> Data
}
```

- [ ] **Step 1: KeychainKeyStore (both copies)**

```swift
import Foundation
import CryptoKit
import Security

// NOTE: duplicated verbatim in Sources/MaxMi/ and Sources/MaxMiMCP/ — two executable
// targets, one 40-line function; a shared target for this alone isn't worth it.
//
// LOGIN KEYCHAIN SHARING: Both binaries (MaxMi.app + maxmi-mcp) share the encryption
// key via the login keychain, identified by service name. Both are signed with the same
// identity, so keychain ACLs recognize them as the same app. First read in each binary
// prompts once for "Always Allow" (at most 2 prompts total), then silent. No keychain
// access group entitlement needed (that would require a provisioning profile).
enum KeychainKeyStore {
    enum KeyError: Error { case unavailable(OSStatus) }

    static let service = "dev.mafex.maxmi.dbkey"

    static func getOrCreate() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw KeyError.unavailable(status) }

        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: fresh,
        ]
        status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return fresh }
        if status == errSecDuplicateItem {           // lost the creation race — re-read
            status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        }
        throw KeyError.unavailable(status)
    }
}
```

- [ ] **Step 2: App wiring** — `Sources/MaxMi/AppWiring.swift`. Replace the Task-2 TODO cipher with the real flow. In `init()` (after `db` creation, before `store` use):

```swift
        // Spec §6 ordering: key -> backfill -> capture. No key => capture stays paused
        // and we never write plaintext post-M3 (spec §9).
        let cipher: any FieldCipher
        var encryptionAvailable = true
        do {
            cipher = AESGCMFieldCipher(keyData: try KeychainKeyStore.getOrCreate())
        } catch {
            NSLog("MaxMi: encryption key unavailable: \(error)")
            cipher = AESGCMFieldCipher.testCipher   // placeholder; never used for writes (capture paused)
            encryptionAvailable = false
        }
        store = Store(db: db, cipher: cipher)
        self.encryptionAvailable = encryptionAvailable
```
Add `let encryptionAvailable: Bool` property. In `start()`: after the permission gate and before creating the FocusObserver, add:
```swift
        menuBar.encryptionAvailable = encryptionAvailable
        guard encryptionAvailable else { return }          // capture paused per §9
        do { try store.encryptExistingContent(nowMs: epochNowMs()) }   // §6: backfill before capture
        catch { NSLog("MaxMi: backfill failed, will retry next launch: \(error)") }
```
(Backfill failure does NOT block capture — spec §9: mixed state is safe via passthrough; flag stays unset; retries next launch. Note the guard ordering: menu installs first, so the warning is visible.)

- [ ] **Step 3: Menu warning** — `Sources/MaxMi/MenuBarController.swift`: add
```swift
    private let encryptionItem = NSMenuItem(title: "⚠ Memory encryption unavailable", action: nil, keyEquivalent: "")
    var encryptionAvailable: Bool = true { didSet { encryptionItem.isHidden = encryptionAvailable } }
```
and insert `encryptionItem` (hidden by default) next to the existing permission/key warning items in `install`.

- [ ] **Step 4: MCP wiring** — `Sources/MaxMiMCP/LazyTools.swift`: replace the TODO cipher in `resolve()`:
```swift
        let keyData: Data
        do { keyData = try KeychainKeyStore.getOrCreate() }
        catch {
            logStderr("keychain unavailable: \(error)")
            lockedOut = true                                   // new stored flag checked by call()
            return nil
        }
        let queries = MemoryQueries(store: Store(db: db, cipher: AESGCMFieldCipher(keyData: keyData)), ...)
```
In `call()`, when `resolve()` returns nil, distinguish: if `lockedOut` → `ToolResult(text: "Memory is locked — open the MaxMi app once to unlock.", isError: true)` (spec §9 verbatim); else the existing no-DB text. `lockedOut` resets to false at the top of each `resolve()` attempt (a later unlock must recover without restart; and per spec §5, pre-first-unlock lockout is expected behavior, not a bug).
Add a test to `Tests/MaxMiMCPTests/LazyToolsTests.swift`: LazyTools has an internal seam already (it builds its own Store) — add an injectable `keyProvider: () throws -> Data` (default `KeychainKeyStore.getOrCreate` in the executables, throwing stub in the test) and assert the locked message + isError true + recovery when the provider stops throwing. Keep Keychain itself out of tests.

- [ ] **Step 5: Full suite + build — PASS**, zero new warnings. Commit:
```bash
git add Sources Tests
git commit -m "feat(app,mcp): Keychain-backed encryption key with locked-state degradation"
```

---

### Task 5: Signing, packaging, README, live verification

**Files:**
- Create: `packaging/MaxMi.entitlements`
- Modify: `packaging/make-app.sh`, `README.md`
- Test: build + codesign verification + the spec §11 live walkthrough (controller/human).

- [ ] **Step 1: make-app.sh** — replace the codesign section:

```bash
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
```
Also delete the now-stale ad-hoc comment block above it. Keep the MCP registration echo.

- [ ] **Step 2: README** — update the TCC note: signed builds keep their Accessibility grant across rebuilds; ONE final re-grant is needed when upgrading from an ad-hoc build (`tccutil reset Accessibility dev.mafex.maxmi`, relaunch, grant). Add an "Encryption" section: content columns are AES-256-GCM (`enc:v1:`), key in Keychain (service `dev.mafex.maxmi.dbkey`), shared with maxmi-mcp via login keychain by service name (both binaries signed with same identity → at most 2 one-time "Always Allow" prompts, then silent); deleting the key makes old memories unrecoverable; metadata/URLs/embeddings remain cleartext by design (link spec §8).

- [ ] **Step 3: Build + sign + verify**

```bash
DEVELOPER_DIR=... swift test          # full suite green
./packaging/make-app.sh               # must print "Signed with: Apple Development..."
codesign -dv MaxMi.app 2>&1 | grep -E "Authority|TeamIdentifier"    # TeamIdentifier=6B7UDKRDH2
codesign -d --entitlements - MaxMi.app     # should show NO keychain-access-groups / empty or minimal
```

- [ ] **Step 4: Commit**
```bash
git add packaging README.md
git commit -m "feat(packaging): sign with Apple Development identity (no entitlements needed)"
```

- [ ] **Step 5: Live verification (controller/human — spec §11)**
1. ONE final TCC reset + re-grant (signature changed ad-hoc→identity): `tccutil reset Accessibility dev.mafex.maxmi`, launch, grant.
2. First launch: backfill runs (stderr log), then capture resumes. `sqlite3 ... "SELECT content FROM derivatives LIMIT 3"` → only `enc:v1:` strings; `strings maxmi.db | grep -i gintama` (or any known fact word) → nothing.
3. search_memory via maxmi-mcp → decrypted facts, up to 2 one-time "Always Allow" keychain prompts (one per binary), then works silently.
4. Browse a new page → new capture → fact extracted → searchable (fresh-write path).
5. Rebuild twice (`./packaging/make-app.sh` ×2, relaunch) → zero TCC prompts, zero Keychain prompts. THE payoff criterion.
6. Optional §11.7: delete the key (`security delete-generic-password -s dev.mafex.maxmi.dbkey`), relaunch → menu shows "Memory encryption unavailable", capture paused, no crash; re-create by relaunching once more (fresh key; old rows unreadable — expected loss semantics). Skippable if you don't want to burn the real key — do it BEFORE step 4's real browsing if at all.

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §3 architecture/file map → Tasks 1–4 match (FieldCipher in Core, Store cipher param, Backfill.swift, KeychainKeyStore in both executables, make-app.sh signing with no entitlements). §4 wire format + passthrough + integrity-marker → Task 1 (format/passthrough/integrity tests) + Task 2 (marker rendering, mixed-state test). §5 key mgmt → Task 4 (service/accessible constants, login keychain sharing by service name + same identity, duplicate-add race, AfterFirstUnlock caveat honored by lockedOut-reset logic; test seam via keyProvider injection; Keychain only in executables). §6 backfill → Task 3 (batch 200, prefix+flag idempotency, interrupt test) + Task 4 wiring (key→backfill→capture ordering, capture-paused-until-complete via the guard/sequencing in start()). §7 signing → Task 5 (identity, inner-first, no entitlements, SIGN_IDENTITY override, ad-hoc fallback with warning, hardened runtime absent). §8 threat model → README note (Task 5 Step 2). §9 errors → Task 4 (menu warning + paused capture; MCP locked message verbatim; backfill-failure-continues), Task 2 (corrupt row marker). §10 tests → Tasks 1–3 test lists match the spec's bullets 1:1; Keychain/signing live-only per spec. §11 exit criteria → Task 5 Step 5 walks all seven.

**Placeholders:** none. The Task-2 "TODO(Task 4)" cipher in wiring is an explicit inter-task seam with named replacement, not an unfinished step.

**Type consistency:** `AESGCMFieldCipher(keyData:)`/`testCipher`/`FieldCipher`/`CipherError` (Task 1) used identically in Tasks 2–4; `Store(db:cipher:)` (Task 2) used in Tasks 3–4; `encryptExistingContent(batchSize:nowMs:)`/`isContentEncrypted()` (Task 3) called in Task 4 wiring; `KeychainKeyStore.getOrCreate()` (Task 4) referenced in Task 5's verification only.
