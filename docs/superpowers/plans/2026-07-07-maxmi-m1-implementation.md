# MaxMi Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar app that captures the active browser tab via the AX tree, versions it per-hour into local SQLite, and (via Gemini) extracts fact sentences + 1536-dim embeddings — per the spec at `docs/superpowers/specs/2026-07-07-maxmi-capture-to-db-design.md`.

**Architecture:** One SwiftPM package, four library targets + one executable, mirroring `burnt/` structurally. `MaxMiStore` owns the versioning state machine (freeze-then-create, hash-guarded completion); `MaxMiCore` owns orchestration (CapturePipeline over protocol-typed Store/Relay); `MaxMiCapture` reads AX trees behind a snapshot abstraction so tests use recorded fixtures; `MaxMiRelay` is the Gemini HTTP client. sqlite-vec is **vendored as a C target compiled with `SQLITE_CORE`** and initialized per-connection — macOS system SQLite omits `sqlite3_load_extension` (verified), so runtime dylib loading is impossible.

**Tech Stack:** Swift 6.0 SwiftPM, macOS 14+, GRDB.swift 7.x, vendored sqlite-vec (C), CryptoKit (SHA-256), AppKit/ApplicationServices (AX), Gemini API (`gemini-flash-lite-latest` extract, `gemini-embedding-001` embed @1536).

## Global Constraints

- `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]` — exactly like `burnt/Package.swift`.
- Menu-bar only: `LSUIElement=true` in Info.plist; ad-hoc codesign via `packaging/make-app.sh` (copy burnt's pattern).
- Build/test always with `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"` prefix (burnt convention; CLT-only SDK breaks AppKit builds).
- Timestamps are **epoch milliseconds** (INTEGER); `hour_bucket = committed_at / 3_600_000`.
- IDs are UUIDv7 strings (lowercase hex, RFC 9562 layout).
- DB at `~/Library/Application Support/MaxMi/maxmi.db`, WAL mode, files chmod 600, dir excluded from Time Machine.
- Plaintext content in M1 (spec §9) — no crypto anywhere in this plan.
- The only network calls are to `generativelanguage.googleapis.com`; key from `.env` (`GEMINI_API_KEY`), never Keychain.
- Extraction runs ONLY on freeze/idle/sweeper triggers (spec §3a), never per-capture.
- Commit messages: plain conventional style, **no Co-Authored-By / AI attribution trailers**.
- Repo root for all paths below: `/Users/mafex/code/personal/MaxMi/`.

## File Structure (locked in)

```
Package.swift
packaging/Info.plist            packaging/make-app.sh
Vendor/sqlite-vec/              sqlite-vec.c, sqlite-vec.h, include/module.modulemap (C target)
Sources/
  MaxMiCore/    Ident.swift (UUIDv7), Hashing.swift, HourBucket.swift, EnvConfig.swift,
                Protocols.swift (MemoryStore, MemoryRelay), CapturePipeline.swift, RetryWorker.swift
  MaxMiStore/   Database.swift (open/config/vec init), Migrations.swift, Records.swift,
                StoreAPI.swift (commitCapture, pendingWork, markExtracted, derivatives, retry queue),
                VectorIndex.swift
  MaxMiCapture/ AXSnapshot.swift (node model + protocol), BrowserTabExtractor.swift,
                Denylist.swift, FocusObserver.swift, ChromiumKick.swift
  MaxMiRelay/   GeminiClient.swift, ExtractPrompt.swift, JSONArrayParser.swift
  MaxMi/        main.swift, MenuBarController.swift, PermissionGate.swift, AppWiring.swift
Tests/
  MaxMiCoreTests/    IdentTests, HourBucketTests, EnvConfigTests, PipelineTests, RetryWorkerTests
  MaxMiStoreTests/   MigrationTests, CommitCaptureTests, MarkExtractedTests, VectorIndexTests
  MaxMiCaptureTests/ ExtractorTests (+ Fixtures/*.json), DenylistTests
  MaxMiRelayTests/   GeminiClientTests, JSONArrayParserTests
```

Task order: 1 scaffold → 2 Core utils → 3 env config → 4 DB open+schema → 5 commitCapture → 6 statuses/retry → 7 vectors → 8 relay → 9 pipeline → 10 extractor → 11 observers → 12 app wiring → 13 packaging + manual verify.

---

### Task 1: Package scaffold + vendored sqlite-vec C target

**Files:**
- Create: `Package.swift`, `.gitignore` (append), `Vendor/sqlite-vec/{sqlite-vec.c,sqlite-vec.h}`, `Vendor/sqlite-vec/include/{module.modulemap,shim.h}`, plus one placeholder Swift file per target (`Sources/<Target>/<Target>.swift` containing `// <Target>` so all targets compile empty), and empty test files.
- Test: `swift build` + `swift test` green on the empty skeleton.

**Interfaces:**
- Produces: SwiftPM targets `MaxMiCore`, `MaxMiStore` (depends on Core, GRDB, `CSQLiteVec`), `MaxMiCapture` (depends on Core), `MaxMiRelay` (depends on Core), executable `MaxMi`; C module `CSQLiteVec` exposing `int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);`.

- [ ] **Step 1: Fetch sqlite-vec source (pin v0.1.6)**

```bash
cd /Users/mafex/code/personal/MaxMi
mkdir -p Vendor/sqlite-vec/include
curl -fsSL -o /tmp/sqlite-vec.tar.gz https://github.com/asg017/sqlite-vec/releases/download/v0.1.6/sqlite-vec-0.1.6-amalgamation.tar.gz
tar -xzf /tmp/sqlite-vec.tar.gz -C /tmp/
cp /tmp/sqlite-vec.c /tmp/sqlite-vec.h Vendor/sqlite-vec/
```
Expected: both files exist; `grep -c sqlite3_vec_init Vendor/sqlite-vec/sqlite-vec.h` ≥ 1. (If the URL 404s, take the amalgamation from any v0.1.x release asset — the init symbol is stable.)

- [ ] **Step 2: Write the C module glue**

`Vendor/sqlite-vec/include/shim.h`:
```c
#pragma once
#include <sqlite3.h>
#include "../sqlite-vec.h"
```

`Vendor/sqlite-vec/include/module.modulemap`:
```
module CSQLiteVec {
    header "shim.h"
    link "sqlite3"
    export *
}
```

- [ ] **Step 3: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaxMi",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            path: "Vendor/sqlite-vec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),           // link against real sqlite3 symbols, no ext thunk
                .unsafeFlags(["-Wno-everything"]) // vendored amalgamation, not our lint problem
            ]
        ),
        .target(name: "MaxMiCore"),
        .target(name: "MaxMiStore", dependencies: [
            "MaxMiCore", "CSQLiteVec",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "MaxMiCapture", dependencies: ["MaxMiCore"]),
        .target(name: "MaxMiRelay", dependencies: ["MaxMiCore"]),
        .executableTarget(name: "MaxMi", dependencies: [
            "MaxMiCore", "MaxMiStore", "MaxMiCapture", "MaxMiRelay",
        ]),
        .testTarget(name: "MaxMiCoreTests", dependencies: ["MaxMiCore"]),
        .testTarget(name: "MaxMiStoreTests", dependencies: ["MaxMiStore"]),
        .testTarget(name: "MaxMiCaptureTests", dependencies: ["MaxMiCapture"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "MaxMiRelayTests", dependencies: ["MaxMiRelay"]),
    ]
)
```

Note: `SQLITE_CORE` makes the amalgamation call libsqlite3 functions directly, so per-connection init works against Apple's system SQLite with **no** `sqlite3_load_extension` anywhere. If GRDB 7 API friction appears later, pinning `from: "6.29.0"` is an acceptable fallback — nothing in this plan uses 7-only API.

- [ ] **Step 4: Placeholder sources + empty tests, then build**

Create `Sources/MaxMiCore/MaxMiCore.swift` (`// MaxMiCore`), same for the other four targets; create `Tests/MaxMiCaptureTests/Fixtures/.gitkeep` and one trivial test file per test target, e.g. `Tests/MaxMiCoreTests/SmokeTests.swift`:
```swift
import XCTest
final class SmokeTests: XCTestCase { func testSmoke() { XCTAssertTrue(true) } }
```
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`
Expected: PASS (4 smoke tests; CSQLiteVec compiles — warnings suppressed).

- [ ] **Step 5: .gitignore + commit**

Append to `.gitignore`: `.build/`, `.env`, `MaxMi.app`, `*.db`, `*.db-wal`, `*.db-shm`.
```bash
git add -A && git commit -m "feat: SwiftPM scaffold with vendored sqlite-vec C target"
```

---

### Task 2: Core utilities — UUIDv7, SHA-256 hashing, hour buckets

**Files:**
- Create: `Sources/MaxMiCore/Ident.swift`, `Sources/MaxMiCore/Hashing.swift`, `Sources/MaxMiCore/HourBucket.swift`
- Test: `Tests/MaxMiCoreTests/IdentTests.swift`, `Tests/MaxMiCoreTests/HourBucketTests.swift`

**Interfaces:**
- Produces: `Ident.uuidv7(nowMs: Int64) -> String`; `ContentHash.sha256Hex(_ s: String) -> String`; `HourBucket.bucket(forMs: Int64) -> Int64`; `typealias EpochMs = Int64` and `func epochNowMs() -> Int64` (the ONLY clock call site — everything else takes `nowMs` as a parameter for testability).

- [ ] **Step 1: Write failing tests**

`Tests/MaxMiCoreTests/IdentTests.swift`:
```swift
import XCTest
@testable import MaxMiCore

