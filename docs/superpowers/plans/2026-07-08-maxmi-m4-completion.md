# MaxMi M4 Completion Implementation Plan — Slack Refinement + Document Parsers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close M4 — refine SlackParser to isolate message content from sidebar chrome, and add dedicated Notion/Obsidian/Notes document parsers over a shared `DocumentExtraction` helper, all registered in the existing framework — per `docs/superpowers/specs/2026-07-08-maxmi-m4-completion-design.md`.

**Architecture:** Separate per-app `SourceParser` structs (Minimi-style), registered by bundle id in `ParserRegistry`. The three document parsers share one internal `DocumentExtraction.bodyText(in:)` helper for the mechanical visual-order text walk; each owns only its bundle id, `sourceApp` name, and `sourceKey` derivation (verified live to differ). SlackParser gains a message-area locator that excludes the sidebar. Nothing below `commitCapture` changes; `CaptureDispatch`, pause gates, encryption, MCP all inherited unchanged.

**Tech Stack:** Swift 6, MaxMiCapture (SourceParser/ParsedCapture/AppInfo/AXNode from M4), fixture-driven tests (recorded/synthetic AXNode trees).

## Global Constraints

- Build/test with `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"`; zero new warnings in our targets.
- Content cap 8000 chars, newest-anchored, hard-bounded (same as SlackParser) — lives in `DocumentExtraction`.
- `sourceKey` REQUIRED non-empty; empty body → parse returns nil (no empty threads). Keys: Notion `notion:<page-title-slug>`, Obsidian `obsidian:<vault-slug>/<note-slug>` from title `<note> - <vault> - Obsidian <ver>`, Notes `notes:<note-title-slug>`. slug = lowercased, trimmed, spaces→`-`.
- Bundle ids: Notion `notion.id`, Obsidian `md.obsidian`, Notes `com.apple.Notes`.
- Slack: exclude sidebar/nav (narrow left column, x < 240 band) from message collection; everything else about SlackParser unchanged (slack: key, sender-attributed lines, 8000 cap, empty→nil).
- No-silent-fallback holds for all registered parsers (a doc parser nil/throw → skip, never generic) — already enforced by `CaptureDispatch`, unchanged.
- No Mail parser (rides generic fallback). No config-driven mega-parser — separate structs sharing only the mechanical helper.
- Commit messages conventional, NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `m4-completion` off main.

## File Structure

```
Sources/MaxMiCapture/DocumentExtraction.swift  NEW: internal bodyText(in:) helper (visual-order text + cap)
Sources/MaxMiCapture/NotionParser.swift        NEW: notion:<page> key + DocumentExtraction
Sources/MaxMiCapture/ObsidianParser.swift       NEW: obsidian:<vault>/<note> key + DocumentExtraction
Sources/MaxMiCapture/NotesParser.swift           NEW: notes:<note> key + DocumentExtraction
Sources/MaxMiCapture/ParserRegistry.swift        MODIFY: register the 3 new parsers
Sources/MaxMiCapture/SlackParser.swift           MODIFY: exclude sidebar from message collection
Tests/MaxMiCaptureTests/DocumentExtractionTests.swift  NEW
Tests/MaxMiCaptureTests/DocumentParsersTests.swift     NEW (Notion/Obsidian/Notes)
Tests/MaxMiCaptureTests/ParserRegistryTests.swift      MODIFY: 3 new registrations
Tests/MaxMiCaptureTests/SlackParserTests.swift         MODIFY: sidebar-exclusion test
```

Task order: 1 DocumentExtraction + 3 doc parsers + registry → 2 Slack sidebar isolation → 3 live verification (controller/human).

---

### Task 1: DocumentExtraction helper + Notion/Obsidian/Notes parsers + registry

