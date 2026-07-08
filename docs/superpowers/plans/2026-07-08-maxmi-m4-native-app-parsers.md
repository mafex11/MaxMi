# MaxMi Milestone 4: Native-App Parser Framework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend capture beyond browser tabs to native macOS apps via an app-agnostic parser framework — a generic AX fallback for every app plus one dedicated Slack parser — per the spec at `docs/superpowers/specs/2026-07-08-maxmi-m4-native-app-parsers-design.md`.

**Architecture:** A parser layer in `MaxMiCapture` between the existing `AXReader` (builds the `AXNode` tree) and `Store.commitCapture`. A `ParserRegistry` maps bundle id → `SourceParser`; matched apps (Slack) get structured extraction, everything else gets `GenericAXParser`. `FocusObserver`'s gate widens from browser-only to any capturable app; `AppWiring` dispatches through the registry with per-app/per-thread pause. Nothing below `commitCapture` changes.

**Tech Stack:** Swift 6, existing MaxMiCapture/MaxMiStore/MaxMiCore, AppKit/ApplicationServices AX APIs, fixture-driven tests (recorded `AXNode` JSON trees).

## Global Constraints

- Build/test with `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"`; zero new warnings in our targets.
- `sourceKey` REQUIRED non-empty and stable across re-captures; empty-key or nil parse result → skip (no thread). Empty content → skip (no empty threads).
- No-silent-fallback: a registered parser returning nil/throwing → log + SKIP; NEVER run GenericAXParser for a registered app.
- AXReader window locator order: `AXFocusedWindow` → `AXMainWindow` → `AXWindows.first` (Slack/WhatsApp leave AXWindows empty).
- Slack key: `slack:<workspace>/<view>` from window title `<view> - <workspace> - Slack`, lowercased, spaces→`-`; fallback `slack:<full-title>`. source_app `"Slack"`.
- Generic key: `<bundleID>:<windowTitle>`; source_app = app localized name.
- Denylist must still block `chrome://`/`about:`/etc. but NOT native `slack:`/`whatsapp:`/`<bundleid>:` keys.
- Per-app pause (`settings['paused_apps']` JSON array of bundle ids) + per-thread pause (`settings['paused_threads']` JSON array of source_keys); default capture-on.
- Slack content cap ~8000 chars, newest-anchored.
- No native helpers, no WhatsApp dedicated parser, no document parsers, no changes below Store boundary.
- Commit messages conventional, NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `m4-native-parsers` off main.

## File Structure

```
Sources/MaxMiCapture/SourceParser.swift    protocol SourceParser + ParsedCapture + AppInfo
Sources/MaxMiCapture/GenericAXParser.swift  visible-text fallback (reuses visualOrderText)
Sources/MaxMiCapture/SlackParser.swift      AXRow chat parser, slack: keys
Sources/MaxMiCapture/ParserRegistry.swift   bundle-id -> SourceParser
Sources/MaxMiCapture/BrowserTabExtractor.swift  MODIFY: expose visualOrderText for reuse
Sources/MaxMiCapture/AXReader.swift         MODIFY: window locator order
Sources/MaxMiCapture/FocusObserver.swift    MODIFY: gate widens; onCapture passes AppInfo not Browser
Sources/MaxMiCapture/Denylist.swift         MODIFY: allow native scheme keys
Sources/MaxMiStore/PauseSettings.swift      pausedApps/pausedThreads get/set on Store
Sources/MaxMi/AppWiring.swift               MODIFY: registry dispatch, pause checks, source_app
Sources/MaxMi/MenuBarController.swift        MODIFY: per-app pause submenu + pause-current-thread
Tests/MaxMiCaptureTests/                     SlackParserTests, GenericAXParserTests, ParserRegistryTests,
                                             + AXReader/Denylist/no-silent-fallback fixtures
Tests/MaxMiStoreTests/PauseSettingsTests.swift
```

Task order: 1 parser contract + generic fallback → 2 Slack parser → 3 registry + Denylist native-key fix → 4 pause settings (Store) → 5 FocusObserver gate widening → 6 AppWiring dispatch + menu + live verify.

---

### Task 1: SourceParser contract + GenericAXParser

**Files:**
- Create: `Sources/MaxMiCapture/SourceParser.swift`, `Sources/MaxMiCapture/GenericAXParser.swift`
- Modify: `Sources/MaxMiCapture/BrowserTabExtractor.swift` (make `visualOrderText` accessible to the new parser — change `static func visualOrderText` from default-internal to keep internal but ensure same-module reuse; it already is `static func` internal, so GenericAXParser in the same target can call it directly — no change needed unless the compiler disagrees, in which case widen to `static func` without `private`).
- Test: `Tests/MaxMiCaptureTests/GenericAXParserTests.swift`