final class IdentTests: XCTestCase {
    func testUUIDv7ShapeAndVersion() {
        let id = Ident.uuidv7(nowMs: 1_720_000_000_000)
        // 8-4-4-4-12 lowercase hex
        XCTAssertNotNil(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression))
    }
    func testUUIDv7TimeSortable() {
        let a = Ident.uuidv7(nowMs: 1_000)
        let b = Ident.uuidv7(nowMs: 2_000)
        XCTAssertLessThan(a.prefix(13), b.prefix(13)) // 48-bit ms timestamp leads
    }
    func testSha256HexKnownVector() {
        XCTAssertEqual(ContentHash.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
```

`Tests/MaxMiCoreTests/HourBucketTests.swift`:
```swift
import XCTest
@testable import MaxMiCore

final class HourBucketTests: XCTestCase {
    func testBucketMath() {
        XCTAssertEqual(HourBucket.bucket(forMs: 0), 0)
        XCTAssertEqual(HourBucket.bucket(forMs: 3_599_999), 0)
        XCTAssertEqual(HourBucket.bucket(forMs: 3_600_000), 1)
        // 2026-07-07T10:30:00Z = 1783593000000 ms -> hour 495442
        XCTAssertEqual(HourBucket.bucket(forMs: 1_783_593_000_000), 495_442)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=... swift test --filter MaxMiCoreTests`
Expected: FAIL — `cannot find 'Ident' in scope` etc.

- [ ] **Step 3: Implement**

`Sources/MaxMiCore/HourBucket.swift`:
```swift
public typealias EpochMs = Int64

public func epochNowMs() -> EpochMs {
    EpochMs(Date().timeIntervalSince1970 * 1000)
}

public enum HourBucket {
    public static func bucket(forMs ms: EpochMs) -> Int64 { ms / 3_600_000 }
}
```

`Sources/MaxMiCore/Hashing.swift`:
```swift
import CryptoKit
import Foundation

public enum ContentHash {
    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

`Sources/MaxMiCore/Ident.swift`:
```swift
import Foundation

public enum Ident {
    /// RFC 9562 UUIDv7: 48-bit ms timestamp | ver 7 | 12 rand | var 10 | 62 rand.
    public static func uuidv7(nowMs: EpochMs) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ts = UInt64(nowMs)
        for i in 0..<6 { bytes[i] = UInt8((ts >> (8 * (5 - i))) & 0xff) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // variant 10
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }
}
```

- [ ] **Step 4: Run tests — PASS expected**

Run: `DEVELOPER_DIR=... swift test --filter MaxMiCoreTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCore Tests/MaxMiCoreTests
git commit -m "feat(core): UUIDv7, sha256 hex, epoch-hour bucket utilities"
```

---

### Task 3: `.env` config loader

**Files:**
- Create: `Sources/MaxMiCore/EnvConfig.swift`
- Test: `Tests/MaxMiCoreTests/EnvConfigTests.swift`

**Interfaces:**
- Produces:
```swift
public struct EnvConfig: Sendable, Equatable {
    public let geminiAPIKey: String?
    public let extractModel: String   // default "gemini-flash-lite-latest"
    public let embedModel: String     // default "gemini-embedding-001"
    public let embedDims: Int         // default 1536
    public static func load(searchPaths: [URL]) -> EnvConfig
    // App passes [AppSupport/MaxMi/.env, repoRoot/.env]; first file that exists wins.
}
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCoreTests/EnvConfigTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class EnvConfigTests: XCTestCase {
    func write(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func testParsesKeysCommentsAndQuotes() throws {
        let u = try write("""
        # comment
        GEMINI_API_KEY="abc123"
        MAXMI_EMBED_DIMS=768

        MAXMI_EXTRACT_MODEL=gemini-2.5-flash-lite
        """)
        let c = EnvConfig.load(searchPaths: [u])
        XCTAssertEqual(c.geminiAPIKey, "abc123")
        XCTAssertEqual(c.embedDims, 768)
        XCTAssertEqual(c.extractModel, "gemini-2.5-flash-lite")
        XCTAssertEqual(c.embedModel, "gemini-embedding-001") // default survives
    }
    func testMissingFileYieldsDefaultsAndNilKey() {
        let c = EnvConfig.load(searchPaths: [URL(fileURLWithPath: "/nonexistent/.env")])
        XCTAssertNil(c.geminiAPIKey)
        XCTAssertEqual(c.embedDims, 1536)
        XCTAssertEqual(c.extractModel, "gemini-flash-lite-latest")
    }
    func testFirstExistingPathWins() throws {
        let a = try write("GEMINI_API_KEY=first")
        let b = try write("GEMINI_API_KEY=second")
        XCTAssertEqual(EnvConfig.load(searchPaths: [a, b]).geminiAPIKey, "first")
    }
}
```

- [ ] **Step 2: Run — FAIL** (`cannot find 'EnvConfig'`).

- [ ] **Step 3: Implement** — `Sources/MaxMiCore/EnvConfig.swift`:

```swift
import Foundation

public struct EnvConfig: Sendable, Equatable {
    public let geminiAPIKey: String?
    public let extractModel: String
    public let embedModel: String
    public let embedDims: Int

    public static func load(searchPaths: [URL]) -> EnvConfig {
        var kv: [String: String] = [:]
        if let path = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let raw = try? String(contentsOf: path, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
                var val = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                kv[key] = val
            }
        }
        return EnvConfig(
            geminiAPIKey: kv["GEMINI_API_KEY"],
            extractModel: kv["MAXMI_EXTRACT_MODEL"] ?? "gemini-flash-lite-latest",
            embedModel: kv["MAXMI_EMBED_MODEL"] ?? "gemini-embedding-001",
            embedDims: kv["MAXMI_EMBED_DIMS"].flatMap(Int.init) ?? 1536
        )
    }
}
```

- [ ] **Step 4: Run — PASS.**  - [ ] **Step 5: Commit** `feat(core): .env config loader with defaults`

---

### Task 4: Database open, sqlite-vec init, schema migration v1

**Files:**
- Create: `Sources/MaxMiStore/Database.swift`, `Sources/MaxMiStore/Migrations.swift`
- Test: `Tests/MaxMiStoreTests/MigrationTests.swift`

**Interfaces:**
- Produces: `public final class MaxMiDatabase { public let dbQueue: DatabaseQueue; public init(path: String) throws; public static func inMemory() throws -> MaxMiDatabase }`. Opening configures WAL (file DBs), registers sqlite-vec on every connection, runs migrations, chmods files to 600. All schema per spec §4, `extract_status` naming (NOT `embedding_status` on versions).

- [ ] **Step 1: Failing test** — `Tests/MaxMiStoreTests/MigrationTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore

final class MigrationTests: XCTestCase {
    func testSchemaAndVecPresent() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            for t in ["threads", "versions", "derivatives", "retry_queue", "settings", "schema_migrations"] {
                XCTAssertTrue(try d.tableExists(t), "missing table \(t)")
            }
            // sqlite-vec is alive on this connection
            let v = try String.fetchOne(d, sql: "SELECT vec_version()")
            XCTAssertNotNil(v)
            // vec0 virtual table exists
            let n = try Int.fetchOne(d, sql:
                "SELECT count(*) FROM sqlite_master WHERE name='derivative_embeddings'")
            XCTAssertEqual(n, 1)
        }
    }
    func testVersionUniqueInvariantEnforced() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://x.com','X',NULL,1,1)")
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v1','t1',100,'c','h',1,0,1,'pending')
                """)
            XCTAssertThrowsError(try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,is_frozen,committed_at,extract_status)
                VALUES ('v2','t1',100,'c2','h2',1,0,2,'pending')
                """)) // UNIQUE(thread_id, hour_bucket)
        }
    }
}
```

- [ ] **Step 2: Run — FAIL** (`cannot find 'MaxMiDatabase'`).

- [ ] **Step 3: Implement** — `Sources/MaxMiStore/Database.swift`:

```swift
import Foundation
import GRDB
import CSQLiteVec

public final class MaxMiDatabase {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            var err: UnsafeMutablePointer<CChar>? = nil
            let rc = sqlite3_vec_init(db.sqliteConnection, &err, nil)
            if rc != SQLITE_OK {
                throw DatabaseError(resultCode: ResultCode(rawValue: rc),
                                    message: err.map { String(cString: $0) } ?? "sqlite3_vec_init failed")
            }
        }
        let isFile = path != ":memory:"
        if isFile {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        if isFile {
            try dbQueue.write { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
        }
        try Migrations.migrator.migrate(dbQueue)
    }

    public static func inMemory() throws -> MaxMiDatabase {
        try MaxMiDatabase(path: ":memory:")
    }
}
```

Note: GRDB's `DatabaseQueue(path: ":memory:")` opens a private in-memory DB — fine for tests. `prepareDatabase` runs for every new connection, so vec is present on readers too. If the GRDB version exposes `sqliteConnection` differently, use `db.sqliteConnection!` (it is non-nil inside prepareDatabase).

`Sources/MaxMiStore/Migrations.swift`:

```swift
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE threads (
              id             TEXT PRIMARY KEY,
              source_app     TEXT NOT NULL,
              source_key     TEXT NOT NULL,
              source_title   TEXT,
              last_tree_hash TEXT,
              created_at     INTEGER NOT NULL,
              updated_at     INTEGER NOT NULL,
              UNIQUE(source_app, source_key)
            );
            CREATE TABLE versions (
              id             TEXT PRIMARY KEY,
              thread_id      TEXT NOT NULL REFERENCES threads(id),
              hour_bucket    INTEGER NOT NULL,
              content        TEXT NOT NULL,
              content_hash   TEXT NOT NULL,
              word_count     INTEGER NOT NULL DEFAULT 0,
              is_frozen      INTEGER NOT NULL DEFAULT 0,
              committed_at   INTEGER NOT NULL,
              extract_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(thread_id, hour_bucket)
            );
            CREATE INDEX idx_versions_thread ON versions(thread_id);
            CREATE TABLE derivatives (
              id               TEXT PRIMARY KEY,
              thread_id        TEXT NOT NULL REFERENCES threads(id),
              version_id       TEXT NOT NULL REFERENCES versions(id),
              content          TEXT NOT NULL,
              content_hash     TEXT NOT NULL,
              committed_at     INTEGER NOT NULL,
              embedding_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(thread_id, content_hash)
            );
            CREATE INDEX idx_derivatives_version ON derivatives(version_id);
            CREATE TABLE retry_queue (
              id              TEXT PRIMARY KEY,
              kind            TEXT NOT NULL,
              version_id      TEXT,
              derivative_id   TEXT,
              attempts        INTEGER NOT NULL DEFAULT 0,
              next_attempt_at INTEGER NOT NULL,
              last_error      TEXT
            );
            CREATE INDEX idx_retry_due ON retry_queue(next_attempt_at);
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE schema_migrations (id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL);
            """)
            try db.execute(sql: """
            CREATE VIRTUAL TABLE derivative_embeddings USING vec0(
              derivative_id TEXT PRIMARY KEY,
              embedding     FLOAT[1536]
            );
            """)
        }
        return m
    }
}
```

(`schema_migrations` mirrors Minimi's table for DB-diffing parity; GRDB tracks its own migrations in `grdb_migrations` — both exist, harmless.)

- [ ] **Step 4: Run — PASS.**  - [ ] **Step 5: Commit** `feat(store): DB open with per-connection sqlite-vec init + schema v1`

---

### Task 5: `commitCapture` — upsert thread, freeze-then-create, reset-to-pending

**Files:**
- Create: `Sources/MaxMiStore/Records.swift`, `Sources/MaxMiStore/StoreAPI.swift`
- Test: `Tests/MaxMiStoreTests/CommitCaptureTests.swift`

**Interfaces:**
- Consumes: `MaxMiDatabase` (Task 4), `Ident`/`ContentHash`/`HourBucket` (Task 2).
- Produces (on `public final class Store`):
```swift
public struct CaptureInput: Sendable {
    public let sourceApp: String     // "Web"
    public let sourceKey: String     // full canonical URL
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String)
}
public enum CommitResult: Equatable, Sendable {
    case deduplicated                          // tree hash unchanged
    case committed(versionID: String, contentHash: String)
}
public final class Store {
    public init(db: MaxMiDatabase)
    public func commitCapture(_ input: CaptureInput, nowMs: EpochMs) throws -> CommitResult
}
```

Semantics (spec §3/§4, all in ONE transaction): dedup vs `threads.last_tree_hash` → upsert thread → freeze mutable versions with past `hour_bucket` (`is_frozen=1`) → upsert current-bucket version REPLACING content/hash/word_count and resetting `extract_status='pending'`. Clock-stepped-back rule: writing into an already-frozen row for the current bucket **un-freezes** it (`is_frozen=0`).

- [ ] **Step 1: Failing tests** — `Tests/MaxMiStoreTests/CommitCaptureTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CommitCaptureTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db)
    }
    func input(_ content: String, url: String = "https://example.com/a") -> CaptureInput {
        CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: "T", content: content)
    }
    let h10 = EpochMs(495_442) * 3_600_000        // some hour start
    var h11: EpochMs { h10 + 3_600_000 }

    func testNewPageCreatesThreadAndPendingVersion() throws {
        guard case .committed(let vid, let hash) = try store.commitCapture(input("hello world"), nowMs: h10)
        else { return XCTFail() }
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 1)
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions WHERE id=?", arguments: [vid])!
            XCTAssertEqual(row["extract_status"], "pending")
            XCTAssertEqual(row["is_frozen"], 0)
            XCTAssertEqual(row["word_count"], 2)
            XCTAssertEqual(row["content_hash"] as String, hash)
        }
    }
    func testIdenticalContentDeduplicates() throws {
        _ = try store.commitCapture(input("same"), nowMs: h10)
        XCTAssertEqual(try store.commitCapture(input("same"), nowMs: h10 + 1000), .deduplicated)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM versions"), 1)
        }
    }
    func testWithinHourRewritesInPlaceAndResetsPending() throws {
        guard case .committed(let v1, _) = try store.commitCapture(input("first"), nowMs: h10) else { return XCTFail() }
        // simulate pipeline finishing on v1
        try db.dbQueue.write { try $0.execute(sql: "UPDATE versions SET extract_status='completed'") }
        guard case .committed(let v2, _) = try store.commitCapture(input("first plus more"), nowMs: h10 + 60_000) else { return XCTFail() }
        XCTAssertEqual(v1, v2, "same hour -> same row")
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions")!
            XCTAssertEqual(row["content"], "first plus more")
            XCTAssertEqual(row["extract_status"], "pending", "content change resets status")
        }
    }
    func testHourRolloverFreezesOldCreatesNew() throws {
        _ = try store.commitCapture(input("hour ten"), nowMs: h10)
        _ = try store.commitCapture(input("hour eleven"), nowMs: h11)
        try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT * FROM versions ORDER BY hour_bucket")
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["is_frozen"], 1)
            XCTAssertEqual(rows[1]["is_frozen"], 0)
        }
    }
    func testClockSteppedBackWritesIntoFrozenRow() throws {
        _ = try store.commitCapture(input("a"), nowMs: h10)
        _ = try store.commitCapture(input("b"), nowMs: h11)      // freezes h10 row
        _ = try store.commitCapture(input("c"), nowMs: h10 + 1)  // clock stepped back
        try db.dbQueue.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT * FROM versions WHERE hour_bucket=?",
                                       arguments: [495_442])!
            XCTAssertEqual(row["content"], "c")
            XCTAssertEqual(row["is_frozen"], 0, "un-frozen by write")
        }
    }
    func testDistinctURLsDistinctThreads() throws {
        _ = try store.commitCapture(input("a", url: "https://x.com/1"), nowMs: h10)
        _ = try store.commitCapture(input("b", url: "https://x.com/2"), nowMs: h10)
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 2)
        }
    }
}
```

- [ ] **Step 2: Run — FAIL** (`cannot find 'Store'`).

- [ ] **Step 3: Implement** — `Sources/MaxMiStore/StoreAPI.swift`:

```swift
import Foundation
import GRDB
import MaxMiCore

public struct CaptureInput: Sendable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
    }
}

public enum CommitResult: Equatable, Sendable {
    case deduplicated
    case committed(versionID: String, contentHash: String)
}

public final class Store {
    let db: MaxMiDatabase
    public init(db: MaxMiDatabase) { self.db = db }

    public func commitCapture(_ input: CaptureInput, nowMs: EpochMs) throws -> CommitResult {
        let hash = ContentHash.sha256Hex(input.content)
        let bucket = HourBucket.bucket(forMs: nowMs)
        let words = input.content.split(whereSeparator: \.isWhitespace).count

        return try db.dbQueue.write { d in
            // 1. Upsert thread; dedup on unchanged tree hash.
            let existing = try Row.fetchOne(d,
                sql: "SELECT id, last_tree_hash FROM threads WHERE source_app=? AND source_key=?",
                arguments: [input.sourceApp, input.sourceKey])
            let threadID: String
            if let existing {
                if existing["last_tree_hash"] as String? == hash { return .deduplicated }
                threadID = existing["id"]
                try d.execute(sql: "UPDATE threads SET source_title=?, last_tree_hash=?, updated_at=? WHERE id=?",
                              arguments: [input.sourceTitle, hash, nowMs, threadID])
            } else {
                threadID = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?)
                    """, arguments: [threadID, input.sourceApp, input.sourceKey, input.sourceTitle, hash, nowMs, nowMs])
            }

            // 2. Freeze-then-create: seal mutable versions from past hours.
            try d.execute(sql: "UPDATE versions SET is_frozen=1 WHERE thread_id=? AND is_frozen=0 AND hour_bucket<>?",
                          arguments: [threadID, bucket])

            // 3. Upsert this hour's version (replace content, reset pending, un-freeze if clock stepped back).
            if let vid = try String.fetchOne(d, sql: "SELECT id FROM versions WHERE thread_id=? AND hour_bucket=?",
                                             arguments: [threadID, bucket]) {
                try d.execute(sql: """
                    UPDATE versions SET content=?, content_hash=?, word_count=?, committed_at=?,
                                        extract_status='pending', is_frozen=0 WHERE id=?
                    """, arguments: [input.content, hash, words, nowMs, vid])
                return .committed(versionID: vid, contentHash: hash)
            } else {
                let vid = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT INTO versions (id, thread_id, hour_bucket, content, content_hash, word_count, is_frozen, committed_at, extract_status)
                    VALUES (?,?,?,?,?,?,0,?,'pending')
                    """, arguments: [vid, threadID, bucket, input.content, hash, words, nowMs])
                return .committed(versionID: vid, contentHash: hash)
            }
        }
    }
}
```

`Sources/MaxMiStore/Records.swift` — plain row structs used by later tasks:

```swift
import MaxMiCore

public struct PendingVersion: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let hourBucket: Int64
    public let content: String
    public let contentHash: String
    public let sourceApp: String
    public let sourceKey: String
    public let previousFrozenContent: String?   // latest frozen version of same thread, by hour_bucket
}

public struct PendingDerivative: Sendable, Equatable {
    public let id: String
    public let content: String
}
```

- [ ] **Step 4: Run — PASS** (all 6 tests).  - [ ] **Step 5: Commit** `feat(store): commitCapture with freeze-then-create and pending reset`

---

### Task 6: Pipeline-facing Store API — pendingWork, hash-guarded markExtracted, derivatives, retry queue

**Files:**
- Modify: `Sources/MaxMiStore/StoreAPI.swift` (extend `Store`)
- Test: `Tests/MaxMiStoreTests/MarkExtractedTests.swift`

**Interfaces:**
- Consumes: `Store`, `PendingVersion`, `PendingDerivative` (Task 5).
- Produces (methods on `Store`):
```swift
public func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PendingVersion]
// versions with extract_status='pending' that are EXTRACTABLE (spec §3a):
//   frozen (is_frozen=1) OR past hour_bucket (implicitly frozen) OR idle
//   (committed_at <= nowMs - idleThresholdMs). previousFrozenContent joined in.
public func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PendingDerivative]
// hash-dedup on UNIQUE(thread_id, content_hash): INSERT OR IGNORE; returns ONLY newly-inserted rows.
public func markExtracted(versionID: String, contentHashRead: String) throws -> Bool
// UPDATE ... SET extract_status='completed' WHERE id=? AND content_hash=? — the §3a race guard.
// false = content moved mid-flight, stays pending.
public func markExtractFailed(versionID: String) throws
public func markEmbedded(derivativeID: String) throws
public func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws
// backoff: next_attempt_at = nowMs + min(30_000 * 2^attempts, 3_600_000); attempts += 1 on re-enqueue (same target upserts).
public func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)]
public func clearRetry(id: String) throws
public func pendingDerivatives(versionID: String) throws -> [PendingDerivative]
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiStoreTests/MarkExtractedTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MarkExtractedTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let h10 = EpochMs(495_442) * 3_600_000
    var h11: EpochMs { h10 + 3_600_000 }

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db)
    }
    @discardableResult
    func commit(_ content: String, at: EpochMs, url: String = "https://e.com/p") throws -> (vid: String, hash: String) {
        guard case .committed(let v, let h) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: nil, content: content), nowMs: at)
        else { fatalError("dedup unexpected") }
        return (v, h)
    }

    func testFreshMutableVersionIsNotYetWork() throws {
        try commit("just captured", at: h10)
        let work = try store.pendingWork(nowMs: h10 + 60_000, idleThresholdMs: 300_000)
        XCTAssertTrue(work.isEmpty, "not idle, not frozen -> no work")
    }
    func testIdleVersionBecomesWork() throws {
        try commit("sat here a while", at: h10)
        let work = try store.pendingWork(nowMs: h10 + 301_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1)
        XCTAssertNil(work[0].previousFrozenContent)
    }
    func testImplicitlyFrozenPastHourIsWorkWithFrozenBaseline() throws {
        try commit("hour ten content", at: h10)
        _ = try commit("hour eleven content", at: h11)   // freezes h10 row
        // h11 row: not idle yet -> only... wait, h10 row was completed? No: both pending.
        let work = try store.pendingWork(nowMs: h11 + 1_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1, "frozen h10 row is work; fresh h11 row is not")
        XCTAssertEqual(work[0].hourBucket, 495_442)
        XCTAssertNil(work[0].previousFrozenContent, "h10 has no earlier frozen version")
    }
    func testPreviousFrozenContentJoin() throws {
        let a = try commit("old text", at: h10)
        _ = try store.markExtracted(versionID: a.vid, contentHashRead: a.hash)
        _ = try commit("new text", at: h11)              // freezes h10
        let work = try store.pendingWork(nowMs: h11 + 3_600_000, idleThresholdMs: 300_000)
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work[0].previousFrozenContent, "old text")
    }
    func testMarkExtractedHashGuard() throws {
        let a = try commit("v1 content", at: h10)
        // capture lands mid-flight, content moves:
        _ = try commit("v2 content", at: h10 + 60_000)
        XCTAssertFalse(try store.markExtracted(versionID: a.vid, contentHashRead: a.hash),
                       "stale hash must not complete")
        try db.dbQueue.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT extract_status FROM versions"), "pending")
        }
        // pipeline re-reads current content, completes with fresh hash:
        let fresh = ContentHash.sha256Hex("v2 content")
        XCTAssertTrue(try store.markExtracted(versionID: a.vid, contentHashRead: fresh))
    }
    func testInsertDerivativesDedupsByThreadAndHash() throws {
        let a = try commit("content", at: h10)
        let tid = try db.dbQueue.read { try String.fetchOne($0, sql: "SELECT id FROM threads")! }
        let first = try store.insertDerivatives(versionID: a.vid, threadID: tid,
                                                facts: ["Fact one.", "Fact two."], nowMs: h10)
        XCTAssertEqual(first.count, 2)
        let second = try store.insertDerivatives(versionID: a.vid, threadID: tid,
                                                 facts: ["Fact two.", "Fact three."], nowMs: h10)
        XCTAssertEqual(second.map(\.content), ["Fact three."], "re-run is idempotent")
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM derivatives"), 3)
        }
    }
    func testRetryQueueBackoffAndDrain() throws {
        let a = try commit("x", at: h10)
        try store.enqueueRetry(kind: "extract", versionID: a.vid, derivativeID: nil, error: "offline", nowMs: h10)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 1_000).isEmpty, "30s backoff not elapsed")
        let due = try store.dueRetries(nowMs: h10 + 31_000)
        XCTAssertEqual(due.count, 1)
        // re-enqueue same target doubles backoff (attempts=1 -> 60s)
        try store.enqueueRetry(kind: "extract", versionID: a.vid, derivativeID: nil, error: "offline", nowMs: h10 + 31_000)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 61_000).isEmpty)
        XCTAssertEqual(try store.dueRetries(nowMs: h10 + 92_000).count, 1)
        try store.clearRetry(id: due[0].id)
        XCTAssertTrue(try store.dueRetries(nowMs: h10 + 999_000).isEmpty)
    }
}
```

- [ ] **Step 2: Run — FAIL** (missing methods).

- [ ] **Step 3: Implement** — append to `Store` in `Sources/MaxMiStore/StoreAPI.swift`:

```swift
extension Store {
    public func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PendingVersion] {
        try db.dbQueue.read { d in
            let currentBucket = HourBucket.bucket(forMs: nowMs)
            let rows = try Row.fetchAll(d, sql: """
                SELECT v.id, v.thread_id, v.hour_bucket, v.content, v.content_hash,
                       t.source_app, t.source_key,
                       (SELECT p.content FROM versions p
                         WHERE p.thread_id = v.thread_id AND p.hour_bucket < v.hour_bucket
                         ORDER BY p.hour_bucket DESC LIMIT 1) AS previous_frozen_content
                FROM versions v JOIN threads t ON t.id = v.thread_id
                WHERE v.extract_status = 'pending'
                  AND (v.is_frozen = 1 OR v.hour_bucket < ? OR v.committed_at <= ?)
                ORDER BY v.committed_at
                """, arguments: [currentBucket, nowMs - idleThresholdMs])
            return rows.map { r in
                PendingVersion(id: r["id"], threadID: r["thread_id"], hourBucket: r["hour_bucket"],
                               content: r["content"], contentHash: r["content_hash"],
                               sourceApp: r["source_app"], sourceKey: r["source_key"],
                               previousFrozenContent: r["previous_frozen_content"])
            }
        }
    }

    public func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE versions SET extract_status='completed' WHERE id=? AND content_hash=?",
                          arguments: [versionID, contentHashRead])
            return d.changesCount > 0
        }
    }

    public func markExtractFailed(versionID: String) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE versions SET extract_status='failed' WHERE id=?", arguments: [versionID])
        }
    }

    public func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PendingDerivative] {
        try db.dbQueue.write { d in
            var inserted: [PendingDerivative] = []
            for fact in facts {
                let id = Ident.uuidv7(nowMs: nowMs)
                try d.execute(sql: """
                    INSERT OR IGNORE INTO derivatives (id, thread_id, version_id, content, content_hash, committed_at, embedding_status)
                    VALUES (?,?,?,?,?,?,'pending')
                    """, arguments: [id, threadID, versionID, fact, ContentHash.sha256Hex(fact), nowMs])
                if d.changesCount > 0 { inserted.append(PendingDerivative(id: id, content: fact)) }
            }
            return inserted
        }
    }

    public func markEmbedded(derivativeID: String) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE derivatives SET embedding_status='completed' WHERE id=?", arguments: [derivativeID])
        }
    }

    public func pendingDerivatives(versionID: String) throws -> [PendingDerivative] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT id, content FROM derivatives WHERE version_id=? AND embedding_status='pending'",
                             arguments: [versionID])
                .map { PendingDerivative(id: $0["id"], content: $0["content"]) }
        }
    }

    public func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            let existing = try Row.fetchOne(d, sql: """
                SELECT id, attempts FROM retry_queue
                WHERE kind=? AND ifnull(version_id,'')=ifnull(?,'') AND ifnull(derivative_id,'')=ifnull(?,'')
                """, arguments: [kind, versionID, derivativeID])
            let attempts = (existing?["attempts"] as Int? ?? 0)
            let backoff: EpochMs = min(30_000 * EpochMs(1 << min(attempts, 10)), 3_600_000)
            if let existing {
                try d.execute(sql: "UPDATE retry_queue SET attempts=?, next_attempt_at=?, last_error=? WHERE id=?",
                              arguments: [attempts + 1, nowMs + backoff, error, existing["id"] as String])
            } else {
                try d.execute(sql: """
                    INSERT INTO retry_queue (id, kind, version_id, derivative_id, attempts, next_attempt_at, last_error)
                    VALUES (?,?,?,?,1,?,?)
                    """, arguments: [Ident.uuidv7(nowMs: nowMs), kind, versionID, derivativeID, nowMs + backoff, error])
            }
        }
    }

    public func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM retry_queue WHERE next_attempt_at <= ? ORDER BY next_attempt_at",
                             arguments: [nowMs])
                .map { ($0["id"], $0["kind"], $0["version_id"], $0["derivative_id"]) }
        }
    }

    public func clearRetry(id: String) throws {
        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM retry_queue WHERE id=?", arguments: [id]) }
    }
}
```

Backoff note: first enqueue stores `attempts=1` with a 30s delay (`1<<0`); the test's 92s expectation covers the second enqueue's 60s (`1<<1`). `changesCount` is GRDB's per-connection "rows changed by last statement".

- [ ] **Step 4: Run — PASS** (8 tests).  - [ ] **Step 5: Commit** `feat(store): pending-work query, hash-guarded completion, dedup derivatives, retry queue`

---

### Task 7: Vector index — insert + KNN round-trip

**Files:**
- Create: `Sources/MaxMiStore/VectorIndex.swift`
- Test: `Tests/MaxMiStoreTests/VectorIndexTests.swift`

**Interfaces:**
- Consumes: `MaxMiDatabase` (Task 4), `Store` (Tasks 5–6).
- Produces (on `Store`): `public func insertEmbedding(derivativeID: String, vector: [Float]) throws` (throws `StoreError.dimensionMismatch` unless count == 1536) and `public func nearestDerivatives(to vector: [Float], limit: Int) throws -> [(derivativeID: String, distance: Double)]` — unused by M1 runtime, implemented + tested so M2 is drop-in (spec §6). Also `public enum StoreError: Error { case dimensionMismatch(expected: Int, got: Int) }`.

- [ ] **Step 1: Failing test** — `Tests/MaxMiStoreTests/VectorIndexTests.swift`:

```swift
import XCTest
@testable import MaxMiStore

final class VectorIndexTests: XCTestCase {
    func unit(_ hotIndex: Int) -> [Float] {
        var v = [Float](repeating: 0.001, count: 1536); v[hotIndex] = 1.0; return v
    }
    func testInsertAndNearestRoundTrip() throws {
        let db = try MaxMiDatabase.inMemory()
        let store = Store(db: db)
        try store.insertEmbedding(derivativeID: "d-a", vector: unit(0))
        try store.insertEmbedding(derivativeID: "d-b", vector: unit(500))
        try store.insertEmbedding(derivativeID: "d-c", vector: unit(1000))
        let hits = try store.nearestDerivatives(to: unit(500), limit: 2)
        XCTAssertEqual(hits.first?.derivativeID, "d-b")
        XCTAssertEqual(hits.count, 2)
        XCTAssertLessThan(hits[0].distance, hits[1].distance)
    }
    func testDimensionMismatchThrows() throws {
        let store = Store(db: try MaxMiDatabase.inMemory())
        XCTAssertThrowsError(try store.insertEmbedding(derivativeID: "d-x", vector: [1, 2, 3]))
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** — `Sources/MaxMiStore/VectorIndex.swift`:

```swift
import Foundation
import GRDB

public enum StoreError: Error {
    case dimensionMismatch(expected: Int, got: Int)
}

extension Store {
    public func insertEmbedding(derivativeID: String, vector: [Float]) throws {
        guard vector.count == 1536 else {
            throw StoreError.dimensionMismatch(expected: 1536, got: vector.count)
        }
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }  // little-endian f32, vec0's raw format
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO derivative_embeddings (derivative_id, embedding) VALUES (?, ?)",
                          arguments: [derivativeID, blob])
        }
    }

    public func nearestDerivatives(to vector: [Float], limit: Int) throws -> [(derivativeID: String, distance: Double)] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT derivative_id, distance FROM derivative_embeddings
                WHERE embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [blob, limit])
                .map { ($0["derivative_id"], $0["distance"]) }
        }
    }
}
```

(vec0 KNN syntax: `MATCH` + `k = ?`. If the vendored version predates `k`, use `LIMIT ?` — the test tells you immediately.)

- [ ] **Step 4: Run — PASS.**  - [ ] **Step 5: Commit** `feat(store): vector insert + KNN round-trip via sqlite-vec`

---

### Task 8: Gemini relay — client, prompt, JSON parsing, normalization

**Files:**
- Create: `Sources/MaxMiCore/Protocols.swift`, `Sources/MaxMiRelay/GeminiClient.swift`, `Sources/MaxMiRelay/ExtractPrompt.swift`, `Sources/MaxMiRelay/JSONArrayParser.swift`
- Test: `Tests/MaxMiRelayTests/JSONArrayParserTests.swift`, `Tests/MaxMiRelayTests/GeminiClientTests.swift`

**Interfaces:**
- Produces in `MaxMiCore/Protocols.swift` (Core owns the protocol; Relay implements, Pipeline consumes):
```swift
public protocol MemoryRelay: Sendable {
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String]
    func embed(text: String) async throws -> [Float]
}
public enum RelayError: Error {
    case notConfigured          // no API key
    case network(underlying: Error)
    case httpStatus(Int)        // 429/5xx -> retryable
    case malformedResponse(String)
}
```
- Produces in Relay: `public final class GeminiClient: MemoryRelay { public init(config: EnvConfig, session: URLSession = .shared) }`; `enum ExtractPrompt { static func build(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) -> String }`; `enum JSONArrayParser { static func parse(_ raw: String) throws -> [String] }`.

- [ ] **Step 1: Failing parser tests** — `Tests/MaxMiRelayTests/JSONArrayParserTests.swift`:

```swift
import XCTest
@testable import MaxMiRelay

