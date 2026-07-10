# MaxMi Clean Capture Implementation Plan — Central Keying + Fingerprint Dedup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MaxMi capture cleanly by design — route every capture through one `ThreadKeyDeriver` (parsers stop making final keys) and add `message_fingerprints` per-item dedup — so the DB never fractures, per `docs/superpowers/specs/2026-07-10-maxmi-clean-capture-design.md`.

**Architecture:** Adopt Minimi's separation of content (parser) / identity (central keyer) / novelty (fingerprint dedup). A pure `ThreadKeyDeriver` in MaxMiCapture turns a parser's `ParsedCapture` (whose `sourceKey` becomes a hint) into a clean, stable key via per-app semantic rules + universal hygiene + coarsen-don't-drop fallback. `commitCapture` in MaxMiStore gains a fingerprint pass so near-duplicate recaptures create no new facts. Golden fixtures lock cleanliness in so new parsers are born clean.

**Tech Stack:** Swift 6, MaxMiCapture (SourceParser/ParsedCapture/URLKeyNormalizer), MaxMiStore (GRDB DatabaseMigrator, Store.commitCapture), MaxMiCore (ContentHash.sha256Hex, Ident, HourBucket), fixture-driven XCTest.

## Global Constraints

- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings.
- `ThreadKeyDeriver.derive` is **pure and total**: always returns a non-empty key; never throws; never returns empty (worst case = app-level fallback). No capture is ever dropped for a keying failure (spec §7).
- Principle: **coarse-but-stable beats fine-but-volatile** — a degenerate key coarsens to the app-level key, never drops the capture (spec §3a).
- Fingerprint dedup fails **open**: on DB error, treat items as novel and commit (a redundant fact beats lost memory) (spec §7).
- Keys are lowercased, whitespace-collapsed, punctuation/`…`-stripped, length-bounded; file-extension last segments coarsen to parent (spec §3a).
- Real dirty-key corpus (test inputs, from live DB): 18 maps-coord threads → one `web:.../maps`; docs id `1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg` split across `?tab=` values → one key; spreadsheet split across `/spreadsheets/d/<id>` vs `/spreadsheets/u/3/d/<id>` → one key; `terminal:warp/inspect2.mjs`, `terminal:warp/maxmi.app).`, `terminal:warp/layer…)` → coarsen.
- Migration `v2` is additive (new table only); existing threads/versions untouched; runs idempotently via `DatabaseMigrator` (spec §6).
- No change to encryption, MCP, extraction, capture cadence; no schema redesign; no historical rewrite (spec §4).
- Commit messages conventional; NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `clean-capture` off main.

## File Structure

```
Sources/MaxMiCapture/ThreadKeyDeriver.swift   NEW: pure derive(ParsedCapture)->String; per-app rules + hygiene + fallback
Sources/MaxMiCapture/TerminalParser.swift      MODIFY: cwd rule stays but deriver owns final hygiene (keep method, deriver re-cleans)
Sources/MaxMiStore/Migrations.swift            MODIFY: add v2 message_fingerprints migration
Sources/MaxMiStore/StoreAPI.swift              MODIFY: fingerprint pass in commitCapture + FingerprintDedup helper
Sources/MaxMi/AppWiring.swift                  MODIFY: call ThreadKeyDeriver.derive before building CaptureInput
Tests/MaxMiCaptureTests/ThreadKeyDeriverTests.swift   NEW: hygiene + per-app + real dirty corpus
Tests/MaxMiStoreTests/FingerprintDedupTests.swift     NEW: novel-only commit, no-novel->dedup
Tests/MaxMiStoreTests/MigrationTests.swift            MODIFY: assert v2 table exists
```

Task order: 1 ThreadKeyDeriver (pure, no deps) → 2 wire deriver into AppWiring → 3 fingerprint migration + dedup in commitCapture → 4 golden-fixtures harness → 5 live verify.

---

### Task 1: ThreadKeyDeriver — the central keying chokepoint

**Files:**
- Create: `Sources/MaxMiCapture/ThreadKeyDeriver.swift`
- Test: `Tests/MaxMiCaptureTests/ThreadKeyDeriverTests.swift`