**Interfaces:**
- Consumes: `AXNode` (M1, MaxMiCapture), `BrowserTabExtractor.visualOrderText(in:excludingToolbars:)`.
- Produces (later tasks rely on these EXACT signatures):
```swift
public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowTitle: String?
    public init(bundleID: String, name: String, windowTitle: String?)
}
public struct ParsedCapture: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String)
}
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
}
public struct GenericAXParser: SourceParser {
    public init()
    // visual-order text; key "<bundleID>:<windowTitle-or-'window'>"; nil if content empty
}
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCaptureTests/GenericAXParserTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class GenericAXParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, frame: CGRect? = nil, _ children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false, children: children)
    }
    func app(_ title: String? = "My Note") -> AppInfo {
        AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: title)
    }

    func testCollectsVisualOrderTextWithBundleTitleKey() throws {
        let win = node("AXWindow", children: [
            node("AXStaticText", value: "Second line", frame: CGRect(x: 0, y: 100, width: 10, height: 10)),
            node("AXStaticText", value: "First line", frame: CGRect(x: 0, y: 10, width: 10, height: 10)),
        ])
        let cap = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app()))
        XCTAssertEqual(cap.sourceApp, "Notes")
        XCTAssertEqual(cap.sourceKey, "com.apple.Notes:My Note")
        XCTAssertEqual(cap.content, "First line\nSecond line")
        XCTAssertEqual(cap.sourceTitle, "My Note")
    }
    func testNilWindowTitleFallsBackToWindowLiteral() throws {
        let win = node("AXWindow", children: [node("AXStaticText", value: "x", frame: CGRect(x: 0, y: 0, width: 1, height: 1))])
        let cap = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app(nil)))
        XCTAssertEqual(cap.sourceKey, "com.apple.Notes:window")
    }
    func testEmptyContentReturnsNil() throws {
        let win = node("AXWindow", children: [node("AXButton")])  // no static text
        XCTAssertNil(try GenericAXParser().parse(window: win, app: app()))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`AppInfo`/`ParsedCapture`/`GenericAXParser` undefined).
Run: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --filter GenericAXParserTests`

- [ ] **Step 3: Implement** — `Sources/MaxMiCapture/SourceParser.swift`:

```swift
import Foundation

public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowTitle: String?
    public init(bundleID: String, name: String, windowTitle: String?) {
        self.bundleID = bundleID; self.name = name; self.windowTitle = windowTitle
    }
}

public struct ParsedCapture: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
    }
}

/// Turns a window's AX tree into a capture, or nil if it can't handle it.
/// Throwing is treated identically to nil by the caller (log + skip), never a crash.
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
}
```

`Sources/MaxMiCapture/GenericAXParser.swift`:

```swift
import Foundation

/// Fallback for any capturable app without a dedicated parser: visible text in
/// visual order, keyed by bundle id + window title (coarse but guarantees coverage).
public struct GenericAXParser: SourceParser {
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // Reuse M1's proven visual-order text collection.
        let content = (try? BrowserTabExtractor.visualOrderText(in: window)) ?? ""
        guard !content.isEmpty else { return nil }   // no empty threads
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: content
        )
    }
}
```
Note: `BrowserTabExtractor.visualOrderText` throws `ExtractionError.emptyContent` on empty — the `try?`→`?? ""`→`guard !isEmpty` chain converts that to a clean nil. If `visualOrderText` is `private`, change it to internal `static func` (no access keyword) so the same-module parser can call it; do not otherwise alter it.