final class JSONArrayParserTests: XCTestCase {
    func testPlainArray() throws {
        XCTAssertEqual(try JSONArrayParser.parse(#"["a", "b"]"#), ["a", "b"])
    }
    func testFencedArray() throws {
        let raw = "```json\n[\"fact one\", \"fact two\"]\n```"
        XCTAssertEqual(try JSONArrayParser.parse(raw), ["fact one", "fact two"])
    }
    func testProseWrappedArray() throws {
        XCTAssertEqual(try JSONArrayParser.parse(#"Here you go: ["x"] hope that helps"#), ["x"])
    }
    func testGarbageThrows() {
        XCTAssertThrowsError(try JSONArrayParser.parse("no array here"))
        XCTAssertThrowsError(try JSONArrayParser.parse(#"{"not": "an array"}"#))
        XCTAssertThrowsError(try JSONArrayParser.parse(#"[1, 2, 3]"#)) // numbers, not strings
    }
    func testEmptyArrayIsValid() throws {
        XCTAssertEqual(try JSONArrayParser.parse("[]"), [])
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement parser** — `Sources/MaxMiRelay/JSONArrayParser.swift`:

```swift
import Foundation
import MaxMiCore

enum JSONArrayParser {
    /// Spec §10: direct parse, then one reparse attempt (strip fences, first-[ to last-]).
    static func parse(_ raw: String) throws -> [String] {
        if let arr = decode(raw) { return arr }
        var s = raw
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end {
            if let arr = decode(String(s[start...end])) { return arr }
        }
        throw RelayError.malformedResponse(String(raw.prefix(200)))
    }
    private static func decode(_ s: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(s.utf8))
    }
}
```

`Sources/MaxMiCore/Protocols.swift` — exactly the protocol + error enum from the Interfaces block above (public, in Core).

`Sources/MaxMiRelay/ExtractPrompt.swift`:

```swift
enum ExtractPrompt {
    static func build(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) -> String {
        var p = """
        You extract memory facts from a snapshot of what a user is reading on screen.

        Return ONLY a JSON array of strings. Each string is one atomic, self-contained, \
        third-person fact sentence about what the user did, read, or learned — naming the \
        user by their first name (use "The user" if unknown). 2-6 facts for a rich page, \
        [] if there is nothing meaningful (navigation chrome, empty pages, cookie banners).

        Source: \(sourceApp) — \(sourceKey)
        """
        if let prev = previousContent {
            p += """


            PREVIOUS snapshot (already processed — do NOT repeat facts derivable from it):
            ---
            \(prev)
            ---
            Extract ONLY facts that are new in the current snapshot.
            """
        }
        p += """


        CURRENT snapshot:
        ---
        \(newContent)
        ---
        JSON array:
        """
        return p
    }
}
```

`Sources/MaxMiRelay/GeminiClient.swift`:

```swift
import Foundation
import MaxMiCore

public final class GeminiClient: MemoryRelay {
    let config: EnvConfig
    let session: URLSession
    let baseURL: URL

    public init(config: EnvConfig, session: URLSession = .shared,
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!) {
        self.config = config; self.session = session; self.baseURL = baseURL
    }

    public func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] {
        let prompt = ExtractPrompt.build(newContent: newContent, previousContent: previousContent,
                                         sourceApp: sourceApp, sourceKey: sourceKey)
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2, "responseMimeType": "application/json"],
        ]
        let data = try await post(path: "models/\(config.extractModel):generateContent", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw RelayError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return try JSONArrayParser.parse(text)
    }

    public func embed(text: String) async throws -> [Float] {
        let body: [String: Any] = [
            "model": "models/\(config.embedModel)",
            "content": ["parts": [["text": text]]],
            "outputDimensionality": config.embedDims,
        ]
        let data = try await post(path: "models/\(config.embedModel):embedContent", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emb = obj["embedding"] as? [String: Any],
              let values = emb["values"] as? [Double] else {
            throw RelayError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return normalize(values.map(Float.init))
    }

    /// Spec §7: only 3072-dim output is pre-normalized by Google; at 1536 we re-normalize.
    func normalize(_ v: [Float]) -> [Float] {
        let mag = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let key = config.geminiAPIKey else { throw RelayError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw RelayError.network(underlying: error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RelayError.httpStatus(status) }
        return data
    }
}
```

- [ ] **Step 4: Client tests with a stub URLProtocol** — `Tests/MaxMiRelayTests/GeminiClientTests.swift`:

```swift
import XCTest
@testable import MaxMiRelay
import MaxMiCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GeminiClientTests: XCTestCase {
    func makeClient() -> GeminiClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let env = EnvConfig.load(searchPaths: [])  // defaults; then inject key via copy
        let keyed = EnvConfig(geminiAPIKey: "test-key", extractModel: env.extractModel,
                              embedModel: env.embedModel, embedDims: env.embedDims)
        return GeminiClient(config: keyed, session: URLSession(configuration: cfg))
    }
    func testExtractParsesFactsAndSendsKey() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            XCTAssertTrue(req.url!.path.contains(":generateContent"))
            let resp = #"{"candidates":[{"content":{"parts":[{"text":"[\"Sudhanshu read the MaxMi spec.\"]"}]}}]}"#
            return (200, Data(resp.utf8))
        }
        let facts = try await makeClient().extract(newContent: "spec text", previousContent: nil,
                                                   sourceApp: "Web", sourceKey: "https://x.com")
        XCTAssertEqual(facts, ["Sudhanshu read the MaxMi spec."])
    }
    func testEmbedNormalizes() async throws {
        // 1536 values of 2.0 -> normalized magnitude 1
        let values = Array(repeating: 2.0, count: 1536)
        let json = try JSONSerialization.data(withJSONObject: ["embedding": ["values": values]])
        StubProtocol.handler = { _ in (200, json) }
        let v = try await makeClient().embed(text: "fact")
        XCTAssertEqual(v.count, 1536)
        let mag = sqrt(v.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(mag, 1.0, accuracy: 0.001)
    }
    func testHTTP429Throws() async {
        StubProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await makeClient().embed(text: "x")
            XCTFail("expected throw")
        } catch let RelayError.httpStatus(code) { XCTAssertEqual(code, 429) }
        catch { XCTFail("wrong error \(error)") }
    }
    func testNoKeyThrowsNotConfigured() async {
        let client = GeminiClient(config: EnvConfig.load(searchPaths: []),
                                  session: .shared)
        do { _ = try await client.embed(text: "x"); XCTFail() }
        catch RelayError.notConfigured {} catch { XCTFail("wrong error \(error)") }
    }
}
```

Note: `EnvConfig` needs a memberwise `public init` for the test — add it (`public init(geminiAPIKey:extractModel:embedModel:embedDims:)`) to `EnvConfig.swift` if Task 3's struct didn't expose one.

- [ ] **Step 5: Run — PASS** (9 relay tests).  - [ ] **Step 6: Commit** `feat(relay): Gemini extract+embed client with prompt, lenient JSON parsing, normalization`

---

### Task 9: CapturePipeline + RetryWorker (Core orchestration, mocked deps)

**Files:**
- Modify: `Sources/MaxMiCore/Protocols.swift` (add `MemoryStore` protocol)
- Create: `Sources/MaxMiCore/CapturePipeline.swift`, `Sources/MaxMiCore/RetryWorker.swift`
- Test: `Tests/MaxMiCoreTests/PipelineTests.swift`

**Interfaces:**
- Consumes: `MemoryRelay` + `RelayError` (Task 8).
- Produces in `Protocols.swift` — the Store abstraction Core orchestrates against (implemented by `MaxMiStore.Store` via a thin conformance in Task 12's wiring; method names/signatures MUST match Task 6 exactly):
```swift
public struct PipelineVersion: Sendable, Equatable {
    public let id: String, threadID: String, content: String, contentHash: String
    public let sourceApp: String, sourceKey: String
    public let previousFrozenContent: String?
    public init(id: String, threadID: String, content: String, contentHash: String,
                sourceApp: String, sourceKey: String, previousFrozenContent: String?)
}
public struct PipelineDerivative: Sendable, Equatable {
    public let id: String, content: String
    public init(id: String, content: String)
}
public protocol MemoryStore: Sendable {
    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion]
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative]
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative]
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool
    func markExtractFailed(versionID: String) throws
    func markEmbedded(derivativeID: String) throws
    func insertEmbedding(derivativeID: String, vector: [Float]) throws
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)]
    func clearRetry(id: String) throws
}
```
- Produces: `public actor CapturePipeline { public init(store: any MemoryStore, relay: any MemoryRelay, idleThresholdMs: EpochMs = 300_000, clock: @escaping @Sendable () -> EpochMs = epochNowMs); public func tick() async }` — one sweep: pendingWork → per version: extract (previousFrozenContent as baseline) → insertDerivatives → embed each NEW + any still-pending derivative → markEmbedded/insertEmbedding → hash-guarded markExtracted. Retryable errors (`network`, `httpStatus(429/5xx)`, `notConfigured`) → `enqueueRetry(kind:"extract", ...)` and move on; `malformedResponse` → markExtractFailed + enqueueRetry (spec §10). `RetryWorker` is folded in: `tick()` FIRST drains `dueRetries` by clearing each due row (its version re-qualifies via `pendingWork` anyway since status is still `pending` — the queue is a wake-up list, not a work list).

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCoreTests/PipelineTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class MockStore: MemoryStore, @unchecked Sendable {
    var work: [PipelineVersion] = []
    var insertedFacts: [String] = []
    var newDerivatives: [PipelineDerivative] = []      // what insertDerivatives returns
    var stillPending: [PipelineDerivative] = []
    var embedded: [String] = []
    var vectors: [String: [Float]] = [:]
    var extractedOK: [(String, String)] = []
    var markExtractedResult = true
    var failed: [String] = []
    var retries: [(kind: String, versionID: String?, error: String)] = []
    var due: [(id: String, kind: String, versionID: String?, derivativeID: String?)] = []
    var cleared: [String] = []

    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion] { work }
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative] {
        insertedFacts.append(contentsOf: facts); return newDerivatives
    }
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative] { stillPending }
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        extractedOK.append((versionID, contentHashRead)); return markExtractedResult
    }
    func markExtractFailed(versionID: String) throws { failed.append(versionID) }
    func markEmbedded(derivativeID: String) throws { embedded.append(derivativeID) }
    func insertEmbedding(derivativeID: String, vector: [Float]) throws { vectors[derivativeID] = vector }
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        retries.append((kind, versionID, error))
    }
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] { due }
    func clearRetry(id: String) throws { cleared.append(id) }
}

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var extractResult: Result<[String], Error> = .success([])
    var embedResult: Result<[Float], Error> = .success(Array(repeating: 0.1, count: 1536))
    var extractCalls: [(new: String, prev: String?)] = []
    var embedCalls: [String] = []
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] {
        extractCalls.append((newContent, previousContent)); return try extractResult.get()
    }
    func embed(text: String) async throws -> [Float] {
        embedCalls.append(text); return try embedResult.get()
    }
}

final class PipelineTests: XCTestCase {
    func version(_ id: String = "v1", prev: String? = nil) -> PipelineVersion {
        PipelineVersion(id: id, threadID: "t1", content: "page text", contentHash: "hash1",
                        sourceApp: "Web", sourceKey: "https://e.com", previousFrozenContent: prev)
    }
    func makeSUT() -> (CapturePipeline, MockStore, MockRelay) {
        let s = MockStore(); let r = MockRelay()
        return (CapturePipeline(store: s, relay: r, clock: { 1_000_000 }), s, r)
    }

    func testHappyPathExtractEmbedComplete() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success(["Fact A.", "Fact B."])
        s.newDerivatives = [.init(id: "d1", content: "Fact A."), .init(id: "d2", content: "Fact B.")]
        await p.tick()
        XCTAssertEqual(s.insertedFacts, ["Fact A.", "Fact B."])
        XCTAssertEqual(r.embedCalls, ["Fact A.", "Fact B."])
        XCTAssertEqual(Set(s.embedded), ["d1", "d2"])
        XCTAssertEqual(s.vectors.count, 2)
        XCTAssertEqual(s.extractedOK.first?.0, "v1")
        XCTAssertEqual(s.extractedOK.first?.1, "hash1", "completes with the hash it READ")
        XCTAssertTrue(s.retries.isEmpty)
    }
    func testPreviousFrozenContentPassedAsBaseline() async {
        let (p, s, r) = makeSUT()
        s.work = [version(prev: "old frozen text")]
        await p.tick()
        XCTAssertEqual(r.extractCalls.first?.prev, "old frozen text")
    }
    func testNetworkErrorEnqueuesRetryNotFailed() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .failure(RelayError.httpStatus(429))
        await p.tick()
        XCTAssertEqual(s.retries.count, 1)
        XCTAssertEqual(s.retries.first?.kind, "extract")
        XCTAssertTrue(s.failed.isEmpty, "retryable != failed")
        XCTAssertTrue(s.extractedOK.isEmpty)
    }
    func testMalformedMarksFailedAndRetries() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .failure(RelayError.malformedResponse("garbage"))
        await p.tick()
        XCTAssertEqual(s.failed, ["v1"])
        XCTAssertEqual(s.retries.count, 1)
    }
    func testEmbedFailureLeavesVersionIncomplete() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success(["Fact A."])
        s.newDerivatives = [.init(id: "d1", content: "Fact A.")]
        r.embedResult = .failure(RelayError.httpStatus(503))
        await p.tick()
        XCTAssertTrue(s.embedded.isEmpty)
        XCTAssertTrue(s.extractedOK.isEmpty, "version stays pending until derivatives embed")
        XCTAssertEqual(s.retries.count, 1)
    }
    func testDueRetriesAreClearedFirst() async {
        let (p, s, _) = makeSUT()
        s.due = [(id: "r1", kind: "extract", versionID: "v1", derivativeID: nil)]
        await p.tick()
        XCTAssertEqual(s.cleared, ["r1"])
    }
    func testEmptyFactArrayStillCompletes() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success([])
        await p.tick()
        XCTAssertEqual(s.extractedOK.count, 1, "nothing meaningful on page is a valid outcome")
    }
}
```

- [ ] **Step 2: Run — FAIL** (`cannot find 'CapturePipeline'` / `MemoryStore`).

- [ ] **Step 3: Implement** — add the `MemoryStore` protocol + structs from the Interfaces block to `Sources/MaxMiCore/Protocols.swift`, then `Sources/MaxMiCore/CapturePipeline.swift`:

```swift
import Foundation