**Files:**
- Create: `Sources/MaxMiCapture/DocumentExtraction.swift`, `Sources/MaxMiCapture/NotionParser.swift`, `Sources/MaxMiCapture/ObsidianParser.swift`, `Sources/MaxMiCapture/NotesParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift`
- Test: `Tests/MaxMiCaptureTests/DocumentExtractionTests.swift`, `Tests/MaxMiCaptureTests/DocumentParsersTests.swift`, `Tests/MaxMiCaptureTests/ParserRegistryTests.swift`

**Interfaces:**
- Consumes: `SourceParser`, `ParsedCapture`, `AppInfo`, `AXNode` (M4).
- Produces:
```swift
enum DocumentExtraction {   // internal to MaxMiCapture
    static let contentCap = 8000
    // visual-order (y then x) text from AXTextArea + AXStaticText; newest-anchored hard cap; "" if none
    static func bodyText(in root: AXNode) -> String
}
public struct NotionParser: SourceParser { public init() }     // key notion:<slug(title)>
public struct ObsidianParser: SourceParser { public init() }   // key obsidian:<vault>/<note>
public struct NotesParser: SourceParser { public init() }      // key notes:<slug(title)>
// ParserRegistry.init registers all three by their bundle ids (constants below)
extension ParserRegistry {
    static let notionBundleID = "notion.id"
    static let obsidianBundleID = "md.obsidian"
    static let notesBundleID = "com.apple.Notes"
}
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCaptureTests/DocumentExtractionTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class DocumentExtractionTests: XCTestCase {
    func n(_ role: String, _ value: String? = nil, _ x: CGFloat = 0, _ y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func testCollectsTextAreaAndStaticTextInVisualOrder() {
        let root = n("AXGroup", nil, 0, 0, [
            n("AXStaticText", "second", 0, 100),
            n("AXTextArea", "first", 0, 10),
            n("AXStaticText", "third", 0, 200),
        ])
        XCTAssertEqual(DocumentExtraction.bodyText(in: root), "first\nsecond\nthird")
    }
    func testEmptyWhenNoText() {
        XCTAssertEqual(DocumentExtraction.bodyText(in: n("AXGroup", nil, 0, 0, [n("AXButton")])), "")
    }
    func testHardCapNewestAnchored() {
        // 400 lines of ~50 chars each, oldest y=0..newest y=399
        var kids: [AXNode] = []
        for i in 0..<400 { kids.append(n("AXStaticText", "line \(i) " + String(repeating: "x", count: 40), 0, CGFloat(i))) }
        let out = DocumentExtraction.bodyText(in: n("AXGroup", nil, 0, 0, kids))
        XCTAssertLessThanOrEqual(out.count, 8000)
        XCTAssertTrue(out.contains("line 399"), "newest kept")
        XCTAssertFalse(out.contains("line 0 "), "oldest dropped")
    }
}
```

`Tests/MaxMiCaptureTests/DocumentParsersTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class DocumentParsersTests: XCTestCase {
    func n(_ role: String, _ value: String? = nil, _ y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func win(_ body: [AXNode]) -> AXNode { n("AXWindow", nil, 0, body) }

    func testNotionKeyFromTitleAndBody() throws {
        let app = AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "June LP")
        let cap = try XCTUnwrap(try NotionParser().parse(window: win([n("AXTextArea", "Anime list", 10)]), app: app))
        XCTAssertEqual(cap.sourceApp, "Notion")
        XCTAssertEqual(cap.sourceKey, "notion:june-lp")
        XCTAssertTrue(cap.content.contains("Anime list"))
    }
    func testObsidianKeyFromTitleParts() throws {
        let app = AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Welcome - My Vault - Obsidian 1.12.7")
        let cap = try XCTUnwrap(try ObsidianParser().parse(window: win([n("AXStaticText", "note body", 10)]), app: app))
        XCTAssertEqual(cap.sourceApp, "Obsidian")
        XCTAssertEqual(cap.sourceKey, "obsidian:my-vault/welcome")
    }
    func testObsidianUnexpectedTitleFallsBack() throws {
        let app = AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Obsidian")
        let cap = try XCTUnwrap(try ObsidianParser().parse(window: win([n("AXStaticText", "x", 10)]), app: app))
        XCTAssertEqual(cap.sourceKey, "obsidian:obsidian")
    }
    func testNotesKeyFromTitle() throws {
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries")
        let cap = try XCTUnwrap(try NotesParser().parse(window: win([n("AXStaticText", "milk eggs", 10)]), app: app))
        XCTAssertEqual(cap.sourceApp, "Notes")
        XCTAssertEqual(cap.sourceKey, "notes:groceries")
    }
    func testEmptyBodyReturnsNil() throws {
        let app = AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "Empty")
        XCTAssertNil(try NotionParser().parse(window: win([n("AXButton")]), app: app))
    }
    func testNilTitleStillKeys() throws {
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: nil)
        let cap = try XCTUnwrap(try NotesParser().parse(window: win([n("AXStaticText", "x", 10)]), app: app))
        XCTAssertTrue(cap.sourceKey.hasPrefix("notes:"))
    }
}
```