- [ ] **Step 4: Run — PASS** (3 tests). Full suite green (122 existing).
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiCapture/SourceParser.swift Sources/MaxMiCapture/GenericAXParser.swift Sources/MaxMiCapture/BrowserTabExtractor.swift Tests/MaxMiCaptureTests/GenericAXParserTests.swift
git commit -m "feat(capture): SourceParser contract + generic AX fallback parser"
```

---

### Task 2: SlackParser

**Files:**
- Create: `Sources/MaxMiCapture/SlackParser.swift`, `Tests/MaxMiCaptureTests/Fixtures/slack-window.json`
- Test: `Tests/MaxMiCaptureTests/SlackParserTests.swift`

**Interfaces:**
- Consumes: `SourceParser`, `ParsedCapture`, `AppInfo` (Task 1), `AXNode`.
- Produces: `public struct SlackParser: SourceParser { public init() }` — window title `<view> - <workspace> - Slack` → key `slack:<workspace>/<view>`; sender-attributed message lines from `AXRow`s in visual order; content cap 8000 chars newest-anchored.

- [ ] **Step 1: Write the fixture** — `Tests/MaxMiCaptureTests/Fixtures/slack-window.json` (shape from the live probe: rows of static text, sidebar chrome + message area):

```json
{
  "role": "AXWindow", "value": null, "title": "general - Acme - Slack", "url": null,
  "frame": {"x":0,"y":0,"width":1200,"height":800}, "focused": false,
  "children": [
    {"role": "AXGroup", "value": null, "title": "sidebar", "url": null,
     "frame": {"x":0,"y":0,"width":220,"height":800}, "focused": false, "children": [
       {"role": "AXStaticText", "value": "Home", "title": null, "url": null, "frame": {"x":10,"y":20,"width":100,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "general", "title": null, "url": null, "frame": {"x":10,"y":60,"width":100,"height":16}, "focused": false, "children": []}
     ]},
    {"role": "AXGroup", "value": null, "title": "messages", "url": null,
     "frame": {"x":220,"y":0,"width":980,"height":800}, "focused": false, "children": [
       {"role": "AXRow", "value": null, "title": null, "url": null, "frame": {"x":240,"y":100,"width":900,"height":40}, "focused": false, "children": [
         {"role": "AXStaticText", "value": "Alice", "title": null, "url": null, "frame": {"x":240,"y":100,"width":80,"height":16}, "focused": false, "children": []},
         {"role": "AXStaticText", "value": "shipped the build", "title": null, "url": null, "frame": {"x":240,"y":118,"width":300,"height":16}, "focused": false, "children": []}
       ]},
       {"role": "AXRow", "value": null, "title": null, "url": null, "frame": {"x":240,"y":160,"width":900,"height":40}, "focused": false, "children": [
         {"role": "AXStaticText", "value": "Bob", "title": null, "url": null, "frame": {"x":240,"y":160,"width":80,"height":16}, "focused": false, "children": []},
         {"role": "AXStaticText", "value": "deploy looks green", "title": null, "url": null, "frame": {"x":240,"y":178,"width":300,"height":16}, "focused": false, "children": []}
       ]}
     ]}
  ]
}
```

- [ ] **Step 2: Failing tests** — `Tests/MaxMiCaptureTests/SlackParserTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class SlackParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
    func app(_ title: String?) -> AppInfo {
        AppInfo(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", windowTitle: title)
    }

    func testKeyFromTitleAndSenderAttributedMessages() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("general - Acme - Slack")))
        XCTAssertEqual(cap.sourceApp, "Slack")
        XCTAssertEqual(cap.sourceKey, "slack:acme/general")
        XCTAssertTrue(cap.content.contains("Alice: shipped the build"))
        XCTAssertTrue(cap.content.contains("Bob: deploy looks green"))
        // message ordering top->bottom
        XCTAssertLessThan(cap.content.range(of: "Alice")!.lowerBound, cap.content.range(of: "Bob")!.lowerBound)
    }
    func testUnexpectedTitleFallsBackToFullTitleKey() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app("Huddle")))
        XCTAssertEqual(cap.sourceKey, "slack:huddle")
    }
    func testNilTitleStillParses() throws {
        let win = try fixture("slack-window")
        let cap = try XCTUnwrap(try SlackParser().parse(window: win, app: app(nil)))
        XCTAssertTrue(cap.sourceKey.hasPrefix("slack:"))
    }
    func testEmptyMessageAreaReturnsNil() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil, focused: false, children: [])
        XCTAssertNil(try SlackParser().parse(window: bare, app: app("x - y - Slack")))
    }
}
```

- [ ] **Step 3: Run — FAIL.**

- [ ] **Step 4: Implement** — `Sources/MaxMiCapture/SlackParser.swift`:

```swift
import Foundation