public actor CapturePipeline {
    let store: any MemoryStore
    let relay: any MemoryRelay
    let idleThresholdMs: EpochMs
    let clock: @Sendable () -> EpochMs

    public init(store: any MemoryStore, relay: any MemoryRelay,
                idleThresholdMs: EpochMs = 300_000,
                clock: @escaping @Sendable () -> EpochMs = epochNowMs) {
        self.store = store; self.relay = relay
        self.idleThresholdMs = idleThresholdMs; self.clock = clock
    }

    /// One sweep. Called by the app's timer and after freezes. Never throws; errors route to the retry queue.
    public func tick() async {
        let now = clock()
        // Retry queue is a wake-up list: clear due rows; their versions re-qualify via pendingWork.
        if let due = try? store.dueRetries(nowMs: now) {
            for r in due { try? store.clearRetry(id: r.id) }
        }
        guard let work = try? store.pendingWork(nowMs: now, idleThresholdMs: idleThresholdMs) else { return }
        for v in work { await process(v, now: now) }
    }

    private func process(_ v: PipelineVersion, now: EpochMs) async {
        do {
            let facts = try await relay.extract(newContent: v.content,
                                                previousContent: v.previousFrozenContent,
                                                sourceApp: v.sourceApp, sourceKey: v.sourceKey)
            let fresh = try store.insertDerivatives(versionID: v.id, threadID: v.threadID,
                                                    facts: facts, nowMs: now)
            // fresh + anything a previous crashed/failed run left pending
            var toEmbed = fresh
            let freshIDs = Set(fresh.map(\.id))
            toEmbed += (try store.pendingDerivatives(versionID: v.id)).filter { !freshIDs.contains($0.id) }
            for d in toEmbed {
                let vec = try await relay.embed(text: d.content)
                try store.insertEmbedding(derivativeID: d.id, vector: vec)
                try store.markEmbedded(derivativeID: d.id)
            }
            // Hash guard (§3a): false = content moved mid-flight; stays pending for next tick.
            _ = try store.markExtracted(versionID: v.id, contentHashRead: v.contentHash)
        } catch let e as RelayError {
            if case .malformedResponse = e { try? store.markExtractFailed(versionID: v.id) }
            try? store.enqueueRetry(kind: "extract", versionID: v.id, derivativeID: nil,
                                    error: String(describing: e), nowMs: now)
        } catch {
            try? store.enqueueRetry(kind: "extract", versionID: v.id, derivativeID: nil,
                                    error: String(describing: error), nowMs: now)
        }
    }
}
```

`Sources/MaxMiCore/RetryWorker.swift` is intentionally NOT a separate class — delete it from the file map; the drain lives in `tick()`. (Simplification over the spec's phrasing; behavior identical: a periodic worker drains the queue.)

- [ ] **Step 4: Run — PASS** (7 pipeline tests). Fix `failed`-status versions being re-picked: they aren't (`pendingWork` filters `extract_status='pending'`), and the retry clear doesn't resurrect them — acceptable for M1: `failed` requires the next capture (reset to pending) to retry. This matches spec §10 "mark failed and enqueue retry" with the queue-as-wakeup semantics.

- [ ] **Step 5: Commit** `feat(core): CapturePipeline orchestration with retry-queue wakeups and hash-guarded completion`

---

### Task 10: AX snapshot model + BrowserTabExtractor + denylist (fixture-driven)

**Files:**
- Create: `Sources/MaxMiCapture/AXSnapshot.swift`, `Sources/MaxMiCapture/BrowserTabExtractor.swift`, `Sources/MaxMiCapture/Denylist.swift`
- Create: `Tests/MaxMiCaptureTests/Fixtures/zen-meet.json`, `Tests/MaxMiCaptureTests/Fixtures/safari-domain-only.json`, `Tests/MaxMiCaptureTests/Fixtures/chrome-article.json`
- Test: `Tests/MaxMiCaptureTests/ExtractorTests.swift`, `Tests/MaxMiCaptureTests/DenylistTests.swift`

**Interfaces:**
- Produces:
```swift
public struct AXNode: Codable, Sendable {           // pure-value mirror of an AX subtree
    public let role: String                          // "AXWebArea", "AXStaticText", ...
    public let value: String?                        // kAXValueAttribute
    public let title: String?
    public let url: String?                          // AXURL / AXDocument, already stringified
    public let frame: CGRect?                        // kAXFrameAttribute
    public let focused: Bool                         // kAXFocusedAttribute
    public let children: [AXNode]
}
public struct TabCapture: Equatable, Sendable {
    public let url: String                           // full canonical, normalized
    public let title: String?
    public let content: String                       // visual-order text, newline-joined
}
public enum ExtractionError: Error, Equatable {
    case noWebArea, noURL, addressFieldFocused, emptyContent
}
public enum BrowserTabExtractor {
    public static func extract(window: AXNode, windowTitle: String?) throws -> TabCapture
}
public enum Denylist {
    public static func isBlocked(_ url: String) -> Bool
}
```
- Live AX → `AXNode` conversion happens in Task 11 (`FocusObserver`); this task is pure logic against fixtures, exactly as spec §11 requires (no live browser in CI).

- [ ] **Step 1: Write the fixtures**

`Tests/MaxMiCaptureTests/Fixtures/zen-meet.json` (shape from my live Zen probe — web area with AXURL, address bar as scheme-less AXComboBox):
```json
{
  "role": "AXWindow", "value": null, "title": "Meet - Daily Sync", "url": null, "frame": {"x":0,"y":0,"width":1440,"height":900}, "focused": false,
  "children": [
    {"role": "AXToolbar", "value": null, "title": null, "url": null, "frame": {"x":0,"y":0,"width":1440,"height":40}, "focused": false, "children": [
      {"role": "AXComboBox", "value": "meet.google.com/abc-defg-hij", "title": null, "url": null, "frame": {"x":200,"y":5,"width":600,"height":30}, "focused": false, "children": []}
    ]},
    {"role": "AXWebArea", "value": null, "title": null, "url": "https://meet.google.com/abc-defg-hij", "frame": {"x":0,"y":40,"width":1440,"height":860}, "focused": false, "children": [
      {"role": "AXStaticText", "value": "Daily Sync", "title": null, "url": null, "frame": {"x":20,"y":60,"width":200,"height":20}, "focused": false, "children": []},
      {"role": "AXGroup", "value": null, "title": null, "url": null, "frame": {"x":0,"y":100,"width":1440,"height":700}, "focused": false, "children": [
        {"role": "AXStaticText", "value": "Participants joined", "title": null, "url": null, "frame": {"x":20,"y":120,"width":300,"height":20}, "focused": false, "children": []},
        {"role": "AXStaticText", "value": "Left column later row", "title": null, "url": null, "frame": {"x":20,"y":300,"width":300,"height":20}, "focused": false, "children": []}
      ]},
      {"role": "AXStaticText", "value": "Right of title", "title": null, "url": null, "frame": {"x":400,"y":60,"width":200,"height":20}, "focused": false, "children": []}
    ]}
  ]
}
```

`Tests/MaxMiCaptureTests/Fixtures/safari-domain-only.json` (Safari failure mode: NO web-area URL, address field shows bare domain — extractor must normalize the fallback):
```json
{
  "role": "AXWindow", "value": null, "title": "Example Article", "url": null, "frame": {"x":0,"y":0,"width":1200,"height":800}, "focused": false,
  "children": [
    {"role": "AXToolbar", "value": null, "title": null, "url": null, "frame": {"x":0,"y":0,"width":1200,"height":38}, "focused": false, "children": [
      {"role": "AXTextField", "value": "example.com", "title": "Address and search", "url": null, "frame": {"x":300,"y":4,"width":500,"height":30}, "focused": false, "children": []}
    ]},
    {"role": "AXGroup", "value": null, "title": null, "url": null, "frame": {"x":0,"y":38,"width":1200,"height":762}, "focused": false, "children": [
      {"role": "AXStaticText", "value": "Article body text.", "title": null, "url": null, "frame": {"x":20,"y":60,"width":600,"height":20}, "focused": false, "children": []}
    ]}
  ]
}
```

`Tests/MaxMiCaptureTests/Fixtures/chrome-article.json` (happy Chromium: web area carries the URL; address field mid-edit AND focused — must be ignored because web area wins):
```json
{
  "role": "AXWindow", "value": null, "title": "How SQLite Works", "url": null, "frame": {"x":0,"y":0,"width":1440,"height":900}, "focused": false,
  "children": [
    {"role": "AXToolbar", "value": null, "title": null, "url": null, "frame": {"x":0,"y":0,"width":1440,"height":42}, "focused": false, "children": [
      {"role": "AXTextField", "value": "how does sqli", "title": "Address and search bar", "url": null, "frame": {"x":250,"y":6,"width":700,"height":30}, "focused": true, "children": []}
    ]},
    {"role": "AXWebArea", "value": null, "title": null, "url": "https://sqlite.org/arch.html", "frame": {"x":0,"y":42,"width":1440,"height":858}, "focused": false, "children": [
      {"role": "AXStaticText", "value": "Architecture of SQLite", "title": null, "url": null, "frame": {"x":40,"y":80,"width":400,"height":28}, "focused": false, "children": []},
      {"role": "AXStaticText", "value": "This document describes the architecture.", "title": null, "url": null, "frame": {"x":40,"y":120,"width":800,"height":20}, "focused": false, "children": []}
    ]}
  ]
}
```

- [ ] **Step 2: Failing tests** — `Tests/MaxMiCaptureTests/ExtractorTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class ExtractorTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
    func testWebAreaURLWinsOverAddressBar() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("zen-meet"), windowTitle: "Meet - Daily Sync")
        XCTAssertEqual(cap.url, "https://meet.google.com/abc-defg-hij", "AXURL, not the scheme-less combo box")
        XCTAssertEqual(cap.title, "Meet - Daily Sync")
    }
    func testVisualOrderTopToBottomThenLeft() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("zen-meet"), windowTitle: nil)
        XCTAssertEqual(cap.content.components(separatedBy: "\n"),
                       ["Daily Sync", "Right of title", "Participants joined", "Left column later row"])
    }
    func testSafariFallbackNormalizesSchemelessDomain() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("safari-domain-only"), windowTitle: "Example Article")
        XCTAssertEqual(cap.url, "https://example.com", "address-bar fallback gets https:// prefixed")
        XCTAssertEqual(cap.content, "Article body text.")
    }
    func testFocusedAddressFieldIgnoredWhenWebAreaPresent() throws {
        let cap = try BrowserTabExtractor.extract(window: try fixture("chrome-article"), windowTitle: nil)
        XCTAssertEqual(cap.url, "https://sqlite.org/arch.html")
        XCTAssertFalse(cap.content.contains("how does sqli"), "toolbar text is not page content")
    }
    func testFocusedAddressFieldWithoutWebAreaThrows() throws {
        var fx = try fixture("safari-domain-only")
        // simulate mid-typing: mark the address field focused via a mutated copy
        let data = try JSONEncoder().encode(fx)
        var s = String(data: data, encoding: .utf8)!
        s = s.replacingOccurrences(of: #""value":"example.com","title":"Address and search","url":null,"frame":{"x":300,"y":4,"width":500,"height":30},"focused":false"#,
                                   with: #""value":"exampl","title":"Address and search","url":null,"frame":{"x":300,"y":4,"width":500,"height":30},"focused":true"#)
        fx = try JSONDecoder().decode(AXNode.self, from: Data(s.utf8))
        XCTAssertThrowsError(try BrowserTabExtractor.extract(window: fx, windowTitle: nil)) {
            XCTAssertEqual($0 as? ExtractionError, .addressFieldFocused)
        }
    }
    func testNoURLAnywhereThrows() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [])
        XCTAssertThrowsError(try BrowserTabExtractor.extract(window: bare, windowTitle: nil)) {
            XCTAssertEqual($0 as? ExtractionError, .noURL)
        }
    }
}
```

`Tests/MaxMiCaptureTests/DenylistTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class DenylistTests: XCTestCase {
    func testBlockedHostsAndPatterns() {
        XCTAssertTrue(Denylist.isBlocked("https://accounts.google.com/signin"))
        XCTAssertTrue(Denylist.isBlocked("https://vault.bitwarden.com/#/vault"))
        XCTAssertTrue(Denylist.isBlocked("https://my.1password.com/home"))
        XCTAssertTrue(Denylist.isBlocked("https://foo.okta.com/app"))
        XCTAssertTrue(Denylist.isBlocked("https://example.com/reset-password?token=x"))
        XCTAssertTrue(Denylist.isBlocked("https://netbanking.hdfcbank.com/netbanking"))
    }
    func testAllowedHosts() {
        XCTAssertFalse(Denylist.isBlocked("https://google.com/search?q=x"))
        XCTAssertFalse(Denylist.isBlocked("https://news.ycombinator.com"))
        XCTAssertFalse(Denylist.isBlocked("not a url"))  // unparseable -> allow, capture layer already has the URL
    }
}
```

- [ ] **Step 3: Run — FAIL.**

- [ ] **Step 4: Implement** — `Sources/MaxMiCapture/AXSnapshot.swift`:

```swift
import Foundation