Extend `Tests/MaxMiCaptureTests/ParserRegistryTests.swift` with:

```swift
    func testDocumentParsersRegistered() {
        let r = ParserRegistry()
        XCTAssertTrue(r.parser(for: "notion.id") is NotionParser)
        XCTAssertTrue(r.parser(for: "md.obsidian") is ObsidianParser)
        XCTAssertTrue(r.parser(for: "com.apple.Notes") is NotesParser)
    }
```

- [ ] **Step 2: Run — FAIL** (`DocumentExtraction`/`NotionParser`/etc. undefined).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter DocumentExtractionTests`

- [ ] **Step 3: Implement helper** — `Sources/MaxMiCapture/DocumentExtraction.swift`:

```swift
import Foundation

/// Shared mechanical text walk for document-shape apps (Notion/Obsidian/Notes).
/// Per-app parsers own key derivation; only the body-text collection lives here.
enum DocumentExtraction {
    static let contentCap = 8000

    /// AXTextArea + AXStaticText values in visual order (y then x), newest-anchored
    /// hard cap. Returns "" if there is no text (caller returns nil → no empty thread).
    static func bodyText(in root: AXNode) -> String {
        var texts: [(y: CGFloat, x: CGFloat, s: String)] = []
        collect(root, into: &texts)
        guard !texts.isEmpty else { return "" }
        let ordered = texts.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }.map(\.s)
        // newest-anchored: keep whole trailing lines within the cap, then hard-bound.
        var kept: [String] = []
        var total = 0
        for line in ordered.reversed() {
            let add = line.count + 1
            if total + add > contentCap && !kept.isEmpty { break }
            kept.insert(line, at: 0)
            total += add
        }
        return String(kept.joined(separator: "\n").suffix(contentCap))
    }

    private static func collect(_ node: AXNode, into out: inout [(y: CGFloat, x: CGFloat, s: String)]) {
        if node.role == "AXTextArea" || node.role == "AXStaticText",
           let v = node.value, !v.isEmpty {
            out.append((node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0, v))
        }
        for c in node.children { collect(c, into: &out) }
    }
}

/// slug: lowercased, trimmed, spaces→"-". Shared by the document parsers' keys.
func docSlug(_ s: String) -> String {
    s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
}
```

`Sources/MaxMiCapture/NotionParser.swift`:

```swift
import Foundation

/// Native Notion app. Window title is the page name; body is AXTextArea/AXStaticText.
public struct NotionParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle, content: body)
    }
}
```

`Sources/MaxMiCapture/ObsidianParser.swift`:

```swift
import Foundation