**Interfaces:**
- Consumes: `ParsedCapture` (sourceApp, sourceKey [now a HINT], sourceTitle, content), `URLKeyNormalizer.normalize` (existing).
- Produces:
```swift
public enum ThreadKeyDeriver {
    // Pure, total: always non-empty. Turns a parser's ParsedCapture into a clean stable key.
    public static func derive(_ capture: ParsedCapture) -> String
    // Universal hygiene applied to every key (exposed for testing).
    static func hygiene(_ key: String, appFallback: String) -> String
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/MaxMiCaptureTests/ThreadKeyDeriverTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class ThreadKeyDeriverTests: XCTestCase {
    func cap(_ app: String, _ key: String, _ title: String? = nil, _ content: String = "x") -> ParsedCapture {
        ParsedCapture(sourceApp: app, sourceKey: key, sourceTitle: title, content: content)
    }

    // ── Universal hygiene ──
    func testStripsTrailingPunctuationAndBrackets() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/maxmi.app).", appFallback: "terminal:warp"),
                       "terminal:warp")   // ".app).": file-ext token -> coarsen to parent
    }
    func testStripsEllipsisTruncation() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/layer…)", appFallback: "terminal:warp"),
                       "terminal:warp/layer")
    }
    func testCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/My  Project", appFallback: "terminal:warp"),
                       "terminal:warp/my-project")
    }
    func testFileExtensionSegmentCoarsensToParent() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:warp/inspect2.mjs", appFallback: "terminal:warp"),
                       "terminal:warp")
    }
    func testDegenerateKeyCoarsensToAppFallback() {
        XCTAssertEqual(ThreadKeyDeriver.hygiene("terminal:", appFallback: "terminal:warp"), "terminal:warp")
        XCTAssertEqual(ThreadKeyDeriver.hygiene("   ", appFallback: "web:unknown"), "web:unknown")
    }
    func testLengthBounded() {
        let long = "web:example.com/" + String(repeating: "a", count: 500)
        XCTAssertLessThanOrEqual(ThreadKeyDeriver.hygiene(long, appFallback: "web:example.com").count, 200)
    }

    // ── Web via URLKeyNormalizer (real dirty corpus) ──
    func testMapsCoordsCollapse() {
        let a = ThreadKeyDeriver.derive(cap("Web", "https://www.google.com/maps/@13.0001,77.71,2550m/data=!3?entry=ttu"))
        let b = ThreadKeyDeriver.derive(cap("Web", "https://www.google.com/maps/@12.999,77.71,2070m/data=!3?entry=ttu"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "https://www.google.com/maps")
    }
    func testDocsTabFractureCollapses() {
        let id = "1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg"
        let a = ThreadKeyDeriver.derive(cap("Web", "https://docs.google.com/document/d/\(id)/edit?tab=t.6xoj"))
        let b = ThreadKeyDeriver.derive(cap("Web", "https://docs.google.com/document/d/\(id)/edit?tab=t.p2vx"))
        XCTAssertEqual(a, b)
    }

    // ── Per-app: non-web keys pass through hygiene but keep their scheme ──
    func testSlackKeyPreserved() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Slack", "slack:acme/general")), "slack:acme/general")
    }
    func testTerminalGarbageKeyCleaned() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Warp", "terminal:warp/maxmi.app).")), "terminal:warp")
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Warp", "terminal:warp/inspect2.mjs")), "terminal:warp")
    }
    func testMailKeyPreserved() {
        XCTAssertEqual(ThreadKeyDeriver.derive(cap("Mail", "mail:inbox")), "mail:inbox")
    }
}
```

- [ ] **Step 2: Run — FAIL** (`ThreadKeyDeriver` undefined).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter ThreadKeyDeriverTests`

- [ ] **Step 3: Implement** — `Sources/MaxMiCapture/ThreadKeyDeriver.swift`:

```swift
import Foundation

/// The single keying chokepoint. Parsers propose a key (ParsedCapture.sourceKey is a HINT);
/// this turns it into a clean, STABLE thread key. Pure and total — always returns a non-empty
/// key, coarsening to an app-level fallback rather than ever dropping a capture.
/// Principle: coarse-but-stable beats fine-but-volatile (spec §3a).
public enum ThreadKeyDeriver {
    static let maxLen = 200

    public static func derive(_ capture: ParsedCapture) -> String {
        let fallback = appFallback(for: capture)
        // Web: identity comes from the normalized URL, not the raw hint.
        if capture.sourceApp == "Web" {
            let normalized = URLKeyNormalizer.normalize(capture.sourceKey)
            return hygiene(normalized, appFallback: fallback, isURL: true)
        }
        // Native apps: the parser's hint already carries the scheme (slack:/terminal:/mail:...).
        return hygiene(capture.sourceKey, appFallback: fallback)
    }