public struct AXNode: Codable, Sendable {
    public let role: String
    public let value: String?
    public let title: String?
    public let url: String?
    public let frame: CGRect?
    public let focused: Bool
    public let children: [AXNode]

    public init(role: String, value: String?, title: String?, url: String?,
                frame: CGRect?, focused: Bool, children: [AXNode]) {
        self.role = role; self.value = value; self.title = title
        self.url = url; self.frame = frame; self.focused = focused; self.children = children
    }
}
```

`Sources/MaxMiCapture/BrowserTabExtractor.swift`:

```swift
import Foundation

public struct TabCapture: Equatable, Sendable {
    public let url: String
    public let title: String?
    public let content: String
}

public enum ExtractionError: Error, Equatable {
    case noWebArea, noURL, addressFieldFocused, emptyContent
}

public enum BrowserTabExtractor {
    static let addressRoles: Set<String> = ["AXTextField", "AXComboBox"]

    public static func extract(window: AXNode, windowTitle: String?) throws -> TabCapture {
        // 1. Primary: web area's own URL (AXURL / AXDocument) — presentation-independent.
        let webArea = firstNode(in: window) { $0.role == "AXWebArea" }
        if let urlString = webArea?.url, !urlString.isEmpty {
            let content = try visualOrderText(in: webArea!)
            return TabCapture(url: urlString, title: windowTitle ?? window.title, content: content)
        }
        // 2. Fallback: toolbar address field. Refuse mid-typing states outright.
        let address = firstNode(in: window) { addressRoles.contains($0.role) && ($0.value?.contains(".") ?? false) }
        if let address {
            if address.focused { throw ExtractionError.addressFieldFocused }
            guard var raw = address.value, !raw.isEmpty else { throw ExtractionError.noURL }
            if !raw.contains("://") { raw = "https://" + raw }   // browsers strip the scheme (verified on Zen)
            let content = try visualOrderText(in: webArea ?? window, excludingToolbars: true)
            return TabCapture(url: raw, title: windowTitle ?? window.title, content: content)
        }
        throw ExtractionError.noURL
    }