/// Native Obsidian app. Title "<note> - <vault> - Obsidian <ver>" -> obsidian:<vault>/<note>.
public struct ObsidianParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle, content: body)
    }
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "obsidian:unknown" }
        let parts = title.components(separatedBy: " - ")
        // "<note> - <vault> - Obsidian <version>": note=parts[0], vault=parts[1]
        if parts.count >= 3, parts.last?.hasPrefix("Obsidian") == true {
            return "obsidian:\(docSlug(parts[1]))/\(docSlug(parts[0]))"
        }
        return "obsidian:\(docSlug(title))"
    }
}
```

`Sources/MaxMiCapture/NotesParser.swift`:

```swift
import Foundation

/// Apple Notes. Window title is the note title.
public struct NotesParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let body = DocumentExtraction.bodyText(in: window)
        guard !body.isEmpty else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle, content: body)
    }
}
```

Register in `Sources/MaxMiCapture/ParserRegistry.swift` — replace the `init`:

```swift
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    public static let notionBundleID = "notion.id"
    public static let obsidianBundleID = "md.obsidian"
    public static let notesBundleID = "com.apple.Notes"
    private let parsers: [String: any SourceParser]

    public init() {
        parsers = [
            Self.slackBundleID: SlackParser(),
            Self.notionBundleID: NotionParser(),
            Self.obsidianBundleID: ObsidianParser(),
            Self.notesBundleID: NotesParser(),
        ]
    }
```

- [ ] **Step 4: Run — PASS** (DocumentExtraction 3 + DocumentParsers 6 + registry 1 new). Full suite green (147 existing → ~157).
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiCapture/DocumentExtraction.swift Sources/MaxMiCapture/NotionParser.swift Sources/MaxMiCapture/ObsidianParser.swift Sources/MaxMiCapture/NotesParser.swift Sources/MaxMiCapture/ParserRegistry.swift Tests/MaxMiCaptureTests/DocumentExtractionTests.swift Tests/MaxMiCaptureTests/DocumentParsersTests.swift Tests/MaxMiCaptureTests/ParserRegistryTests.swift
git commit -m "feat(capture): Notion/Obsidian/Notes document parsers over shared DocumentExtraction"
```

---

### Task 2: Slack sidebar isolation (Tier 1 refinement)

**Files:**
- Modify: `Sources/MaxMiCapture/SlackParser.swift`
- Test: `Tests/MaxMiCaptureTests/SlackParserTests.swift` (extend), `Tests/MaxMiCaptureTests/Fixtures/slack-window.json` (add a sidebar subtree)

**Interfaces:**
- Consumes: `AXNode`, `AppInfo`, `ParsedCapture` (unchanged). No new public API — `key(fromTitle:)` and the cap stay exactly as-is; only `collectRows` gains a sidebar filter.

**Design (spec §4):** the sidebar is a narrow left column (x≈0, ~220pt wide) of channel-name `AXStaticText`. Exclude `AXRow`s whose x-origin is in the sidebar band (`x < 240`) from message collection. This is a best-effort heuristic (spec §5) — a message row always sits in the main content area (x ≥ 240 given the ~220pt sidebar); sidebar entries, even if exposed as rows, are filtered.

- [ ] **Step 1: Extend the fixture** — add a sidebar subtree to `Tests/MaxMiCaptureTests/Fixtures/slack-window.json` so a test can prove exclusion. The existing fixture has a `sidebar` AXGroup with plain AXStaticText; add an `AXRow` INSIDE the sidebar at x<240 containing a channel name, alongside the existing message-area rows at x≥240. Concretely, inside the existing `"title": "sidebar"` group's children, add:

```json
       {"role": "AXRow", "value": null, "title": null, "url": null, "frame": {"x":10,"y":90,"width":200,"height":24}, "focused": false, "children": [
         {"role": "AXStaticText", "value": "random-channel", "title": null, "url": null, "frame": {"x":10,"y":90,"width":180,"height":16}, "focused": false, "children": []}
       ]}
```
(Message-area rows in the fixture are at x=240; this sidebar row is at x=10 < 240.)