    /// App-level coarse key used when a specific key degenerates.
    static func appFallback(for capture: ParsedCapture) -> String {
        switch capture.sourceApp {
        case "Web":
            // host-level fallback
            if let host = URLComponents(string: capture.sourceKey)?.host { return "https://\(host)" }
            return "web:unknown"
        case "Warp", "Terminal", "iTerm2": return "terminal:\(capture.sourceApp.lowercased())"
        default:
            // scheme prefix of the hint if present (e.g. "slack:x" -> "slack:"), else app name
            if let scheme = capture.sourceKey.split(separator: ":").first, capture.sourceKey.contains(":") {
                return "\(scheme):\(capture.sourceApp.lowercased())"
            }
            return "\(capture.sourceApp.lowercased()):unknown"
        }
    }

    /// Universal hygiene. `isURL` keeps URL structure intact (only trims junk); non-URL keys
    /// get scheme-preserving slug cleanup + file-extension coarsening.
    static func hygiene(_ raw: String, appFallback: String, isURL: Bool = false) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        key = key.replacingOccurrences(of: "\n", with: " ")
        // strip trailing junk: whitespace, brackets, punctuation, ellipsis
        let trailingJunk = CharacterSet(charactersIn: " \t.,;:)]}>…")
        while let last = key.unicodeScalars.last, trailingJunk.contains(last) { key.unicodeScalars.removeLast() }
        if key.isEmpty { return appFallback }
        if isURL {
            return String(key.prefix(maxLen))
        }
        // Non-URL: split scheme:path, clean the path segments.
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            // no scheme -> degenerate
            return appFallback
        }
        let scheme = parts[0].lowercased()
        var path = parts[1]
        // collapse whitespace runs to single dash, lowercase
        path = path.lowercased().replacingOccurrences(of: " ", with: "-")
        while path.contains("--") { path = path.replacingOccurrences(of: "--", with: "-") }
        // last segment file-extension coarsening: "warp/inspect2.mjs" -> "warp"
        var segs = path.split(separator: "/").map(String.init)
        if let last = segs.last, let dot = last.lastIndex(of: "."), dot != last.startIndex {
            let ext = last[last.index(after: dot)...]
            if ext.count <= 5 && !ext.isEmpty && ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                segs.removeLast()
            }
        }
        let cleanedPath = segs.joined(separator: "/")
        if cleanedPath.isEmpty { return appFallback }
        return String("\(scheme):\(cleanedPath)".prefix(maxLen))
    }
}
```

- [ ] **Step 4: Run — PASS** (all ThreadKeyDeriverTests).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter ThreadKeyDeriverTests`

- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiCapture/ThreadKeyDeriver.swift Tests/MaxMiCaptureTests/ThreadKeyDeriverTests.swift
git commit -m "feat(capture): ThreadKeyDeriver — central key hygiene + coarsen-dont-drop"
```

---

### Task 2: Wire ThreadKeyDeriver into the capture path

**Files:**
- Modify: `Sources/MaxMi/AppWiring.swift` (the `CaptureInput` construction, ~line 209)
- Test: covered by Task 1 (deriver) + Task 5 live; AppWiring is untested glue (no MaxMiTests target — verified by build + live, per M4 precedent).

**Interfaces:**
- Consumes: `ThreadKeyDeriver.derive(_:) -> String` (Task 1), existing `parsed: ParsedCapture`, `store.commitCapture`.
- Produces: nothing new; changes the `sourceKey` passed to `CaptureInput` to the derived key.

- [ ] **Step 1: Modify AppWiring** — after the `shouldCommit` gate and before `commitCapture`, derive the clean key. Current code:

```swift
            guard CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: pausedThreads) else { return }

            let result = try store.commitCapture(
                CaptureInput(sourceApp: parsed.sourceApp, sourceKey: parsed.sourceKey,
                            sourceTitle: parsed.sourceTitle, content: parsed.content),
                nowMs: epochNowMs())