    static func visualOrderText(in root: AXNode, excludingToolbars: Bool = false) throws -> String {
        var texts: [(node: AXNode, y: CGFloat, x: CGFloat)] = []
        collectStaticText(root, into: &texts, skipToolbars: excludingToolbars)
        // top->bottom then left->right (spec §5): sort by y, then x
        let sorted = texts.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        let joined = sorted.compactMap(\.node.value).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !joined.isEmpty else { throw ExtractionError.emptyContent }
        return joined
    }

    private static func collectStaticText(_ node: AXNode, into out: inout [(AXNode, CGFloat, CGFloat)], skipToolbars: Bool) {
        if skipToolbars && node.role == "AXToolbar" { return }
        if node.role == "AXStaticText", node.value != nil {
            out.append((node, node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0))
        }
        for child in node.children { collectStaticText(child, into: &out, skipToolbars: skipToolbars) }
    }

    private static func firstNode(in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        if match(root) { return root }
        for child in root.children { if let hit = firstNode(in: child, where: match) { return hit } }
        return nil
    }
}
```

`Sources/MaxMiCapture/Denylist.swift`:

```swift
import Foundation

public enum Denylist {
    // Seeded from the host list pulled out of Minimi's binary (spec §5).
    static let blockedHostSuffixes: [String] = [
        "accounts.google.com", "bitwarden.com", "1password.com", "okta.com",
        "lastpass.com", "dashlane.com", "authy.com",
        "netbanking.hdfcbank.com", "onlinesbi.sbi", "icicibank.com", "axisbank.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com",
        "paypal.com", "stripe.com/login",
    ]
    static let blockedPathFragments: [String] = [
        "/reset-password", "/forgot-password", "/change-password", "/2fa", "/mfa", "/otp",
    ]