/// Dedicated parser for the native Slack app. Window reached by the caller via
/// AXReader's locator (Slack leaves AXWindows empty). Content = AXRow messages
/// in visual order, sender-attributed; key from the window title.
public struct SlackParser: SourceParser {
    static let contentCap = 8000
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let lines = messageLines(in: window)
        guard !lines.isEmpty else { return nil }
        var content = lines.joined(separator: "\n")
        if content.count > Self.contentCap {                       // newest-anchored: keep the tail
            content = String(content.suffix(Self.contentCap))
        }
        return ParsedCapture(
            sourceApp: "Slack",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: content
        )
    }

    /// "<view> - <workspace> - Slack" -> "slack:<workspace>/<view>"; else "slack:<title>".
    func key(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "slack:unknown" }
        let parts = title.components(separatedBy: " - ")
        func slug(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        }
        if parts.count >= 3, parts.last == "Slack" {
            let view = slug(parts[0]); let workspace = slug(parts[parts.count - 2])
            return "slack:\(workspace)/\(view)"
        }
        return "slack:\(slug(title))"
    }

    /// Collect AXRow message text in visual order. Within a row, first static text
    /// is treated as sender, the rest as the message body.
    private func messageLines(in root: AXNode) -> [String] {
        var rows: [(y: CGFloat, texts: [String])] = []
        collectRows(root, into: &rows)
        return rows.sorted { $0.y < $1.y }.compactMap { row in
            let ts = row.texts.filter { !$0.isEmpty }
            guard !ts.isEmpty else { return nil }
            if ts.count >= 2 { return "\(ts[0]): \(ts.dropFirst().joined(separator: " "))" }
            return ts[0]
        }
    }

    private func collectRows(_ node: AXNode, into out: inout [(y: CGFloat, texts: [String])]) {
        if node.role == "AXRow" {
            var texts: [(CGFloat, CGFloat, String)] = []
            collectStaticText(node, into: &texts)
            let ordered = texts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
            out.append((node.frame?.origin.y ?? 0, ordered))
            return   // don't descend into nested rows twice
        }
        for c in node.children { collectRows(c, into: &out) }
    }

    private func collectStaticText(_ node: AXNode, into out: inout [(CGFloat, CGFloat, String)]) {
        if node.role == "AXStaticText", let v = node.value, !v.isEmpty {
            out.append((node.frame?.origin.y ?? 0, node.frame?.origin.x ?? 0, v))
        }
        for c in node.children { collectStaticText(c, into: &out) }
    }
}
```

- [ ] **Step 5: Run — PASS** (4 tests). Full suite green.
- [ ] **Step 6: Commit**
```bash
git add Sources/MaxMiCapture/SlackParser.swift Tests/MaxMiCaptureTests/SlackParserTests.swift Tests/MaxMiCaptureTests/Fixtures/slack-window.json
git commit -m "feat(capture): Slack native-app parser (AXRow messages, slack: keys)"
```

---

### Task 3: ParserRegistry + Denylist native-key fix + AXReader locator

**Files:**
- Create: `Sources/MaxMiCapture/ParserRegistry.swift`, `Tests/MaxMiCaptureTests/ParserRegistryTests.swift`
- Modify: `Sources/MaxMiCapture/Denylist.swift` (allow native scheme keys), `Sources/MaxMiCapture/AXReader.swift` (locator order)
- Test: extend `Tests/MaxMiCaptureTests/DenylistTests.swift`

**Interfaces:**
- Consumes: `SourceParser`, `SlackParser`, `GenericAXParser` (Tasks 1-2).
- Produces:
```swift
public struct ParserRegistry: Sendable {
    public init()                                    // registers SlackParser for Slack's bundle id
    public func parser(for bundleID: String) -> (any SourceParser)?   // nil = use generic fallback
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
}
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiCaptureTests/ParserRegistryTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class ParserRegistryTests: XCTestCase {
    func testSlackBundleReturnsSlackParser() {
        let p = ParserRegistry().parser(for: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(p is SlackParser)
    }
    func testUnregisteredBundleReturnsNil() {
        XCTAssertNil(ParserRegistry().parser(for: "com.apple.Notes"))
    }
}
```

Extend `Tests/MaxMiCaptureTests/DenylistTests.swift` with:
```swift
    func testNativeSchemeKeysAreNotBlocked() {
        // native-app source_keys must pass (they are not chrome://-style internal pages)
        XCTAssertFalse(Denylist.isBlocked("slack:acme/general"))
        XCTAssertFalse(Denylist.isBlocked("whatsapp:Mom"))
        XCTAssertFalse(Denylist.isBlocked("com.apple.Notes:Groceries"))
    }
    func testBrowserInternalSchemesStillBlocked() {
        XCTAssertTrue(Denylist.isBlocked("chrome://settings"))
        XCTAssertTrue(Denylist.isBlocked("about:blank"))
    }
```

- [ ] **Step 2: Run — FAIL** (`ParserRegistry` undefined; native-key test fails because current Denylist blocks all non-http(s) schemes).

- [ ] **Step 3: Implement registry** — `Sources/MaxMiCapture/ParserRegistry.swift`:

```swift
import Foundation

public struct ParserRegistry: Sendable {
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    private let parsers: [String: any SourceParser]

    public init() {
        parsers = [Self.slackBundleID: SlackParser()]
    }

    public func parser(for bundleID: String) -> (any SourceParser)? {
        parsers[bundleID]
    }
}
```

- [ ] **Step 4: Fix Denylist** — `Sources/MaxMiCapture/Denylist.swift`. The current `isBlocked` blocks every non-http(s) scheme (to catch `chrome://`). Native keys use custom schemes (`slack:`, `whatsapp:`) or `bundleid:title` (which URL-parses oddly). Restrict the scheme block to the known browser-internal schemes only:

Replace the scheme guard (currently something like `if let scheme = url.scheme, scheme != "http", scheme != "https" { return true }`) with:
```swift
        // Block browser-internal pages, not native-app source keys (slack:, whatsapp:, bundleid:title).
        let browserInternalSchemes: Set<String> = ["chrome", "about", "edge", "arc", "brave", "vivaldi", "file", "view-source", "devtools", "chrome-extension"]
        if let scheme = url.scheme?.lowercased(), browserInternalSchemes.contains(scheme) { return true }
```
Keep the rest of `isBlocked` (host/path denylist for banking, reset-password, etc.) unchanged. Note: `URL(string: "slack:acme/general")?.scheme == "slack"` → not in the set → not blocked. `URL(string: "com.apple.Notes:Groceries")` parses scheme as `com.apple.notes`-ish or nil depending on form — either way not in the set → not blocked. Confirm both behaviors with the new tests.

- [ ] **Step 5: Fix AXReader locator** — `Sources/MaxMiCapture/AXReader.swift`, the window lookup (currently `copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement? ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first`). Insert `AXMainWindow` between them:

```swift
        guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                ?? copyAttr(app, "AXMainWindow") as! AXUIElement?
                ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
```
(Slack/WhatsApp populate AXMainWindow while leaving AXWindows empty — verified live. Browsers keep working via AXFocusedWindow.) This is live-AX code with no unit test (same policy as M1's AXReader); the fix is exercised by the Task 6 manual verification.

- [ ] **Step 6: Run — PASS** (registry 2 + denylist 2 new). Full suite green.
- [ ] **Step 7: Commit**
```bash
git add Sources/MaxMiCapture/ParserRegistry.swift Sources/MaxMiCapture/Denylist.swift Sources/MaxMiCapture/AXReader.swift Tests/MaxMiCaptureTests/ParserRegistryTests.swift Tests/MaxMiCaptureTests/DenylistTests.swift
git commit -m "feat(capture): parser registry, native-scheme denylist fix, AXMainWindow locator"
```

---

### Task 4: Pause settings (Store)

**Files:**
- Create: `Sources/MaxMiStore/PauseSettings.swift`, `Tests/MaxMiStoreTests/PauseSettingsTests.swift`

**Interfaces:**
- Consumes: `Store`, `MaxMiDatabase` (settings table exists from M1).
- Produces (on Store):
```swift
public func pausedApps() throws -> Set<String>              // settings['paused_apps'] JSON array of bundle ids
public func pausedThreads() throws -> Set<String>           // settings['paused_threads'] JSON array of source_keys
public func setAppPaused(_ bundleID: String, paused: Bool, nowMs: EpochMs) throws
public func setThreadPaused(_ sourceKey: String, paused: Bool, nowMs: EpochMs) throws
```

- [ ] **Step 1: Failing tests** — `Tests/MaxMiStoreTests/PauseSettingsTests.swift`:

```swift
import XCTest
@testable import MaxMiStore
import MaxMiCore

final class PauseSettingsTests: XCTestCase {
    var store: Store!
    let t0 = EpochMs(495_442) * 3_600_000
    override func setUpWithError() throws {
        store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
    }
    func testDefaultsEmpty() throws {
        XCTAssertTrue(try store.pausedApps().isEmpty)
        XCTAssertTrue(try store.pausedThreads().isEmpty)
    }
    func testPauseAndUnpauseApp() throws {
        try store.setAppPaused("net.whatsapp.WhatsApp", paused: true, nowMs: t0)
        XCTAssertEqual(try store.pausedApps(), ["net.whatsapp.WhatsApp"])
        try store.setAppPaused("net.whatsapp.WhatsApp", paused: false, nowMs: t0 + 1)
        XCTAssertTrue(try store.pausedApps().isEmpty)
    }
    func testPauseThreadIsIdempotentAndAdditive() throws {
        try store.setThreadPaused("slack:acme/general", paused: true, nowMs: t0)
        try store.setThreadPaused("slack:acme/general", paused: true, nowMs: t0 + 1)  // idempotent
        try store.setThreadPaused("whatsapp:Mom", paused: true, nowMs: t0 + 2)
        XCTAssertEqual(try store.pausedThreads(), ["slack:acme/general", "whatsapp:Mom"])
    }
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** — `Sources/MaxMiStore/PauseSettings.swift`:

```swift
import Foundation
import GRDB
import MaxMiCore

extension Store {
    public func pausedApps() throws -> Set<String> { try readSet("paused_apps") }
    public func pausedThreads() throws -> Set<String> { try readSet("paused_threads") }

    public func setAppPaused(_ bundleID: String, paused: Bool, nowMs: EpochMs) throws {
        try mutateSet("paused_apps", element: bundleID, insert: paused, nowMs: nowMs)
    }
    public func setThreadPaused(_ sourceKey: String, paused: Bool, nowMs: EpochMs) throws {
        try mutateSet("paused_threads", element: sourceKey, insert: paused, nowMs: nowMs)
    }

    private func readSet(_ key: String) throws -> Set<String> {
        try db.dbQueue.read { d in
            guard let json = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?", arguments: [key]),
                  let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
            return Set(arr)
        }
    }

    private func mutateSet(_ key: String, element: String, insert: Bool, nowMs: EpochMs) throws {
        try db.dbQueue.write { d in
            var set: Set<String> = []
            if let json = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?", arguments: [key]),
               let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                set = Set(arr)
            }
            if insert { set.insert(element) } else { set.remove(element) }
            let json = String(decoding: try JSONEncoder().encode(set.sorted()), as: UTF8.self)
            try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)", arguments: [key, json, nowMs])
        }
    }
}
```
(Settings values are metadata, NOT encrypted — bundle ids and source keys are cleartext like all other metadata per M3 §2. That's correct: no `cipher` involvement here.)

- [ ] **Step 4: Run — PASS** (3 tests). Full suite green.
- [ ] **Step 5: Commit**
```bash
git add Sources/MaxMiStore/PauseSettings.swift Tests/MaxMiStoreTests/PauseSettingsTests.swift
git commit -m "feat(store): per-app and per-thread capture pause settings"
```

---

### Task 5: FocusObserver gate widening (browser → any capturable app)

**Files:**
- Modify: `Sources/MaxMiCapture/FocusObserver.swift`
- Test: none automated (live AX / NSWorkspace observer, same policy as M1). Build-only + Task 6 manual verify.

**Interfaces:**
- Consumes: `ParserRegistry` (Task 3).
- Produces: FocusObserver's `onCapture` closure now passes `AppInfo` instead of `Browser`. New signature:
```swift
public init(debounceMs: Int = 1000, recaptureIntervalSec: Double = 45,
            isCapturable: @escaping @Sendable (String) -> Bool,   // bundle id -> capture?
            onCapture: @escaping @MainActor (AppInfo, pid_t) -> Void)