```

Replace with (derive the clean key; note `shouldCommit`/denylist/pause still run on the parser's key BEFORE derivation — that's correct, denylist matches raw URLs):

```swift
            guard CaptureDispatch.shouldCommit(parsed: parsed, pausedThreads: pausedThreads) else { return }

            // Central keying chokepoint: parsers propose a key; the deriver makes it clean+stable
            // (coarsen-don't-drop). No parser writes the final source_key directly (spec §3a).
            let cleanKey = ThreadKeyDeriver.derive(parsed)
            let result = try store.commitCapture(
                CaptureInput(sourceApp: parsed.sourceApp, sourceKey: cleanKey,
                            sourceTitle: parsed.sourceTitle, content: parsed.content),
                nowMs: epochNowMs())
```

Also update `lastSourceKey = parsed.sourceKey` (two occurrences at ~217, ~220) to `lastSourceKey = cleanKey` so "pause current thread" targets the actual stored key:

```swift
            case .committed:
                captureCount += 1
                menuBar.captureCount = captureCount
                lastSourceKey = cleanKey
            case .deduplicated:
                lastSourceKey = cleanKey
```

- [ ] **Step 2: Verify MaxMiCapture is imported in AppWiring** — `ThreadKeyDeriver` is in MaxMiCapture, already imported (it uses `CaptureDispatch`, `ParsedCapture`). Confirm with:
Run: `grep -n "import MaxMiCapture" Sources/MaxMi/AppWiring.swift`
Expected: a line exists. If not, add `import MaxMiCapture` at the top.

- [ ] **Step 3: Build** — confirm the wiring compiles.
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build`
Expected: `Build complete!`

- [ ] **Step 4: Full suite** — nothing regressed.
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`
Expected: all green (existing count + Task 1's ~11).

- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMi/AppWiring.swift
git commit -m "feat(capture): route every capture through ThreadKeyDeriver before commit"
```

---

### Task 3: message_fingerprints migration + per-item dedup in commitCapture

**Files:**
- Modify: `Sources/MaxMiStore/Migrations.swift` (add `v2`), `Sources/MaxMiStore/StoreAPI.swift` (fingerprint pass + helper)
- Test: `Tests/MaxMiStoreTests/FingerprintDedupTests.swift` (new), `Tests/MaxMiStoreTests/MigrationTests.swift` (extend)

**Interfaces:**
- Consumes: `ContentHash.sha256Hex` (MaxMiCore, existing), `commitCapture` internals (threadID, GRDB `d`).
- Produces:
```swift
// StoreAPI internal: split content into items and return only the novel ones' info.
// Returns (hasNovel: Bool) — if false, commitCapture returns .deduplicated.
// Fails OPEN (returns true) on any DB error so capture is never lost (spec §7).
```

- [ ] **Step 1: Failing migration test** — extend `Tests/MaxMiStoreTests/MigrationTests.swift` with:

```swift
    func testV2AddsMessageFingerprintsTable() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            let n = try Int.fetchOne(d, sql:
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message_fingerprints'")
            XCTAssertEqual(n, 1, "v2 migration must create message_fingerprints")
        }
    }
```

- [ ] **Step 2: Run — FAIL** (table doesn't exist).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter testV2AddsMessageFingerprintsTable`

- [ ] **Step 3: Add v2 migration** — in `Sources/MaxMiStore/Migrations.swift`, after the `m.registerMigration("v1")` block closes (before `return m`):

```swift
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            CREATE TABLE message_fingerprints (
              fingerprint  TEXT PRIMARY KEY,
              thread_id    TEXT NOT NULL REFERENCES threads(id),
              seen_at      INTEGER NOT NULL
            );
            CREATE INDEX idx_fingerprints_thread ON message_fingerprints(thread_id);
            """)
        }
```

- [ ] **Step 4: Run — migration test PASS.**
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter testV2AddsMessageFingerprintsTable`

- [ ] **Step 5: Failing dedup tests** — `Tests/MaxMiStoreTests/FingerprintDedupTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class FingerprintDedupTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }
    let h10 = EpochMs(495_500) * 3_600_000
    var h11: EpochMs { h10 + 3_600_000 }
    func cap(_ content: String) -> CaptureInput {
        CaptureInput(sourceApp: "Slack", sourceKey: "slack:acme/general", sourceTitle: "general", content: content)
    }

    func testFirstCaptureCommitsAllItems() throws {
        guard case .committed = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10) else { return XCTFail() }
        let fp = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fingerprints") }
        XCTAssertEqual(fp, 2, "both lines fingerprinted")
    }
    func testRecaptureWithNoNewItemsDeduplicates() throws {
        _ = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10)
        // next hour, same two messages + only whitespace/order noise -> no novel items
        let r = try store.commitCapture(cap("Bob: hello\nAlice: hi"), nowMs: h11)
        XCTAssertEqual(r, .deduplicated, "reordered same messages -> no new facts")
    }
    func testRecaptureWithOneNewItemCommits() throws {
        _ = try store.commitCapture(cap("Alice: hi\nBob: hello"), nowMs: h10)
        guard case .committed = try store.commitCapture(cap("Alice: hi\nBob: hello\nCarol: new msg"), nowMs: h11)
        else { return XCTFail("a genuinely new line must commit") }
        let fp = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fingerprints") }
        XCTAssertEqual(fp, 3, "third line adds one fingerprint")
    }
}
```

- [ ] **Step 6: Run — FAIL** (fingerprints table empty; no dedup logic yet; `testRecaptureWithNoNewItemsDeduplicates` gets `.committed` not `.deduplicated`).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter FingerprintDedupTests`