- [ ] **Step 2: Failing test** — add to `Tests/MaxMiCaptureTests/SlackParserTests.swift`:

```swift
    func testSidebarRowsExcludedFromContent() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("general - Acme - Slack")))
        // message-area rows (x>=240) present
        XCTAssertTrue(cap.content.contains("Alice: shipped the build"))
        XCTAssertTrue(cap.content.contains("Bob: deploy looks green"))
        // sidebar row (x<240) excluded
        XCTAssertFalse(cap.content.contains("random-channel"), "sidebar chrome must not appear in message content")
    }
```

- [ ] **Step 3: Run — FAIL** (current parser collects all AXRows regardless of x; "random-channel" leaks in).

- [ ] **Step 4: Implement** — in `Sources/MaxMiCapture/SlackParser.swift`, add a sidebar-band constant and filter rows by their x-origin in `collectRows`:

```swift
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    static let sidebarMaxX: CGFloat = 240   // rows left of this are sidebar/nav chrome, not messages
    public init() {}
```

Change `collectRows` to skip rows in the sidebar band:

```swift
    private func collectRows(_ node: AXNode, into out: inout [(y: CGFloat, texts: [String])]) {
        if node.role == "AXRow" {
            // Sidebar/nav rows sit in the narrow left column (x < sidebarMaxX); messages are
            // in the main content area to their right. Exclude sidebar chrome (spec §4).
            let x = node.frame?.origin.x ?? .greatestFiniteMagnitude
            if x < Self.sidebarMaxX { return }
            var texts: [(CGFloat, CGFloat, String)] = []
            collectStaticText(node, into: &texts)
            let ordered = texts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
            out.append((node.frame?.origin.y ?? 0, ordered))
            return
        }
        for c in node.children { collectRows(c, into: &out) }
    }
```
Note: a row with no frame defaults to `.greatestFiniteMagnitude` → NOT excluded (frameless rows are kept, conservative — better to over-capture than silently drop a real message; matches spec §5 "include if unsure"). The existing sender-attribution and cap logic are untouched.

- [ ] **Step 5: Run — PASS** (new sidebar test + all existing SlackParserTests still green — the fixture's message rows at x=240 are ≥ sidebarMaxX so they're kept; earlier tests unaffected). Full suite green.
- [ ] **Step 6: Commit**
```bash
git add Sources/MaxMiCapture/SlackParser.swift Tests/MaxMiCaptureTests/SlackParserTests.swift Tests/MaxMiCaptureTests/Fixtures/slack-window.json
git commit -m "fix(capture): exclude Slack sidebar chrome from message content"
```

---

### Task 3: Live verification (controller/human — closes M4)

**Files:** none (verification only). Do NOT run this as a subagent — it's the controller/human step.

- [ ] **Step 1: Rebuild + relaunch** (kill the running process first so the new build actually takes over — a prior session hit this):
```bash
cd /Users/mafex/code/personal/MaxMi
./packaging/make-app.sh
pkill -f "MaxMi.app/Contents/MacOS/MaxMi"; sleep 1; open MaxMi.app
```
(Signing identity persists from M3; Accessibility grant should survive. Re-grant only if macOS prompts.)

- [ ] **Step 2: Register the new apps' bundle ids are dispatched.** No config change needed — they were already in `KnownApps` (generic fallback) and are now in `ParserRegistry`, so dispatch upgrades automatically.

- [ ] **Step 3: Drive each app** (focus, view content, leave ~30s for capture + idle extraction):
  1. **Slack** — open a channel with real messages.
  2. **Notion** — open a page.
  3. **Obsidian** — open a note.
  4. **Notes** — open a note.