    public static func isBlocked(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return blockedPathFragments.contains { path.contains($0) }
    }
}
```

- [ ] **Step 5: Run — PASS** (9 capture tests).  - [ ] **Step 6: Commit** `feat(capture): fixture-driven tab extractor (web-area URL first) + sensitive-domain denylist`

---

### Task 11: Live AX layer — FocusObserver, snapshot reader, Chromium kick

**Files:**
- Create: `Sources/MaxMiCapture/FocusObserver.swift`, `Sources/MaxMiCapture/ChromiumKick.swift`, `Sources/MaxMiCapture/AXReader.swift`
- Test: none automated (live AX needs TCC + a real browser — spec §11 keeps CI fixture-only). Verified manually in Task 13. Keep every branch here thin; all decision logic already lives in tested `BrowserTabExtractor`/`Denylist`.

**Interfaces:**
- Consumes: `AXNode` (Task 10).
- Produces:
```swift
public enum Browser: String, CaseIterable, Sendable {
    case chrome = "com.google.Chrome", arc = "company.thebrowser.Browser",
         zen = "app.zen-browser.zen", safari = "com.apple.Safari",
         brave = "com.brave.Browser", edge = "com.microsoft.edgemac"
    public var isChromium: Bool { self != .safari && self != .zen }
}
public enum AXReader {
    public static func snapshotFrontmostWindow(pid: pid_t, maxNodes: Int = 20_000, maxDepth: Int = 40) -> (window: AXNode, title: String?)?
}
public enum ChromiumKick {
    public static func apply(pid: pid_t)   // sets AXManualAccessibility=true, once per pid
}
@MainActor public final class FocusObserver {
    public init(debounceMs: Int = 1_000, recaptureIntervalSec: Double = 45,
                onCapture: @escaping @MainActor (Browser, pid_t) -> Void)
    public func start()
    public func stop()
}
```
- `FocusObserver` fires `onCapture` (debounced 1s) on: app activation to a browser, AX focus-change inside it, and the 45s re-capture timer while a browser stays frontmost (spec §5). It only identifies *which* browser+pid; reading and committing is the app's closure (Task 12).

- [ ] **Step 1: Implement AXReader** — `Sources/MaxMiCapture/AXReader.swift`:

```swift
import ApplicationServices
import AppKit

public enum AXReader {
    public static func snapshotFrontmostWindow(pid: pid_t, maxNodes: Int = 20_000, maxDepth: Int = 40) -> (window: AXNode, title: String?)? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        var budget = maxNodes
        let node = convert(window, depth: 0, maxDepth: maxDepth, budget: &budget)
        let title = copyAttr(window, kAXTitleAttribute) as? String
        return (node, title)
    }

    private static func convert(_ el: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        let role = copyAttr(el, kAXRoleAttribute) as? String ?? "?"
        let value = copyAttr(el, kAXValueAttribute) as? String
        let title = copyAttr(el, kAXTitleAttribute) as? String
        // AXURL (WebKit/Gecko) then AXDocument (Chromium) — spec §5 primary URL source.
        let url = (copyAttr(el, "AXURL") as? URL)?.absoluteString
            ?? (copyAttr(el, "AXURL") as? String)
            ?? (copyAttr(el, "AXDocument") as? String)
        let focused = (copyAttr(el, kAXFocusedAttribute) as? Bool) ?? false
        var frame: CGRect? = nil
        if let v = copyAttr(el, "AXFrame") {
            var r = CGRect.zero
            if AXValueGetValue(v as! AXValue, .cgRect, &r) { frame = r }
        }
        var children: [AXNode] = []
        if depth < maxDepth, budget > 0,
           let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for kid in kids {
                if budget <= 0 { break }
                children.append(convert(kid, depth: depth + 1, maxDepth: maxDepth, budget: &budget))
            }
        }
        return AXNode(role: role, value: value, title: title, url: url,
                      frame: frame, focused: focused, children: children)
    }

    private static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
}
```

(Force-casts on `AXUIElement`/`AXValue` are the standard CF-bridging idiom here; guarded by the `== .success` check.)

- [ ] **Step 2: Implement ChromiumKick** — `Sources/MaxMiCapture/ChromiumKick.swift`:

```swift
import ApplicationServices

public enum ChromiumKick {
    nonisolated(unsafe) static var kicked = Set<pid_t>()

    /// Chromium builds its renderer AX tree lazily (spec §5). AXManualAccessibility
    /// is Chromium-specific and avoids AXEnhancedUserInterface's window-manager side effects.
    public static func apply(pid: pid_t) {
        guard !kicked.contains(pid) else { return }
        kicked.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
```

- [ ] **Step 3: Implement FocusObserver** — `Sources/MaxMiCapture/FocusObserver.swift`:

```swift
import AppKit
import ApplicationServices

public enum Browser: String, CaseIterable, Sendable {
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case zen = "app.zen-browser.zen"
    case safari = "com.apple.Safari"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"
    public var isChromium: Bool {
        switch self { case .safari, .zen: return false; default: return true }
    }
}

@MainActor
public final class FocusObserver {
    let debounceMs: Int
    let recaptureIntervalSec: Double
    let onCapture: @MainActor (Browser, pid_t) -> Void

    var debounceTask: Task<Void, Never>?
    var recaptureTimer: Timer?
    var axObserver: AXObserver?
    var current: (browser: Browser, pid: pid_t)?

    public init(debounceMs: Int = 1_000, recaptureIntervalSec: Double = 45,
                onCapture: @escaping @MainActor (Browser, pid_t) -> Void) {
        self.debounceMs = debounceMs
        self.recaptureIntervalSec = recaptureIntervalSec
        self.onCapture = onCapture
    }

    public func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.frontmostChanged(app) }
        }
        if let app = NSWorkspace.shared.frontmostApplication { frontmostChanged(app) }
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        recaptureTimer?.invalidate(); recaptureTimer = nil
        debounceTask?.cancel()
        detachAXObserver()
        current = nil
    }

    func frontmostChanged(_ app: NSRunningApplication) {
        detachAXObserver()
        recaptureTimer?.invalidate(); recaptureTimer = nil
        guard let bid = app.bundleIdentifier, let browser = Browser(rawValue: bid) else {
            current = nil; return   // non-browser frontmost -> ignore (spec §5)
        }
        current = (browser, app.processIdentifier)
        if browser.isChromium { ChromiumKick.apply(pid: app.processIdentifier) }
        attachAXObserver(pid: app.processIdentifier)
        scheduleCapture()
        recaptureTimer = Timer.scheduledTimer(withTimeInterval: recaptureIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleCapture() }
        }
    }

    func scheduleCapture() {
        debounceTask?.cancel()
        let ms = debounceMs
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self, let cur = self.current else { return }
            self.onCapture(cur.browser, cur.pid)
        }
    }

    func attachAXObserver(pid: pid_t) {
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in me.scheduleCapture() }
        }
        guard AXObserverCreate(pid, cb, &observer) == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appEl, kAXTitleChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    func detachAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
    }
}
```

(`kAXTitleChangedNotification` catches same-window tab switches, which change the title without changing the focused element.)

- [ ] **Step 4: Build check** — `DEVELOPER_DIR=... swift build` — compiles clean; full test suite still green.

- [ ] **Step 5: Commit** `feat(capture): live AX reader, focus observer with recapture timer, Chromium AX kick`

---

### Task 12: App target — wiring, menu bar, permission gate

**Files:**
- Create: `Sources/MaxMi/main.swift`, `Sources/MaxMi/AppWiring.swift`, `Sources/MaxMi/MenuBarController.swift`, `Sources/MaxMi/PermissionGate.swift`
- Test: build-only (UI shell); logic it calls is all tested in Tasks 2–11.

**Interfaces:**
- Consumes: everything. The `MemoryStore` conformance lives HERE (adapter pattern — `MaxMiStore` never imports Core's pipeline types):

- [ ] **Step 1: Store adapter** — top of `Sources/MaxMi/AppWiring.swift`:

```swift
import Foundation
import MaxMiCore
import MaxMiStore
import MaxMiCapture
import MaxMiRelay