- [ ] **Step 7: Implement fingerprint pass** — in `Sources/MaxMiStore/StoreAPI.swift`, add a helper and call it inside the `commitCapture` write block, AFTER the `last_tree_hash` dedup returns and thread upsert, BEFORE version upsert. Add this private helper to `Store`:

```swift
    /// Split content into items, fingerprint each (normalized), record novel ones.
    /// Returns true if ANY item was novel (=> commit). Fails OPEN (true) on error (spec §7).
    private func recordNovelFingerprints(_ content: String, threadID: String, nowMs: EpochMs,
                                         _ d: Database) -> Bool {
        // Items = non-empty lines (chat/mail/terminal); a single-line/document is one item.
        let items = content.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return true }
        var anyNovel = false
        for item in items {
            let fp = ContentHash.sha256Hex("\(threadID)\n\(item)")   // thread-scoped fingerprint
            do {
                let exists = try Int.fetchOne(d, sql:
                    "SELECT 1 FROM message_fingerprints WHERE fingerprint=? LIMIT 1", arguments: [fp]) != nil
                if !exists {
                    anyNovel = true
                    try d.execute(sql: "INSERT OR IGNORE INTO message_fingerprints (fingerprint, thread_id, seen_at) VALUES (?,?,?)",
                                  arguments: [fp, threadID, nowMs])
                }
            } catch {
                return true   // fail open: never lose a capture over a dedup error
            }
        }
        return anyNovel
    }
```

Then wire it into `commitCapture`. After the thread upsert block (after step "1. Upsert thread") and BEFORE the freeze step "2", insert:

```swift
            // Per-item fingerprint dedup: if no line is novel for this thread, skip (spec §3b).
            // Complements last_tree_hash (which catches identical whole trees) by catching
            // recaptures where only order/chrome changed but no new message appeared.
            if !recordNovelFingerprints(input.content, threadID: threadID, nowMs: nowMs, d) {
                return .deduplicated
            }
```

- [ ] **Step 8: Run — PASS** (FingerprintDedupTests + MigrationTests). Then full suite.
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`
Expected: all green. Note: existing CommitCaptureTests use unique content per call so they still commit; a test that commits the SAME content twice in different hours now dedups — if any existing test breaks on that, it's revealing the new (correct) behavior; adjust that test's content to differ.

- [ ] **Step 9: Commit**
```bash
git add Sources/MaxMiStore/Migrations.swift Sources/MaxMiStore/StoreAPI.swift Tests/MaxMiStoreTests/FingerprintDedupTests.swift Tests/MaxMiStoreTests/MigrationTests.swift
git commit -m "feat(store): message_fingerprints per-item dedup (v2 migration + commitCapture pass)"
```

---

### Task 4: Golden-fixtures regression harness

**Files:**
- Create: `Tests/MaxMiCaptureTests/KeyFixturesTests.swift`
- Create: `Tests/MaxMiCaptureTests/Fixtures/keys/README.md` (how to add a parser fixture)

**Interfaces:**
- Consumes: `ThreadKeyDeriver.derive` (Task 1). Pure data-driven test; no new production code.

**Purpose (spec §3c):** assert per-app that derived keys are (a) clean and (b) STABLE across varied captures of the same logical entity. This is the gate that makes a new parser prove cleanliness before merge.

- [ ] **Step 1: Write the fixtures test** — `Tests/MaxMiCaptureTests/KeyFixturesTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