```
`current` becomes `(bundleID: String, pid: pid_t)`. `isChromium`-style retry stays the caller's concern (AppWiring), so FocusObserver no longer needs the `Browser` enum — but KEEP the `Browser` enum in the file (AppWiring still uses its bundle-id list + `isChromium`); FocusObserver just stops gating on it directly.

- [ ] **Step 1: Rewrite the gate.** In `frontmostChanged`, replace the `Browser(rawValue:)` guard with the injected `isCapturable` check, and build an `AppInfo`:

```swift
    func frontmostChanged(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier, isCapturable(bid) else {
            detachAXObserver()
            recaptureTimer?.invalidate(); recaptureTimer = nil
            current = nil; return
        }
        let newPid = app.processIdentifier
        if let cur = current, cur.bundleID == bid, cur.pid == newPid {
            scheduleCapture(); return   // same app/pid -> no observer churn
        }
        detachAXObserver()
        current = (bundleID: bid, pid: newPid)
        appName = app.localizedName ?? bid       // stored for AppInfo
        attachAXObserver(pid: newPid)
        recaptureTimer?.invalidate()
        recaptureTimer = Timer.scheduledTimer(withTimeInterval: recaptureIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleCapture() }
        }
        scheduleCapture()
    }
```
And in the debounced fire (where it currently calls `onCapture(cur.browser, cur.pid)`), read the frontmost window title fresh and pass AppInfo:
```swift
        guard let cur = current else { return }
        let title = /* current window title if cheaply available, else nil — AppWiring re-reads via AXReader anyway */ nil
        onCapture(AppInfo(bundleID: cur.bundleID, name: appName, windowTitle: title), cur.pid)