- [ ] **Step 4: Verify dedicated threads (not generic fallback keys):**
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -header -column "$DB" "SELECT source_app, substr(source_key,1,50) AS key FROM threads WHERE source_app IN ('Notion','Obsidian','Notes','Slack') ORDER BY updated_at DESC LIMIT 10;"
```
Expected: keys like `notion:<page>`, `obsidian:<vault>/<note>`, `notes:<note>`, `slack:<ws>/<view>` — NOT `notion.id:...` / `com.apple.Notes:...` generic fallback keys (spec §9 criterion 2).

- [ ] **Step 5: Verify Slack facts are message-level, not sidebar chrome** — after Slack extraction completes (~5 min idle or sweeper):
```bash
sqlite3 "$DB" "SELECT extract_status FROM versions v JOIN threads t ON t.id=v.thread_id WHERE t.source_app='Slack';"
```
Then MCP search and read the facts:
```bash
printf '%s\n%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"what was discussed in slack"}}}' \
 | ./MaxMi.app/Contents/MacOS/maxmi-mcp
```
Expected: facts reference message content/topics, not "channels include design-jam…" chrome (spec §9 criterion 1).

- [ ] **Step 6: Verify document content searchable + encrypted:**
```bash
# content ciphertext at rest for the doc apps
sqlite3 "$DB" "SELECT substr(content,1,10) FROM versions v JOIN threads t ON t.id=v.thread_id WHERE t.source_app IN ('Notion','Obsidian','Notes') LIMIT 3;"  # expect enc:v1:
# MCP search for a doc topic returns decrypted facts (run after extraction)
```
Then a search for something you know is in a Notion/Obsidian/Notes doc returns it decrypted (spec §9 criterion 3).

- [ ] **Step 7: Confirm Mail still generic fallback** — focus Mail briefly, then:
```bash
sqlite3 "$DB" "SELECT source_app, substr(source_key,1,40) FROM threads WHERE source_key LIKE 'com.apple.mail%' OR source_app='Mail';"
```
Expected: a generic-fallback thread keyed `com.apple.mail:<title>` (NOT a `mail:` dedicated key) — proves Mail deferral (spec §9 criterion 4).

- [ ] **Step 8: Declare M4 complete** when criteria 1-5 hold live. Merge `m4-completion` to main, push.

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §1 Slack refinement → Task 2; §1 three doc parsers over shared helper → Task 1. §3 live-probe findings inform the parsers (Notion bare-title key, Obsidian `view-vault-version` parse, Notes note-title, all AXTextArea+AXStaticText body; Slack sidebar as narrow left column) → Tasks 1-2. §4 Slack message isolation (x<240 band, best-effort, everything-else-unchanged) → Task 2. §5 document parsers (separate structs, shared DocumentExtraction, per-app key derivation, bundle ids, empty→nil, best-effort keys) → Task 1. §6 registry adds 3 entries, CaptureDispatch/KnownApps unchanged → Task 1 (registry) + Task 3 Step 2 (no gate change). §7 no-silent-fallback/encryption/pause inherited unchanged → confirmed (CaptureDispatch untouched). §8 tests (SlackParser sidebar, DocumentExtraction, three parser tests, registry) → Tasks 1-2. §9 exit criteria 1-7 → Task 3 Steps 4-8. §2 non-goals honored (no Mail parser — Task 3 Step 7 confirms it stays generic; no config mega-parser — separate structs; no new milestone machinery).

**Placeholder scan:** none. Every code step has complete code; the fixture addition shows the exact JSON node.

**Type consistency:** `DocumentExtraction.bodyText(in:)` + `docSlug` (Task 1) used by all three doc parsers (Task 1). Parser structs conform to `SourceParser.parse(window:app:) throws -> ParsedCapture?` (M4) — same signature the tests call. `ParserRegistry.init` registers by the bundle-id constants defined in the same task. SlackParser's `collectRows` change (Task 2) preserves its existing `key(fromTitle:)`/cap/sender logic — verified against the current file. `sidebarMaxX` (240) matches the fixture's message rows at x=240 (≥, kept) and the new sidebar row at x=10 (<, excluded).