/// Golden fixtures: real-shaped capture samples per app -> assert derived key is clean + stable.
/// Adding a parser? Add a case here proving two varied captures of the SAME entity share one clean key.
final class KeyFixturesTests: XCTestCase {
    func cap(_ app: String, _ key: String) -> ParsedCapture {
        ParsedCapture(sourceApp: app, sourceKey: key, sourceTitle: nil, content: "x")
    }
    // "clean" = lowercased scheme, no whitespace, no trailing punctuation/ellipsis, no file-ext leaf, bounded.
    func assertClean(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(key.isEmpty, "key empty", file: file, line: line)
        XCTAssertFalse(key.contains(" "), "key has whitespace: \(key)", file: file, line: line)
        XCTAssertFalse(key.contains("…"), "key has ellipsis: \(key)", file: file, line: line)
        XCTAssertNil(key.rangeOfCharacter(from: CharacterSet(charactersIn: ")]}")), "key has bracket junk: \(key)", file: file, line: line)
        XCTAssertLessThanOrEqual(key.count, 200, file: file, line: line)
    }

    // Each tuple: (app, [varied raw keys for the SAME entity]) -> must all derive equal + clean.
    func testKeysAreCleanAndStablePerApp() {
        let groups: [(String, [String])] = [
            ("Web", ["https://www.google.com/maps/@13.0,77.7,2550m/data=!3?entry=ttu",
                     "https://www.google.com/maps/@12.9,77.7,2070m/data=!3?entry=ttu"]),
            ("Web", ["https://docs.google.com/document/d/1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg/edit?tab=t.6xoj",
                     "https://docs.google.com/document/d/1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg/edit?tab=t.p2vx"]),
            ("Warp", ["terminal:warp/maxmi", "terminal:warp/maxmi.app).", "terminal:warp/maxmi  "]),
            ("Slack", ["slack:acme/general", "slack:acme/general"]),
            ("Mail", ["mail:inbox", "mail:inbox"]),
            ("Notion", ["notion:june-lp", "notion:june-lp"]),
        ]
        for (app, keys) in groups {
            let derived = keys.map { ThreadKeyDeriver.derive(cap(app, $0)) }
            for k in derived { assertClean(k) }
            XCTAssertEqual(Set(derived).count, 1, "\(app): varied captures must share ONE key, got \(Set(derived))")
        }
    }
}
```

- [ ] **Step 2: Run — verify PASS** (deriver from Task 1 should satisfy these; if a group fails, the deriver has a real gap — fix the deriver, not the test).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter KeyFixturesTests`
Expected: PASS. If `terminal:warp/maxmi.app).` and `terminal:warp/maxmi` don't unify, the file-ext coarsening in Task 1 needs the trailing-junk strip to run first — verify Task 1 order (trailing junk → then ext coarsening).

- [ ] **Step 3: Write the fixture README** — `Tests/MaxMiCaptureTests/Fixtures/keys/README.md`:

```markdown
# Key fixtures

Every parser must prove its thread keys are **clean** and **stable** before merge.

To add a parser:
1. Capture 2+ real samples of the SAME logical entity (e.g. two views of one page,
   two ticks in one terminal cwd, two pans of one map).
2. Add a `(app, [rawKey1, rawKey2, ...])` group to `KeyFixturesTests.testKeysAreCleanAndStablePerApp`.
3. The test asserts all variants derive to ONE clean key. If they don't, fix the
   parser's key HINT or add a rule to `ThreadKeyDeriver` — never loosen the assertion.

"Clean" = lowercased scheme, no whitespace/ellipsis/bracket junk, no file-extension leaf, <=200 chars.
"Stable" = volatile detail (coords, tabs, timestamps, file args) does NOT change the key.
```

- [ ] **Step 4: Commit**
```bash
git add Tests/MaxMiCaptureTests/KeyFixturesTests.swift Tests/MaxMiCaptureTests/Fixtures/keys/README.md
git commit -m "test(capture): golden key-fixtures harness (clean + stable per app)"
```

---

### Task 5: Live verification (controller/human — closes clean-capture)

**Files:** none (verification only). Do NOT run as a subagent.

- [ ] **Step 1: Rebuild + relaunch** (kill first; AX grant re-check per project memory):
```bash
cd /Users/mafex/code/personal/MaxMi
./packaging/make-app.sh
pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"; sleep 2; open MaxMi.app
```
Re-grant Accessibility if capture doesn't resume (`tccutil reset Accessibility dev.mafex.maxmi`, toggle on, relaunch).