/// Adapts MaxMiStore.Store (concrete rows) to MaxMiCore.MemoryStore (pipeline types).
final class StoreAdapter: MemoryStore, @unchecked Sendable {   // Store is internally serialized by GRDB's DatabaseQueue
    let store: Store
    init(store: Store) { self.store = store }

    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion] {
        try store.pendingWork(nowMs: nowMs, idleThresholdMs: idleThresholdMs).map {
            PipelineVersion(id: $0.id, threadID: $0.threadID, content: $0.content,
                            contentHash: $0.contentHash, sourceApp: $0.sourceApp,
                            sourceKey: $0.sourceKey, previousFrozenContent: $0.previousFrozenContent)
        }
    }
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative] {
        try store.insertDerivatives(versionID: versionID, threadID: threadID, facts: facts, nowMs: nowMs)
            .map { PipelineDerivative(id: $0.id, content: $0.content) }
    }
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative] {
        try store.pendingDerivatives(versionID: versionID).map { PipelineDerivative(id: $0.id, content: $0.content) }
    }
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        try store.markExtracted(versionID: versionID, contentHashRead: contentHashRead)
    }
    func markExtractFailed(versionID: String) throws { try store.markExtractFailed(versionID: versionID) }
    func markEmbedded(derivativeID: String) throws { try store.markEmbedded(derivativeID: derivativeID) }
    func insertEmbedding(derivativeID: String, vector: [Float]) throws {
        try store.insertEmbedding(derivativeID: derivativeID, vector: vector)
    }
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        try store.enqueueRetry(kind: kind, versionID: versionID, derivativeID: derivativeID, error: error, nowMs: nowMs)
    }
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] {
        try store.dueRetries(nowMs: nowMs)
    }
    func clearRetry(id: String) throws { try store.clearRetry(id: id) }
}
```

- [ ] **Step 2: AppWiring (rest of the file)** — composition root + the capture closure:

```swift
@MainActor
final class AppWiring {
    let store: Store
    let pipeline: CapturePipeline
    var observer: FocusObserver?
    let menuBar: MenuBarController
    var pipelineTimer: Timer?
    var paused = false
    private(set) var captureCount = 0

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxMi", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        // Spec §6/§9: keep plaintext memories out of Time Machine.
        var dir = appSupport
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)

        let config = EnvConfig.load(searchPaths: [
            appSupport.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ])
        let db = try MaxMiDatabase(path: appSupport.appendingPathComponent("maxmi.db").path)
        store = Store(db: db)
        let relay = GeminiClient(config: config)
        pipeline = CapturePipeline(store: StoreAdapter(store: store), relay: relay)
        menuBar = MenuBarController()
        menuBar.hasAPIKey = config.geminiAPIKey != nil
    }

    func start() {
        menuBar.install(
            onTogglePause: { [weak self] in self?.paused.toggle(); self?.menuBar.paused = self?.paused ?? false },
            onQuit: { NSApp.terminate(nil) }
        )
        guard PermissionGate.ensureAccessibility(menuBar: menuBar) else { return }  // re-checked by menu action
        let observer = FocusObserver { [weak self] browser, pid in
            self?.captureFrontmost(browser: browser, pid: pid)
        }
        observer.start()
        self.observer = observer
        // Pipeline sweep every 30s: picks up idle/frozen versions and due retries (spec §3a sweeper).
        pipelineTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            Task { await self.pipeline.tick() }
        }
    }

    func captureFrontmost(browser: Browser, pid: pid_t) {
        guard !paused else { return }
        // Chromium post-kick: empty tree is "retry shortly", NOT a failed capture (spec §10).
        attemptCapture(browser: browser, pid: pid, attemptsLeft: browser.isChromium ? 3 : 1)
    }

    private func attemptCapture(browser: Browser, pid: pid_t, attemptsLeft: Int) {
        guard let (window, title) = AXReader.snapshotFrontmostWindow(pid: pid) else {
            retryOrGiveUp(browser: browser, pid: pid, attemptsLeft: attemptsLeft); return
        }
        do {
            let cap = try BrowserTabExtractor.extract(window: window, windowTitle: title)
            guard !Denylist.isBlocked(cap.url) else { return }   // dropped, never stored (spec §5)
            let result = try store.commitCapture(
                CaptureInput(sourceApp: "Web", sourceKey: cap.url, sourceTitle: cap.title, content: cap.content),
                nowMs: epochNowMs())
            if case .committed = result {
                captureCount += 1
                menuBar.captureCount = captureCount
            }
        } catch ExtractionError.emptyContent, ExtractionError.noWebArea {
            retryOrGiveUp(browser: browser, pid: pid, attemptsLeft: attemptsLeft)
        } catch {
            NSLog("MaxMi capture skipped: \(error)")             // logged, skipped, never crash (spec §10)
        }
    }

    private func retryOrGiveUp(browser: Browser, pid: pid_t, attemptsLeft: Int) {
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptCapture(browser: browser, pid: pid, attemptsLeft: attemptsLeft - 1)
        }
    }
}
```

- [ ] **Step 3: MenuBarController + PermissionGate + main** —

`Sources/MaxMi/MenuBarController.swift`:

```swift
import AppKit

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let countItem = NSMenuItem(title: "Captures: 0", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "⚠ Grant Accessibility…", action: nil, keyEquivalent: "")
    private let keyItem = NSMenuItem(title: "⚠ No GEMINI_API_KEY in .env", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "p")

    var captureCount: Int = 0 { didSet { countItem.title = "Captures: \(captureCount)" } }
    var paused: Bool = false { didSet { pauseItem.title = paused ? "Resume Capture" : "Pause Capture" } }
    var hasAPIKey: Bool = true { didSet { keyItem.isHidden = hasAPIKey } }
    var accessibilityGranted: Bool = true { didSet { permissionItem.isHidden = accessibilityGranted } }

    func install(onTogglePause: @escaping () -> Void, onQuit: @escaping () -> Void) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧠"
        let menu = NSMenu()
        permissionItem.isHidden = accessibilityGranted
        keyItem.isHidden = hasAPIKey
        permissionItem.action = #selector(NSApplication.openAccessibilitySettings)
        permissionItem.target = NSApp
        menu.addItem(countItem)
        menu.addItem(.separator())
        menu.addItem(permissionItem)
        menu.addItem(keyItem)
        menu.addItem(withTitle: "Pause Capture", action: nil, keyEquivalent: "").isHidden = true // placeholder ordering
        menu.addItem(pauseItem)
        pauseItem.setAction { onTogglePause() }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MaxMi", action: nil, keyEquivalent: "q")
        quit.setAction { onQuit() }
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }
}

// Closure-backed NSMenuItem actions (no @objc target boilerplate per item).
private final class ActionTrampoline: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
private var trampolineKey: UInt8 = 0
extension NSMenuItem {
    func setAction(_ block: @escaping () -> Void) {
        let t = ActionTrampoline(block)
        objc_setAssociatedObject(self, &trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ActionTrampoline.fire)
    }
}
extension NSApplication {
    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
```

(Remove the placeholder-ordering line if it reads awkwardly at implementation time — it exists only to keep this listing append-only; the real menu is: count, separator, warnings, pause, separator, quit.)

`Sources/MaxMi/PermissionGate.swift`:

```swift
import ApplicationServices

@MainActor
enum PermissionGate {
    /// Spec §5: check AXIsProcessTrustedWithOptions with the system prompt on first run.
    static func ensureAccessibility(menuBar: MenuBarController) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        menuBar.accessibilityGranted = trusted
        return trusted
    }
}
```

`Sources/MaxMi/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only; pairs with LSUIElement in Info.plist

let wiring = try AppWiring()
wiring.start()

// If permission was missing at launch, poll until granted, then start capture.
if wiring.observer == nil {
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
        Task { @MainActor in
            if AXIsProcessTrusted() {
                t.invalidate()
                wiring.start()
            }
        }
    }
}

app.run()
```

- [ ] **Step 4: Build + full suite** — `DEVELOPER_DIR=... swift build && DEVELOPER_DIR=... swift test`
Expected: builds; all ~35 tests green.

- [ ] **Step 5: Commit** `feat(app): menu-bar shell, permission gate, capture wiring with Chromium retry`

---

### Task 13: Packaging + end-to-end manual verification (exit criteria)

**Files:**
- Create: `packaging/Info.plist`, `packaging/make-app.sh`, `README.md` (replace stub)

- [ ] **Step 1: Info.plist** — `packaging/Info.plist` (burnt's, adapted):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>MaxMi</string>
	<key>CFBundleExecutable</key>
	<string>MaxMi</string>
	<key>CFBundleIdentifier</key>
	<string>dev.mafex.maxmi</string>
	<key>CFBundleName</key>
	<string>MaxMi</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 2: make-app.sh** — `packaging/make-app.sh` (burnt's pattern, no vendored node):

```bash
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
```

`chmod +x packaging/make-app.sh`.

- [ ] **Step 3: Manual verification — walk the spec §12 exit criteria** (use the `verify` skill's mindset: drive the real flow):

```bash
cd /Users/mafex/code/personal/MaxMi
echo "GEMINI_API_KEY=<real key>" > ~/Library/Application\ Support/MaxMi/.env
./packaging/make-app.sh && open MaxMi.app
```

Then check each criterion, in order:
1. **Menu bar + permission:** 🧠 appears; Accessibility prompt fires; grant it (rebuilds need `tccutil reset Accessibility dev.mafex.maxmi` + re-grant).
2. **Distinct threads, full URLs:** browse 3 distinct pages in Zen AND Safari (Safari with default settings — this proves the web-area URL path). Then:
   `sqlite3 ~/Library/Application\ Support/MaxMi/maxmi.db "SELECT source_key, source_title FROM threads"` → one row per page, every source_key a full `https://` URL.
3. **Dedup + rollover:** revisit an unchanged page → `SELECT count(*) FROM versions` unchanged. (Hour rollover is verified by the CommitCaptureTests clock tests; live, optionally set the Mac clock forward one hour and revisit → old row `is_frozen=1`, new row created.)
4. **Facts + embeddings:** sit on one page ≥5 min (idle trigger) or just wait for a sweep after switching away:
   `sqlite3 ... "SELECT v.extract_status, count(d.id) FROM versions v LEFT JOIN derivatives d ON d.version_id=v.id GROUP BY v.id"` → `completed` with N≥0 facts; `SELECT count(*) FROM derivative_embeddings` matches completed derivatives. Re-capture the same page repeatedly within the hour → derivative count does NOT grow with duplicates.
5. **Network kill:** turn Wi-Fi off, browse 2 new pages, confirm `retry_queue` rows + versions `pending`; Wi-Fi on, wait ≤60s → queue drains, statuses complete. Nothing lost.
6. **Denylist + count:** visit `https://accounts.google.com` → no thread appears. Menu shows a live capture count. `ls -l ~/Library/Application\ Support/MaxMi/` → `-rw-------` on db/wal/shm.

- [ ] **Step 4: README** — replace the stub with: what MaxMi is (one paragraph), M1 scope, build (`./packaging/make-app.sh`), `.env` setup, the TCC re-grant note, and a pointer to the spec + this plan.

- [ ] **Step 5: Final commit**

```bash
git add -A && git commit -m "feat(packaging): app bundle build script + M1 verification README"
```

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §3 flow → Tasks 5/6/9/12; §3a triggers+race → 6/9 (idle+sweeper via `pendingWork`, freeze via commit, hash guard tested both at Store and mocked-pipeline level); §4 schema incl. UNIQUE + indexes + clock-back rule → 4/5; §5 capture incl. web-area-URL-first, Chromium kick, Zen bundle id, denylist, recapture timer → 10/11/12; §6 store incl. static sqlite-vec + chmod 600 + TM exclusion → 1/4/12; §7 relay incl. prompt ownership, normalization, batch TODO → 8; §8 .env → 3; §9 plaintext + mitigations → 4/12 (no crypto anywhere); §10 error handling incl. retry-shortly for Chromium → 6/8/9/12; §11 test strategy (Store owns versioning tests, Core mocked-orchestration, fixture-driven capture, stubbed HTTP relay) → matches task-by-task; §12 exit criteria → Task 13 walks all six. Deliberate deviation, noted inline: `RetryWorker` folded into `CapturePipeline.tick()` (queue-as-wakeup) instead of a separate class — same behavior, less machinery.

**Placeholders:** none — every code step has complete code; the one intentionally-deferred piece (live-AX correctness) is explicitly moved to manual verification per spec §11, not left vague.

**Type consistency:** `MemoryStore` protocol (Task 9) methods match `Store` concrete methods (Tasks 5–7) 1:1 via `StoreAdapter` (Task 12); `PendingVersion/PendingDerivative` (Store) vs `PipelineVersion/PipelineDerivative` (Core) are deliberately separate types bridged only in the adapter; `EnvConfig` memberwise init requirement flagged in Task 8 where it's first needed.