```
Add stored props: `let isCapturable: @Sendable (String) -> Bool`, `var appName: String = ""`, and change `current` to `(bundleID: String, pid: pid_t)?`. Update `init` to the new signature. Note: `windowTitle` is passed nil here because AppWiring re-reads the window via AXReader (which yields the authoritative title); the parser gets the title from AppInfo, so AppWiring must populate AppInfo.windowTitle from the AXReader snapshot's title before calling the parser (see Task 6). Keep the `Browser` enum + `isChromium` in the file for AppWiring's use.

- [ ] **Step 2: Build check** — `DEVELOPER_DIR=... swift build`. FocusObserver compiles; AppWiring will not (its `onCapture` closure signature changed) — that's expected and fixed in Task 6. To keep the branch building between tasks, this task's commit ALSO includes the minimal AppWiring signature adaptation to make it compile, even though full dispatch logic lands in Task 6. Concretely: change AppWiring's FocusObserver construction to the new closure shape and have it call a temporary `captureFrontmost(app: AppInfo, pid: pid_t)` that, for now, only handles browsers (delegates to the existing path when `Browser(rawValue: app.bundleID) != nil`, else no-op). This keeps every commit green.

- [ ] **Step 3: Full suite + build green** (no behavior change yet for non-browsers).
- [ ] **Step 4: Commit**
```bash
git add Sources/MaxMiCapture/FocusObserver.swift Sources/MaxMi/AppWiring.swift
git commit -m "feat(capture): widen focus observer gate to any capturable app (AppInfo)"
```

---

### Task 6: AppWiring dispatch + pause + menu + live verification

**Files:**
- Modify: `Sources/MaxMi/AppWiring.swift`, `Sources/MaxMi/MenuBarController.swift`
- Test: `Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift` (the dispatch decision is pure logic — extract it into a testable free function); live §11 walkthrough (controller/human).

**Interfaces:**
- Consumes: `ParserRegistry`, `GenericAXParser`, `SlackParser`, `ParsedCapture`, `AppInfo` (Tasks 1-3), `Store.pausedApps/pausedThreads/setAppPaused/setThreadPaused` (Task 4), `AXReader` (Task 3).
- Produces: a pure dispatch function (testable without live AX):
```swift
// In MaxMiCapture, so it can be unit-tested with fixtures:
public enum CaptureDispatch {
    /// Decide what to store for a frontmost app's window. Returns nil = skip.
    /// registeredParser nil => use generic. A registered parser returning nil/throwing
    /// => nil (NEVER fall through to generic) — the no-silent-fallback rule.
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture?
}
```

- [ ] **Step 1: Failing test** — `Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class NoSilentFallbackTests: XCTestCase {
    // A Slack window whose message area is empty -> SlackParser returns nil.
    func testRegisteredParserNilDoesNotFallThroughToGeneric() {
        // bare Slack window: has static text (so generic WOULD produce something) but no AXRow messages
        let win = AXNode(role: "AXWindow", value: nil, title: "x - y - Slack", url: nil, frame: nil, focused: false,
            children: [AXNode(role: "AXStaticText", value: "sidebar noise", title: nil, url: nil,
                              frame: CGRect(x:0,y:0,width:1,height:1), focused: false, children: [])])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack", windowTitle: "x - y - Slack")
        // SlackParser finds no AXRow -> nil; dispatch must NOT run GenericAXParser (which would capture "sidebar noise")
        XCTAssertNil(CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry()))
    }
    func testUnregisteredAppUsesGeneric() {
        let win = AXNode(role: "AXWindow", value: nil, title: "Note", url: nil, frame: nil, focused: false,
            children: [AXNode(role: "AXStaticText", value: "note body", title: nil, url: nil,
                              frame: CGRect(x:0,y:0,width:1,height:1), focused: false, children: [])])
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Note")
        let cap = CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry())
        XCTAssertEqual(cap?.content, "note body")
        XCTAssertEqual(cap?.sourceApp, "Notes")
    }
}
```

- [ ] **Step 2: Run — FAIL** (`CaptureDispatch` undefined).

- [ ] **Step 3: Implement CaptureDispatch** — add to `Sources/MaxMiCapture/ParserRegistry.swift` (or a new `CaptureDispatch.swift`):

```swift
public enum CaptureDispatch {
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture? {
        if let parser = registry.parser(for: app.bundleID) {
            // No-silent-fallback: registered parser owns this app. nil/throw -> skip, never generic.
            let result = try? parser.parse(window: window, app: app)
            return result ?? nil
        }
        return (try? GenericAXParser().parse(window: window, app: app)) ?? nil
    }
}
```

- [ ] **Step 4: Wire AppWiring.** Replace the browser-only `captureFrontmost`/`attemptCapture` with app-general dispatch. Key changes:
  - FocusObserver constructed with `isCapturable: { [registry] bid in Browser(rawValue: bid) != nil || registry.parser(for: bid) != nil || KnownApps.contains(bid) }` where `KnownApps` is a small allowlist including WhatsApp/Notes/Notion/Obsidian/Mail so they get the generic fallback (spec §3 "known-capturable app"). Define `KnownApps` as a `Set<String>` in AppWiring.
  - `captureFrontmost(app: AppInfo, pid:)`: `guard !paused` and `guard !(try store.pausedApps()).contains(app.bundleID)`; then `attemptCapture(app:pid:attemptsLeft:)` with attempts = `Browser(rawValue: app.bundleID)?.isChromium == true || app.bundleID == ParserRegistry.slackBundleID ? 3 : 1` (Electron apps need the retry-shortly).
  - `attemptCapture`: read `AXReader.snapshotFrontmostWindow(pid:)` → `(window, title)`. Build `let appInfo = AppInfo(bundleID: app.bundleID, name: app.name, windowTitle: title ?? app.windowTitle)` (AXReader's title is authoritative). For browsers, keep using `BrowserTabExtractor` (unchanged) to preserve the web-area-URL logic; for non-browsers, `CaptureDispatch.parse(window:app:registry:)`. Unify into a `ParsedCapture` either way:
    - browser branch: build `ParsedCapture(sourceApp: "Web", sourceKey: cap.url, sourceTitle: cap.title, content: cap.content)` from the existing `BrowserTabExtractor.extract`.
  - Then shared tail: `guard let parsed else { retryOrGiveUp(...) }`; `guard !Denylist.isBlocked(parsed.sourceKey)`; `guard !(try store.pausedThreads()).contains(parsed.sourceKey)`; `commitCapture(CaptureInput(sourceApp: parsed.sourceApp, sourceKey: parsed.sourceKey, sourceTitle: parsed.sourceTitle, content: parsed.content))`; bump `captureCount` on `.committed`.
  - `retryOrGiveUp` keeps its 2s/attemptsLeft shape but now keyed on `(app, pid)`.
  Show the full rewritten `captureFrontmost`/`attemptCapture`/`retryOrGiveUp` in the implementation (the implementer writes it from these exact rules; the browser path must remain byte-for-byte behavior-preserving — same `BrowserTabExtractor.extract`, same denylist, same retry on `.emptyContent/.noWebArea/.noURL`).

- [ ] **Step 5: Menu — per-app pause + pause current thread.** In `MenuBarController.swift`, add:
  - A "Pause capture for ▸" submenu populated from a caller-provided list of recently-seen `(bundleID, name)` with checkmarks reflecting `pausedApps()`; toggling calls back into AppWiring → `store.setAppPaused(...)`.
  - A "Pause capture for current thread" item that calls back with the last-captured `source_key` → `store.setThreadPaused(...)`.
  AppWiring tracks `recentApps: [(String,String)]` (last ~8 distinct) and `lastSourceKey: String?`, updates them on each commit, and passes closures to the menu. Keep it minimal (spec §7: "exposed minimally in M4").

- [ ] **Step 6: Full suite + build green.** ~132 tests (122 + 3 generic + 4 slack + 2 registry + 2 denylist + 3 pause + 2 no-silent-fallback minus overlaps). Zero warnings.

- [ ] **Step 7: Commit**
```bash
git add Sources/MaxMi/AppWiring.swift Sources/MaxMi/MenuBarController.swift Sources/MaxMiCapture/ParserRegistry.swift Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift
git commit -m "feat(app): dispatch capture through parser registry with per-app/thread pause + menu"
```

- [ ] **Step 8: Live verification (controller/human, spec §11).** Rebuild + re-grant if needed:
```bash
./packaging/make-app.sh
# signed identity persists from M3 — Accessibility grant should survive; if the app was replaced, re-grant once.
open MaxMi.app
```
Then:
1. Focus Slack, browse a channel → `sqlite3 ...maxmi.db "SELECT source_app, source_key FROM threads WHERE source_app='Slack'"` shows `slack:<workspace>/<view>` rows; content column is `enc:v1:`.
2. Focus Notes (or WhatsApp) → a thread appears with `source_app='Notes'`, key `com.apple.Notes:<title>` (generic fallback proves coverage).
3. MCP search: `search_memory "what did I discuss in Slack"` via maxmi-mcp → returns decrypted Slack facts.
4. Menu → Pause capture for Slack → focus Slack, browse → no new Slack thread. Unpause → capture resumes.
5. Confirm a Slack window with no messages does NOT create a generic "sidebar noise" thread (no-silent-fallback holds live).

---

## Self-Review (done at plan-writing time)

**Spec coverage:** §1 framework+fallback+Slack → Tasks 1-3, 6. §3 architecture/flow/file map → Tasks 1-6 match (SourceParser, GenericAXParser, SlackParser, ParserRegistry, AXReader locator, FocusObserver gate, AppWiring dispatch). §4 contract → Task 1 (AppInfo/ParsedCapture/SourceParser, non-empty key enforced by skip-on-nil). §5 Slack parser (AXMainWindow via AXReader Task 3, title→key, AXRow sender lines, content cap, sidebar handling) → Task 2 + 3. §6 generic fallback → Task 1. §7 pause (per-app + per-thread + menu) → Tasks 4, 6. §9 errors (no-silent-fallback, empty→skip, retry-shortly for Electron) → Tasks 6 (CaptureDispatch + tests), 6-step-4 (retry). §10 tests → each task's fixture tests + NoSilentFallbackTests + live §11. §11 exit criteria → Task 6 Step 8 walks all seven. §2 non-goals honored (no native helper, no WhatsApp parser — it's in KnownApps for generic fallback only, no doc parsers, nothing below Store).

**Placeholder scan:** none. Task 5's "temporary browser-only captureFrontmost" is an explicit inter-task green-build seam with named replacement in Task 6, not a vague TODO. Task 6 Step 4 gives exact dispatch rules rather than full code because the browser path must be preserved byte-for-byte from existing code — the rules are precise enough to implement without invention.

**Type consistency:** `AppInfo`/`ParsedCapture`/`SourceParser` (Task 1) consumed verbatim by Tasks 2,3,6. `ParserRegistry.parser(for:)`/`slackBundleID` (Task 3) used by Task 6's `CaptureDispatch` and AppWiring. `CaptureDispatch.parse(window:app:registry:)` (Task 6) matches its test. `Store.pausedApps/pausedThreads/setAppPaused/setThreadPaused` (Task 4) called in Task 6. FocusObserver's new `onCapture: (AppInfo, pid_t)` (Task 5) matches AppWiring's `captureFrontmost(app:pid:)` (Task 6). `BrowserTabExtractor.visualOrderText` reused by GenericAXParser (Task 1) — same-module internal access confirmed against current code.