- [ ] **Step 2: Maps no longer fractures** — pan/zoom Google Maps several times, wait ~1 min, then:
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -column "$DB" "SELECT count(*) FROM threads WHERE source_key='https://www.google.com/maps' AND updated_at/1000 > strftime('%s','now','-5 minutes');"
sqlite3 -column "$DB" "SELECT count(DISTINCT source_key) FROM threads WHERE source_key LIKE '%/maps%' AND updated_at/1000 > strftime('%s','now','-5 minutes');"
```
Expected: the second query returns 1 (all pans → one `.../maps` thread), NOT N-per-pan.

- [ ] **Step 3: Terminal keys are clean** — work in one project dir in Warp, then:
```bash
sqlite3 -column "$DB" "SELECT DISTINCT source_key FROM threads WHERE source_app='Warp' AND updated_at/1000 > strftime('%s','now','-5 minutes');"
```
Expected: keys like `terminal:warp/<projectdir>` — NO file-extension leaves, NO trailing `).`/`…`.

- [ ] **Step 4: Fingerprint dedup works** — keep Slack/Mail focused across two capture ticks WITHOUT new messages:
```bash
sqlite3 -column "$DB" "SELECT t.source_key, count(v.id) AS versions FROM threads t JOIN versions v ON v.thread_id=t.id WHERE t.source_app IN ('Slack','Mail') GROUP BY t.id;"
```
Expected: version count does NOT climb every tick when no new messages arrived (dedup holding).

- [ ] **Step 5: No new fracture overall** — after ~10 min of normal use:
```bash
sqlite3 -column "$DB" "SELECT count(*) AS new_singletons FROM (SELECT t.id FROM threads t JOIN versions v ON v.thread_id=t.id WHERE t.updated_at/1000 > strftime('%s','now','-10 minutes') GROUP BY t.id HAVING count(v.id)=1);"
```
Expected: dramatically fewer new singletons than the pre-fix rate (325 Web singletons was the old baseline).

- [ ] **Step 6: Declare clean-capture complete** when steps 2-5 hold. The separate historical-cleanup pass (re-key existing dirty threads through the deriver) is tracked as follow-up, NOT part of this.

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §1 root cause (freelanced keys) → Task 1+2 (central deriver, parsers stop keying). §2 Minimi mechanisms → §3a deriver (Task 1), §3b fingerprints (Task 3), §3c fixtures (Task 4). §3a all sub-rules (semantic per-app, universal hygiene, degenerate→app fallback, coarse>fine) → Task 1 (hygiene, appFallback, derive) + tests. §3b table + novel-only + no-novel→dedup + fail-open → Task 3 (migration + recordNovelFingerprints). §3c clean+stable fixtures + new-parser gate → Task 4. §5 architecture (deriver between shouldCommit and commitCapture; fingerprint in commit) → Task 2 + Task 3. §6 additive v2 migration, dirty/clean coexistence documented → Task 3 Step 3 + Global Constraints. §7 deriver total/never-empty, fingerprint fail-open → Task 1 (appFallback) + Task 3 (return true on catch). §8 all test classes → Tasks 1,3,4. §9 exit criteria 1-6 → Task 5 steps. §4 non-goals honored (no schema redesign, no historical rewrite → Task 5 Step 6, no encryption/MCP/cadence change).

**Placeholder scan:** none. Every code step shows complete code; the one heuristic (item-splitting = non-empty lines) is spelled out in `recordNovelFingerprints`.

**Type consistency:** `ThreadKeyDeriver.derive(_ capture: ParsedCapture) -> String` and `hygiene(_:appFallback:isURL:)` used identically in Tasks 1, 2, 4. `ParsedCapture` fields (sourceApp/sourceKey/sourceTitle/content) match SourceParser.swift. `recordNovelFingerprints(_:threadID:nowMs:_:) -> Bool` returns Bool consumed by `if !... { return .deduplicated }` in Task 3. `CommitResult.deduplicated`/`.committed` match StoreAPI.swift. `ContentHash.sha256Hex` (MaxMiCore) exists. Migration id `v2` follows the `m.registerMigration("v1")` pattern. `MaxMiDatabase.inMemory()` + `AESGCMFieldCipher.testCipher` match existing CommitCaptureTests.
