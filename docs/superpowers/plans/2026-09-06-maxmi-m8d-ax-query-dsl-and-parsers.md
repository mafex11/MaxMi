# MaxMi M8 Phase D — AX Query DSL + Anchored Parsers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MaxMi's per-app geometry heuristics with an `AXQuery` path DSL, a `StructuredParser` v2 protocol that routes by bundle ID *and* by browser host, and fourteen anchored parsers each pinned by golden `CapturedContent` fixtures.

**Architecture:** `AXQuery` compiles a small XPath-like grammar (`//AXRow[domClass*="c-virtual_list__item"][0]`) into cached `[Step]` values and evaluates them over an `AXNode` tree — no throwing, no geometry unless a parser explicitly asks for it. `StructuredParser` adds a static `ParserConfig` (bundle IDs, hosts, forced AX attribute set, offscreen policy, `preferOverNative`) and a `parse(_:context:)` that returns Phase A's `CapturedContent?`, where `nil` means NOT_HANDLED and falls through to `GenericPageExtractor`. `ParserRegistry` gains a bundle-ID map and a host map so a Slack *web* tab and the Slack *app* reach the same anchored parser. Each existing parser keeps its `SourceParser` conformance (which owns the thread key and the accumulation/offscreen policies, per spec §4f rule 1) and gains a `StructuredParser` conformance that owns the content.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+, XCTest, ApplicationServices/AppKit accessibility APIs.

**Spec:** `docs/superpowers/specs/2026-09-06-maxmi-m8-structured-capture-design.md` — this plan implements §7 in full (7a `AXQuery`, 7b `StructuredParser` v2 + `ParserConfig` + `ParseContext` + registry routing, 7c the anchored parser table, 7d fixture tooling) plus the Phase-D parts of §8 (cross-cutting), §9 (testing), and §11 (exit criteria, item 8). Phases B (§5) and C (§6) are separate plans and are out of scope here.

**Depends on: the Phase A plan (`docs/superpowers/plans/2026-09-06-maxmi-m8a-typed-capture-contract.md`) being merged first.** Per spec §10, "D depends only on A" and may run in parallel with B and C on a separate branch/worktree. Every task in this plan **consumes** these Phase A types and must never redefine them:

| Phase A type | Where it lives after Phase A |
|---|---|
| `CapturedContent` (`.document`/`.conversation`/`.tasks`/`.calendar`/`.terminal`/`.generic`) and its `var kind: CaptureContentKind` | `Sources/MaxMiCore/CapturedContent.swift` |
| `Block`, `BlockType`, `Region`, `RegionKind`, `FocusedElement`, `GenericPage`, `Document`, `Message` (+ `Message.makeID(sender:timeString:text:)`), `Conversation`, `TaskStatus`, `TaskItem`, `CalendarEvent`, `TerminalSegment`, `TerminalSession`, `Authorship` | `Sources/MaxMiCore/CapturedContent.swift` |
| `CapturedContentEnvelope` (+ `currentSchemaVersion`, `encode(_:) throws -> String`, `decode(_:) -> CapturedContent?`) | `Sources/MaxMiCore/CapturedContent.swift` |
| `ContentRenderer.render(_:style:)`, `RenderStyle`, `renderBlock`, `renderBlocks`, `renderMessage`, `renderTask`, `renderEvent`, `renderSegment`, `regionOrder`, `regionHeader(_:)` | `Sources/MaxMiCore/ContentRenderer.swift` |
| `GenericPageExtractor.extract(window:focusedElement:url:options:) -> Result` with `Options{totalBudget, mainShare, dialogShare, restShare, offscreenPolicy}` and `Result{page, truncated}` | `Sources/MaxMiCapture/GenericPageExtractor.swift` |
| `AXNode.subrole`, `.headingLevel`, `.selected`, `.placeholder`, `.selectedText`, `.hidden`; `AXReader.textEntryRoles`; `AXReader.focusedElementSnapshot(pid:)` | `Sources/MaxMiCapture/AXSnapshot.swift`, `AXReader.swift` |
| `ParsedCapture.structured: CapturedContent?`; `SourceParser.parseStructured(window:app:) throws -> CapturedContent?` (default `nil`) | `Sources/MaxMiCapture/SourceParser.swift` |
| `LegacyContentAdapter.adapt(renderedContent:kind:)` | `Sources/MaxMiCore/LegacyContentAdapter.swift` |
| `CaptureDispatch.ParseResult.parsedByFallback(ParsedCapture, failedParser: String)` | `Sources/MaxMiCapture/ParserRegistry.swift` |

**Phase D adds `domClassList` and `domIdentifier` to `AXNode` and `AXReader`** (spec §12 Q1: every other attribute addition moved into Phase A; only these two stay here).

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- **Execute only after the Phase A plan is merged.** Phase A lands the `AXNode` attribute additions first so Phase D only adds `domClassList`/`domIdentifier` on top (§10). If `Sources/MaxMiCore/CapturedContent.swift` does not exist, stop and merge Phase A.
- **Never redefine a Phase A type.** Consume the names in the table above exactly. A task that needs a new type puts it in a Phase D file.
- **XCTest only.** Zero `import Testing` anywhere; tests are `final class …: XCTestCase` with `func test…` methods (§2: "506 tests, all XCTest").
- **The existing tests stay green.** Every signature change in this plan lists its exact existing call sites.
- **`AXQuery` never throws and is total** (§7a). An invalid path is a programmer error: `preconditionFailure` in debug, `nil` / `[]` in release. Parsed paths are cached in a **lock-guarded LRU of capacity 128** keyed on the path string.
- **`AXQuery` matching is case-sensitive except `domClass`, which is case-insensitive** (§7a). Predicates on one step are ANDed. `description` is an explicit **alias of `label`**, because `AXReader` folds `kAXDescriptionAttribute ?? kAXHelpAttribute` into `label` (§7a, §12 Q1).
- **`domClassList`/`domIdentifier` are read only under an `AXWebArea` ancestor** (§7a, §8), or when a parser's `ParserConfig.attributeSet` forces them.
- **`nil` from a `StructuredParser` means NOT_HANDLED and routes to `GenericPageExtractor`** (§7b, §4f rule 3). The fallback is **not silent**: `capture_health_events.parser` records `"GenericPageExtractor.v2/fallback/<ParserTypeName>"` (§8). `capture_health_events` gains no new column.
- **Mail stays AppleScript-sourced** (§12 Q6). Mail's AX tree is ~80 ms/node. Phase D's only Mail change is the compose-window `Mail.subjectField` read (§7c).
- **Discord must not use any geometric split** — its `AXFrame` values are unreliable (§7c, `DiscordParser.swift` header comment).
- **Visual-order sorting is translation-invariant.** `AXFrame` is global screen coordinates, so every comparison against a window edge or midpoint is done relative to the window frame (§4e, and the `project_maxmi_ax_capture` regression).
- **Every rewritten parser ships ≥2 recorded, hand-scrubbed AX fixtures with a golden expected `CapturedContent` JSON, at least one of them with a nonzero window origin** (§9, §11 item 8).
- **Fixtures are hand-scrubbed.** Never commit real page text, messages, file contents, URLs, names, or tokens (`Tests/MaxMiCaptureTests/Fixtures/README.md`). Every new fixture gets a row in that README's table.
- **No PII/email redaction inside captured content** beyond the existing `Denylist` app + domain denylist (§3 Non-goals).
- **No `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`, ever** (§3 Non-goals).
- **No change to the MCP tool surface** (§4g). `search_memory`, `list_active_threads`, `get_latest_context` keep their shapes and keep reading `content`.
- **Secure fields are never read** — the value is not fetched, not merely not stored (§8). No parser in this plan reads the `value` of a node whose `subrole == "AXSecureTextField"`.
- **Commit messages are plain imperative** ("Add AXQuery path grammar"). **No `Co-Authored-By` trailers, no AI attribution anywhere** — not in commit messages, code comments, or docs.
- **Live verification ritual** (§9, unchanged): `./packaging/make-app.sh && pkill -9 -x MaxMi && sleep 2 && open MaxMi.app`. **No `tccutil reset`** — signed builds keep the Accessibility grant across rebuilds. Verify captures by timestamp strictly after the new process start.

### What Phase D changes about Phase A's parsers

Phase A migrated each parser's **output type** (`SlackParser` already returns a `.conversation`). Phase D replaces each parser's **anchoring**: DOM-class and identifier anchors instead of x-band geometry, and a golden fixture per parser. In every parser task:

- The existing type keeps its `SourceParser` conformance. `parse(window:app:)` stays the owner of `sourceApp`, `sourceKey`, `accumulationPolicy`, `offscreenPolicy` and `contentKind` — that is spec §4f rule 1 ("call `parse` for keys/policies and attach the structured value"), and it is why the existing key-derivation tests keep passing untouched.
- The type gains a `StructuredParser` conformance: `static var config: ParserConfig` and `parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?`.
- `parseStructured(window:app:)` (the `SourceParser` requirement Phase A added) becomes a four-line bridge to `parse(_:context:)`. It is written out explicitly in each parser, not provided by a constrained protocol extension — two competing default implementations of the same requirement is exactly the kind of overload-resolution subtlety that silently picks the wrong one.
- Where Phase D's implementation supersedes an interim Phase A body inside `parseStructured`, **replace that body**; do not leave two content paths for one app. Concretely, Phase A Task 16 routes Notes, Notion, Obsidian, Discord and Messages through `GenericV2Content.page` / `GenericV2Content.lines`. In each of Tasks 11, 12, 15, 16 and 17 the new `parse(_:context:)` becomes the whole content path and the `parseStructured` bridge is exactly the four lines the task shows — the `GenericV2Content` call is **deleted**, not chained. Returning `nil` is the correct degradation: `CaptureDispatch` rule 3 (Phase A Task 10) already routes it to `GenericPageExtractor`, which is strictly better than `GenericV2Content.lines`, and it is what records the §8 fallback marker.
- Two Phase A members are **superseded and replaced**, not shadowed: `TerminalParser.promptPatterns` / `TerminalParser.segments(fromScrollback:)` (Phase A Task 14) are replaced by Task 7's `PromptShape` + `promptShape(in:)` + `segments(fromScrollback:)`, and Phase A's `TerminalSegmentationTests.swift` is deleted in favour of `TerminalStructuredTests.swift` because Task 7's tests assert a superset of its behaviour plus the absolute `cwd` path Phase A explicitly deferred ("The richer absolute path is Phase D's anchored rewrite"). Nothing else in Phase A is deleted by this plan.

### Three reconciliations of spec text against the code

Decided here so no task has to reopen them.

1. **`ParserConfig` gains `hosts: [String]`.** §7b lists the fields `app`, `bundleIDs`, `attributeSet`, `offscreenPolicy`, `preferOverNative`, `minAppVersion`, and separately requires "a third [map] keyed by **host** so browsers route web-app hosts through the same mechanism". A host map needs the hosts to come from somewhere, and `ParserConfig` is the only per-parser declaration site. `hosts` is added, defaulting to `[]`. A leading-dot entry (`".slack.com"`) means suffix match, mirroring `WebAppCaptureParser.classify`'s existing `host.hasSuffix(".slack.com")`.
2. **`ParserConfig.attributeSet` is implemented as forced AX attribute names, not a generic attribute bag.** §7b says it is "extra AX attributes `AXReader` must fetch for this app" and §8 says it is "what keeps the extra AX reads off apps that do not need them". Adding a `[String: String]` bag to `AXNode` would change the wire shape of eleven fixtures for no consumer. Instead `AXReader.snapshotFrontmostWindow(pid:maxNodes:maxDepth:forcedAttributes:)` takes a `Set<String>`; the only names it honours are `"AXDOMClassList"` and `"AXDOMIdentifier"`, and honouring them means bypassing the `AXWebArea`-ancestor gate for the whole tree. That is exactly what Electron apps (Slack, Notion, Obsidian) need, because they do not always expose an `AXWebArea` above their DOM.
3. **`StructuredParser` does not carry the thread key.** §7b's protocol returns only `CapturedContent?`, but `sourceKey` is load-bearing and heavily tested (`SlackParser.key(fromTitle:)`, `TerminalParser.terminalKey`, `ObsidianParser.key(fromTitle:)`, `DiscordParser.key(fromTitle:)`, `MessagesParser.key(fromTitle:)`). §4f rule 1 already resolves it: keys and policies come from `SourceParser.parse`. The protocol stays exactly as §7b writes it.

---

## File Structure

### Created

| File | Responsibility |
|---|---|
| `Sources/MaxMiCapture/AXQuery.swift` | The path grammar: `Axis`, `Attribute`, `Operator`, `Predicate`, `Step`, the parser, the capacity-128 LRU path cache, and `find`/`findAll` evaluation. Nothing app-specific. |
| `Sources/MaxMiCapture/AXQueryHelpers.swift` | `AXQuery.Matchers`, `sortedByVisualOrder(_:relativeTo:)`, `collectStaticTexts(in:)`, `formatTable(_:)`. Split from `AXQuery.swift` so the grammar file stays readable. |
| `Sources/MaxMiCapture/StructuredParser.swift` | `ParserConfig`, `ParseContext`, the `StructuredParser` protocol. Types only — no routing, no parsers. |
| `Sources/MaxMiCapture/StructuredParserRouting.swift` | `ParserRegistry`'s structured + host maps, host resolution, `CaptureDispatch.structuredCapture(window:context:registry:)`, `StructuredParseResult`, and the §8 fallback-marker helper. |
| `Sources/MaxMiCapture/EditorParser.swift` | Cursor + VS Code → `.document`. New parser; these two apps used `GenericAXParser` before. |
| `Sources/MaxMiCapture/WebPageParser.swift` | The browser generic-web path: `GenericPageExtractor` over the active `AXWebArea` subtree with `url` set. |
| `Sources/MaxMiCapture/FinderParser.swift` | Finder → `.generic` with sidebar/main/toolbar regions and joined table rows. New parser; Finder used `GenericAXParser` before. |
| `tools/ax-snapshot-record.swift` | Records the focused window as a `Codable` `AXNode` JSON fixture. `tools/ax-structure-inventory.swift` deliberately emits no attribute values and cannot produce a loadable fixture (§12 Q11). |
| `Tests/MaxMiCaptureTests/FixtureLoading.swift` | The one `fixture(_:)` loader (replacing six duplicates, §7d) plus `goldenCapturedContent(_:)` and `assertGolden(_:matches:)`. |
| `Tests/MaxMiCaptureTests/AXQueryPathTests.swift` | Table-driven grammar tests + the LRU cache. |
| `Tests/MaxMiCaptureTests/AXQueryEvaluationTests.swift` | `find`/`findAll` over synthetic trees; attribute aliases; `domClass` case-insensitivity. |
| `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift` | Matchers, translation-invariant visual order, `collectStaticTexts`, `formatTable`. |
| `Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift` | `domClassList`/`domIdentifier` decode; the eleven pre-M8 fixtures still decode; the web-area read gate. |
| `Tests/MaxMiCaptureTests/StructuredParserRoutingTests.swift` | Bundle-ID routing, host routing, `preferOverNative`, `nil` → `GenericPageExtractor` fall-through, the fallback marker string. |
| `Tests/MaxMiCaptureTests/TerminalStructuredTests.swift` | Prompt-shape segmentation, `isRunning`, `cwd`, failure → one segment with `command: nil`, golden fixtures. |
| `Tests/MaxMiCaptureTests/EditorParserTests.swift` | Editor anchor, active-tab title for both title orders, integrated terminal dropped, key derivation, golden fixtures. |
| `Tests/MaxMiCaptureTests/WebPageParserTests.swift` | Landmark regions, `url`, golden fixtures. |
| `Tests/MaxMiCaptureTests/SlackStructuredTests.swift` | DOM-class anchors, composer draft, geometry fallback, golden fixtures. |
| `Tests/MaxMiCaptureTests/DiscordStructuredTests.swift` | "Messages in" list anchor, heading-based sender attribution, no geometry, golden fixtures. |
| `Tests/MaxMiCaptureTests/MessagesStructuredTests.swift` | Bubble side → `isUser` with a nonzero window origin, golden fixtures. |
| `Tests/MaxMiCaptureTests/WhatsAppStructuredTests.swift` | `WAMessageBubbleTableViewCell` anchor, golden fixtures. |
| `Tests/MaxMiCaptureTests/MailComposeDraftTests.swift` | `Mail.subjectField` compose draft; nil when no compose window. |
| `Tests/MaxMiCaptureTests/NotesStructuredTests.swift` | `Note Body Text View` anchor, title from first line, `— Shared` authorship, golden fixtures. |
| `Tests/MaxMiCaptureTests/NotionStructuredTests.swift` | `notion-frame`/`notion-peek-renderer` anchor, skipped subtrees, `notion-topbar` title, golden fixtures. |
| `Tests/MaxMiCaptureTests/ObsidianStructuredTests.swift` | `cm-editor` / `markdown-preview-view` anchors, note title, golden fixtures. |
| `Tests/MaxMiCaptureTests/FinderStructuredTests.swift` | Sidebar/main/toolbar regions, `.tableRow` with `selected`, path, golden fixtures. |
| `Tests/MaxMiCaptureTests/CalendarStructuredTests.swift` | `.calendar` events from the detail root, golden fixtures. |
| `Tests/MaxMiCaptureTests/RemindersStructuredTests.swift` | `.tasks` with status from the row checkbox, golden fixtures. |
| 28 fixture + golden JSON files under `Tests/MaxMiCaptureTests/Fixtures/` | Two per parser; named in each parser task. |

### Modified

| File | Change |
|---|---|
| `Sources/MaxMiCapture/AXSnapshot.swift` | `AXNode` gains `domClassList: [String]?` and `domIdentifier: String?`, defaulted in `init` and decoded with `decodeIfPresent`. |
| `Sources/MaxMiCapture/AXReader.swift` | `convert` threads an `inWebArea` flag and a `forcedAttributes` set; `snapshotFrontmostWindow` gains `forcedAttributes:`; new pure `readsDOMAttributes(role:inWebArea:forced:)`. |
| `Sources/MaxMiCapture/ParserRegistry.swift` | New bundle-ID constants (`finderBundleID`, `cursorBundleID`, `vsCodeBundleID`); the structured and host maps are built here and consumed by `StructuredParserRouting.swift`. |
| `Sources/MaxMiCapture/BrowserCapturePipeline.swift` | Routes a browser window through the host map first, then `WebPageParser`; carries the structured value on `BrowserCaptureResult`. |
| `Sources/MaxMiCapture/WebAppCaptureParser.swift` | `classify` keeps its ten cases for the parser ID and `contentKind`, but no longer decides content shape — the host map does (§7b). |
| `Sources/MaxMiCapture/TerminalParser.swift` | `StructuredParser` conformance; prompt-shape segmentation; `cwdPath`; `pathBodyPattern` promoted to a `static let`. |
| `Sources/MaxMiCapture/SlackParser.swift` | `StructuredParser` conformance; DOM-class anchors with the existing x-band walk as fallback; `channelName(fromTitle:)`. |
| `Sources/MaxMiCapture/DiscordParser.swift` | `StructuredParser` conformance; "Messages in" list anchor; heading-based sender attribution. |
| `Sources/MaxMiCapture/MessagesParser.swift` | `StructuredParser` conformance; bubble side → `isUser`. |
| `Sources/MaxMiCapture/NativeConversationParser.swift` | `WhatsAppParser` gains `StructuredParser` conformance; `NativeConversationExtraction.conversationName(window:app:)` promoted to internal. |
| `Sources/MaxMiCapture/MailParser.swift` | New `composeDraft(window:)`; `parseStructured` returns it first when a compose window is frontmost. |
| `Sources/MaxMiCapture/NotesParser.swift` | `StructuredParser` conformance; `Note Body Text View` anchor. |
| `Sources/MaxMiCapture/NotionParser.swift` | `StructuredParser` conformance; `notion-frame` anchor. |
| `Sources/MaxMiCapture/ObsidianParser.swift` | `StructuredParser` conformance; `cm-editor` / `markdown-preview-view` anchors; `noteName(fromTitle:)`. |
| `Sources/MaxMiCapture/StructuredNativeParsers.swift` | `CalendarParser`/`FantasticalParser`/`RemindersParser` gain `StructuredParser` conformance; `StructuredEntityExtraction.preferredDetailRoot` and `orderedFields` promoted to internal. |
| `Sources/MaxMiCore/ApplicationRegistry.swift` | Cursor, VS Code and Finder move to `captureStrategy: .nativeParser`; Finder gains a descriptor. |
| `Sources/MaxMi/AppWiring.swift` | The non-browser dispatch switch (`:1479`) and the browser branch (`:1446-1477`) pass a `ParseContext` and handle the structured fall-through result. |
| `Tests/MaxMiCoreTests/ApplicationRegistryTests.swift:66` | `cursor?.captureStrategy` expectation moves from `.genericAX` to `.nativeParser`. |
| `Tests/MaxMiCaptureTests/ExtractorTests.swift:5`, `BrowserCapturePipelineTests.swift:6`, `NativeConversationParserTests.swift:5`, `GenericAXParserTests.swift:5`, `SlackParserTests.swift:5`, `StructuredNativeParserTests.swift:5` | The six duplicated `func fixture(_:)` helpers are deleted in favour of `FixtureLoading.swift` (§7d). |
| `Tests/MaxMiCaptureTests/Fixtures/README.md` | A row per new fixture, plus the recording + hand-scrub procedure. |

### Deleted

| File | Why |
|---|---|
| `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` | Phase A Task 14's interim segmentation test. Task 7 replaces the segmentation with the shape-aware version Phase A explicitly deferred ("The richer absolute path is Phase D's anchored rewrite") and asserts a superset of its behaviour. |
| The six duplicated `func fixture(_:)` methods (not whole files) | Consolidated into `Tests/MaxMiCaptureTests/FixtureLoading.swift` per spec §7d. |

---

### Task 1: `AXNode.domClassList` / `domIdentifier` + the `AXReader` web-area gate

**Ordering note:** the spec lists the DOM attributes inside §7a, and §7a's `domClass` predicate cannot be evaluated without them, so the attribute addition lands before the DSL rather than after it.

**Files:**
- Modify: `Sources/MaxMiCapture/AXSnapshot.swift` (the whole `AXNode` struct)
- Modify: `Sources/MaxMiCapture/AXReader.swift:20` (`snapshotFrontmostWindow`), `:57-91` (`convert`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/dom-attributes.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift`

**Interfaces:**
- Consumes: `AXNode` including the Phase A attributes (`subrole`, `headingLevel`, `selected`, `placeholder`, `selectedText`, `hidden`) and `AXReader.textEntryRoles`.
- Produces: `AXNode.domClassList: [String]?`, `AXNode.domIdentifier: String?`; the full initializer `AXNode.init(role:value:title:url:frame:focused:children:identifier:label:subrole:headingLevel:selected:placeholder:selectedText:hidden:domClassList:domIdentifier:)` with both new parameters defaulted `nil` so the ~120 existing `AXNode(` construction sites compile unchanged; `AXReader.snapshotFrontmostWindow(pid:maxNodes:maxDepth:forcedAttributes:)` with `forcedAttributes: Set<String> = []`; `AXReader.domAttributeNames: Set<String>` (`["AXDOMClassList", "AXDOMIdentifier"]`); `AXReader.readsDOMAttributes(role:inWebArea:forced:) -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/Fixtures/dom-attributes.json`:

```json
{
  "role": "AXWindow", "value": null, "title": "Workspace", "url": null,
  "frame": {"x":320,"y":140,"width":1000,"height":700}, "focused": false,
  "children": [
    {"role": "AXWebArea", "value": null, "title": null, "url": "https://app.example.com/room/1",
     "frame": {"x":320,"y":180,"width":1000,"height":660}, "focused": false,
     "domIdentifier": "root", "children": [
       {"role": "AXGroup", "value": null, "title": null, "url": null,
        "frame": {"x":600,"y":200,"width":700,"height":600}, "focused": false,
        "domClassList": ["c-message_list", "p-workspace__primary"], "children": [
          {"role": "AXGroup", "value": null, "title": null, "url": null,
           "frame": {"x":600,"y":220,"width":700,"height":40}, "focused": false,
           "domClassList": ["c-virtual_list__item"], "domIdentifier": "msg-1", "children": [
             {"role": "AXStaticText", "value": "Ada", "title": null, "url": null,
              "frame": {"x":610,"y":220,"width":80,"height":16}, "focused": false,
              "domClassList": ["c-message__sender"], "children": []},
             {"role": "AXStaticText", "value": "index rebuilt", "title": null, "url": null,
              "frame": {"x":610,"y":238,"width":300,"height":16}, "focused": false,
              "children": []}
           ]}
        ]}
     ]}
  ]
}
```

Append to the table in `Tests/MaxMiCaptureTests/Fixtures/README.md`:

```markdown
| `dom-attributes.json` | Hand-authored web-area DOM shape at a nonzero window origin | `AXNode` decoding of `domClassList`/`domIdentifier`, `AXQuery` `domClass`/`domId` predicates |
```

Create `Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class AXNodeDOMAttributeTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testDOMAttributesDecode() throws {
        let window = try fixture("dom-attributes")
        let webArea = window.children[0]
        XCTAssertEqual(webArea.domIdentifier, "root")
        XCTAssertNil(webArea.domClassList)
        let list = webArea.children[0]
        XCTAssertEqual(list.domClassList, ["c-message_list", "p-workspace__primary"])
        let item = list.children[0]
        XCTAssertEqual(item.domIdentifier, "msg-1")
        XCTAssertEqual(item.children[0].domClassList, ["c-message__sender"])
    }

    func testAbsentDOMAttributesDefaultToNilInEveryPreM8Fixture() throws {
        for name in ["calendar-event", "chrome-article", "chromium-gmail-thread", "cursor-editor",
                     "gecko-slack-chat", "pages-document", "reminder-task", "safari-domain-only",
                     "slack-window", "whatsapp-conversation", "zen-meet"] {
            let node = try fixture(name)
            XCTAssertNil(node.domClassList, "\(name) has no domClassList and must decode as nil")
            XCTAssertNil(node.domIdentifier, "\(name) has no domIdentifier and must decode as nil")
        }
    }

    func testEncodeDecodeRoundTripPreservesDOMAttributes() throws {
        let original = try fixture("dom-attributes")
        let decoded = try JSONDecoder().decode(AXNode.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.children[0].children[0].domClassList,
                       ["c-message_list", "p-workspace__primary"])
        XCTAssertEqual(decoded.children[0].domIdentifier, "root")
    }

    func testMemberwiseInitDefaultsKeepOldCallSitesValid() {
        let node = AXNode(role: "AXStaticText", value: "x", title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                          focused: false, children: [])
        XCTAssertNil(node.domClassList)
        XCTAssertNil(node.domIdentifier)
    }

    func testDOMReadGateIsWebAreaScoped() {
        XCTAssertTrue(AXReader.readsDOMAttributes(role: "AXWebArea", inWebArea: false, forced: []),
                      "the web area itself is inside the web")
        XCTAssertTrue(AXReader.readsDOMAttributes(role: "AXGroup", inWebArea: true, forced: []))
        XCTAssertFalse(AXReader.readsDOMAttributes(role: "AXGroup", inWebArea: false, forced: []),
                       "native subtrees pay nothing for DOM attributes")
    }

    func testForcedAttributeSetBypassesTheWebAreaGate() {
        XCTAssertTrue(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXDOMClassList"]))
        XCTAssertTrue(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXDOMIdentifier"]))
        XCTAssertFalse(AXReader.readsDOMAttributes(
            role: "AXGroup", inWebArea: false, forced: ["AXHeadingLevel"]),
            "only the two DOM attribute names are honoured")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXNodeDOMAttributeTests`
Expected: FAIL to compile — "value of type 'AXNode' has no member 'domClassList'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/AXSnapshot.swift`, add the two stored properties after `hidden`:

```swift
    /// "AXDOMClassList", read only under an AXWebArea ancestor (or when forced by a
    /// ParserConfig.attributeSet). Web/Electron trees only — nil everywhere else.
    public let domClassList: [String]?
    /// "AXDOMIdentifier", same gate as domClassList.
    public let domIdentifier: String?
```

extend the initializer's parameter list and body:

```swift
                placeholder: String? = nil, selectedText: String? = nil, hidden: Bool = false,
                domClassList: [String]? = nil, domIdentifier: String? = nil) {
```

```swift
        self.domClassList = domClassList; self.domIdentifier = domIdentifier
```

add both to `CodingKeys`:

```swift
        case subrole, headingLevel, selected, placeholder, selectedText, hidden
        case domClassList, domIdentifier
```

add both to `init(from:)` (after `hidden`):

```swift
        domClassList = try container.decodeIfPresent([String].self, forKey: .domClassList)
        domIdentifier = try container.decodeIfPresent(String.self, forKey: .domIdentifier)
```

and to `encode(to:)` (after `hidden`):

```swift
        try container.encodeIfPresent(domClassList, forKey: .domClassList)
        try container.encodeIfPresent(domIdentifier, forKey: .domIdentifier)
```

In `Sources/MaxMiCapture/AXReader.swift`, add next to `textEntryRoles`:

```swift
    /// The only two attribute names `ParserConfig.attributeSet` can force. Both are web-only,
    /// so the default gate is "an AXWebArea ancestor was seen".
    static let domAttributeNames: Set<String> = ["AXDOMClassList", "AXDOMIdentifier"]

    /// Pure gate, so the cost policy in spec §8 is unit-testable without a live tree.
    static func readsDOMAttributes(role: String, inWebArea: Bool, forced: Set<String>) -> Bool {
        if inWebArea || role == "AXWebArea" { return true }
        return !forced.intersection(domAttributeNames).isEmpty
    }
```

change the `snapshotFrontmostWindow` signature and its `convert` call:

```swift
    public static func snapshotFrontmostWindow(
        pid: pid_t, maxNodes: Int = 20_000, maxDepth: Int = 40,
        forcedAttributes: Set<String> = []
    ) -> (window: AXNode, title: String?)? {
```

```swift
            let node = convert(window, depth: 0, maxDepth: maxDepth, budget: &budget,
                               inWebArea: false, forcedAttributes: forcedAttributes)
```

change `convert`'s signature, add the reads, thread the flag, and pass the fields:

```swift
    private static func convert(_ el: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int,
                                inWebArea: Bool = false,
                                forcedAttributes: Set<String> = []) -> AXNode {
```

```swift
        // Web/Electron DOM anchors. Gated so native subtrees pay nothing for them.
        let readsDOM = readsDOMAttributes(role: role, inWebArea: inWebArea, forced: forcedAttributes)
        let domClassList = readsDOM ? (copyAttr(el, "AXDOMClassList") as? [String]) : nil
        let domIdentifier = readsDOM ? (copyAttr(el, "AXDOMIdentifier") as? String) : nil
```

```swift
                children.append(convert(kid, depth: depth + 1, maxDepth: maxDepth, budget: &budget,
                                        inWebArea: readsDOM, forcedAttributes: forcedAttributes))
```

```swift
        return AXNode(role: role, value: value, title: title, url: url,
                      frame: frame, focused: focused, children: children,
                      identifier: identifier, label: label,
                      subrole: subrole, headingLevel: headingLevel, selected: selected,
                      placeholder: placeholder, selectedText: selectedText, hidden: hidden,
                      domClassList: domClassList, domIdentifier: domIdentifier)
```

`focusedElementSnapshot(pid:)` (added in Phase A) keeps calling `convert` with the defaults — it feeds only `FocusedElement`, which needs no DOM anchor, so it stays off the DOM read path.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXNodeDOMAttributeTests`
Expected: PASS, 6 tests.

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS, unchanged — the eleven pre-M8 fixtures decode with both new fields nil.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/AXSnapshot.swift Sources/MaxMiCapture/AXReader.swift \
        Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/dom-attributes.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Read DOM class list and DOM identifier under web areas"
```

---

### Task 2: `AXQuery` path grammar, parser and LRU cache

**Files:**
- Create: `Sources/MaxMiCapture/AXQuery.swift`
- Test: `Tests/MaxMiCaptureTests/AXQueryPathTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (the grammar knows attribute *names*, not `AXNode` fields).
- Produces, all `internal` so `@testable import` can see them and the public surface stays the four functions §7a lists: `AXQuery.Axis` (`.child`, `.descendant`), `AXQuery.Attribute` (`.role`, `.subrole`, `.title`, `.description`, `.label`, `.value`, `.identifier`, `.domId`, `.domClass`), `AXQuery.Operator` (`.equals`, `.prefix`, `.contains`), `AXQuery.Predicate{attribute, op, expected}`, `AXQuery.Step{axis, role: String?, predicates: [Predicate], index: Int?}`, `AXQuery.parsePath(_:) -> [Step]?` (uncached), `AXQuery.steps(for:) -> [Step]?` (cached), `AXQuery.pathCacheCapacity = 128`, `AXQuery.cachedPathCount()`, `AXQuery.resetPathCache()`, and in DEBUG builds `AXQuery.trapsOnInvalidPath` (default `true`).
- `role == nil` means the `*` wildcard. `index` is zero-based and at most one per step.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/AXQueryPathTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class AXQueryPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AXQuery.resetPathCache()
        // An invalid path is a programmer error and traps in debug builds. These tests assert the
        // release behaviour (nil / []), so the trap is switched off for the duration.
        AXQuery.trapsOnInvalidPath = false
    }

    override func tearDown() {
        AXQuery.trapsOnInvalidPath = true
        AXQuery.resetPathCache()
        super.tearDown()
    }

    func step(_ axis: AXQuery.Axis, _ role: String?,
              _ predicates: [AXQuery.Predicate] = [], _ index: Int? = nil) -> AXQuery.Step {
        AXQuery.Step(axis: axis, role: role, predicates: predicates, index: index)
    }

    func predicate(_ attribute: AXQuery.Attribute, _ op: AXQuery.Operator,
                   _ expected: String) -> AXQuery.Predicate {
        AXQuery.Predicate(attribute: attribute, op: op, expected: expected)
    }

    func testValidPaths() {
        let cases: [(path: String, expected: [AXQuery.Step])] = [
            ("/AXRow", [step(.child, "AXRow")]),
            ("//AXRow", [step(.descendant, "AXRow")]),
            ("/AXTable/AXRow", [step(.child, "AXTable"), step(.child, "AXRow")]),
            ("/AXTable//AXRow", [step(.child, "AXTable"), step(.descendant, "AXRow")]),
            ("//AXOutline//AXRow", [step(.descendant, "AXOutline"), step(.descendant, "AXRow")]),
            ("/*", [step(.child, nil)]),
            ("//*", [step(.descendant, nil)]),
            ("//AXGroup[identifier=\"editor\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .equals, "editor")])]),
            ("//AXGroup[identifier^=\"workbench.\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .prefix, "workbench.")])]),
            ("//AXGroup[identifier*=\"editor\"]",
             [step(.descendant, "AXGroup", [predicate(.identifier, .contains, "editor")])]),
            ("//*[domClass*=\"c-virtual_list__item\"]",
             [step(.descendant, nil, [predicate(.domClass, .contains, "c-virtual_list__item")])]),
            ("//*[domId=\"msg-1\"]", [step(.descendant, nil, [predicate(.domId, .equals, "msg-1")])]),
            ("//AXStaticText[description*=\"message from\"]",
             [step(.descendant, "AXStaticText", [predicate(.description, .contains, "message from")])]),
            ("//AXRow[label^=\"Row \"]",
             [step(.descendant, "AXRow", [predicate(.label, .prefix, "Row ")])]),
            ("//AXRow[0]", [step(.descendant, "AXRow", [], 0)]),
            ("//AXRow[3]", [step(.descendant, "AXRow", [], 3)]),
            ("//AXRow[subrole=\"AXTabButton\"][title*=\"Inbox\"]",
             [step(.descendant, "AXRow",
                   [predicate(.subrole, .equals, "AXTabButton"),
                    predicate(.title, .contains, "Inbox")])]),
            ("//AXRow[value=\"1\"][2]",
             [step(.descendant, "AXRow", [predicate(.value, .equals, "1")], 2)]),
            ("//AXWebArea//AXGroup[domClass*=\"notion-frame\"]//AXStaticText",
             [step(.descendant, "AXWebArea"),
              step(.descendant, "AXGroup", [predicate(.domClass, .contains, "notion-frame")]),
              step(.descendant, "AXStaticText")]),
        ]

        for c in cases {
            XCTAssertEqual(AXQuery.parsePath(c.path), c.expected, "path \(c.path)")
        }
    }

    func testInvalidPathsReturnNil() {
        let invalid = [
            "",                                 // empty
            "AXRow",                            // no leading slash
            "/",                                // empty role token
            "//",                               // empty role token
            "/AXRow/",                          // trailing slash
            "///AXRow",                         // three slashes
            "/AXRow[",                          // unterminated bracket
            "/AXRow]",                          // stray close
            "/AXRow[identifier]",               // predicate without operator
            "/AXRow[identifier=editor]",        // unquoted value
            "/AXRow[identifier=\"editor]",      // unterminated quote
            "/AXRow[bogus=\"x\"]",              // unknown attribute
            "/AXRow[identifier~=\"x\"]",        // unknown operator
            "/AXRow[-1]",                       // negative index
            "/AXRow[0][1]",                     // two indexes on one step
            "/AXRow trailing",                  // trailing junk
            "/AX-Row",                          // illegal character in a role token
        ]
        for path in invalid {
            XCTAssertNil(AXQuery.parsePath(path), "path \(path) must not parse")
        }
    }

    func testWildcardRoleIsRepresentedAsNil() {
        XCTAssertNil(try XCTUnwrap(AXQuery.parsePath("//*")).first?.role)
        XCTAssertEqual(try XCTUnwrap(AXQuery.parsePath("//AXRow")).first?.role, "AXRow")
    }

    func testCachedStepsEqualUncachedStepsAndAreReused() {
        let path = "//AXTable//AXRow[value=\"1\"][0]"
        XCTAssertEqual(AXQuery.cachedPathCount(), 0)
        let first = AXQuery.steps(for: path)
        XCTAssertEqual(AXQuery.cachedPathCount(), 1)
        let second = AXQuery.steps(for: path)
        XCTAssertEqual(AXQuery.cachedPathCount(), 1, "a hit must not add an entry")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, AXQuery.parsePath(path), "the cache must not change the result")
    }

    func testInvalidPathsAreNotCached() {
        XCTAssertNil(AXQuery.steps(for: "/AXRow["))
        XCTAssertEqual(AXQuery.cachedPathCount(), 0)
    }

    func testCacheEvictsBeyondCapacityAndKeepsTheNewestEntries() {
        for i in 0..<(AXQuery.pathCacheCapacity + 10) {
            XCTAssertNotNil(AXQuery.steps(for: "//AXRow\(i)"))
        }
        XCTAssertEqual(AXQuery.cachedPathCount(), AXQuery.pathCacheCapacity)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXQueryPathTests`
Expected: FAIL to compile — "cannot find 'AXQuery' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/AXQuery.swift`:

```swift
import Foundation

/// Path expressions over an `AXNode` tree, so a parser declares *where* its content lives
/// instead of re-deriving it from geometry per app.
///
/// The API is total: it never throws. A malformed path is a programmer error, so it traps in
/// debug builds and degrades to nil / [] in release. Parsed paths are cached, because the
/// anchored parsers evaluate the same handful of literals on every capture tick.
public enum AXQuery {
    // MARK: - Grammar

    enum Axis: Equatable {
        /// `/Role` — a direct child.
        case child
        /// `//Role` — any descendant.
        case descendant
    }

    enum Operator: String, Equatable {
        case equals = "="
        case prefix = "^="
        case contains = "*="
    }

    /// `description` is an alias of `label`: `AXReader` folds kAXDescriptionAttribute into
    /// `label`, so the two names resolve to the same field (spec §12 Q1).
    enum Attribute: String, Equatable, CaseIterable {
        case role, subrole, title, description, label, value, identifier, domId, domClass
    }

    struct Predicate: Equatable {
        let attribute: Attribute
        let op: Operator
        let expected: String
    }

    struct Step: Equatable {
        let axis: Axis
        /// nil == the `*` wildcard.
        let role: String?
        /// ANDed.
        let predicates: [Predicate]
        /// Zero-based, applied to the matches this step produced.
        let index: Int?
    }

    // MARK: - Invalid-path policy

    #if DEBUG
    /// A malformed path is a programmer error, not input, so debug builds trap on it. The
    /// grammar's own tests flip this off to assert the release behaviour (nil / []).
    nonisolated(unsafe) static var trapsOnInvalidPath = true
    #endif

    static func invalid(_ path: String, _ reason: String) -> [Step]? {
        #if DEBUG
        if trapsOnInvalidPath {
            preconditionFailure("AXQuery: malformed path \"\(path)\" — \(reason)")
        }
        #endif
        return nil
    }

    // MARK: - Parsing

    static func parsePath(_ path: String) -> [Step]? {
        guard !path.isEmpty else { return invalid(path, "empty path") }
        guard path.hasPrefix("/") else { return invalid(path, "a path must start with / or //") }
        var chars = Array(path)
        var i = 0
        var steps: [Step] = []
        while i < chars.count {
            guard chars[i] == "/" else { return invalid(path, "expected / at offset \(i)") }
            i += 1
            var axis = Axis.child
            if i < chars.count, chars[i] == "/" {
                axis = .descendant
                i += 1
            }
            // Role token: `*` or an identifier of letters, digits and underscores.
            var role: String? = nil
            if i < chars.count, chars[i] == "*" {
                i += 1
            } else {
                var token = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    token.append(chars[i])
                    i += 1
                }
                guard !token.isEmpty else { return invalid(path, "empty role token at offset \(i)") }
                role = token
            }
            // Bracket groups: `[n]` or `[attr op "value"]`, any number, all ANDed.
            var predicates: [Predicate] = []
            var index: Int? = nil
            while i < chars.count, chars[i] == "[" {
                i += 1
                guard let close = chars[i...].firstIndex(of: "]") else {
                    return invalid(path, "unterminated [")
                }
                let body = String(chars[i..<close])
                i = close + 1
                if body.allSatisfy(\.isNumber), !body.isEmpty {
                    guard index == nil, let n = Int(body) else {
                        return invalid(path, "at most one index per step")
                    }
                    index = n
                } else if let predicate = parsePredicate(body) {
                    predicates.append(predicate)
                } else {
                    return invalid(path, "bad predicate [\(body)]")
                }
            }
            steps.append(Step(axis: axis, role: role, predicates: predicates, index: index))
            // Anything that is not the start of the next step is junk.
            if i < chars.count, chars[i] != "/" { return invalid(path, "trailing junk at offset \(i)") }
        }
        guard !steps.isEmpty else { return invalid(path, "no steps") }
        return steps
    }

    static func parsePredicate(_ body: String) -> Predicate? {
        // Longest operator first so `^=` and `*=` are not read as an attribute ending in ^ or *.
        for op in [Operator.prefix, .contains, .equals] {
            guard let split = body.range(of: op.rawValue) else { continue }
            let name = String(body[..<split.lowerBound])
            let rest = String(body[split.upperBound...])
            guard let attribute = Attribute(rawValue: name) else { return nil }
            guard rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") else { return nil }
            return Predicate(attribute: attribute, op: op,
                             expected: String(rest.dropFirst().dropLast()))
        }
        return nil
    }

    // MARK: - Path cache

    static let pathCacheCapacity = 128

    /// Lock-guarded LRU. Only successful parses are cached; a malformed path is a programmer
    /// error that will be fixed, not a hot path worth remembering.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [Step]] = [:]
        /// Least-recently-used first.
        private var order: [String] = []

        func steps(for path: String, parse: (String) -> [Step]?) -> [Step]? {
            lock.lock()
            if let hit = entries[path] {
                order.removeAll { $0 == path }
                order.append(path)
                lock.unlock()
                return hit
            }
            lock.unlock()
            guard let parsed = parse(path) else { return nil }
            lock.lock()
            entries[path] = parsed
            order.removeAll { $0 == path }
            order.append(path)
            while order.count > AXQuery.pathCacheCapacity {
                entries.removeValue(forKey: order.removeFirst())
            }
            lock.unlock()
            return parsed
        }

        func count() -> Int {
            lock.lock(); defer { lock.unlock() }
            return entries.count
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
            order.removeAll()
        }
    }

    private static let pathCache = PathCache()

    static func steps(for path: String) -> [Step]? {
        pathCache.steps(for: path, parse: parsePath)
    }

    static func cachedPathCount() -> Int { pathCache.count() }

    static func resetPathCache() { pathCache.removeAll() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXQueryPathTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/AXQuery.swift Tests/MaxMiCaptureTests/AXQueryPathTests.swift
git commit -m "Add AXQuery path grammar with a cached parser"
```

---

### Task 3: `AXQuery.find` / `findAll` evaluation

**Files:**
- Modify: `Sources/MaxMiCapture/AXQuery.swift` (append the evaluation section)
- Test: `Tests/MaxMiCaptureTests/AXQueryEvaluationTests.swift`

**Interfaces:**
- Consumes: `AXQuery.Step`/`Predicate`/`Attribute`/`Operator` and `AXQuery.steps(for:)` (Task 2); `AXNode` including `domClassList`/`domIdentifier` (Task 1).
- Produces: `AXQuery.find(_ path: String, in node: AXNode) -> AXNode?`, `AXQuery.findAll(_ path: String, in node: AXNode) -> [AXNode]`, and the internal `AXQuery.attributeValues(_:_:) -> [String]` / `AXQuery.matches(_:_:) -> Bool` used by Task 4's `Matchers`.
- Evaluation order is defined and tested: the current node set starts as `[node]`; a `.child` step expands to each current node's `children` in order; a `.descendant` step expands to each current node's descendants in pre-order **excluding itself**; the step's role and predicates filter the expansion; an `index` then selects one element of that step's filtered output. No de-duplication is performed, because `AXNode` has no identity.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/AXQueryEvaluationTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class AXQueryEvaluationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AXQuery.resetPathCache()
        AXQuery.trapsOnInvalidPath = false
    }

    override func tearDown() {
        AXQuery.trapsOnInvalidPath = true
        AXQuery.resetPathCache()
        super.tearDown()
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil,
              domClassList: [String]? = nil, domIdentifier: String? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
               children: children, identifier: identifier, label: label, subrole: subrole,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: domIdentifier)
    }

    /// AXWindow > AXTable > (AXRow "one", AXRow "two"), plus AXGroup > AXRow "three".
    func tree() -> AXNode {
        node("AXWindow", children: [
            node("AXTable", identifier: "files", children: [
                node("AXRow", value: "one", children: [node("AXStaticText", value: "one-cell")]),
                node("AXRow", value: "two", children: [node("AXStaticText", value: "two-cell")]),
            ]),
            node("AXGroup", identifier: "editor-main", children: [
                node("AXRow", value: "three"),
            ]),
        ])
    }

    func testChildAxisMatchesDirectChildrenOnly() {
        XCTAssertEqual(AXQuery.findAll("/AXRow", in: tree()).count, 0,
                       "rows are grandchildren, not children")
        XCTAssertEqual(AXQuery.findAll("/AXTable/AXRow", in: tree()).map(\.value), ["one", "two"])
    }

    func testDescendantAxisMatchesAtAnyDepthAndExcludesSelf() {
        XCTAssertEqual(AXQuery.findAll("//AXRow", in: tree()).map(\.value), ["one", "two", "three"])
        let row = node("AXRow", value: "self", children: [node("AXRow", value: "nested")])
        XCTAssertEqual(AXQuery.findAll("//AXRow", in: row).map(\.value), ["nested"],
                       "// never matches the node it is evaluated against")
    }

    func testWildcardMatchesAnyRole() {
        XCTAssertEqual(AXQuery.findAll("/*", in: tree()).map(\.role), ["AXTable", "AXGroup"])
        XCTAssertEqual(AXQuery.findAll("//*[domId=\"nope\"]", in: tree()), [])
    }

    func testFindReturnsTheFirstMatchAndNilWhenThereIsNone() {
        XCTAssertEqual(AXQuery.find("//AXRow", in: tree())?.value, "one")
        XCTAssertNil(AXQuery.find("//AXButton", in: tree()))
    }

    func testEqualsPrefixAndContainsOperators() {
        let root = node("AXWindow", children: [
            node("AXGroup", identifier: "workbench.editor.main"),
            node("AXGroup", identifier: "workbench.panel.terminal"),
            node("AXGroup", identifier: "sidebar"),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier=\"sidebar\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier^=\"workbench.\"]", in: root).count, 2)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier*=\"terminal\"]", in: root)
                        .map(\.identifier), ["workbench.panel.terminal"])
    }

    func testPredicatesOnOneStepAreAnded() {
        let root = node("AXWindow", children: [
            node("AXRow", title: "Inbox", subrole: "AXTabButton"),
            node("AXRow", title: "Inbox", subrole: "AXOther"),
            node("AXRow", title: "Sent", subrole: "AXTabButton"),
        ])
        let matches = AXQuery.findAll("/AXRow[subrole=\"AXTabButton\"][title*=\"Inbox\"]", in: root)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].title, "Inbox")
        XCTAssertEqual(matches[0].subrole, "AXTabButton")
    }

    func testIndexSelectsOneMatchAndIsZeroBased() {
        XCTAssertEqual(AXQuery.findAll("//AXRow[0]", in: tree()).map(\.value), ["one"])
        XCTAssertEqual(AXQuery.findAll("//AXRow[2]", in: tree()).map(\.value), ["three"])
        XCTAssertEqual(AXQuery.findAll("//AXRow[9]", in: tree()), [],
                       "an out-of-range index yields no match, never a crash")
    }

    func testIndexAppliesAfterThePredicatesOnTheSameStep() {
        let root = node("AXWindow", children: [
            node("AXRow", value: "a", identifier: "keep"),
            node("AXRow", value: "b", identifier: "drop"),
            node("AXRow", value: "c", identifier: "keep"),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXRow[identifier=\"keep\"][1]", in: root).map(\.value), ["c"])
    }

    func testDescriptionIsAnAliasOfLabel() {
        let root = node("AXWindow", children: [node("AXStaticText", label: "message from Ada")])
        XCTAssertEqual(AXQuery.findAll("/AXStaticText[description*=\"message from\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXStaticText[label*=\"message from\"]", in: root).count, 1)
    }

    func testRoleSubroleTitleValueAndIdentifierAttributesResolve() {
        let root = node("AXWindow", children: [
            node("AXRow", value: "v", title: "t", identifier: "i", subrole: "s"),
        ])
        for path in ["/AXRow[role=\"AXRow\"]", "/AXRow[value=\"v\"]", "/AXRow[title=\"t\"]",
                     "/AXRow[identifier=\"i\"]", "/AXRow[subrole=\"s\"]"] {
            XCTAssertEqual(AXQuery.findAll(path, in: root).count, 1, path)
        }
    }

    func testDomIdMatchesDomIdentifier() {
        let root = node("AXWindow", children: [node("AXGroup", domIdentifier: "msg-1")])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domId=\"msg-1\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domId=\"MSG-1\"]", in: root).count, 0,
                       "domId is case-sensitive")
    }

    func testDomClassMatchesAnyEntryAndIsCaseInsensitive() {
        let root = node("AXWindow", children: [
            node("AXGroup", domClassList: ["p-workspace__primary", "c-virtual_list__item"]),
        ])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"c-virtual_list\"]", in: root).count, 1,
                       "any entry of the class list may satisfy the predicate")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"C-VIRTUAL_LIST\"]", in: root).count, 1,
                       "domClass is the one case-insensitive attribute")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass=\"c-virtual_list__item\"]", in: root).count, 1)
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass^=\"p-workspace\"]", in: root).count, 1)
    }

    func testMissingAttributeNeverMatches() {
        let root = node("AXWindow", children: [node("AXGroup")])
        XCTAssertEqual(AXQuery.findAll("/AXGroup[identifier*=\"\"]", in: root).count, 0,
                       "a node with no identifier matches nothing, not the empty substring")
        XCTAssertEqual(AXQuery.findAll("/AXGroup[domClass*=\"x\"]", in: root).count, 0)
    }

    func testMultiStepDescendantChainsResolveInDocumentOrder()  {
        let root = node("AXWindow", children: [
            node("AXWebArea", children: [
                node("AXGroup", domClassList: ["notion-frame"], children: [
                    node("AXStaticText", value: "first"),
                    node("AXGroup", children: [node("AXStaticText", value: "second")]),
                ]),
            ]),
        ])
        XCTAssertEqual(
            AXQuery.findAll("//AXWebArea//AXGroup[domClass*=\"notion-frame\"]//AXStaticText", in: root)
                .map(\.value),
            ["first", "second"])
    }

    func testInvalidPathYieldsNoMatchesInsteadOfCrashing() {
        XCTAssertEqual(AXQuery.findAll("/AXRow[", in: tree()), [])
        XCTAssertNil(AXQuery.find("bogus", in: tree()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXQueryEvaluationTests`
Expected: FAIL to compile — "type 'AXQuery' has no member 'findAll'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/AXQuery.swift`, inside `public enum AXQuery`:

```swift
    // MARK: - Evaluation

    public static func find(_ path: String, in node: AXNode) -> AXNode? {
        findAll(path, in: node).first
    }

    public static func findAll(_ path: String, in node: AXNode) -> [AXNode] {
        guard let steps = steps(for: path) else { return [] }
        var current = [node]
        for step in steps {
            var produced: [AXNode] = []
            for source in current {
                switch step.axis {
                case .child:
                    produced.append(contentsOf: source.children.filter { satisfies($0, step) })
                case .descendant:
                    // Pre-order, excluding `source` itself: `//Role` is "somewhere below here".
                    appendDescendants(of: source, satisfying: step, into: &produced)
                }
            }
            if let index = step.index {
                current = index >= 0 && index < produced.count ? [produced[index]] : []
            } else {
                current = produced
            }
            if current.isEmpty { return [] }
        }
        return current
    }

    private static func appendDescendants(
        of node: AXNode, satisfying step: Step, into out: inout [AXNode]
    ) {
        for child in node.children {
            if satisfies(child, step) { out.append(child) }
            appendDescendants(of: child, satisfying: step, into: &out)
        }
    }

    static func satisfies(_ node: AXNode, _ step: Step) -> Bool {
        if let role = step.role, node.role != role { return false }
        return step.predicates.allSatisfy { matches(node, $0) }
    }

    /// A predicate is satisfied when ANY of the attribute's values satisfies the operator, so a
    /// multi-entry `domClassList` behaves like a CSS class check.
    static func matches(_ node: AXNode, _ predicate: Predicate) -> Bool {
        let caseInsensitive = predicate.attribute == .domClass
        let expected = caseInsensitive ? predicate.expected.lowercased() : predicate.expected
        for raw in attributeValues(node, predicate.attribute) {
            let actual = caseInsensitive ? raw.lowercased() : raw
            switch predicate.op {
            case .equals: if actual == expected { return true }
            case .prefix: if actual.hasPrefix(expected) { return true }
            case .contains: if actual.contains(expected) { return true }
            }
        }
        return false
    }

    /// An absent attribute yields no values, so it can never satisfy any operator — including
    /// `*=""`, which would otherwise match everything.
    static func attributeValues(_ node: AXNode, _ attribute: Attribute) -> [String] {
        switch attribute {
        case .role:       return [node.role]
        case .subrole:    return node.subrole.map { [$0] } ?? []
        case .title:      return node.title.map { [$0] } ?? []
        // AXDescription is folded into `label` by AXReader, so both names read the same field.
        case .description, .label: return node.label.map { [$0] } ?? []
        case .value:      return node.value.map { [$0] } ?? []
        case .identifier: return node.identifier.map { [$0] } ?? []
        case .domId:      return node.domIdentifier.map { [$0] } ?? []
        case .domClass:   return node.domClassList ?? []
        }
    }
```

`AXNode` is not `Equatable`, and the tests compare `findAll(...)` results against `[]`. Add the conformance next to the struct in `Sources/MaxMiCapture/AXSnapshot.swift` — every stored property is already `Equatable`, so the synthesised implementation is correct and it also makes golden fixture assertions readable:

```swift
extension AXNode: Equatable {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXQueryEvaluationTests`
Expected: PASS, 15 tests.

Run: `swift test --filter AXQueryPathTests`
Expected: PASS, 6 tests (the grammar is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/AXQuery.swift Sources/MaxMiCapture/AXSnapshot.swift \
        Tests/MaxMiCaptureTests/AXQueryEvaluationTests.swift
git commit -m "Evaluate AXQuery paths over AX node trees"
```

---

### Task 4: `Matchers`, visual-order helpers, `collectStaticTexts`, `formatTable`

**Files:**
- Create: `Sources/MaxMiCapture/AXQueryHelpers.swift`
- Test: `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift`

**Interfaces:**
- Consumes: `AXQuery.attributeValues(_:_:)`, `AXQuery.findAll(_:in:)` (Task 3); `Block`, `BlockType` (Phase A `CapturedContent.swift`); `ContentRenderer.renderBlock(_:)` (Phase A).
- Produces: `AXQuery.Matchers.hasRole(_:)`, `.hasIdentifierPrefix(_:)`, `.hasClass(_:)`, `.hasTitleContaining(_:)`, `.and(_:)`, `.or(_:)`, `.not(_:)` — each `(AXNode) -> Bool`; `AXQuery.sortedByVisualOrder(_ nodes: [AXNode], relativeTo origin: CGRect?) -> [AXNode]`; `AXQuery.collectStaticTexts(in: AXNode) -> [String]`; `AXQuery.formatTable(_ row: AXNode) -> Block`; and `AXQuery.first(in: AXNode, where: (AXNode) -> Bool) -> AXNode?` / `AXQuery.all(in: AXNode, where: (AXNode) -> Bool) -> [AXNode]` so a `Matchers` composition can actually be run against a tree.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class AXQueryHelperTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, selected: Bool = false, hidden: Bool = false,
              domClassList: [String]? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
               children: children, identifier: identifier, label: label, subrole: nil,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: hidden, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 80, height: 16))
    }

    // MARK: - Matchers

    func testHasRoleAndHasIdentifierPrefix() {
        let row = node("AXRow", identifier: "workbench.editor.main")
        XCTAssertTrue(AXQuery.Matchers.hasRole("AXRow")(row))
        XCTAssertFalse(AXQuery.Matchers.hasRole("AXTable")(row))
        XCTAssertTrue(AXQuery.Matchers.hasIdentifierPrefix("workbench.")(row))
        XCTAssertFalse(AXQuery.Matchers.hasIdentifierPrefix("sidebar")(row))
        XCTAssertFalse(AXQuery.Matchers.hasIdentifierPrefix("x")(node("AXRow")),
                       "a node with no identifier never matches a prefix")
    }

    func testHasClassMatchesAnyEntryCaseInsensitively() {
        let group = node("AXGroup", domClassList: ["c-message_list", "P-Workspace"])
        XCTAssertTrue(AXQuery.Matchers.hasClass("c-message_list")(group))
        XCTAssertTrue(AXQuery.Matchers.hasClass("p-workspace")(group))
        XCTAssertFalse(AXQuery.Matchers.hasClass("cm-editor")(group))
        XCTAssertFalse(AXQuery.Matchers.hasClass("x")(node("AXGroup")))
    }

    func testHasTitleContaining() {
        XCTAssertTrue(AXQuery.Matchers.hasTitleContaining("Messages in")(
            node("AXList", title: "Messages in general")))
        XCTAssertFalse(AXQuery.Matchers.hasTitleContaining("Messages in")(node("AXList")))
    }

    func testAndOrNotCompose() {
        let row = node("AXRow", title: "Inbox", identifier: "mail.row")
        let isRow = AXQuery.Matchers.hasRole("AXRow")
        let isInbox = AXQuery.Matchers.hasTitleContaining("Inbox")
        let isTable = AXQuery.Matchers.hasRole("AXTable")
        XCTAssertTrue(AXQuery.Matchers.and(isRow, isInbox)(row))
        XCTAssertFalse(AXQuery.Matchers.and(isRow, isTable)(row))
        XCTAssertTrue(AXQuery.Matchers.or(isTable, isInbox)(row))
        XCTAssertFalse(AXQuery.Matchers.or(isTable, AXQuery.Matchers.hasRole("AXCell"))(row))
        XCTAssertTrue(AXQuery.Matchers.not(isTable)(row))
        XCTAssertFalse(AXQuery.Matchers.not(isRow)(row))
    }

    func testAllAndFirstRunAMatcherOverATree() {
        let root = node("AXWindow", children: [
            node("AXGroup", children: [node("AXRow", value: "a"), node("AXRow", value: "b")]),
        ])
        let isRow = AXQuery.Matchers.hasRole("AXRow")
        XCTAssertEqual(AXQuery.all(in: root, where: isRow).map(\.value), ["a", "b"])
        XCTAssertEqual(AXQuery.first(in: root, where: isRow)?.value, "a")
        XCTAssertNil(AXQuery.first(in: root, where: AXQuery.Matchers.hasRole("AXCell")))
    }

    // MARK: - Visual order

    func testVisualOrderSortsByYThenX() {
        let nodes = [text("c", y: 40, x: 0), text("b", y: 10, x: 90), text("a", y: 10, x: 0)]
        XCTAssertEqual(AXQuery.sortedByVisualOrder(nodes, relativeTo: nil).map(\.value),
                       ["a", "b", "c"])
    }

    func testVisualOrderIsTranslationInvariant() {
        // Same layout, once flush at the origin and once on a second display at (1440, 220).
        // AXFrame is global screen coordinates, so the ORDER must not change with the origin.
        let flushWindow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let flush = [text("c", y: 40, x: 0), text("b", y: 10, x: 90), text("a", y: 10, x: 0)]
        let offsetWindow = CGRect(x: 1440, y: 220, width: 800, height: 600)
        let offset = [text("c", y: 260, x: 1440), text("b", y: 230, x: 1530),
                      text("a", y: 230, x: 1440)]
        XCTAssertEqual(AXQuery.sortedByVisualOrder(flush, relativeTo: flushWindow).map(\.value),
                       AXQuery.sortedByVisualOrder(offset, relativeTo: offsetWindow).map(\.value))
        XCTAssertEqual(AXQuery.sortedByVisualOrder(offset, relativeTo: offsetWindow).map(\.value),
                       ["a", "b", "c"])
    }

    func testNodesWithNoFrameSortAheadOfPositionedNodes() {
        let unpositioned = node("AXStaticText", value: "z", frame: nil)
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([text("a", y: 10, x: 0), unpositioned], relativeTo: nil)
                .map(\.value),
            ["z", "a"], "a nil frame is treated as the origin, which sorts first and is stable")
    }

    // MARK: - collectStaticTexts

    func testCollectStaticTextsReturnsVisualOrderTrimmedNonEmptyValues() {
        let row = node("AXRow", children: [
            text("  second  ", y: 20, x: 0),
            text("first", y: 10, x: 0),
            text("   ", y: 30, x: 0),
            node("AXButton", title: "Send", frame: CGRect(x: 0, y: 40, width: 10, height: 10)),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: row), ["first", "second"],
                       "AXStaticText only, trimmed, empties dropped, buttons excluded")
    }

    func testCollectStaticTextsIncludesSelfAndSkipsHiddenAndMenuSubtrees() {
        XCTAssertEqual(AXQuery.collectStaticTexts(in: text("only", y: 0, x: 0)), ["only"])
        let root = node("AXGroup", children: [
            node("AXMenu", children: [text("File", y: 0, x: 0)]),
            node("AXGroup", hidden: true, children: [text("hidden", y: 10, x: 0)]),
            text("kept", y: 20, x: 0),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: root), ["kept"])
    }

    func testCollectStaticTextsDropsAdjacentDuplicates() {
        let row = node("AXRow", children: [
            text("Report.pdf", y: 10, x: 0),
            text("Report.pdf", y: 10, x: 1),
            text("12 KB", y: 10, x: 100),
        ])
        XCTAssertEqual(AXQuery.collectStaticTexts(in: row), ["Report.pdf", "12 KB"])
    }

    // MARK: - formatTable

    func testFormatTableJoinsCellsInVisualOrderAndCarriesSelection() {
        let row = node("AXRow", selected: true,
                       frame: CGRect(x: 1440, y: 300, width: 600, height: 20), children: [
            node("AXCell", frame: CGRect(x: 1740, y: 300, width: 100, height: 20),
                 children: [text("12 KB", y: 300, x: 1740)]),
            node("AXCell", frame: CGRect(x: 1440, y: 300, width: 200, height: 20),
                 children: [text("Report.pdf", y: 300, x: 1440)]),
        ])
        let block = AXQuery.formatTable(row)
        XCTAssertEqual(block.type, .tableRow(cells: ["Report.pdf", "12 KB"], selected: true))
        XCTAssertEqual(block.text, "Report.pdf 12 KB")
        XCTAssertFalse(block.authoredByUser)
        XCTAssertEqual(ContentRenderer.renderBlock(block), "* Report.pdf | 12 KB")
    }

    func testFormatTableOnARowWithNoCellTextYieldsAnEmptyRow() {
        let block = AXQuery.formatTable(node("AXRow"))
        XCTAssertEqual(block.type, .tableRow(cells: [], selected: false))
        XCTAssertEqual(block.text, "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXQueryHelperTests`
Expected: FAIL to compile — "type 'AXQuery' has no member 'Matchers'".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/AXQueryHelpers.swift`:

```swift
import Foundation
import MaxMiCore

public extension AXQuery {
    /// Composable predicates for the cases a path literal cannot express — an OR across two
    /// attributes, or a check a parser wants to reuse at several depths.
    enum Matchers {
        public static func hasRole(_ r: String) -> (AXNode) -> Bool {
            { $0.role == r }
        }

        public static func hasIdentifierPrefix(_ p: String) -> (AXNode) -> Bool {
            { ($0.identifier ?? "").hasPrefix(p) && $0.identifier != nil }
        }

        /// Case-insensitive, matching the `domClass` predicate.
        public static func hasClass(_ c: String) -> (AXNode) -> Bool {
            let needle = c.lowercased()
            return { ($0.domClassList ?? []).contains { $0.lowercased() == needle } }
        }

        public static func hasTitleContaining(_ s: String) -> (AXNode) -> Bool {
            { ($0.title ?? "").contains(s) && $0.title != nil }
        }

        public static func and(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool {
            { node in ms.allSatisfy { $0(node) } }
        }

        public static func or(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool {
            { node in ms.contains { $0(node) } }
        }

        public static func not(_ m: @escaping (AXNode) -> Bool) -> (AXNode) -> Bool {
            { !m($0) }
        }
    }

    /// Pre-order descendants (including `root`) satisfying `match`.
    static func all(in root: AXNode, where match: (AXNode) -> Bool) -> [AXNode] {
        var out: [AXNode] = []
        func visit(_ node: AXNode) {
            if match(node) { out.append(node) }
            for child in node.children { visit(child) }
        }
        visit(root)
        return out
    }

    static func first(in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        all(in: root, where: match).first
    }

    /// Sorts by (minY, minX). `AXFrame` is global screen coordinates, so `origin` is subtracted
    /// first: the ORDER of the same layout must not depend on which display the window is on.
    static func sortedByVisualOrder(_ nodes: [AXNode], relativeTo origin: CGRect?) -> [AXNode] {
        let ox = origin?.minX ?? 0
        let oy = origin?.minY ?? 0
        return nodes.enumerated().sorted { lhs, rhs in
            let ly = (lhs.element.frame?.minY ?? oy) - oy
            let ry = (rhs.element.frame?.minY ?? oy) - oy
            if ly != ry { return ly < ry }
            let lx = (lhs.element.frame?.minX ?? ox) - ox
            let rx = (rhs.element.frame?.minX ?? ox) - ox
            if lx != rx { return lx < rx }
            // Stable: equal positions keep their input order.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Static-text values under `node` (including `node` itself) in visual order, trimmed,
    /// empties dropped, adjacent duplicates collapsed. Menu and hidden subtrees are excluded.
    static func collectStaticTexts(in node: AXNode) -> [String] {
        var found: [AXNode] = []
        func visit(_ current: AXNode) {
            if menuRoles.contains(current.role) || current.hidden { return }
            if current.role == "AXStaticText" { found.append(current) }
            for child in current.children { visit(child) }
        }
        visit(node)
        let ordered = sortedByVisualOrder(found, relativeTo: node.frame)
            .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ordered.reduce(into: [String]()) { result, value in
            if result.last != value { result.append(value) }
        }
    }

    /// One AX row becomes ONE joined table row. `text` is the space-joined form, so delta and
    /// dedup can compare rows as text while `ContentRenderer` renders from `cells`.
    static func formatTable(_ row: AXNode) -> Block {
        var cellNodes: [AXNode] = []
        func visit(_ current: AXNode) {
            if menuRoles.contains(current.role) || current.hidden { return }
            if current.role == "AXCell" || current.role == "AXStaticText" {
                cellNodes.append(current)
                if current.role == "AXCell" { return }
            }
            for child in current.children { visit(child) }
        }
        for child in row.children { visit(child) }
        let cells = sortedByVisualOrder(cellNodes, relativeTo: row.frame)
            .map { cell -> String in
                cell.role == "AXCell"
                    ? collectStaticTexts(in: cell).joined(separator: " ")
                    : (cell.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if result.last != value { result.append(value) }
            }
        return Block(type: .tableRow(cells: cells, selected: row.selected),
                     text: cells.joined(separator: " "),
                     authoredByUser: false)
    }

    /// Menu content is structurally excluded from every helper, not filtered by text.
    static var menuRoles: Set<String> { ["AXMenuBar", "AXMenuBarItem", "AXMenu"] }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXQueryHelperTests`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/AXQueryHelpers.swift Tests/MaxMiCaptureTests/AXQueryHelperTests.swift
git commit -m "Add AXQuery matchers, visual order and table helpers"
```

---

### Task 5: `StructuredParser` v2, `ParserConfig`, `ParseContext` and registry routing

**Files:**
- Create: `Sources/MaxMiCapture/StructuredParser.swift`
- Create: `Sources/MaxMiCapture/StructuredParserRouting.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (new bundle-ID constants; the two new maps)
- Test: `Tests/MaxMiCaptureTests/StructuredParserRoutingTests.swift`

**Interfaces:**
- Consumes: `AppInfo` (`Sources/MaxMiCapture/SourceParser.swift:4`); `OffscreenCapturePolicy` (`Sources/MaxMiCore/CaptureEnvelope.swift:31`); `EpochMs` (`Sources/MaxMiCore/HourBucket.swift:3`); `CapturedContent`, `GenericPage`, `Region`, `RegionKind`, `Block` (Phase A); `GenericPageExtractor.extract(window:focusedElement:url:options:)` (Phase A).
- Produces:
  - `ParserConfig(app:bundleIDs:hosts:attributeSet:offscreenPolicy:preferOverNative:minAppVersion:)` — `public`, `Sendable`, `Equatable`, with `hosts: [String] = []`, `attributeSet: [String] = []`, `offscreenPolicy: OffscreenCapturePolicy = .visibleOnly()`, `preferOverNative: Bool = false`, `minAppVersion: String? = nil`.
  - `ParseContext(app:windowTitle:url:previousStructured:now:)` — `public`, `Sendable`, plus the convenience `init(app: AppInfo, url: String? = nil, previousStructured: CapturedContent? = nil, now: EpochMs = EpochMs(Date().timeIntervalSince1970 * 1000))` that defaults `windowTitle` to `app.windowTitle`.
  - `protocol StructuredParser: Sendable { static var config: ParserConfig { get }; func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? }`.
  - `ParserRegistry.structuredParser(for bundleID: String) -> (any StructuredParser)?`, `.structuredParser(forHost host: String) -> (any StructuredParser)?`, `.structuredParser(bundleID: String, url: String?) -> (any StructuredParser)?`, `.forcedAttributes(for bundleID: String) -> Set<String>`, `.registeredStructuredHosts: [String]`.
  - `ParserRegistry.host(fromURL: String?) -> String?`.
  - `CaptureDispatch.StructuredParseResult` (`.parsed(CapturedContent, parserName: String)`, `.fellThrough(CapturedContent, notHandledBy: String?)`) and `CaptureDispatch.structuredCapture(window:context:registry:) -> StructuredParseResult`.
  - `CaptureDispatch.fallbackParserID(notHandledBy: String?) -> String` producing exactly `"GenericPageExtractor.v2/fallback/<ParserTypeName>"`, or `"GenericPageExtractor.v2"` when no parser claimed the window (§8). If the Phase A plan already added a helper producing this same literal, call that one instead of adding a second.
  - `ParserRegistry.finderBundleID = "com.apple.finder"`, `.cursorBundleID = "com.todesktop.230313mzl4w4u92"`, `.vsCodeBundleID = "com.microsoft.VSCode"`, `.editorBundleIDs = [cursorBundleID, vsCodeBundleID]`.
- Later tasks register their parser by adding it to `structuredParsers` / `hostParsers` in `ParserRegistry.init`; the maps are built there so there is one registration site, exactly as the existing `parsers` map is.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/StructuredParserRoutingTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Claims the fake native app and always answers.
struct StubNativeParser: StructuredParser {
    static let config = ParserConfig(app: "StubNative", bundleIDs: ["com.example.native"],
                                     attributeSet: ["AXDOMClassList"])
    func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        .document(Document(title: "native", blocks: [], author: .unknown, url: nil))
    }
}

/// Claims a host and never answers, so the fall-through path is exercised.
struct StubSilentHostParser: StructuredParser {
    static let config = ParserConfig(app: "StubSilent", bundleIDs: [],
                                     hosts: ["silent.example.com"])
    func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? { nil }
}

final class StructuredParserRoutingTests: XCTestCase {
    func window(_ text: String = "body") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: "W", url: nil,
               frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
               children: [AXNode(role: "AXStaticText", value: text, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 100, height: 16),
                                 focused: false, children: [])])
    }

    func context(bundleID: String, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "App", windowTitle: "W"), url: url)
    }

    // MARK: - Config defaults

    func testParserConfigDefaults() {
        let config = ParserConfig(app: "X", bundleIDs: ["a"])
        XCTAssertEqual(config.hosts, [])
        XCTAssertEqual(config.attributeSet, [])
        XCTAssertEqual(config.offscreenPolicy, .visibleOnly())
        XCTAssertFalse(config.preferOverNative)
        XCTAssertNil(config.minAppVersion)
    }

    func testParseContextConvenienceInitTakesWindowTitleFromTheApp() {
        let ctx = ParseContext(app: AppInfo(bundleID: "b", name: "App", windowTitle: "Title"))
        XCTAssertEqual(ctx.windowTitle, "Title")
        XCTAssertNil(ctx.url)
        XCTAssertNil(ctx.previousStructured)
    }

    // MARK: - Host extraction

    func testHostFromURLIsLowercasedAndNilSafe() {
        XCTAssertEqual(ParserRegistry.host(fromURL: "https://App.Slack.com/client/T1"), "app.slack.com")
        XCTAssertNil(ParserRegistry.host(fromURL: nil))
        XCTAssertNil(ParserRegistry.host(fromURL: "not a url"))
    }

    // MARK: - Registry routing

    func testStructuredParserResolvesByBundleID() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        XCTAssertTrue(registry.structuredParser(for: "com.example.native") is StubNativeParser)
        XCTAssertNil(registry.structuredParser(for: "com.example.unknown"))
    }

    func testStructuredParserResolvesByExactHostAndBySuffixEntry() {
        struct SuffixHostParser: StructuredParser {
            static let config = ParserConfig(app: "Suffix", bundleIDs: [],
                                             hosts: ["app.slack.com", ".slack.com"])
            func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
                .generic(GenericPage(regions: [], focused: nil, url: nil))
            }
        }
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [SuffixHostParser()])
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SuffixHostParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SuffixHostParser,
                      "a leading-dot entry means suffix match")
        XCTAssertNil(registry.structuredParser(forHost: "slackalike.com"))
    }

    func testPreferOverNativeDecidesTheOrderBetweenHostAndNative() {
        struct EagerHostParser: StructuredParser {
            static let config = ParserConfig(app: "Eager", bundleIDs: [],
                                             hosts: ["eager.example.com"], preferOverNative: true)
            func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
                .document(Document(title: "host", blocks: [], author: .unknown, url: nil))
            }
        }
        struct PoliteHostParser: StructuredParser {
            static let config = ParserConfig(app: "Polite", bundleIDs: [],
                                             hosts: ["polite.example.com"], preferOverNative: false)
            func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
                .document(Document(title: "host", blocks: [], author: .unknown, url: nil))
            }
        }
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()],
                                      hostParsers: [EagerHostParser(), PoliteHostParser()])
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.native", url: "https://eager.example.com/a") is EagerHostParser)
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.native", url: "https://polite.example.com/a") is StubNativeParser,
            "without preferOverNative the native parser keeps the window")
        XCTAssertTrue(registry.structuredParser(
            bundleID: "com.example.other", url: "https://polite.example.com/a") is PoliteHostParser,
            "with no native claim the host parser is used regardless")
    }

    func testForcedAttributesComeFromTheClaimingParsersConfig() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.native"), ["AXDOMClassList"])
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.unknown"), [])
    }

    func testTheRealRegistryExposesItsStructuredHosts() {
        // Every host entry must be lowercase, or the lookup can never hit it.
        for host in ParserRegistry().registeredStructuredHosts {
            XCTAssertEqual(host, host.lowercased(), "host entry \(host) must be lowercase")
        }
    }

    // MARK: - Dispatch

    func testAClaimingParserReturnsItsContentAndItsTypeName() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        let result = CaptureDispatch.structuredCapture(
            window: window(), context: context(bundleID: "com.example.native"), registry: registry)
        guard case .parsed(let content, let parserName) = result else {
            return XCTFail("expected .parsed, got \(result)")
        }
        XCTAssertEqual(content, .document(Document(title: "native", blocks: [],
                                                   author: .unknown, url: nil)))
        XCTAssertEqual(parserName, "StubNativeParser")
    }

    func testAParserReturningNilFallsThroughToGenericPageExtractorAndNamesItself() {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [StubSilentHostParser()])
        let result = CaptureDispatch.structuredCapture(
            window: window("real body"),
            context: context(bundleID: "com.example.browser", url: "https://silent.example.com/x"),
            registry: registry)
        guard case .fellThrough(let content, let notHandledBy) = result else {
            return XCTFail("expected .fellThrough, got \(result)")
        }
        XCTAssertEqual(notHandledBy, "StubSilentHostParser")
        guard case .generic(let page) = content else { return XCTFail("expected .generic") }
        XCTAssertEqual(page.url, "https://silent.example.com/x")
        XCTAssertEqual(page.regions.first?.blocks.map(\.text), ["real body"])
        XCTAssertEqual(CaptureDispatch.fallbackParserID(notHandledBy: notHandledBy),
                       "GenericPageExtractor.v2/fallback/StubSilentHostParser")
    }

    func testNoRegisteredParserAlsoFallsThroughButNamesNoParser() {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [])
        let result = CaptureDispatch.structuredCapture(
            window: window("plain"), context: context(bundleID: "com.example.nothing"),
            registry: registry)
        guard case .fellThrough(_, let notHandledBy) = result else {
            return XCTFail("expected .fellThrough, got \(result)")
        }
        XCTAssertNil(notHandledBy)
        XCTAssertEqual(CaptureDispatch.fallbackParserID(notHandledBy: nil),
                       "GenericPageExtractor.v2")
    }

    func testFallThroughUsesTheClaimingParsersOffscreenPolicyBudget() {
        struct BoundedSilentParser: StructuredParser {
            static let config = ParserConfig(app: "Bounded", bundleIDs: ["com.example.bounded"],
                                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
            func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? { nil }
        }
        let registry = ParserRegistry(structuredParsers: [BoundedSilentParser()], hostParsers: [])
        // A node far below the window is only collected under an accessibilityScroll policy.
        let win = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                         children: [AXNode(role: "AXStaticText", value: "far below", title: nil,
                                           url: nil,
                                           frame: CGRect(x: 0, y: 9_000, width: 100, height: 16),
                                           focused: false, children: [])])
        let result = CaptureDispatch.structuredCapture(
            window: win, context: context(bundleID: "com.example.bounded"), registry: registry)
        guard case .fellThrough(.generic(let page), _) = result else {
            return XCTFail("expected a generic fall-through, got \(result)")
        }
        XCTAssertEqual(page.regions.first?.blocks.map(\.text), ["far below"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StructuredParserRoutingTests`
Expected: FAIL to compile — "cannot find type 'StructuredParser' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/StructuredParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Per-parser declaration: which app it claims, which browser hosts it claims, which extra AX
/// attributes it needs, and how it wants off-screen content bounded.
public struct ParserConfig: Sendable, Equatable {
    public let app: String
    public let bundleIDs: [String]
    /// Browser hosts this parser claims. A leading-dot entry (".slack.com") is a suffix match.
    public let hosts: [String]
    /// Extra AX attribute names `AXReader` must fetch for this app. Only "AXDOMClassList" and
    /// "AXDOMIdentifier" are honoured today; they bypass the AXWebArea gate for Electron trees.
    public let attributeSet: [String]
    public let offscreenPolicy: OffscreenCapturePolicy
    /// For browser hosts: beat the generic web path (and any native claim on the same window).
    public let preferOverNative: Bool
    public let minAppVersion: String?

    public init(
        app: String,
        bundleIDs: [String],
        hosts: [String] = [],
        attributeSet: [String] = [],
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly(),
        preferOverNative: Bool = false,
        minAppVersion: String? = nil
    ) {
        self.app = app
        self.bundleIDs = bundleIDs
        self.hosts = hosts
        self.attributeSet = attributeSet
        self.offscreenPolicy = offscreenPolicy
        self.preferOverNative = preferOverNative
        self.minAppVersion = minAppVersion
    }
}

/// Everything a structured parser is allowed to know beyond the AX tree.
public struct ParseContext: Sendable {
    public let app: AppInfo
    public let windowTitle: String?
    public let url: String?
    public let previousStructured: CapturedContent?
    public let now: EpochMs

    public init(app: AppInfo, windowTitle: String?, url: String?,
                previousStructured: CapturedContent?, now: EpochMs) {
        self.app = app
        self.windowTitle = windowTitle
        self.url = url
        self.previousStructured = previousStructured
        self.now = now
    }

    /// Convenience for the `SourceParser.parseStructured(window:app:)` bridges, where the only
    /// thing known beyond `AppInfo` is sometimes a URL.
    public init(app: AppInfo, url: String? = nil, previousStructured: CapturedContent? = nil,
                now: EpochMs = EpochMs(Date().timeIntervalSince1970 * 1000)) {
        self.init(app: app, windowTitle: app.windowTitle, url: url,
                  previousStructured: previousStructured, now: now)
    }
}

/// Parser protocol v2. `nil` means NOT_HANDLED and routes to `GenericPageExtractor` (spec §4f
/// rule 3) — it is never an error and never a lost capture. Thread keys and accumulation
/// policies stay on `SourceParser.parse` (spec §4f rule 1), so this protocol owns content only.
public protocol StructuredParser: Sendable {
    static var config: ParserConfig { get }
    func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?
}
```

Create `Sources/MaxMiCapture/StructuredParserRouting.swift`:

```swift
import Foundation
import MaxMiCore

public extension ParserRegistry {
    static func host(fromURL url: String?) -> String? {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    func structuredParser(for bundleID: String) -> (any StructuredParser)? {
        structuredParsers[bundleID]
    }

    func structuredParser(forHost host: String) -> (any StructuredParser)? {
        let host = host.lowercased()
        if let exact = hostParsers[host] { return exact }
        // A ".slack.com" entry claims every subdomain, mirroring WebAppCaptureParser.classify.
        for (pattern, parser) in hostParsers.sorted(by: { $0.key.count > $1.key.count })
        where pattern.hasPrefix(".") && host.hasSuffix(pattern) {
            return parser
        }
        return nil
    }

    /// A host parser with `preferOverNative` beats a native claim; otherwise native wins and a
    /// host parser is the last resort.
    func structuredParser(bundleID: String, url: String?) -> (any StructuredParser)? {
        let hostParser = Self.host(fromURL: url).flatMap { structuredParser(forHost: $0) }
        if let hostParser, type(of: hostParser).config.preferOverNative { return hostParser }
        if let native = structuredParsers[bundleID] { return native }
        return hostParser
    }

    func forcedAttributes(for bundleID: String) -> Set<String> {
        guard let parser = structuredParsers[bundleID] else { return [] }
        return Set(type(of: parser).config.attributeSet)
    }

    var registeredStructuredHosts: [String] { hostParsers.keys.sorted() }
}

public extension CaptureDispatch {
    enum StructuredParseResult: Sendable, Equatable {
        case parsed(CapturedContent, parserName: String)
        /// `GenericPageExtractor` output. `notHandledBy` names the registered parser that
        /// returned nil, or is nil when no parser claimed the window at all.
        case fellThrough(CapturedContent, notHandledBy: String?)
    }

    /// Spec §8: the fall-through is not silent — `capture_health_events.parser` carries the
    /// marker, so the Capture Health window shows which parsers are degrading.
    static func fallbackParserID(notHandledBy: String?) -> String {
        guard let notHandledBy else { return "GenericPageExtractor.v2" }
        return "GenericPageExtractor.v2/fallback/\(notHandledBy)"
    }

    static func structuredCapture(
        window: AXNode,
        context: ParseContext,
        registry: ParserRegistry
    ) -> StructuredParseResult {
        let parser = registry.structuredParser(bundleID: context.app.bundleID, url: context.url)
        let parserName = parser.map { String(describing: type(of: $0)) }
        if let parser, let content = parser.parse(window, context: context) {
            return .parsed(content, parserName: parserName ?? "unknown")
        }
        var options = GenericPageExtractor.Options()
        if let parser { options.offscreenPolicy = type(of: parser).config.offscreenPolicy }
        let extracted = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: context.url, options: options
        )
        return .fellThrough(.generic(extracted.page), notHandledBy: parserName)
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, add the new bundle-ID constants next to the existing ones:

```swift
    public static let finderBundleID = "com.apple.finder"
    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    public static let vsCodeBundleID = "com.microsoft.VSCode"
    public static let editorBundleIDs = [cursorBundleID, vsCodeBundleID]
```

add the two maps as stored properties next to `parsers`:

```swift
    let structuredParsers: [String: any StructuredParser]
    let hostParsers: [String: any StructuredParser]
```

At the end of the existing `init()`, before `parsers = p`, build them from each parser's own config so there is exactly one registration list. Later tasks append to `structured`:

```swift
        // Structured (v2) parsers. Each one declares the bundle IDs and hosts it claims, so the
        // two maps below are derived, never hand-maintained in parallel with the list.
        let structured: [any StructuredParser] = []
        var byBundle: [String: any StructuredParser] = [:]
        var byHost: [String: any StructuredParser] = [:]
        for parser in structured {
            let config = type(of: parser).config
            for bundleID in config.bundleIDs { byBundle[bundleID] = parser }
            for host in config.hosts { byHost[host.lowercased()] = parser }
        }
        structuredParsers = byBundle
        hostParsers = byHost
```

and add the test-only initializer immediately after `init()`:

```swift
    /// Routing tests build a registry with exactly the parsers under test, so a future
    /// registration cannot silently change what a routing assertion is measuring.
    init(structuredParsers: [any StructuredParser], hostParsers: [any StructuredParser]) {
        parsers = [:]
        var byBundle: [String: any StructuredParser] = [:]
        var byHost: [String: any StructuredParser] = [:]
        for parser in structuredParsers {
            for bundleID in type(of: parser).config.bundleIDs { byBundle[bundleID] = parser }
        }
        for parser in hostParsers {
            for host in type(of: parser).config.hosts { byHost[host.lowercased()] = parser }
        }
        self.structuredParsers = byBundle
        self.hostParsers = byHost
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StructuredParserRoutingTests`
Expected: PASS, 12 tests.

Run: `swift test --filter ParserRegistryTests`
Expected: PASS, unchanged — the existing `SourceParser` map is untouched.

- [ ] **Step 5: Wire the dispatch into `AppWiring`**

In `Sources/MaxMi/AppWiring.swift`, the non-browser branch at `:1479` currently switches on `CaptureDispatch.parseDetailed(window:app:registry:)`. Build the context once above the `do` block, right after `appInfo` is constructed at `:1436-1438`:

```swift
            let parseContext = ParseContext(app: appInfo, url: nil)
```

and add a structured attempt ahead of the existing switch, so a v2 parser claims the window before the v1 path runs:

```swift
                // Structured (v2) routing first: a v2 parser owns the content, the v1 parser
                // still owns the thread key and the policies (spec §4f rule 1).
                switch CaptureDispatch.structuredCapture(
                    window: window, context: parseContext, registry: registry
                ) {
                case .parsed(_, let parserName):
                    effectiveParserName = parserName
                case .fellThrough(_, let notHandledBy) where notHandledBy != nil:
                    effectiveParserName = CaptureDispatch.fallbackParserID(notHandledBy: notHandledBy)
                case .fellThrough:
                    break
                }
```

`parsed` (the `ParsedCapture`) still comes from `CaptureDispatch.parseDetailed`, whose Phase A implementation already attaches `structured` from `parseStructured`. This step only makes the **parser name** in the health ledger reflect v2 routing, which is what §8 asks for.

- [ ] **Step 6: Run the capture and store suites**

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS.

Run: `swift build`
Expected: build succeeds with zero warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/StructuredParser.swift \
        Sources/MaxMiCapture/StructuredParserRouting.swift \
        Sources/MaxMiCapture/ParserRegistry.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiCaptureTests/StructuredParserRoutingTests.swift
git commit -m "Route captures through structured parsers by bundle id and host"
```

---

### Task 6: Fixture tooling — `tools/ax-snapshot-record.swift` and one shared loader

**Files:**
- Create: `tools/ax-snapshot-record.swift`
- Create: `Tests/MaxMiCaptureTests/FixtureLoading.swift`
- Create: `Tests/MaxMiCaptureTests/FixtureLoadingTests.swift`
- Create: `Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json`
- Modify: `Tests/MaxMiCaptureTests/ExtractorTests.swift:5-8`, `BrowserCapturePipelineTests.swift:6-9`, `NativeConversationParserTests.swift:5-8`, `GenericAXParserTests.swift:5-8`, `SlackParserTests.swift:5-8`, `StructuredNativeParserTests.swift:5-8` (delete each duplicated `func fixture(_:)`)
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md` (recording + scrubbing procedure)

**Interfaces:**
- Consumes: `AXNode` with `domClassList`/`domIdentifier` (Task 1); `CapturedContent` and `CapturedContentEnvelope` (Phase A).
- Produces, all at file scope in `MaxMiCaptureTests` so every test file sees them without inheritance: `func fixture(_ name: String) throws -> AXNode`, `func goldenCapturedContent(_ name: String) throws -> CapturedContent`, `func assertGolden(_ content: CapturedContent, matches name: String, file: StaticString, line: UInt)`, and `func goldenJSON(_ content: CapturedContent) throws -> String` (used to *write* a golden the first time).
- The six existing test classes keep calling `try fixture("slack-window")` unchanged — the free function shadows nothing and resolves identically at each call site once the methods are deleted.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/FixtureLoadingTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class FixtureLoadingTests: XCTestCase {
    func testLoadsAnAXFixture() throws {
        XCTAssertEqual(try fixture("slack-window").role, "AXWindow")
    }

    func testMissingFixtureFailsLoudly() {
        XCTAssertThrowsError(try fixture("definitely-not-a-fixture"))
    }

    func testGoldenRoundTripsThroughTheEnvelope() throws {
        let content = CapturedContent.document(
            Document(title: "Note", blocks: [Block(type: .paragraph, text: "line",
                                                   authoredByUser: false)],
                     author: .user, url: nil))
        let json = try goldenJSON(content)
        XCTAssertEqual(CapturedContentEnvelope.decode(json), content)
    }

    func testAssertGoldenPassesForAMatchingGolden() throws {
        // Fixtures/generic-empty-golden.json is the smallest possible golden: an empty page.
        assertGolden(.generic(GenericPage(regions: [], focused: nil, url: nil)),
                     matches: "generic-empty-golden")
    }
}
```

Create `Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json` by printing `try goldenJSON(.generic(GenericPage(regions: [], focused: nil, url: nil)))` once Step 3 is in place; its content is the deterministic envelope for an empty generic page, so it doubles as a check that Phase A's encoder is stable.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FixtureLoadingTests`
Expected: FAIL to compile — "cannot find 'goldenJSON' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Tests/MaxMiCaptureTests/FixtureLoading.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// The one AX fixture loader (spec §7d: six duplicated copies consolidated into this file).
func fixture(_ name: String) throws -> AXNode {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture Fixtures/\(name).json"
    )
    return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
}

/// A golden `CapturedContent`, stored as a `CapturedContentEnvelope` JSON string so the file on
/// disk is exactly what the store would persist.
func goldenCapturedContent(_ name: String) throws -> CapturedContent {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing golden Fixtures/\(name).json"
    )
    let json = try String(contentsOf: url, encoding: .utf8)
    return try XCTUnwrap(CapturedContentEnvelope.decode(json),
                         "Fixtures/\(name).json is not a CapturedContentEnvelope")
}

/// Deterministic bytes for a `CapturedContent`, for writing a golden the first time:
/// `print(try goldenJSON(content))`, hand-scrub it, then save it as the golden file.
func goldenJSON(_ content: CapturedContent) throws -> String {
    try CapturedContentEnvelope.encode(content)
}

func assertGolden(
    _ content: CapturedContent,
    matches name: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let expected = try goldenCapturedContent(name)
        XCTAssertEqual(content, expected, "golden \(name) mismatch", file: file, line: line)
        if content != expected {
            // Printed on failure only, so a drifting parser is one copy-paste away from a fix.
            print("--- actual \(name) ---\n\((try? goldenJSON(content)) ?? "<unencodable>")")
        }
    } catch {
        XCTFail("golden \(name) unavailable: \(error)", file: file, line: line)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FixtureLoadingTests`
Expected: PASS, 4 tests. `testAssertGoldenPassesForAMatchingGolden` fails first with "missing golden Fixtures/generic-empty-golden.json"; print `try goldenJSON(.generic(GenericPage(regions: [], focused: nil, url: nil)))`, save the printed string as that file, and re-run.

- [ ] **Step 5: Delete the six duplicated loaders**

Delete this exact method from each of `Tests/MaxMiCaptureTests/ExtractorTests.swift`, `BrowserCapturePipelineTests.swift`, `NativeConversationParserTests.swift`, `GenericAXParserTests.swift`, `SlackParserTests.swift`, `StructuredNativeParserTests.swift`:

```swift
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
```

Every call site keeps its exact spelling (`try fixture("slack-window")`) and now resolves to the free function.

- [ ] **Step 6: Write the recorder**

Create `tools/ax-snapshot-record.swift`:

```swift
#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

// Records the focused window of a running app as a Codable AXNode JSON fixture, using the same
// budgets as AXReader.snapshotFrontmostWindow (maxNodes 20_000, maxDepth 40) so a fixture is a
// faithful stand-in for a live capture.
//
// THE OUTPUT IS NOT COMMITTABLE AS-IS. Per Tests/MaxMiCaptureTests/Fixtures/README.md every
// recorded fixture must be hand-scrubbed first: no real page text, messages, file contents,
// URLs, names, or tokens. Keep only the minimum role/frame/DOM structure the test needs.

let maximumNodes = 20_000
let maximumDepth = 40

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: ax-snapshot-record.swift <bundle-id> <out.json>\n".utf8))
    exit(2)
}
let bundleID = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write(Data("application is not running\n".utf8))
    exit(3)
}

let application = AXUIElementCreateApplication(app.processIdentifier)
// Chromium/Electron apps keep their AX tree dormant until an assistive client asks for it.
AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.4)

guard let windowRef = copyAttribute(application, kAXFocusedWindowAttribute as String)
        ?? copyAttribute(application, "AXMainWindow")
        ?? (copyAttribute(application, kAXChildrenAttribute as String) as? [AXUIElement])?.first else {
    FileHandle.standardError.write(Data("focused window is unavailable\n".utf8))
    exit(4)
}

let textEntryRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
var budget = maximumNodes

/// Mirrors AXNode's own coding keys, so the output decodes straight into AXNode.
func encode(_ element: AXUIElement, depth: Int, inWebArea: Bool) -> [String: Any] {
    budget -= 1
    let role = (copyAttribute(element, kAXRoleAttribute as String) as? String) ?? "?"
    let rawValue = copyAttribute(element, kAXValueAttribute as String)
    let subrole = copyAttribute(element, kAXSubroleAttribute as String) as? String
    let readsDOM = inWebArea || role == "AXWebArea"
    var node: [String: Any] = [
        "role": role,
        "focused": (copyAttribute(element, kAXFocusedAttribute as String) as? Bool) ?? false,
        "selected": (copyAttribute(element, kAXSelectedAttribute as String) as? Bool) ?? false,
        "hidden": (copyAttribute(element, "AXHidden") as? Bool) ?? false,
    ]
    // A secure field's value is never read, not even by the recorder.
    if subrole != "AXSecureTextField",
       let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue {
        node["value"] = value
    }
    if let title = copyAttribute(element, kAXTitleAttribute as String) as? String {
        node["title"] = title
    }
    if let identifier = copyAttribute(element, kAXIdentifierAttribute as String) as? String {
        node["identifier"] = identifier
    }
    if let label = (copyAttribute(element, kAXDescriptionAttribute as String) as? String)
        ?? (copyAttribute(element, kAXHelpAttribute as String) as? String) {
        node["label"] = label
    }
    if let subrole { node["subrole"] = subrole }
    if let url = (copyAttribute(element, "AXURL") as? URL)?.absoluteString
        ?? (copyAttribute(element, "AXURL") as? String)
        ?? (copyAttribute(element, "AXDocument") as? String) {
        node["url"] = url
    }
    if role == "AXHeading",
       let level = (copyAttribute(element, "AXHeadingLevel") as? NSNumber)?.intValue {
        node["headingLevel"] = level
    }
    if textEntryRoles.contains(role) {
        if let placeholder = copyAttribute(element, kAXPlaceholderValueAttribute as String) as? String {
            node["placeholder"] = placeholder
        }
        if subrole != "AXSecureTextField",
           let selectedText = copyAttribute(element, kAXSelectedTextAttribute as String) as? String {
            node["selectedText"] = selectedText
        }
    }
    if readsDOM {
        if let classList = copyAttribute(element, "AXDOMClassList") as? [String] {
            node["domClassList"] = classList
        }
        if let domID = copyAttribute(element, "AXDOMIdentifier") as? String {
            node["domIdentifier"] = domID
        }
    }
    if let frameValue = copyAttribute(element, "AXFrame") {
        var rect = CGRect.zero
        if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) {
            node["frame"] = ["x": rect.minX, "y": rect.minY,
                             "width": rect.width, "height": rect.height]
        }
    }
    var children: [[String: Any]] = []
    if depth < maximumDepth, budget > 0,
       let kids = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for kid in kids {
            if budget <= 0 { break }
            children.append(encode(kid, depth: depth + 1, inWebArea: readsDOM))
        }
    }
    node["children"] = children
    return node
}

let tree = encode(windowRef as! AXUIElement, depth: 0, inWebArea: false)
let data = try JSONSerialization.data(withJSONObject: tree,
                                      options: [.prettyPrinted, .sortedKeys,
                                                .withoutEscapingSlashes])
try data.write(to: URL(fileURLWithPath: outputPath))
FileHandle.standardError.write(Data("""
wrote \(outputPath) (\(maximumNodes - budget) nodes)
HAND-SCRUB IT before committing: no real page text, messages, file contents, URLs, names or tokens.
""".utf8))
```

Make it executable:

```bash
chmod +x tools/ax-snapshot-record.swift
```

- [ ] **Step 7: Document the procedure**

Replace the final line of `Tests/MaxMiCaptureTests/Fixtures/README.md` ("Never commit real page text…") with:

```markdown
Never commit real page text, messages, file contents, URLs, names, or tokens. Preserve only the
minimum role/frame structure required for a regression test.

## Recording a fixture

1. Open the app and put the window you want to capture in front.
2. `swift tools/ax-snapshot-record.swift <bundle-id> /tmp/<name>.json`
3. **Hand-scrub `/tmp/<name>.json`**: replace every message body, file name, note body, person
   name, URL, e-mail address and token with invented equivalents of a similar shape and length.
   Delete subtrees the test does not need. Keep `role`, `subrole`, `frame`, `identifier`,
   `domClassList` and `domIdentifier` intact — those are what the parser anchors on.
4. Move it to `Tests/MaxMiCaptureTests/Fixtures/<name>.json` and add a row to the table above.
5. Golden `CapturedContent`: print `try goldenJSON(parsed)` from the test, scrub it the same way,
   and save it as `Fixtures/<name>-golden.json`.

At least one fixture per parser must be recorded with the window at a **nonzero screen origin**
(drag it onto a second display or away from the top-left corner first). `AXFrame` is global
screen coordinates, and a flush-at-origin fixture cannot catch a missing window-relative
conversion.
```

- [ ] **Step 8: Run the suite**

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS, including `FixtureLoadingTests` (4 tests) and the six modified classes.

- [ ] **Step 9: Commit**

```bash
git add tools/ax-snapshot-record.swift Tests/MaxMiCaptureTests/FixtureLoading.swift \
        Tests/MaxMiCaptureTests/FixtureLoadingTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json \
        Tests/MaxMiCaptureTests/ExtractorTests.swift \
        Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift \
        Tests/MaxMiCaptureTests/NativeConversationParserTests.swift \
        Tests/MaxMiCaptureTests/GenericAXParserTests.swift \
        Tests/MaxMiCaptureTests/SlackParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Add AX snapshot recorder and one shared fixture loader"
```

---

### Task 7: Terminal (Warp, Terminal.app, iTerm2) → `.terminal`

**Files:**
- Modify: `Sources/MaxMiCapture/TerminalParser.swift` (**replace** Phase A Task 14's `promptPatterns` and `segments(fromScrollback:)`)
- Delete: `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` (Phase A Task 14; superseded — `TerminalStructuredTests` asserts a superset)
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (add `TerminalParser()` to `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/warp-session.json`, `warp-session-golden.json`, `iterm-offset-session.json`, `iterm-offset-session-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/TerminalStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)` (Task 3); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `TerminalSegment`, `TerminalSession`, `CapturedContent` (Phase A).
- Produces: `TerminalParser: StructuredParser` with `static let config`; `TerminalParser.PromptShape` (`.userHost`, `.path`) with `pattern`; `TerminalParser.promptShape(in lines: [String]) -> PromptShape?`; `TerminalParser.commandText(in line: String, shape: PromptShape) -> String?`; `TerminalParser.segments(fromScrollback: String) -> [TerminalSegment]`; `TerminalParser.cwdPath(windowTitle: String?, scrollback: String) -> String?`; `TerminalParser.pathBodyPattern` (a `static let`, promoted from the local string in `lastPathComponent`); `TerminalParser.parseStructured(window:app:)`. Phase A Task 14's `promptPatterns: [String]` is **deleted** — `PromptShape.pattern` replaces it, because segmentation has to know WHICH shape matched in order to strip the cwd from a `user@host` prompt.
- `sourceApp`, `sourceKey` (`terminalKey`), `contentKind: .terminal`, `accumulationPolicy: .appendItems` stay exactly where they are, on `parse(window:app:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/TerminalStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TerminalStructuredTests: XCTestCase {
    func window(_ scrollback: String, origin: CGPoint = .zero) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
               frame: CGRect(origin: origin, size: CGSize(width: 900, height: 600)),
               focused: false,
               children: [AXNode(role: "AXTextArea", value: scrollback, title: nil, url: nil,
                                 frame: CGRect(x: origin.x, y: origin.y,
                                               width: 900, height: 600),
                                 focused: true, children: [])])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                                  windowTitle: title))
    }

    func session(_ content: CapturedContent?) throws -> TerminalSession {
        guard case .terminal(let session) = try XCTUnwrap(content) else {
            throw XCTSkip("expected a .terminal shape, got \(String(describing: content))")
        }
        return session
    }

    // MARK: - Config

    func testConfigClaimsAllThreeTerminalBundleIDs() {
        XCTAssertEqual(Set(TerminalParser.config.bundleIDs),
                       Set(ParserRegistry.terminalBundleIDs))
        XCTAssertEqual(TerminalParser.config.app, "Terminal")
        XCTAssertEqual(TerminalParser.config.offscreenPolicy,
                       .visibleOnly(maxCharacters: 64_000))
        XCTAssertTrue(TerminalParser.config.attributeSet.isEmpty,
                      "a terminal is one AXTextArea; it needs no extra attributes")
    }

    func testRegistryRoutesEveryTerminalBundleIDToTerminalParser() {
        let registry = ParserRegistry()
        for bundleID in ParserRegistry.terminalBundleIDs {
            XCTAssertTrue(registry.structuredParser(for: bundleID) is TerminalParser, bundleID)
        }
    }

    // MARK: - Prompt shape

    func testPromptShapeIsLearnedFromTheFirstMatchingLine() {
        XCTAssertEqual(TerminalParser.promptShape(in: ["noise", "ada@mac ~/code %"]), .userHost)
        XCTAssertEqual(TerminalParser.promptShape(in: ["noise", "~/code % ls"]), .path)
        XCTAssertNil(TerminalParser.promptShape(in: ["just", "output"]))
    }

    func testCommandTextStripsThePromptAndTheCwd() {
        XCTAssertEqual(
            TerminalParser.commandText(in: "ada@mac ~/code/MaxMi % swift test", shape: .userHost),
            "swift test")
        XCTAssertEqual(TerminalParser.commandText(in: "~/code/MaxMi % swift test", shape: .path),
                       "swift test")
        XCTAssertEqual(TerminalParser.commandText(in: "ada@mac ~/code/MaxMi %", shape: .userHost),
                       "", "an idle prompt line yields an empty command, not nil")
        XCTAssertNil(TerminalParser.commandText(in: "  2 failures", shape: .userHost))
    }

    func testCommandTextKeepsAPromptCharacterInsideThePathShapeCommand() {
        XCTAssertEqual(TerminalParser.commandText(in: "~/code % echo \"$ five\"", shape: .path),
                       "echo \"$ five\"",
                       "the path shape already consumed the real terminator")
    }

    // MARK: - Segmentation

    func testSegmentsSplitOnEveryPromptOfTheLearnedShape() throws {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift build
        Compiling MaxMi
        Build complete
        ada@mac ~/code/MaxMi % swift test
        Executed 506 tests, with 2 failures
        ada@mac ~/code/MaxMi %
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(segments[0].output, "Compiling MaxMi\nBuild complete")
        XCTAssertEqual(segments[1].output, "Executed 506 tests, with 2 failures")
        XCTAssertFalse(segments[1].isRunning, "a trailing idle prompt means nothing is running")
    }

    func testLastSegmentIsRunningWhenNoTrailingPromptFollows() {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift test
        Test Suite 'All tests' started
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].command, "swift test")
        XCTAssertTrue(segments[0].isRunning)
    }

    func testOutputBeforeTheFirstPromptBecomesALeadingCommandlessSegment() {
        let scrollback = """
        Welcome to Warp
        ada@mac ~/code % ls
        Package.swift
        ada@mac ~/code %
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.map(\.command), [nil, "ls"])
        XCTAssertEqual(segments[0].output, "Welcome to Warp")
    }

    func testSegmentationFailureYieldsOneCommandlessSegmentCarryingTheWholeBuffer() {
        let blob = "a full-screen TUI with no prompt at all\nsecond line"
        let segments = TerminalParser.segments(fromScrollback: blob)
        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].command)
        XCTAssertEqual(segments[0].output, blob)
        XCTAssertFalse(segments[0].isRunning)
    }

    // MARK: - cwd

    func testCwdPrefersTheWindowTitleAndFallsBackToThePromptPath() {
        XCTAssertEqual(
            TerminalParser.cwdPath(windowTitle: "~/code/MaxMi — -zsh",
                                   scrollback: "ada@mac ~/other %"),
            "~/code/MaxMi")
        XCTAssertEqual(
            TerminalParser.cwdPath(windowTitle: "Claude Code",
                                   scrollback: "ada@mac ~/code/MaxMi % swift test"),
            "~/code/MaxMi", "no path in the title, so the most recent prompt cwd wins")
        XCTAssertNil(TerminalParser.cwdPath(windowTitle: nil, scrollback: "no paths here"))
    }

    func testCwdIgnoresPathsThatAreNotPromptCwds() {
        XCTAssertNil(
            TerminalParser.cwdPath(windowTitle: nil,
                                   scrollback: "opened ~/code/MaxMi/Package.swift for editing"),
            "a path in output is not the shell's current directory")
    }

    // MARK: - End to end

    func testParseProducesATerminalSessionWithCwdAndSegments() throws {
        let scrollback = """
        ada@mac ~/code/MaxMi % swift build
        Build complete
        ada@mac ~/code/MaxMi %
        """
        let content = TerminalParser().parse(window(scrollback), context: context("~/code/MaxMi"))
        let terminal = try session(content)
        XCTAssertEqual(terminal.cwd, "~/code/MaxMi")
        XCTAssertEqual(terminal.segments.map(\.command), ["swift build"])
        XCTAssertEqual(ContentRenderer.render(try XCTUnwrap(content), style: .full),
                       "$ swift build\nBuild complete")
    }

    func testSegmentationIsIdenticalAtANonzeroWindowOrigin() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let flush = TerminalParser().parse(window(scrollback), context: context("~/code"))
        let offset = TerminalParser().parse(window(scrollback, origin: CGPoint(x: 1440, y: 220)),
                                            context: context("~/code"))
        XCTAssertEqual(flush, offset, "a terminal is text; its origin must not matter")
    }

    func testEmptyTerminalIsNotHandled() {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
                          children: [])
        XCTAssertNil(TerminalParser().parse(bare, context: context(nil)),
                     "nil is NOT_HANDLED and routes to GenericPageExtractor")
    }

    func testParseStructuredBridgeMatchesTheStructuredParser() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: "~/code")
        XCTAssertEqual(try TerminalParser().parseStructured(window: window(scrollback), app: app),
                       TerminalParser().parse(window(scrollback), context: context("~/code")))
    }

    // MARK: - Golden fixtures

    func testWarpSessionFixtureMatchesItsGolden() throws {
        let content = TerminalParser().parse(try fixture("warp-session"),
                                             context: context("~/code/sample"))
        assertGolden(try XCTUnwrap(content), matches: "warp-session-golden")
    }

    func testOffsetITermSessionFixtureMatchesItsGolden() throws {
        let iterm = ParseContext(app: AppInfo(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                                              windowTitle: "~/code/sample"))
        let content = TerminalParser().parse(try fixture("iterm-offset-session"), context: iterm)
        assertGolden(try XCTUnwrap(content), matches: "iterm-offset-session-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalStructuredTests`
Expected: FAIL to compile — "type 'TerminalParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

First delete Phase A Task 14's two members from `Sources/MaxMiCapture/TerminalParser.swift` — `static let promptPatterns: [String]` and `static func segments(fromScrollback:)` — and delete `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift`. Then promote the path pattern to a `static let` next to `contentCap`:

```swift
    /// A home-or-absolute path with no prompt terminator inside it.
    static let pathBodyPattern = "(~|/Users/[^/ ]+)(/[^ \t\n:%$#>❯]+)*"
```

and replace the local `let pathBody = …` in `lastPathComponent(in:requirePrompt:)` with `Self.pathBodyPattern`:

```swift
        let pattern = requirePrompt ? "\(Self.pathBodyPattern)\\s*[%$#>❯]" : Self.pathBodyPattern
```

Then append this extension to the same file:

```swift
extension TerminalParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Terminal",
        bundleIDs: ParserRegistry.terminalBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 64_000)
    )

    /// The two prompt shapes worth learning. The trailing `(\s|$)` alternative is what lets an
    /// IDLE prompt (a prompt with nothing typed after it) be recognised, which is how the last
    /// segment learns it is not still running.
    enum PromptShape: Equatable {
        case userHost
        case path

        var pattern: String {
            switch self {
            case .userHost: return "^\\S+@\\S+\\s"
            case .path:     return "^[~/]\\S* [%$❯](\\s|$)"
            }
        }
    }

    /// The shape of the FIRST line that looks like a prompt. Every later split uses that one
    /// shape, so a path printed by a command cannot start a spurious segment.
    static func promptShape(in lines: [String]) -> PromptShape? {
        for line in lines {
            for shape in [PromptShape.userHost, .path]
            where line.range(of: shape.pattern, options: .regularExpression)?.lowerBound
                    == line.startIndex {
                return shape
            }
        }
        return nil
    }

    /// The text the user typed on a prompt line, "" for an idle prompt, nil for an output line.
    static func commandText(in line: String, shape: PromptShape) -> String? {
        guard let head = line.range(of: shape.pattern, options: .regularExpression),
              head.lowerBound == line.startIndex else { return nil }
        var rest = String(line[head.upperBound...])
        // The userHost shape only consumed "user@host "; the cwd and the terminator follow.
        // The path shape already consumed its terminator, so stripping again would eat a
        // prompt character that is part of the command.
        if shape == .userHost,
           let terminator = rest.range(of: "[%$#>❯](\\s|$)", options: .regularExpression) {
            rest = String(rest[terminator.upperBound...])
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func segments(fromScrollback blob: String) -> [TerminalSegment] {
        let lines = blob.components(separatedBy: "\n")
        guard let shape = promptShape(in: lines) else {
            // Segmentation failure (a full-screen TUI, a pager, an unknown prompt theme).
            return [TerminalSegment(command: nil, output: blob, isRunning: false)]
        }
        var segments: [TerminalSegment] = []
        var preamble: [String] = []
        var open: (command: String, output: [String])?

        func flush(isRunning: Bool) {
            if let open {
                segments.append(TerminalSegment(command: open.command,
                                                output: open.output.joined(separator: "\n"),
                                                isRunning: isRunning))
            } else if !preamble.isEmpty {
                segments.append(TerminalSegment(command: nil,
                                                output: preamble.joined(separator: "\n"),
                                                isRunning: false))
                preamble = []
            }
        }

        for line in lines {
            guard let command = commandText(in: line, shape: shape) else {
                if open != nil { open?.output.append(line) } else { preamble.append(line) }
                continue
            }
            flush(isRunning: false)
            // An idle prompt closes the previous segment and opens nothing.
            open = command.isEmpty ? nil : (command, [])
        }
        // Still open at the end == no trailing prompt == the command has not returned.
        flush(isRunning: open != nil)
        return segments
    }

    /// The full cwd path (not the slug `terminalKey` wants). Title first, because a prompt theme
    /// may render a shortened cwd, then the most recent prompt line.
    static func cwdPath(windowTitle: String?, scrollback: String) -> String? {
        if let windowTitle,
           let range = windowTitle.range(of: pathBodyPattern, options: .regularExpression) {
            return String(windowTitle[range])
        }
        let anchored = "\(pathBodyPattern)\\s*[%$#>❯]"
        for line in scrollback.components(separatedBy: "\n").reversed() {
            guard let range = line.range(of: anchored, options: .regularExpression) else { continue }
            return String(line[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t%$#>❯"))
        }
        return nil
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let areas = AXQuery.findAll("//AXTextArea", in: snapshot)
        // Warp exposes one; some emulators expose several — take the richest.
        guard let blob = areas.compactMap(\.value).filter({ !$0.isEmpty })
                .max(by: { $0.count < $1.count }) else { return nil }
        let bounded = String(blob.suffix(Self.contentCap))
        return .terminal(TerminalSession(
            cwd: Self.cwdPath(windowTitle: context.windowTitle, scrollback: bounded),
            segments: Self.segments(fromScrollback: bounded)
        ))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, register it:

```swift
        let structured: [any StructuredParser] = [TerminalParser()]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalStructuredTests`
Expected: PASS for every test except the two golden tests, which fail with "missing golden Fixtures/warp-session-golden.json".

Run: `swift test --filter TerminalParserTests`
Expected: PASS, unchanged — `terminalKey`, `workingDirectory` and `parse(window:app:)` are untouched.

Run: `swift test --filter TerminalSegmentationTests`
Expected: no tests run — that Phase A file was deleted in Step 3.

- [ ] **Step 5: Record the two fixtures and their goldens**

Record Warp flush at the top-left of the display:

```bash
swift tools/ax-snapshot-record.swift dev.warp.Warp-Stable /tmp/warp-session.json
```

Record iTerm2 with the window dragged to a **nonzero screen origin** (second display, or well away from the top-left corner):

```bash
swift tools/ax-snapshot-record.swift com.googlecode.iterm2 /tmp/iterm-offset-session.json
```

Hand-scrub both per `Tests/MaxMiCaptureTests/Fixtures/README.md`, then move them to `Tests/MaxMiCaptureTests/Fixtures/warp-session.json` and `iterm-offset-session.json`.

Each fixture must retain **at minimum**, or the test measures nothing:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `iterm-offset-session.json`),
- the single largest `AXTextArea` with a scrubbed `value` containing at least **three** prompt lines of one shape — two with a command after the prompt and a trailing idle prompt with nothing after it — plus at least two output lines under the first command,
- one shorter decoy `AXTextArea` (Warp's command palette or iTerm's find bar), so "largest wins" is exercised,
- a prompt cwd of the form `~/code/sample` in both the window `title` and the scrollback.

Then print the goldens and save them:

```swift
// Temporarily inside testWarpSessionFixtureMatchesItsGolden:
print(try goldenJSON(try XCTUnwrap(content)))
```

Save the printed strings as `Tests/MaxMiCaptureTests/Fixtures/warp-session-golden.json` and `iterm-offset-session-golden.json`, remove the `print`, and add four rows to the README table:

```markdown
| `warp-session.json` | Scrubbed Warp scrollback, window flush at the origin | `TerminalParser` `.terminal` segmentation |
| `warp-session-golden.json` | Expected `CapturedContent` for `warp-session.json` | golden comparison |
| `iterm-offset-session.json` | Scrubbed iTerm2 scrollback at a nonzero window origin | `TerminalParser` origin invariance |
| `iterm-offset-session-golden.json` | Expected `CapturedContent` for `iterm-offset-session.json` | golden comparison |
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter TerminalStructuredTests`
Expected: PASS, 16 tests.

- [ ] **Step 7: Commit**

```bash
git rm Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift
git add Sources/MaxMiCapture/TerminalParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/TerminalStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/warp-session.json \
        Tests/MaxMiCaptureTests/Fixtures/warp-session-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/iterm-offset-session.json \
        Tests/MaxMiCaptureTests/Fixtures/iterm-offset-session-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Segment terminal scrollback into commands and output"
```

---

### Task 8: Cursor + VS Code → `.document`

**Files:**
- Create: `Sources/MaxMiCapture/EditorParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `EditorParser()` in both `parsers` and `structured`)
- Modify: `Sources/MaxMiCore/ApplicationRegistry.swift` (Cursor and VS Code become `.nativeParser`)
- Modify: `Tests/MaxMiCoreTests/ApplicationRegistryTests.swift:66`
- Create: `Tests/MaxMiCaptureTests/Fixtures/vscode-editor.json`, `vscode-editor-golden.json`, `cursor-offset-editor.json`, `cursor-offset-editor-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/EditorParserTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.Matchers` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext`, `ParserRegistry.editorBundleIDs` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `Document`, `Block`, `Authorship`, `CapturedContent` (Phase A); `ApplicationRegistry.descriptor(for:)` (`Sources/MaxMiCore/ApplicationRegistry.swift`).
- Produces: `EditorParser: SourceParser, StructuredParser`; `EditorParser.config`; `EditorParser.activeTabTitle(fromWindowTitle:) -> String`; `EditorParser.looksLikeFilename(_:) -> Bool`; `EditorParser.workspaceName(fromWindowTitle:) -> String?`; `EditorParser.key(fromTitle:) -> String` producing `"editor:<workspace>/<file>"` or `"editor:<file>"`; `EditorParser.editorTextArea(in:) -> AXNode?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/EditorParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class EditorParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil,
              identifier: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 100), focused: false,
               children: children, identifier: identifier, label: nil)
    }

    /// An editor group with the file, plus a panel group with the integrated terminal.
    func window(editor: String, panel: String?, origin: CGPoint = .zero) -> AXNode {
        var children = [
            node("AXGroup", identifier: "workbench.editor.main",
                 frame: CGRect(x: origin.x + 240, y: origin.y + 80, width: 1000, height: 600),
                 children: [
                     node("AXTextArea", value: editor,
                          frame: CGRect(x: origin.x + 240, y: origin.y + 80,
                                        width: 1000, height: 600)),
                 ]),
        ]
        if let panel {
            children.append(node("AXGroup", identifier: "workbench.panel.terminal",
                                 frame: CGRect(x: origin.x + 240, y: origin.y + 700,
                                               width: 1000, height: 200),
                                 children: [
                                     node("AXTextArea", value: panel,
                                          frame: CGRect(x: origin.x + 240, y: origin.y + 700,
                                                        width: 1000, height: 200)),
                                 ]))
        }
        return node("AXWindow", title: "app.swift — sample",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    func context(_ bundleID: String, _ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "Editor", windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(Set(EditorParser.config.bundleIDs), Set(ParserRegistry.editorBundleIDs))
        XCTAssertEqual(EditorParser.config.app, "Editor")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.cursorBundleID) is EditorParser)
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.vsCodeBundleID) is EditorParser)
        XCTAssertTrue(registry.parser(for: ParserRegistry.vsCodeBundleID) is EditorParser,
                      "the v1 map owns the thread key, so it must be registered too")
    }

    func testActiveTabTitleHandlesBothEditorTitleOrders() {
        // VS Code: "<file> — <workspace>". Cursor: "<workspace> — <file>".
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "app.swift — sample"),
                       "app.swift")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "sample — app.swift"),
                       "app.swift")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "● app.swift — sample"),
                       "app.swift", "the unsaved marker is not part of the file name")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: "Welcome"), "Welcome",
                       "with no file-looking component the first component is used")
        XCTAssertEqual(EditorParser.activeTabTitle(fromWindowTitle: nil), "untitled")
    }

    func testWorkspaceNameIsTheComponentThatIsNotTheFile() {
        XCTAssertEqual(EditorParser.workspaceName(fromWindowTitle: "app.swift — sample"), "sample")
        XCTAssertEqual(EditorParser.workspaceName(fromWindowTitle: "sample — app.swift"), "sample")
        XCTAssertNil(EditorParser.workspaceName(fromWindowTitle: "Welcome"))
    }

    func testKeyIsWorkspaceScopedWhenAWorkspaceIsKnown() {
        XCTAssertEqual(EditorParser.key(fromTitle: "app.swift — Sample Project"),
                       "editor:sample-project/app.swift")
        XCTAssertEqual(EditorParser.key(fromTitle: "Welcome"), "editor:welcome")
        XCTAssertEqual(EditorParser.key(fromTitle: nil), "editor:unknown")
    }

    func testEditorLinesBecomeParagraphBlocksAndTheTitleIsTheActiveTab() throws {
        let content = EditorParser().parse(window(editor: "let a = 1\nlet b = 2", panel: nil),
                                           context: context(ParserRegistry.vsCodeBundleID,
                                                            "app.swift — sample"))
        let doc = try document(content)
        XCTAssertEqual(doc.title, "app.swift")
        XCTAssertEqual(doc.blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["let a = 1", "let b = 2"])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testIntegratedTerminalPanelIsDroppedWhenTheEditorAnchorResolves() throws {
        let content = EditorParser().parse(
            window(editor: "let a = 1", panel: "ada@mac ~/code % swift test"),
            context: context(ParserRegistry.cursorBundleID, "sample — app.swift"))
        let doc = try document(content)
        XCTAssertEqual(doc.blocks.map(\.text), ["let a = 1"])
        XCTAssertFalse(ContentRenderer.render(try XCTUnwrap(content), style: .full)
                        .contains("swift test"),
                       "the panel is not the document the user is editing")
    }

    func testNoEditorAnchorIsNotHandledSoGenericPageExtractorTakesOver() {
        let welcome = node("AXWindow", title: "Welcome",
                           frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                           children: [node("AXGroup", identifier: "workbench.panel.terminal",
                                           children: [node("AXTextArea", value: "shell only")])])
        XCTAssertNil(EditorParser().parse(welcome,
                                          context: context(ParserRegistry.cursorBundleID, "Welcome")),
                     "nil routes to GenericPageExtractor, which will pick the panel up")
    }

    func testEmptyEditorIsNotHandled() {
        XCTAssertNil(EditorParser().parse(window(editor: "   ", panel: nil),
                                          context: context(ParserRegistry.vsCodeBundleID, "a.swift")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        let flush = EditorParser().parse(window(editor: "let a = 1", panel: nil),
                                         context: context(ParserRegistry.vsCodeBundleID,
                                                          "app.swift — sample"))
        let offset = EditorParser().parse(
            window(editor: "let a = 1", panel: nil, origin: CGPoint(x: 1440, y: 220)),
            context: context(ParserRegistry.vsCodeBundleID, "app.swift — sample"))
        XCTAssertEqual(flush, offset)
    }

    func testSourceAppComesFromTheApplicationRegistryDisplayName() throws {
        let app = AppInfo(bundleID: ParserRegistry.cursorBundleID, name: "Cursor",
                          windowTitle: "sample — app.swift")
        let parsed = try XCTUnwrap(try EditorParser().parse(
            window: window(editor: "let a = 1", panel: nil), app: app))
        XCTAssertEqual(parsed.sourceApp, "Cursor")
        XCTAssertEqual(parsed.sourceKey, "editor:sample/app.swift")
        XCTAssertEqual(parsed.contentKind, .document)
        XCTAssertEqual(parsed.accumulationPolicy, .replace)
    }

    func testVSCodeFixtureMatchesItsGolden() throws {
        let content = EditorParser().parse(try fixture("vscode-editor"),
                                           context: context(ParserRegistry.vsCodeBundleID,
                                                            "sample.swift — sample"))
        assertGolden(try XCTUnwrap(content), matches: "vscode-editor-golden")
    }

    func testOffsetCursorFixtureMatchesItsGolden() throws {
        let content = EditorParser().parse(try fixture("cursor-offset-editor"),
                                           context: context(ParserRegistry.cursorBundleID,
                                                            "sample — sample.swift"))
        assertGolden(try XCTUnwrap(content), matches: "cursor-offset-editor-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditorParserTests`
Expected: FAIL to compile — "cannot find 'EditorParser' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/EditorParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Cursor and VS Code. Both are Electron editors whose visible buffer lives in an `AXTextArea`
/// beneath a group whose identifier contains "editor"; the integrated terminal lives beneath a
/// sibling group whose identifier contains "panel" or "terminal". Anchoring on the identifier
/// instead of geometry is what stops the terminal panel being captured as the document.
public struct EditorParser: SourceParser, StructuredParser {
    static let contentCap = 32_000
    public init() {}

    public static let config = ParserConfig(
        app: "Editor",
        bundleIDs: ParserRegistry.editorBundleIDs,
        offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: 96_000)
    )

    // MARK: - Titles and keys

    /// Editors put the workspace on one side of the dash and the file on the other, and the two
    /// apps disagree about which side, so the component that looks like a file wins.
    static func activeTabTitle(fromWindowTitle title: String?) -> String {
        let parts = titleComponents(title)
        guard !parts.isEmpty else { return "untitled" }
        return parts.first(where: looksLikeFilename) ?? parts[0]
    }

    static func workspaceName(fromWindowTitle title: String?) -> String? {
        let parts = titleComponents(title)
        guard parts.count >= 2, let file = parts.first(where: looksLikeFilename) else { return nil }
        return parts.first { $0 != file }
    }

    static func titleComponents(_ title: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        return title.components(separatedBy: " — ")
            .flatMap { $0.components(separatedBy: " - ") }
            // "●" is the unsaved-changes marker and is not part of any name.
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "● \u{2022}\t")) }
            .filter { !$0.isEmpty }
    }

    static func looksLikeFilename(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex,
              dot != s.index(before: s.endIndex) else { return false }
        let ext = s[s.index(after: dot)...]
        return ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func key(fromTitle title: String?) -> String {
        let parts = titleComponents(title)
        guard !parts.isEmpty else { return "editor:unknown" }
        let file = docSlug(activeTabTitle(fromWindowTitle: title))
        guard let workspace = workspaceName(fromWindowTitle: title) else { return "editor:\(file)" }
        return "editor:\(docSlug(workspace))/\(file)"
    }

    // MARK: - Anchor

    /// The largest text area beneath an "editor" group. Falls back to nothing rather than to the
    /// largest text area in the window, because that would be the terminal panel when the panel
    /// is long and the file is short.
    static func editorTextArea(in snapshot: AXNode) -> AXNode? {
        AXQuery.findAll("//AXGroup[identifier*=\"editor\"]//AXTextArea", in: snapshot)
            .filter { ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .max { ($0.value ?? "").count < ($1.value ?? "").count }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let area = Self.editorTextArea(in: snapshot),
              let raw = area.value else { return nil }
        let bounded = String(raw.suffix(Self.contentCap))
        let blocks = bounded.components(separatedBy: "\n")
            .map { Block(type: .paragraph, text: $0, authoredByUser: false) }
        guard blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return .document(Document(
            title: Self.activeTabTitle(fromWindowTitle: context.windowTitle),
            blocks: blocks,
            author: .user,
            url: nil
        ))
    }

    // MARK: - SourceParser (keys and policies, spec §4f rule 1)

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = parse(window, context: ParseContext(app: app)) else { return nil }
        return ParsedCapture(
            sourceApp: ApplicationRegistry.descriptor(for: app.bundleID)?.displayName ?? app.name,
            sourceKey: Self.key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .document,
            parserVersion: 3,
            // §4d: .document accumulates by replace — each capture supersedes the last.
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: structured
        )
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, register in both maps:

```swift
        for bid in Self.editorBundleIDs { p[bid] = EditorParser() }
```

```swift
        let structured: [any StructuredParser] = [TerminalParser(), EditorParser()]
```

In `Sources/MaxMiCore/ApplicationRegistry.swift`, change both editor descriptors' `captureStrategy` from `.genericAX` to `.nativeParser` (Cursor at the `"com.todesktop.230313mzl4w4u92"` descriptor, VS Code at `"com.microsoft.VSCode"`). Leave Xcode on `.genericAX` — Phase D does not add an Xcode parser.

In `Tests/MaxMiCoreTests/ApplicationRegistryTests.swift:66`:

```swift
        XCTAssertEqual(cursor?.captureStrategy, .nativeParser)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EditorParserTests`
Expected: PASS except the two golden tests, which report the missing golden files.

Run: `swift test --filter ApplicationRegistryTests`
Expected: PASS.

Run: `swift test --filter GenericAXParserTests`
Expected: PASS — the existing `cursor-editor.json` test asserts `GenericAXParser` output directly and does not go through the registry.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.microsoft.VSCode /tmp/vscode-editor.json
swift tools/ax-snapshot-record.swift com.todesktop.230313mzl4w4u92 /tmp/cursor-offset-editor.json
```

Record VS Code flush at the origin with a file open **and the integrated terminal visible**; record Cursor with the window dragged to a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `cursor-offset-editor.json`),
- one group whose `identifier` contains `editor` holding an `AXTextArea` whose scrubbed `value` has at least three lines of invented code,
- one sibling group whose `identifier` contains `panel` or `terminal` holding a **longer** `AXTextArea`, so "the editor anchor beats the biggest text area" is what the test proves,
- the tab bar's `AXRadioButton`/`AXTabButton` nodes may be deleted; they are not anchors.

Hand-scrub, move into `Tests/MaxMiCaptureTests/Fixtures/`, print the goldens with `print(try goldenJSON(try XCTUnwrap(content)))`, save them as `vscode-editor-golden.json` and `cursor-offset-editor-golden.json`, and add four README rows following the pattern established in Task 7.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter EditorParserTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/EditorParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Sources/MaxMiCore/ApplicationRegistry.swift \
        Tests/MaxMiCoreTests/ApplicationRegistryTests.swift \
        Tests/MaxMiCaptureTests/EditorParserTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/vscode-editor.json \
        Tests/MaxMiCaptureTests/Fixtures/vscode-editor-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/cursor-offset-editor.json \
        Tests/MaxMiCaptureTests/Fixtures/cursor-offset-editor-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture the active editor buffer in Cursor and VS Code"
```

---

### Task 9: Browser generic web (Chrome, Safari, Zen, Arc) → `.generic` with `url`

**Files:**
- Create: `Sources/MaxMiCapture/WebPageParser.swift`
- (no change needed to `Sources/MaxMiCapture/BrowserTabExtractor.swift` — Phase A Task 15 already exposes `primaryWebArea(in:windowTitle:engine:)`)
- Modify: `Sources/MaxMiCapture/BrowserCapturePipeline.swift` (route through the host map, then `WebPageParser`)
- Modify: `Sources/MaxMiCapture/WebAppCaptureParser.swift` (`classify` keeps the parser ID and `contentKind`; content shape moves out)
- Create: `Tests/MaxMiCaptureTests/Fixtures/chrome-landmarks.json`, `chrome-landmarks-golden.json`, `safari-offset-article.json`, `safari-offset-article-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/WebPageParserTests.swift`

**Interfaces:**
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)` and its `Options` (Phase A); `GenericPage`, `Region`, `RegionKind`, `CapturedContent` (Phase A); `TabCapture`, `BrowserEngine`, `BrowserCaptureQuality`, `ExtractionError` and `BrowserTabExtractor.primaryWebArea(in:windowTitle:engine:)` (the latter added by Phase A Task 15 — do **not** add a second web-area resolver); `ParserRegistry.host(fromURL:)` and `structuredParser(forHost:)` (Task 5).
- Produces: `WebPageParser.extract(window: AXNode, webArea: AXNode, url: String?, options: GenericPageExtractor.Options) -> GenericPageExtractor.Result`; `WebPageParser.parse(window: AXNode, tab: TabCapture) -> CapturedContent`; `BrowserCaptureResult.structured: CapturedContent` (new non-optional field, last in `init`).
- `WebPageParser` is not in the registry maps — it is the browser **default**, reached when no host parser claims the URL. It therefore has no `ParserConfig`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/WebPageParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebPageParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, url: String? = nil,
              subrole: String? = nil, identifier: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 20), focused: false,
               children: children, identifier: identifier, label: nil, subrole: subrole)
    }

    /// A landmarked page inside a browser chrome window, optionally at a nonzero origin.
    func browserWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", title: "How SQLite Works",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: [
            node("AXToolbar", frame: CGRect(x: x, y: y, width: 1440, height: 42), children: [
                node("AXTextField", value: "sqlite.org/arch.html", title: "Address and search bar",
                     frame: CGRect(x: x + 250, y: y + 6, width: 700, height: 30)),
            ]),
            node("AXWebArea", url: "https://sqlite.org/arch.html",
                 frame: CGRect(x: x, y: y + 42, width: 1440, height: 858), children: [
                node("AXGroup", subrole: "AXLandmarkMain",
                     frame: CGRect(x: x + 300, y: y + 80, width: 900, height: 700), children: [
                    node("AXHeading", value: "Architecture",
                         frame: CGRect(x: x + 300, y: y + 80, width: 400, height: 28)),
                    node("AXStaticText", value: "SQLite is a library.",
                         frame: CGRect(x: x + 300, y: y + 120, width: 600, height: 20)),
                ]),
                node("AXGroup", subrole: "AXLandmarkComplementary",
                     frame: CGRect(x: x + 40, y: y + 80, width: 220, height: 700), children: [
                    node("AXStaticText", value: "On this page",
                         frame: CGRect(x: x + 40, y: y + 80, width: 200, height: 20)),
                ]),
                node("AXGroup", subrole: "AXLandmarkNavigation",
                     frame: CGRect(x: x + 300, y: y + 60, width: 900, height: 18), children: [
                    node("AXLink", title: "Docs",
                         frame: CGRect(x: x + 300, y: y + 60, width: 60, height: 18)),
                ]),
            ]),
        ])
    }

    func page(_ content: CapturedContent) throws -> GenericPage {
        guard case .generic(let page) = content else {
            throw XCTSkip("expected .generic, got \(content)")
        }
        return page
    }

    func testPrimaryWebAreaIsTheScoredWebArea() throws {
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: browserWindow(), windowTitle: "How SQLite Works", engine: .chromium))
        XCTAssertEqual(area.role, "AXWebArea")
        XCTAssertEqual(area.url, "https://sqlite.org/arch.html")
    }

    func testNoWebAreaYieldsNil() {
        XCTAssertNil(BrowserTabExtractor.primaryWebArea(
            in: node("AXWindow", children: [node("AXToolbar")]),
            windowTitle: nil, engine: .webkit))
    }

    func testLandmarksBecomeRegionsAndTheUrlIsCarried() throws {
        let window = browserWindow()
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: "How SQLite Works", engine: .chromium))
        let result = WebPageParser.extract(window: window, webArea: area,
                                          url: "https://sqlite.org/arch.html",
                                          options: GenericPageExtractor.Options())
        XCTAssertEqual(result.page.url, "https://sqlite.org/arch.html")
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .sidebar, .navigation])
        XCTAssertEqual(result.page.regions[0].blocks.map(\.text),
                       ["Architecture", "SQLite is a library."])
        XCTAssertEqual(result.page.regions[1].blocks.map(\.text), ["On this page"])
        XCTAssertEqual(result.page.regions[2].blocks.map(\.text), ["Docs"])
    }

    func testBrowserChromeOutsideTheWebAreaIsNeverCaptured() throws {
        let window = browserWindow()
        let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: nil, engine: .chromium))
        let rendered = ContentRenderer.render(
            .generic(WebPageParser.extract(window: window, webArea: area, url: nil,
                                           options: GenericPageExtractor.Options()).page),
            style: .full)
        XCTAssertFalse(rendered.contains("Address and search bar"))
        XCTAssertFalse(rendered.contains("sqlite.org/arch.html"),
                       "the address field's value is chrome, not page content")
    }

    func testRegionsAreIdenticalAtANonzeroWindowOrigin() throws {
        func regions(_ origin: CGPoint) throws -> [Region] {
            let window = browserWindow(origin: origin)
            let area = try XCTUnwrap(BrowserTabExtractor.primaryWebArea(
                in: window, windowTitle: nil, engine: .chromium))
            return WebPageParser.extract(window: window, webArea: area, url: nil,
                                        options: GenericPageExtractor.Options()).page.regions
        }
        XCTAssertEqual(try regions(.zero), try regions(CGPoint(x: 1440, y: 220)),
                       "region detection is window-relative, so the origin must not matter")
    }

    func testParseFromATabCaptureUsesTheTabUrl() throws {
        let tab = TabCapture(url: "https://sqlite.org/arch.html", title: "How SQLite Works",
                             content: "ignored", urlSource: .webArea, quality: .high,
                             truncated: false)
        let content = WebPageParser.parse(window: browserWindow(), tab: tab)
        XCTAssertEqual(try page(content).url, "https://sqlite.org/arch.html")
    }

    func testAWindowWithNoWebAreaFallsBackToTheWholeWindow() throws {
        // A browser can be showing a native error sheet with no web area at all. The parser must
        // still produce a page rather than nothing.
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        children: [node("AXStaticText", value: "You are offline",
                                        frame: CGRect(x: 0, y: 0, width: 200, height: 20))])
        let tab = TabCapture(url: "https://example.com/", title: nil, content: "")
        XCTAssertEqual(try page(WebPageParser.parse(window: bare, tab: tab))
                        .regions.first?.blocks.map(\.text), ["You are offline"])
    }

    func testPipelineCarriesTheStructuredValueAndKeepsTheParserID() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(window: browserWindow(),
                                                     windowTitle: "How SQLite Works",
                                                     browser: browser)
        XCTAssertEqual(result.url, "https://sqlite.org/arch.html")
        XCTAssertEqual(result.webApp, .generic)
        XCTAssertTrue(result.parserID.hasPrefix("BrowserWeb.v2/chromium/generic/"))
        XCTAssertEqual(result.capture.contentKind, .webpage, "spec §12 Q3: browsers keep .webpage")
        XCTAssertEqual(result.capture.structured, result.structured)
        XCTAssertEqual(result.capture.content,
                       ContentRenderer.render(result.structured, style: .full))
        XCTAssertEqual(try page(result.structured).regions.map(\.kind),
                       [.main, .sidebar, .navigation])
    }

    func testChromeLandmarksFixtureMatchesItsGolden() throws {
        let window = try fixture("chrome-landmarks")
        let tab = TabCapture(url: "https://example.com/docs/architecture", title: "Architecture",
                             content: "")
        assertGolden(WebPageParser.parse(window: window, tab: tab),
                     matches: "chrome-landmarks-golden")
    }

    func testOffsetSafariArticleFixtureMatchesItsGolden() throws {
        let window = try fixture("safari-offset-article")
        let tab = TabCapture(url: "https://example.com/posts/one", title: "One", content: "")
        assertGolden(WebPageParser.parse(window: window, tab: tab),
                     matches: "safari-offset-article-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebPageParserTests`
Expected: FAIL to compile — "cannot find 'WebPageParser' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/WebPageParser.swift`:

```swift
import Foundation
import MaxMiCore

/// The browser generic-web path: `GenericPageExtractor` over the active `AXWebArea` subtree,
/// with the tab's URL attached. Landmark subroles give the regions, so a docs sidebar and a
/// nav bar stop being interleaved with the article the user is reading.
///
/// Not registered in `ParserRegistry` — it is the default a browser window reaches when no host
/// parser claims the URL, so it has no `ParserConfig`.
public enum WebPageParser {
    /// Traversal root is the web area, but budgets and region geometry are measured against the
    /// WINDOW, because `AXFrame` is global and the sidebar heuristic is window-relative.
    public static func extract(
        window: AXNode,
        webArea: AXNode,
        url: String?,
        options: GenericPageExtractor.Options
    ) -> GenericPageExtractor.Result {
        // Re-root the walk on the web area while keeping the window's frame, so browser chrome
        // (toolbar, address field, tab bar) is structurally out of reach.
        let rooted = AXNode(
            role: window.role, value: nil, title: window.title, url: url,
            frame: window.frame, focused: window.focused, children: [webArea],
            identifier: window.identifier, label: window.label, subrole: window.subrole
        )
        return GenericPageExtractor.extract(window: rooted, focusedElement: nil,
                                            url: url, options: options)
    }

    public static func parse(window: AXNode, tab: TabCapture) -> CapturedContent {
        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000)
        guard let webArea = BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: tab.title, engine: nil
        ) else {
            // No web area at all (a native error sheet, a blank tab). Walking the whole window
            // is worse than a page but far better than storing nothing.
            return .generic(GenericPageExtractor.extract(
                window: window, focusedElement: nil, url: tab.url, options: options).page)
        }
        return .generic(extract(window: window, webArea: webArea,
                                url: tab.url, options: options).page)
    }
}
```

`BrowserTabExtractor.primaryWebArea(in:windowTitle:engine:)` already exists — Phase A Task 15 added it with exactly this signature and scoring. Do not add a second resolver.

In `Sources/MaxMiCapture/BrowserCapturePipeline.swift`, add the field and the routing:

```swift
public struct BrowserCaptureResult: Sendable, Equatable {
    public let url: String
    public let capture: ParsedCapture
    public let parserID: String
    public let quality: BrowserCaptureQuality
    public let truncated: Bool
    public let webApp: WebAppKind
    /// Always present: a host parser's shape, or the generic web page.
    public let structured: CapturedContent
}
```

```swift
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        let web = WebAppCaptureParser.parse(tab: tab, window: window)
        // Host routing (spec §7b): a registered host parser claims the tab; otherwise the tab is
        // a generic web page. Either way `contentKind` stays whatever `classify` decided (§12 Q3).
        let hostParser = ParserRegistry.host(fromURL: tab.url)
            .flatMap { registry.structuredParser(forHost: $0) }
        let hostContext = ParseContext(
            app: AppInfo(bundleID: browser.bundleID, name: browser.displayName,
                         windowTitle: windowTitle),
            url: tab.url
        )
        let structured = hostParser?.parse(window, context: hostContext)
            ?? WebPageParser.parse(window: window, tab: tab)
```

`BrowserCapturePipeline.parse` therefore needs the registry. Change its signature and pass the structured value through:

```swift
    public static func parse(
        window: AXNode,
        windowTitle: String?,
        browser: ApplicationDescriptor,
        registry: ParserRegistry = ParserRegistry()
    ) throws -> BrowserCaptureResult {
```

```swift
        return BrowserCaptureResult(
            url: tab.url,
            capture: ParsedCapture(
                sourceApp: web.capture.sourceApp,
                sourceKey: web.capture.sourceKey,
                sourceTitle: web.capture.sourceTitle,
                content: ContentRenderer.render(structured, style: .full),
                contentKind: web.capture.contentKind,
                parserVersion: 3,
                accumulationPolicy: web.capture.accumulationPolicy,
                offscreenPolicy: web.capture.offscreenPolicy,
                structured: structured
            ),
            parserID: parserID,
            quality: quality,
            truncated: tab.truncated,
            webApp: web.app,
            structured: structured
        )
```

The `registry` default keeps the existing call site in `Sources/MaxMi/AppWiring.swift:1447` compiling; change it to pass the app's own registry so the two share one instance:

```swift
                let result = try BrowserCapturePipeline.parse(
                    window: window, windowTitle: title, browser: browser, registry: registry
                )
```

`WebAppCaptureParser` keeps `classify`, `messageLines` and the `ParsedCapture` it builds — they still supply `sourceKey`, `contentKind` and the accumulation policy. Add a doc comment above `classify` recording that it no longer decides the content shape:

```swift
    /// Classifies a URL for the parser ID, `contentKind` and accumulation policy ONLY. Since
    /// M8 Phase D the content shape comes from `ParserRegistry`'s host map (spec §7b), so a new
    /// web app is added by registering a `StructuredParser` with a `hosts:` entry, not here.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebPageParserTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter BrowserCapturePipelineTests`
Expected: FAIL on any assertion that reads `result.capture.content` as the old flat visual-order text. Update those assertions to assert against `ContentRenderer.render(result.structured, style: .full)` and to check regions on `result.structured`; the URL, key, `contentKind`, `webApp` and `parserID` assertions all stay as they are.

Run: `swift test --filter ExtractorTests`
Expected: PASS — `BrowserTabExtractor.extract` is unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/chrome-landmarks.json
swift tools/ax-snapshot-record.swift com.apple.Safari /tmp/safari-offset-article.json
```

Record Chrome flush at the origin on a page with a real `<main>`, `<nav>` and `<aside>` (any documentation site); record Safari on an article with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `safari-offset-article.json`),
- the `AXToolbar` with the address `AXTextField` **kept**, so "browser chrome is never captured" is a real assertion,
- one `AXWebArea` with a scrubbed `url`,
- inside it, at least one node with `subrole` `AXLandmarkMain` containing an `AXHeading` and two `AXStaticText` nodes, one with `AXLandmarkComplementary`, and one with `AXLandmarkNavigation` containing an `AXLink`.

Hand-scrub, move into `Fixtures/`, print and save the goldens as in Task 7, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter WebPageParserTests`
Expected: PASS, 10 tests.

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/WebPageParser.swift \
        Sources/MaxMiCapture/BrowserCapturePipeline.swift \
        Sources/MaxMiCapture/WebAppCaptureParser.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiCaptureTests/WebPageParserTests.swift \
        Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/chrome-landmarks.json \
        Tests/MaxMiCaptureTests/Fixtures/chrome-landmarks-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/safari-offset-article.json \
        Tests/MaxMiCaptureTests/Fixtures/safari-offset-article-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture web pages as landmark regions with their URL"
```

---

### Task 10: Slack → `.conversation` with DOM-class anchors

**Files:**
- Modify: `Sources/MaxMiCapture/SlackParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `SlackParser()` in `structured`, with hosts)
- Create: `Tests/MaxMiCaptureTests/Fixtures/slack-dom-messages.json`, `slack-dom-messages-golden.json`, `slack-offset-no-dom.json`, `slack-offset-no-dom-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/SlackStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)`, `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Message`, `Message.makeID(sender:timeString:text:)`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `SlackParser: StructuredParser`; `SlackParser.config` (bundle ID `ParserRegistry.slackBundleID`, hosts `["app.slack.com", ".slack.com"]`, `attributeSet: ["AXDOMClassList"]`, `preferOverNative: true`); `SlackParser.channelName(fromTitle:) -> String`; `SlackParser.domMessages(in:) -> [Message]`; `SlackParser.draftMessage(in:) -> Message?`; `SlackParser.geometryMessages(in:) -> [Message]`; `SlackParser.parseStructured(window:app:)`.
- `key(fromTitle:)`, `messageLines`, `parse(window:app:)` are untouched — `SlackParserTests` keeps passing verbatim.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/SlackStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class SlackStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, domClassList: [String]? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 100, height: 20), focused: false,
               children: children, identifier: nil, label: nil, subrole: nil,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// A DOM-classed Slack window: message list, two virtual-list items, and a composer.
    func domWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: x + 260, y: y, width: 900, height: 700), children: [
                node("AXGroup", domClassList: ["c-virtual_list__item"],
                     frame: CGRect(x: x + 260, y: y + 100, width: 900, height: 40), children: [
                    text("Ada", ["c-message__sender"], y: y + 100, x: x + 260),
                    text("10:14 AM", ["c-timestamp"], y: y + 100, x: x + 700),
                    text("index rebuilt", nil, y: y + 118, x: x + 260),
                ]),
                node("AXGroup", domClassList: ["c-virtual_list__item"],
                     frame: CGRect(x: x + 260, y: y + 160, width: 900, height: 40), children: [
                    text("Grace", ["c-message__sender"], y: y + 160, x: x + 260),
                    text("10:16 AM", ["c-timestamp"], y: y + 160, x: x + 700),
                    text("deploy looks green", nil, y: y + 178, x: x + 260),
                ]),
            ]),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft, domClassList: ["ql-editor"],
                                 frame: CGRect(x: x + 260, y: y + 640, width: 900, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: children)
    }

    /// The pre-DOM shape SlackParserTests already covers: AXRow message rows in an x band.
    func geometryWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXRow", frame: CGRect(x: x + 10, y: y + 90, width: 200, height: 24),
                 children: [text("random-channel", nil, y: y + 90, x: x + 10)]),
            node("AXRow", frame: CGRect(x: x + 240, y: y + 100, width: 900, height: 40),
                 children: [text("Ada", nil, y: y + 100, x: x + 240),
                            text("index rebuilt", nil, y: y + 118, x: x + 240)]),
        ])
    }

    func context(_ title: String?, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigClaimsTheAppAndTheWebHostsAndForcesTheDOMClassList() {
        XCTAssertEqual(SlackParser.config.bundleIDs, [ParserRegistry.slackBundleID])
        XCTAssertEqual(SlackParser.config.hosts, ["app.slack.com", ".slack.com"])
        XCTAssertEqual(SlackParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(SlackParser.config.preferOverNative,
                      "a Slack tab must not fall to the generic web page")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.slackBundleID) is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SlackParser)
    }

    func testChannelNameIsTheFirstTitleComponent() {
        XCTAssertEqual(SlackParser.channelName(fromTitle: "general - Acme - Slack"), "general")
        XCTAssertEqual(SlackParser.channelName(fromTitle: "Huddle"), "Huddle")
        XCTAssertEqual(SlackParser.channelName(fromTitle: nil), "unknown")
    }

    func testDOMAnchorsProduceSenderAttributedTimestampedMessages() throws {
        let c = try conversation(SlackParser().parse(domWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, false],
                       "Slack's DOM exposes no self marker, so isUser is false for real messages")
        XCTAssertEqual(c.messages.map(\.isDraft), [false, false])
        XCTAssertEqual(c.messages[0].id,
                       Message.makeID(sender: "Ada", timeString: "10:14 AM", text: "index rebuilt"))
    }

    func testComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(SlackParser().parse(domWindow(draft: "shipping in five"),
                                                    context: context("general - Acme - Slack")))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "shipping in five")
        XCTAssertEqual(c.messages.count, 3, "the draft is appended, never replacing a message")
    }

    func testAnEmptyComposerProducesNoDraft() throws {
        let c = try conversation(SlackParser().parse(domWindow(draft: "   "),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.count, 2)
        XCTAssertFalse(c.messages.contains { $0.isDraft })
    }

    func testFallsBackToTheXBandHeuristicWhenNoDOMClassesAreExposed() throws {
        let c = try conversation(SlackParser().parse(geometryWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
        XCTAssertFalse(c.messages.contains { $0.text.contains("random-channel") },
                       "the sidebar band is excluded in the fallback too")
    }

    func testTheXBandFallbackIsWindowRelative() throws {
        let c = try conversation(SlackParser().parse(
            geometryWindow(origin: CGPoint(x: 600, y: 120)),
            context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"],
                       "a floated window must not turn every row into a sidebar row")
    }

    func testDOMResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(SlackParser().parse(domWindow(), context: context("general - Acme - Slack")),
                       SlackParser().parse(domWindow(origin: CGPoint(x: 1440, y: 220)),
                                           context: context("general - Acme - Slack")))
    }

    func testAWindowWithNeitherAnchorIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(SlackParser().parse(bare, context: context("x - y - Slack")))
    }

    func testRenderedConversationUsesYouForTheDraftAndNeverTheInternalUserMarker() throws {
        let content = try XCTUnwrap(SlackParser().parse(domWindow(draft: "shipping in five"),
                                                       context: context("general - Acme - Slack")))
        let rendered = ContentRenderer.render(content, style: .full)
        XCTAssertTrue(rendered.contains("(From: You (draft)): shipping in five"))
        XCTAssertFalse(rendered.contains("[user]"))
    }

    func testDOMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-dom-messages"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-dom-messages-golden")
    }

    func testOffsetNoDOMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-offset-no-dom"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-offset-no-dom-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SlackStructuredTests`
Expected: FAIL to compile — "type 'SlackParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/SlackParser.swift`:

```swift
extension SlackParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Slack",
        bundleIDs: [ParserRegistry.slackBundleID],
        // Slack in a browser tab gets the same anchors as the native app, and must beat the
        // generic web page (spec §7b).
        hosts: ["app.slack.com", ".slack.com"],
        // Slack's Electron tree does not always sit under an AXWebArea, so the DOM class list is
        // forced rather than gated (spec §7b, reconciliation 2).
        attributeSet: ["AXDOMClassList"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: true
    )

    static let messageListClass = "c-message_list"
    static let messageItemClass = "c-virtual_list__item"
    static let senderClass = "c-message__sender"
    static let timestampClass = "c-timestamp"
    static let composerClass = "ql-editor"

    /// "<view> - <workspace> - Slack" -> "<view>". Slack's title and message DOM carry no
    /// channel-vs-DM marker, which is why `isGroup` is always true (and unused by the renderer).
    static func channelName(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last == "Slack" { return parts[0] }
        return title
    }

    static func domMessages(in snapshot: AXNode) -> [Message] {
        guard let list = AXQuery.find("//*[domClass*=\"\(messageListClass)\"]", in: snapshot)
        else { return [] }
        let items = AXQuery.findAll("//*[domClass*=\"\(messageItemClass)\"]", in: list)
        return AXQuery.sortedByVisualOrder(items, relativeTo: list.frame).compactMap { item in
            let sender = AXQuery.find("//*[domClass*=\"\(senderClass)\"]", in: item)?
                .value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let timeString = AXQuery.find("//*[domClass*=\"\(timestampClass)\"]", in: item)?
                .value?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The body is every static text that is not the sender line and not the timestamp.
            let body = AXQuery.collectStaticTexts(in: item)
                .filter { $0 != sender && $0 != timeString }
                .joined(separator: " ")
            guard !body.isEmpty else { return nil }
            let resolvedSender = sender?.isEmpty == false ? sender! : "unknown"
            return Message(
                id: Message.makeID(sender: resolvedSender, timeString: timeString, text: body),
                sender: resolvedSender, text: body, timestamp: nil,
                timeString: timeString?.isEmpty == false ? timeString : nil,
                isUser: false, isDraft: false
            )
        }
    }

    /// The composer's live text. A draft is the one message Slack's tree marks as the user's.
    static func draftMessage(in snapshot: AXNode) -> Message? {
        guard let composer = AXQuery.find("//*[domClass*=\"\(composerClass)\"]", in: snapshot)
        else { return nil }
        let text = (composer.value ?? AXQuery.collectStaticTexts(in: composer).joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Message(id: Message.makeID(sender: "You", timeString: nil, text: text),
                       sender: "You", text: text, timestamp: nil, timeString: nil,
                       isUser: true, isDraft: true)
    }

    /// Today's x-band row heuristic, retyped. Used when Slack exposes no DOM classes at all
    /// (older builds, and a tree captured before AXManualAccessibility fully woke).
    static func geometryMessages(in snapshot: AXNode) -> [Message] {
        let windowX = snapshot.frame?.minX ?? 0
        return AXQuery.findAll("//AXRow", in: snapshot)
            .filter { row in
                // Window-relative: AXFrame is global screen coordinates.
                guard let x = row.frame?.minX else { return true }
                return (x - windowX) >= sidebarMaxX
            }
            .compactMap { row -> Message? in
                let texts = AXQuery.collectStaticTexts(in: row)
                guard let first = texts.first else { return nil }
                let sender = texts.count >= 2 ? first : "unknown"
                let body = texts.count >= 2 ? texts.dropFirst().joined(separator: " ") : first
                return Message(id: Message.makeID(sender: sender, timeString: nil, text: body),
                               sender: sender, text: body, timestamp: nil, timeString: nil,
                               isUser: false, isDraft: false)
            }
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        if messages.isEmpty { messages = Self.geometryMessages(in: snapshot) }
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        guard !messages.isEmpty else { return nil }
        return .conversation(Conversation(
            channel: Self.channelName(fromTitle: context.windowTitle),
            isGroup: true,
            messages: messages
        ))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, `SlackParser` claims both a bundle ID and hosts, so it goes in `structured` and the derived loop puts it in both maps automatically:

```swift
        let structured: [any StructuredParser] = [TerminalParser(), EditorParser(), SlackParser()]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SlackStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter SlackParserTests`
Expected: PASS, unchanged — `key(fromTitle:)`, `messageLines` and `parse(window:app:)` are untouched.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.tinyspeck.slackmacgap /tmp/slack-dom-messages.json
```

Record once with a channel open (DOM classes present, window flush at the origin) and once with the window at a nonzero origin — then, for `slack-offset-no-dom.json`, hand-**delete every `domClassList` key** from the scrubbed copy so the geometry fallback is what the golden pins.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `slack-offset-no-dom.json`),
- `slack-dom-messages.json`: one node with `domClassList` containing `c-message_list`, **two** descendants with `c-virtual_list__item`, each holding a `c-message__sender` static text, a `c-timestamp` static text and a body static text, plus one `AXTextArea` with `ql-editor` carrying invented draft text,
- `slack-offset-no-dom.json`: no `domClassList` anywhere; one sidebar `AXRow` at window-relative x < 240 and two message `AXRow`s at window-relative x >= 240, each with a sender static text and a body static text.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter SlackStructuredTests`
Expected: PASS, 12 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/SlackParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/SlackStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/slack-dom-messages.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-dom-messages-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-offset-no-dom.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-offset-no-dom-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Anchor Slack messages on DOM classes with a geometry fallback"
```

---

### Task 11: Discord → `.conversation` **with** sender attribution

**Files:**
- Modify: `Sources/MaxMiCapture/DiscordParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `DiscordParser()` in `structured`, with hosts)
- Create: `Tests/MaxMiCaptureTests/Fixtures/discord-messages.json`, `discord-messages-golden.json`, `discord-offset-messages.json`, `discord-offset-messages-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/DiscordStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.collectStaticTexts(in:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `DiscordParser: StructuredParser`; `DiscordParser.config` (bundle ID `ParserRegistry.discordBundleID`, hosts `["discord.com", "www.discord.com"]`, `preferOverNative: true`); `DiscordParser.messageList(in:) -> AXNode?`; `DiscordParser.channelName(fromTitle:) -> String`; `DiscordParser.messages(in list: AXNode) -> [Message]`; `DiscordParser.parseStructured(window:app:)`.
- `key(fromTitle:)`, `chrome`, `parse(window:app:)` are untouched — `DiscordParserTests` keeps passing verbatim.
- **This task fixes the missing sender attribution the current parser documents as unfixable**, and it must do so with **zero geometry**: Discord's `AXFrame` values are unreliable (spec §7c).

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/DiscordStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class DiscordStructuredTests: XCTestCase {
    /// Every frame here is deliberately identical and wrong — Discord's virtualised list collapses
    /// nodes onto one y and contradicts itself on x. A geometry-free parser must not care.
    let bogusFrame = CGRect(x: 0, y: 0, width: 0, height: 0)

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: bogusFrame,
               focused: false, children: children, identifier: identifier, label: label)
    }

    func text(_ value: String) -> AXNode { node("AXStaticText", value: value) }

    /// Sidebar chrome plus a "Messages in general" list holding two grouped messages, the second
    /// group containing two consecutive messages under one heading.
    func window(listLabel: String = "Messages in general") -> AXNode {
        node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Channels", children: [text("random-channel")]),
            node("AXList", label: listLabel, children: [
                node("AXGroup", children: [
                    node("AXHeading", value: "Ada"),
                    text("index rebuilt"),
                ]),
                node("AXGroup", children: [
                    node("AXHeading", value: "Grace"),
                    text("deploy looks green"),
                    text("shipping now"),
                ]),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigClaimsTheAppAndTheWebHosts() {
        XCTAssertEqual(DiscordParser.config.bundleIDs, [ParserRegistry.discordBundleID])
        XCTAssertEqual(DiscordParser.config.hosts, ["discord.com", "www.discord.com"])
        XCTAssertTrue(DiscordParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.discordBundleID) is DiscordParser)
        XCTAssertTrue(registry.structuredParser(forHost: "discord.com") is DiscordParser)
    }

    func testChannelNameComesFromTheTitle() {
        XCTAssertEqual(DiscordParser.channelName(fromTitle: "#general | Acme - Discord"), "general")
        XCTAssertEqual(DiscordParser.channelName(fromTitle: "Friends - Discord"), "Friends")
        XCTAssertEqual(DiscordParser.channelName(fromTitle: nil), "unknown")
    }

    func testMessageListIsFoundByIdentifierOrLabelContainingMessagesIn() throws {
        XCTAssertEqual(try XCTUnwrap(DiscordParser.messageList(in: window())).label,
                       "Messages in general")
        let byIdentifier = node("AXWindow", children: [
            node("AXList", identifier: "chat-messages Messages in general",
                 children: [node("AXGroup", children: [node("AXHeading", value: "Ada"),
                                                       text("hi")])]),
        ])
        XCTAssertNotNil(DiscordParser.messageList(in: byIdentifier))
        XCTAssertNil(DiscordParser.messageList(in: node("AXWindow",
                                                        children: [node("AXList", label: "Servers")])))
    }

    func testGroupHeadingBecomesTheSenderOfEveryMessageInThatGroup() throws {
        let c = try conversation(DiscordParser().parse(window(),
                                                      context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace", "Grace"],
                       "consecutive messages inherit their group's heading — the attribution fix")
        XCTAssertEqual(c.messages.map(\.text),
                       ["index rebuilt", "deploy looks green", "shipping now"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, false])
    }

    func testSidebarChannelsAreStructurallyOutOfReach() throws {
        let c = try conversation(DiscordParser().parse(window(),
                                                      context: context("#general | Acme - Discord")))
        XCTAssertFalse(c.messages.contains { $0.text.contains("random-channel") },
                       "the sidebar is a different AXList, so no geometry is needed to exclude it")
    }

    func testKnownUIChromeIsFilteredFromMessageBodies() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [
                    node("AXHeading", value: "Ada"),
                    text("Add Reaction"),
                    text("index rebuilt"),
                    text("Edited"),
                ]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
    }

    func testAGroupWithNoHeadingInheritsThePreviousSender() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [node("AXHeading", value: "Ada"), text("first")]),
                node("AXGroup", children: [text("second")]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Ada"])
    }

    func testAGroupWithNoHeadingAndNoPrecedingSenderIsAttributedToUnknown() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [text("orphan")]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.sender), ["unknown"])
    }

    func testNoMessageListIsNotHandled() {
        XCTAssertNil(DiscordParser().parse(node("AXWindow", children: [node("AXList", label: "Servers")]),
                                           context: context("#general | Acme - Discord")))
    }

    func testResultIsUnaffectedByFrameValuesEntirely() throws {
        // Same tree, every frame replaced with an absurd one. Discord's frames lie; the parser
        // must not read them at all.
        func reframed(_ node: AXNode, _ frame: CGRect) -> AXNode {
            AXNode(role: node.role, value: node.value, title: node.title, url: node.url,
                   frame: frame, focused: node.focused,
                   children: node.children.map { reframed($0, frame) },
                   identifier: node.identifier, label: node.label)
        }
        let a = DiscordParser().parse(window(), context: context("#general | Acme - Discord"))
        let b = DiscordParser().parse(reframed(window(), CGRect(x: -9_999, y: 5, width: 1, height: 1)),
                                      context: context("#general | Acme - Discord"))
        XCTAssertEqual(a, b)
    }

    func testDiscordFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(DiscordParser().parse(try fixture("discord-messages"),
                                                        context: context("#general | Acme - Discord"))),
                     matches: "discord-messages-golden")
    }

    func testOffsetDiscordFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(DiscordParser().parse(try fixture("discord-offset-messages"),
                                                        context: context("#general | Acme - Discord"))),
                     matches: "discord-offset-messages-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiscordStructuredTests`
Expected: FAIL to compile — "type 'DiscordParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/DiscordParser.swift`:

```swift
extension DiscordParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Discord",
        bundleIDs: [ParserRegistry.discordBundleID],
        hosts: ["discord.com", "www.discord.com"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: true
    )

    static let messageListMarker = "Messages in"

    /// "#<channel> | <server> - Discord" -> "<channel>".
    static func channelName(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        var head = title
        if let r = head.range(of: " - Discord", options: .backwards) {
            head = String(head[..<r.lowerBound])
        }
        let channel = head.components(separatedBy: " | ").first ?? head
        return channel.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    /// The transcript list, identified by the ONLY stable marker Discord exposes: an identifier
    /// or accessibility label containing "Messages in". No geometry — Discord's frames lie.
    static func messageList(in snapshot: AXNode) -> AXNode? {
        let byLabel = AXQuery.findAll("//AXList[label*=\"\(messageListMarker)\"]", in: snapshot)
        if let list = byLabel.first { return list }
        return AXQuery.findAll("//AXList[identifier*=\"\(messageListMarker)\"]", in: snapshot).first
    }

    /// One message per body line, attributed to its group's `AXHeading`. Discord groups
    /// consecutive messages from one author under a single heading, so a group without a heading
    /// inherits the last sender seen — which is exactly the attribution the old parser lost.
    static func messages(in list: AXNode) -> [Message] {
        var out: [Message] = []
        var lastSender: String?
        for group in list.children {
            let heading = AXQuery.findAll("//AXHeading", in: group)
                .compactMap { ($0.value ?? $0.title)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let heading { lastSender = heading }
            let sender = heading ?? lastSender ?? "unknown"
            // Tree order, not visual order: the frames are unusable.
            let bodies = staticTextsInTreeOrder(group)
                .filter { $0 != heading && !Self.chrome.contains($0) && $0.count > 1 }
            for body in bodies {
                out.append(Message(
                    id: Message.makeID(sender: sender, timeString: nil, text: body),
                    sender: sender, text: body, timestamp: nil, timeString: nil,
                    isUser: false, isDraft: false
                ))
            }
        }
        return out
    }

    static func staticTextsInTreeOrder(_ node: AXNode) -> [String] {
        var out: [String] = []
        func visit(_ current: AXNode) {
            if current.role == "AXStaticText",
               let value = current.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                out.append(value)
            }
            for child in current.children { visit(child) }
        }
        visit(node)
        return out
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let list = Self.messageList(in: snapshot) else { return nil }
        let messages = Self.messages(in: list)
        guard !messages.isEmpty else { return nil }
        return .conversation(Conversation(
            channel: Self.channelName(fromTitle: context.windowTitle),
            isGroup: true,
            messages: messages
        ))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`:

```swift
        let structured: [any StructuredParser] = [
            TerminalParser(), EditorParser(), SlackParser(), DiscordParser(),
        ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DiscordStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter DiscordParserTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.hnc.Discord /tmp/discord-messages.json
```

Record once flush at the origin and once with the window at a nonzero origin (the golden must be **identical apart from nothing** — Discord is geometry-free, so the two goldens differ only in the fixture they came from; that is the point of the pair).

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `discord-offset-messages.json`) and a `title` of the form `#general | Acme - Discord`,
- one `AXList` whose `label` or `identifier` contains `Messages in`,
- inside it, **two** child groups: the first with one `AXHeading` and one body `AXStaticText`; the second with one `AXHeading` and **two** body `AXStaticText`s, so grouped-message inheritance is exercised,
- a second `AXList` of sidebar channels **kept**, so structural exclusion is a real assertion,
- at least one chrome string from `DiscordParser.chrome` (e.g. `Add Reaction`) inside a message group.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter DiscordStructuredTests`
Expected: PASS, 12 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/DiscordParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/DiscordStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/discord-messages.json \
        Tests/MaxMiCaptureTests/Fixtures/discord-messages-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/discord-offset-messages.json \
        Tests/MaxMiCaptureTests/Fixtures/discord-offset-messages-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Attribute Discord messages to their group heading sender"
```

---

### Task 12: Messages → `.conversation` with bubble side → `isUser`

**Files:**
- Modify: `Sources/MaxMiCapture/MessagesParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `MessagesParser()` in `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/messages-thread.json`, `messages-thread-golden.json`, `messages-offset-thread.json`, `messages-offset-thread-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/MessagesStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `MessagesParser: StructuredParser`; `MessagesParser.config`; `MessagesParser.chatName(fromTitle:) -> String`; `MessagesParser.isUserBubble(_ bubble: AXNode, window: AXNode) -> Bool`; `MessagesParser.bubbles(in:) -> [AXNode]`; `MessagesParser.parseStructured(window:app:)`.
- `key(fromTitle:)` and `parse(window:app:)` are untouched — `MessagesParserTests` keeps passing verbatim.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/MessagesStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class MessagesStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: nil, label: label)
    }

    /// Window 900 wide: incoming bubbles on the left (midX < window midX), outgoing on the right.
    func window(origin: CGPoint = .zero, groupSenderLabels: Bool = false) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                              size: CGSize(width: 900, height: 700)),
                    children: [
            node("AXTextArea", value: "are we still on for 4",
                 label: groupSenderLabels ? "Ada" : nil,
                 frame: CGRect(x: x + 40, y: y + 100, width: 300, height: 40)),
            node("AXTextArea", value: "yes, see you then",
                 frame: CGRect(x: x + 540, y: y + 160, width: 300, height: 40)),
            node("AXStaticText", value: "Delivered",
                 frame: CGRect(x: x + 700, y: y + 205, width: 100, height: 14)),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(MessagesParser.config.bundleIDs, [ParserRegistry.messagesBundleID])
        XCTAssertEqual(MessagesParser.config.app, "Messages")
        XCTAssertTrue(MessagesParser.config.hosts.isEmpty, "Messages has no web client")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.messagesBundleID)
                        is MessagesParser)
    }

    func testChatNameComesFromTheWindowTitle() {
        XCTAssertEqual(MessagesParser.chatName(fromTitle: "Ada Lovelace"), "Ada Lovelace")
        XCTAssertEqual(MessagesParser.chatName(fromTitle: "  "), "unknown")
        XCTAssertEqual(MessagesParser.chatName(fromTitle: nil), "unknown")
    }

    func testBubbleSideDecidesIsUser() throws {
        let c = try conversation(MessagesParser().parse(window(), context: context("Ada Lovelace")))
        XCTAssertEqual(c.channel, "Ada Lovelace")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.map(\.text),
                       ["are we still on for 4", "yes, see you then", "Delivered"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, true, true])
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace", "You", "You"])
    }

    func testBubbleSideIsWindowRelativeSoANonzeroOriginChangesNothing() throws {
        let flush = try conversation(MessagesParser().parse(window(),
                                                          context: context("Ada Lovelace")))
        let offset = try conversation(MessagesParser().parse(
            window(origin: CGPoint(x: 1440, y: 220)), context: context("Ada Lovelace")))
        XCTAssertEqual(flush.messages.map(\.isUser), offset.messages.map(\.isUser),
                       "AXFrame is global, so midX must be compared against the window's midX")
        XCTAssertEqual(flush, offset)
    }

    func testIsUserBubbleComparesAgainstTheWindowMidpoint() {
        let win = node("AXWindow", frame: CGRect(x: 1000, y: 0, width: 900, height: 700))
        let left = node("AXTextArea", value: "a", frame: CGRect(x: 1040, y: 10, width: 300, height: 40))
        let right = node("AXTextArea", value: "b", frame: CGRect(x: 1540, y: 10, width: 300, height: 40))
        XCTAssertFalse(MessagesParser.isUserBubble(left, window: win))
        XCTAssertTrue(MessagesParser.isUserBubble(right, window: win))
    }

    func testBubbleWithNoFrameIsTreatedAsIncoming() {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let unpositioned = AXNode(role: "AXTextArea", value: "a", title: nil, url: nil,
                                  frame: nil, focused: false, children: [])
        XCTAssertFalse(MessagesParser.isUserBubble(unpositioned, window: win),
                       "an unknown side must never be claimed as the user's own message")
    }

    func testAGroupChatUsesTheBubbleLabelAsTheSender() throws {
        let c = try conversation(MessagesParser().parse(window(groupSenderLabels: true),
                                                      context: context("Weekend Plans")))
        XCTAssertEqual(c.messages[0].sender, "Ada",
                       "Messages puts a group sender in the bubble's accessibility description")
        XCTAssertEqual(c.messages[1].sender, "You")
    }

    func testMessagesAreOrderedTopToBottom() throws {
        let c = try conversation(MessagesParser().parse(window(), context: context("Ada Lovelace")))
        XCTAssertEqual(c.messages.map(\.text).first, "are we still on for 4")
    }

    func testEmptyTranscriptIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                        children: [node("AXButton", frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertNil(MessagesParser().parse(bare, context: context("Ada Lovelace")))
    }

    func testRenderedOutputUsesYouAndNeverTheInternalUserMarker() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(MessagesParser().parse(window(), context: context("Ada Lovelace"))),
            style: .full)
        XCTAssertTrue(rendered.contains("(From: You): yes, see you then"))
        XCTAssertFalse(rendered.contains("[user]"))
    }

    func testMessagesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(MessagesParser().parse(try fixture("messages-thread"),
                                                        context: context("Ada Lovelace"))),
                     matches: "messages-thread-golden")
    }

    func testOffsetMessagesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(MessagesParser().parse(try fixture("messages-offset-thread"),
                                                        context: context("Ada Lovelace"))),
                     matches: "messages-offset-thread-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MessagesStructuredTests`
Expected: FAIL to compile — "type 'MessagesParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/MessagesParser.swift`:

```swift
extension MessagesParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Messages",
        bundleIDs: [ParserRegistry.messagesBundleID],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3)
    )

    static let bubbleRoles: Set<String> = ["AXTextArea", "AXStaticText"]

    static func chatName(fromTitle title: String?) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    /// Outgoing bubbles sit right of the transcript's centre line. `AXFrame` is global screen
    /// coordinates, so the comparison is against the WINDOW's midX — a floated window would
    /// otherwise flip every message's authorship.
    static func isUserBubble(_ bubble: AXNode, window: AXNode) -> Bool {
        guard let bubbleFrame = bubble.frame, let windowFrame = window.frame,
              windowFrame.width > 0 else { return false }
        return bubbleFrame.midX > windowFrame.midX
    }

    static func bubbles(in snapshot: AXNode) -> [AXNode] {
        let found = AXQuery.all(in: snapshot) {
            bubbleRoles.contains($0.role)
                && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return AXQuery.sortedByVisualOrder(found, relativeTo: snapshot.frame)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let chat = Self.chatName(fromTitle: context.windowTitle)
        let messages = Self.bubbles(in: snapshot).compactMap { bubble -> Message? in
            guard let text = bubble.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let isUser = Self.isUserBubble(bubble, window: snapshot)
            // A group chat exposes the sender as the bubble's accessibility description; a 1:1
            // chat exposes nothing, so the chat name IS the other party.
            let sender = isUser
                ? "You"
                : (bubble.label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? chat
            return Message(id: Message.makeID(sender: sender, timeString: nil, text: text),
                           sender: sender, text: text, timestamp: nil, timeString: nil,
                           isUser: isUser, isDraft: false)
        }
        guard !messages.isEmpty else { return nil }
        // A 1:1 chat is titled with one name; a group chat's messages carry per-bubble senders.
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        return .conversation(Conversation(channel: chat, isGroup: isGroup, messages: messages))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `MessagesParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MessagesStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter MessagesParserTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.apple.MobileSMS /tmp/messages-thread.json
```

Record a 1:1 conversation flush at the origin, and a second recording with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `messages-offset-thread.json`) and the chat name as `title`,
- at least **two** `AXTextArea` bubbles with scrubbed `value`s: one whose `midX` is **left** of the window's `midX` and one whose `midX` is **right** of it, so both `isUser` outcomes are covered,
- one `AXStaticText` status line ("Delivered") on the right side,
- the sidebar conversation list may be deleted; it is not an anchor.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter MessagesStructuredTests`
Expected: PASS, 12 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/MessagesParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/MessagesStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/messages-thread.json \
        Tests/MaxMiCaptureTests/Fixtures/messages-thread-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/messages-offset-thread.json \
        Tests/MaxMiCaptureTests/Fixtures/messages-offset-thread-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Derive Messages authorship from bubble side"
```

---

### Task 13: WhatsApp → `.conversation` via `WAMessageBubbleTableViewCell`

**Files:**
- Modify: `Sources/MaxMiCapture/NativeConversationParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `WhatsAppParser()` in `structured`, with hosts)
- Create: `Tests/MaxMiCaptureTests/Fixtures/whatsapp-bubbles.json`, `whatsapp-bubbles-golden.json`, `whatsapp-offset-bubbles.json`, `whatsapp-offset-bubbles-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/WhatsAppStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `MessagesParser.isUserBubble(_:window:)` (Task 12); `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `WhatsAppParser: StructuredParser`; `WhatsAppParser.config` (bundle IDs `ParserRegistry.whatsAppBundleIDs`, hosts `["web.whatsapp.com"]`, `preferOverNative: true`); `WhatsAppParser.bubbleCellIdentifier = "WAMessageBubbleTableViewCell"`; `WhatsAppParser.timeStringPattern`; `WhatsAppParser.splitBubbleTexts(_:) -> (body: String, timeString: String?)`; `NativeConversationExtraction.conversationName(window:app:) -> String?` (promoted from private).
- `TeamsParser` is untouched in this task — it keeps Phase A's `.conversation` output; spec §7c lists no separate Teams anchor.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/WhatsAppStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WhatsAppStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              identifier: String? = nil, frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: label)
    }

    func bubble(_ body: String, time: String?, x: CGFloat, y: CGFloat, label: String? = nil) -> AXNode {
        var kids = [node("AXStaticText", value: body,
                         frame: CGRect(x: x, y: y, width: 260, height: 18))]
        if let time {
            kids.append(node("AXStaticText", value: time,
                             frame: CGRect(x: x + 220, y: y + 20, width: 40, height: 12)))
        }
        return node("AXCell", label: label, identifier: "WAMessageBubbleTableViewCell",
                    frame: CGRect(x: x, y: y, width: 300, height: 40), children: kids)
    }

    /// Window 1000 wide: incoming bubble left of centre, outgoing right of centre.
    func window(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                              size: CGSize(width: 1000, height: 700)),
                    children: [
            node("AXGroup", label: "Chats", frame: CGRect(x: x, y: y, width: 300, height: 700),
                 children: [node("AXStaticText", value: "Archived",
                                 frame: CGRect(x: x + 10, y: y + 20, width: 100, height: 16))]),
            node("AXHeading", value: "Ada Lovelace", label: "conversation title",
                 frame: CGRect(x: x + 340, y: y + 20, width: 200, height: 22)),
            bubble("are we still on for 4", time: "16:02", x: x + 340, y: y + 100),
            bubble("yes, see you then", time: "16:04", x: x + 660, y: y + 160),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(WhatsAppParser.config.bundleIDs, ParserRegistry.whatsAppBundleIDs)
        XCTAssertEqual(WhatsAppParser.config.hosts, ["web.whatsapp.com"])
        XCTAssertTrue(WhatsAppParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: "net.whatsapp.WhatsApp") is WhatsAppParser)
        XCTAssertTrue(registry.structuredParser(forHost: "web.whatsapp.com") is WhatsAppParser)
    }

    func testBubbleCellsAreTheOnlyMessageAnchor() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.text), ["are we still on for 4", "yes, see you then"])
        XCTAssertFalse(c.messages.contains { $0.text == "Archived" },
                       "the chat list is not a bubble cell, so it is structurally excluded")
    }

    func testTimeStringIsSplitOutOfTheBubbleBody() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.timeString), ["16:02", "16:04"])
        XCTAssertFalse(c.messages[0].text.contains("16:02"))
    }

    func testSplitBubbleTextsRecognisesBothTimeFormats() {
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "16:02"]).timeString, "16:02")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "4:02 PM"]).timeString, "4:02 PM")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "16:02"]).body, "hello")
        XCTAssertNil(WhatsAppParser.splitBubbleTexts(["hello", "there"]).timeString)
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts(["hello", "there"]).body, "hello there")
        XCTAssertEqual(WhatsAppParser.splitBubbleTexts([]).body, "")
    }

    func testBubbleSideDecidesIsUser() throws {
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.isUser), [false, true])
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace", "You"])
    }

    func testChannelComesFromTheConversationHeaderNotTheWindowTitle() throws {
        // WhatsApp's window title is just "WhatsApp"; the header carries the identity.
        let c = try conversation(WhatsAppParser().parse(window(), context: context("WhatsApp")))
        XCTAssertEqual(c.channel, "Ada Lovelace")
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(WhatsAppParser().parse(window(), context: context("WhatsApp")),
                       WhatsAppParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                              context: context("WhatsApp")))
    }

    func testAGroupBubbleLabelBecomesTheSender() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700), children: [
            node("AXHeading", value: "Weekend Plans", label: "conversation title",
                 frame: CGRect(x: 340, y: 20, width: 200, height: 22)),
            bubble("bringing snacks", time: "16:02", x: 340, y: 100, label: "Grace"),
        ])
        let c = try conversation(WhatsAppParser().parse(win, context: context("WhatsApp")))
        XCTAssertEqual(c.messages.map(\.sender), ["Grace"])
    }

    func testNoBubbleCellsIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                        children: [node("AXStaticText", value: "Use WhatsApp on your phone",
                                        frame: CGRect(x: 400, y: 300, width: 200, height: 16))])
        XCTAssertNil(WhatsAppParser().parse(bare, context: context("WhatsApp")))
    }

    func testWhatsAppFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(WhatsAppParser().parse(try fixture("whatsapp-bubbles"),
                                                        context: context("WhatsApp"))),
                     matches: "whatsapp-bubbles-golden")
    }

    func testOffsetWhatsAppFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(WhatsAppParser().parse(try fixture("whatsapp-offset-bubbles"),
                                                        context: context("WhatsApp"))),
                     matches: "whatsapp-offset-bubbles-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WhatsAppStructuredTests`
Expected: FAIL to compile — "type 'WhatsAppParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/NativeConversationParser.swift`, promote the existing title derivation so the structured parser reuses the tested logic instead of re-deriving it. Change `private static func conversationTitle` to `static func conversationTitle` and `private static func mainPaneBoundary` to `static func mainPaneBoundary`, then add:

```swift
extension NativeConversationExtraction {
    /// The conversation identity the v1 parser already derives from the header, exposed so the
    /// structured parsers do not re-implement it. WhatsApp's window title is just "WhatsApp".
    static func conversationName(window: AXNode, app: AppInfo) -> String? {
        conversationTitle(
            in: window, app: app,
            mainBoundary: mainPaneBoundary(window),
            requiresHeaderSemantics: true
        )
    }
}
```

Append to the same file:

```swift
extension WhatsAppParser: StructuredParser {
    public static let config = ParserConfig(
        app: "WhatsApp",
        bundleIDs: ParserRegistry.whatsAppBundleIDs,
        hosts: ["web.whatsapp.com"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000),
        preferOverNative: true
    )

    /// The one stable anchor WhatsApp exposes. Cells outside it (the chat list, banners, the
    /// "Use WhatsApp on your phone" notice) are structurally excluded.
    static let bubbleCellIdentifier = "WAMessageBubbleTableViewCell"
    /// "16:02" or "4:02 PM".
    static let timeStringPattern = "^\\d{1,2}:\\d{2}(\\s?[AP]M)?$"

    /// A bubble's static texts are the body plus, usually, a trailing timestamp.
    static func splitBubbleTexts(_ texts: [String]) -> (body: String, timeString: String?) {
        guard let last = texts.last,
              last.range(of: timeStringPattern, options: .regularExpression) != nil else {
            return (texts.joined(separator: " "), nil)
        }
        return (texts.dropLast().joined(separator: " "), last)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let cells = AXQuery.findAll("//*[identifier=\"\(Self.bubbleCellIdentifier)\"]", in: snapshot)
        guard !cells.isEmpty else { return nil }
        let channel = NativeConversationExtraction.conversationName(
            window: snapshot, app: context.app
        ) ?? context.windowTitle ?? "unknown"
        let messages = AXQuery.sortedByVisualOrder(cells, relativeTo: snapshot.frame)
            .compactMap { cell -> Message? in
                let split = Self.splitBubbleTexts(AXQuery.collectStaticTexts(in: cell))
                guard !split.body.isEmpty else { return nil }
                let isUser = MessagesParser.isUserBubble(cell, window: snapshot)
                let sender = isUser
                    ? "You"
                    : (cell.label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                        $0.isEmpty ? nil : $0
                    } ?? channel
                return Message(
                    id: Message.makeID(sender: sender, timeString: split.timeString,
                                       text: split.body),
                    sender: sender, text: split.body, timestamp: nil,
                    timeString: split.timeString, isUser: isUser, isDraft: false
                )
            }
        guard !messages.isEmpty else { return nil }
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        return .conversation(Conversation(channel: channel, isGroup: isGroup, messages: messages))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `WhatsAppParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WhatsAppStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter NativeConversationParserTests`
Expected: PASS, unchanged — only two access modifiers changed.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift net.whatsapp.WhatsApp /tmp/whatsapp-bubbles.json
```

Record a 1:1 chat flush at the origin, and a second recording with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `whatsapp-offset-bubbles.json`),
- the conversation header node (an `AXHeading` or `AXStaticText` whose `identifier`/`label` contains `conversation`, `chat`, `title` or `header`) carrying an invented contact name in the right-hand pane,
- **two** cells with `identifier == "WAMessageBubbleTableViewCell"`, one whose `midX` is left of the window's `midX` and one right of it, each holding a body `AXStaticText` and a `16:02`-shaped timestamp `AXStaticText`,
- the left-hand chat list **kept** with at least one `AXStaticText`, so structural exclusion is a real assertion.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter WhatsAppStructuredTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/NativeConversationParser.swift \
        Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/WhatsAppStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/whatsapp-bubbles.json \
        Tests/MaxMiCaptureTests/Fixtures/whatsapp-bubbles-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/whatsapp-offset-bubbles.json \
        Tests/MaxMiCaptureTests/Fixtures/whatsapp-offset-bubbles-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Anchor WhatsApp messages on bubble table cells"
```

---

### Task 14: Mail — compose-window subject field only

**Files:**
- Modify: `Sources/MaxMiCapture/MailParser.swift`
- Create: `Tests/MaxMiCaptureTests/MailComposeDraftTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.collectStaticTexts(in:)` (Tasks 3-4); `Message`, `Conversation`, `CapturedContent` (Phase A); `MailParser.parseStructured(window:app:)` as added by Phase A Task 8.
- Produces: `MailParser.subjectFieldIdentifier = "Mail.subjectField"`; `MailParser.composeDraft(window: AXNode) -> CapturedContent?`.
- **Mail keeps its AppleScript source** (spec §12 Q6: Mail's AX tree is ~80 ms/node, so reaching the message list would take minutes). This task adds the ONE AX read spec §7c still asks for and changes nothing else. `MailParserTests` keeps passing verbatim.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/MailComposeDraftTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class MailComposeDraftTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: 0, y: 0, width: 600, height: 400), focused: false,
               children: children, identifier: identifier, label: nil)
    }

    /// A Mail compose window: the subject field plus the body text area.
    func composeWindow(subject: String, body: String?) -> AXNode {
        var children = [node("AXTextField", value: subject, identifier: "Mail.subjectField")]
        if let body { children.append(node("AXTextArea", value: body)) }
        return node("AXWindow", children: children)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func testComposeWindowBecomesASingleUserDraftKeyedOnTheSubject() throws {
        let c = try conversation(MailParser.composeDraft(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today.")))
        XCTAssertEqual(c.channel, "Re: index rebuild")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.count, 1)
        let draft = c.messages[0]
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "Shipping the fix today.")
    }

    func testAnEmptyBodyStillProducesADraftSoTheSubjectIsCaptured() throws {
        let c = try conversation(MailParser.composeDraft(
            window: composeWindow(subject: "Quick question", body: nil)))
        XCTAssertEqual(c.channel, "Quick question")
        XCTAssertEqual(c.messages[0].text, "")
    }

    func testAnEmptySubjectAndEmptyBodyIsNotADraft() {
        XCTAssertNil(MailParser.composeDraft(window: composeWindow(subject: "   ", body: "  ")),
                     "an untouched compose window carries no information")
    }

    func testAWindowWithoutTheSubjectFieldIsNotAComposeWindow() {
        let reading = node("AXWindow", children: [
            node("AXTextArea", value: "the message you are reading"),
            node("AXTextField", value: "search", identifier: "Mail.searchField"),
        ])
        XCTAssertNil(MailParser.composeDraft(window: reading),
                     "no Mail.subjectField means the AppleScript path must run untouched")
    }

    func testTheSubjectFieldIsMatchedByExactIdentifier() {
        let lookalike = node("AXWindow", children: [
            node("AXTextField", value: "x", identifier: "Mail.subjectFieldContainer"),
        ])
        XCTAssertNil(MailParser.composeDraft(window: lookalike))
    }

    func testParseStructuredPrefersTheComposeDraftOverTheAppleScriptBody() throws {
        let app = AppInfo(bundleID: ParserRegistry.mailBundleID, name: "Mail",
                          windowTitle: "Re: index rebuild")
        let content = try MailParser().parseStructured(
            window: composeWindow(subject: "Re: index rebuild", body: "Shipping the fix today."),
            app: app)
        let c = try conversation(content)
        XCTAssertEqual(c.channel, "Re: index rebuild")
        XCTAssertTrue(c.messages.allSatisfy(\.isDraft),
                      "a frontmost compose window is what the user is doing right now")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MailComposeDraftTests`
Expected: FAIL to compile — "type 'MailParser' has no member 'composeDraft'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/MailParser.swift`, add next to the other `static let`s:

```swift
    /// The ONE AX attribute Mail is worth reading. Everything else comes from AppleScript,
    /// because Mail's AX tree costs ~80 ms per node (spec §12 Q6).
    static let subjectFieldIdentifier = "Mail.subjectField"
```

and add this method to `MailParser`:

```swift
    /// A frontmost compose window, as a single user draft. nil for every other Mail window, so
    /// the AppleScript path stays authoritative for reading mail.
    static func composeDraft(window: AXNode) -> CapturedContent? {
        guard let subjectField = AXQuery.find(
            "//*[identifier=\"\(subjectFieldIdentifier)\"]", in: window
        ) else { return nil }
        let subject = (subjectField.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The compose body is the largest text area in the window; a compose window has no others.
        let body = AXQuery.findAll("//AXTextArea", in: window)
            .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .max { $0.count < $1.count } ?? ""
        guard !subject.isEmpty || !body.isEmpty else { return nil }
        let channel = subject.isEmpty ? "(no subject)" : subject
        return .conversation(Conversation(
            channel: channel,
            isGroup: false,
            messages: [Message(id: Message.makeID(sender: "You", timeString: nil, text: body),
                               sender: "You", text: body, timestamp: nil, timeString: nil,
                               isUser: true, isDraft: true)]
        ))
    }
```

In `MailParser.parseStructured(window:app:)` (added by Phase A Task 8), insert this as the **first** statement of the method body:

```swift
        // A frontmost compose window is what the user is doing right now, so it wins over the
        // AppleScript-sourced inbox (spec §7c).
        if let draft = Self.composeDraft(window: window) { return draft }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MailComposeDraftTests`
Expected: PASS, 6 tests.

Run: `swift test --filter MailParserTests`
Expected: PASS, unchanged — `makeCapture(fromScriptOutput:windowTitle:)` and the `MailRecord` mapping are untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/MailParser.swift \
        Tests/MaxMiCaptureTests/MailComposeDraftTests.swift
git commit -m "Capture the Mail compose window as a draft"
```

---

### Task 15: Notes → `.document`

**Files:**
- Modify: `Sources/MaxMiCapture/NotesParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `NotesParser()` in `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/notes-body.json`, `notes-body-golden.json`, `notes-offset-shared.json`, `notes-offset-shared-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/NotesStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.collectStaticTexts(in:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Document`, `Block`, `Authorship`, `CapturedContent` (Phase A).
- Produces: `NotesParser: StructuredParser`; `NotesParser.config`; `NotesParser.bodyIdentifier = "Note Body Text View"`; `NotesParser.sharedSuffix = "— Shared"`; `NotesParser.noteTitle(fromBody lines: [String], windowTitle: String?) -> String`; `NotesParser.parseStructured(window:app:)`.
- `parse(window:app:)` (and its `notes:<slug>` key) is untouched — `DocumentParsersTests` keeps passing verbatim.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/NotesStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NotesStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func window(body: String?, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            node("AXOutline", frame: CGRect(x: x, y: y, width: 260, height: 700), children: [
                node("AXStaticText", value: "All iCloud",
                     frame: CGRect(x: x + 10, y: y + 20, width: 200, height: 16)),
            ]),
        ]
        if let body {
            children.append(node("AXTextArea", value: body, identifier: "Note Body Text View",
                                 frame: CGRect(x: x + 300, y: y + 60, width: 700, height: 620)))
        }
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1100, height: 760)),
                    children: children)
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.notesBundleID, name: "Notes",
                                  windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(NotesParser.config.bundleIDs, [ParserRegistry.notesBundleID])
        XCTAssertEqual(NotesParser.config.app, "Notes")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.notesBundleID)
                        is NotesParser)
    }

    func testTitleIsTheBodysFirstLineAndTheRestBecomesParagraphs() throws {
        let doc = try document(NotesParser().parse(
            window(body: "Grocery list\nmilk\noats"), context: context("Grocery list")))
        XCTAssertEqual(doc.title, "Grocery list")
        XCTAssertEqual(doc.blocks.map(\.text), ["milk", "oats"])
        XCTAssertEqual(doc.blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testTitleFallsBackToTheWindowTitleWhenTheBodyStartsBlank() throws {
        let doc = try document(NotesParser().parse(window(body: "\n\nmilk"),
                                                  context: context("Grocery list")))
        XCTAssertEqual(doc.title, "Grocery list")
        XCTAssertEqual(doc.blocks.map(\.text), ["milk"])
    }

    func testTitleFallsBackToUntitledWithNeitherSource() throws {
        let doc = try document(NotesParser().parse(window(body: "\nmilk"), context: context(nil)))
        XCTAssertEqual(doc.title, "untitled")
    }

    func testASharedHeaderLineMarksTheAuthorAsOther() throws {
        let doc = try document(NotesParser().parse(
            window(body: "Trip plan\nAda Lovelace — Shared\nflights booked"),
            context: context("Trip plan")))
        XCTAssertEqual(doc.author, .other("Ada Lovelace"))
        XCTAssertEqual(doc.blocks.map(\.text), ["flights booked"],
                       "the shared header is metadata, not note content")
    }

    func testASharedHeaderWithNoNameStillMarksTheNoteAsShared() throws {
        let doc = try document(NotesParser().parse(window(body: "Trip plan\n— Shared\nnotes"),
                                                  context: context("Trip plan")))
        XCTAssertEqual(doc.author, .unknown)
    }

    func testTheSidebarIsStructurallyExcluded() throws {
        let doc = try document(NotesParser().parse(window(body: "Grocery list\nmilk"),
                                                  context: context("Grocery list")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "All iCloud" })
    }

    func testWithoutTheBodyAnchorTheNoteIsNotHandled() {
        XCTAssertNil(NotesParser().parse(window(body: nil), context: context("Grocery list")),
                     "nil routes to GenericPageExtractor")
    }

    func testAnEmptyBodyIsNotHandled() {
        XCTAssertNil(NotesParser().parse(window(body: "   \n  "), context: context("x")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(
            NotesParser().parse(window(body: "Grocery list\nmilk"), context: context("Grocery list")),
            NotesParser().parse(window(body: "Grocery list\nmilk", origin: CGPoint(x: 1440, y: 220)),
                                context: context("Grocery list")))
    }

    func testNotesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotesParser().parse(try fixture("notes-body"),
                                                      context: context("Grocery list"))),
                     matches: "notes-body-golden")
    }

    func testOffsetSharedNotesFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotesParser().parse(try fixture("notes-offset-shared"),
                                                      context: context("Trip plan"))),
                     matches: "notes-offset-shared-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotesStructuredTests`
Expected: FAIL to compile — "type 'NotesParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/NotesParser.swift`:

```swift
extension NotesParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Notes",
        bundleIDs: [ParserRegistry.notesBundleID],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3)
    )

    /// Notes exposes the editor as one text area with a stable identifier, which is what keeps
    /// the note list and the folder sidebar out of the document.
    static let bodyIdentifier = "Note Body Text View"
    /// Notes appends this to a collaborator line on a shared note.
    static let sharedSuffix = "— Shared"

    static func noteTitle(fromBody lines: [String], windowTitle: String?) -> String {
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return first.trimmingCharacters(in: .whitespaces)
        }
        let fallback = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "untitled" : fallback
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let body = AXQuery.find("//*[identifier=\"\(Self.bodyIdentifier)\"]", in: snapshot),
              let raw = body.value,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var lines = raw.components(separatedBy: "\n")
        let title = Self.noteTitle(fromBody: lines, windowTitle: context.windowTitle)
        // Drop the title line itself, wherever the first non-blank line was.
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == title
        }) {
            lines.removeSubrange(...index)
        }
        // A shared note names its collaborator on a header line ending "— Shared".
        var author = Authorship.user
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasSuffix(Self.sharedSuffix)
        }) {
            let header = lines[index].trimmingCharacters(in: .whitespaces)
            let name = String(header.dropLast(Self.sharedSuffix.count))
                .trimmingCharacters(in: .whitespaces)
            author = name.isEmpty ? .unknown : .other(name)
            lines.remove(at: index)
        }
        let blocks = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Block(type: .paragraph, text: $0, authoredByUser: false) }
        return .document(Document(title: title, blocks: blocks, author: author, url: nil))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `NotesParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotesStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter DocumentParsersTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.apple.Notes /tmp/notes-body.json
```

Record a plain note flush at the origin, and a **shared** note with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `notes-offset-shared.json`),
- one `AXTextArea` with `identifier == "Note Body Text View"` whose scrubbed `value` has a title line plus at least two body lines; for `notes-offset-shared.json` the second line must end with `— Shared`,
- the folder `AXOutline` and the note-list `AXTable` **kept** with at least one `AXStaticText` each, so structural exclusion is a real assertion.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter NotesStructuredTests`
Expected: PASS, 12 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/NotesParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/NotesStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/notes-body.json \
        Tests/MaxMiCaptureTests/Fixtures/notes-body-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/notes-offset-shared.json \
        Tests/MaxMiCaptureTests/Fixtures/notes-offset-shared-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Anchor Notes on the note body text view"
```

---

### Task 16: Notion → `.document`

**Files:**
- Modify: `Sources/MaxMiCapture/NotionParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `NotionParser()` in `structured`, with hosts)
- Create: `Tests/MaxMiCaptureTests/Fixtures/notion-page.json`, `notion-page-golden.json`, `notion-offset-peek.json`, `notion-offset-peek-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/NotionStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)`, `AXQuery.Matchers`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Document`, `Block`, `Authorship`, `CapturedContent` (Phase A).
- Produces: `NotionParser: StructuredParser`; `NotionParser.config` (bundle ID `ParserRegistry.notionBundleID`, hosts `["www.notion.so", "notion.so", ".notion.site"]`, `attributeSet: ["AXDOMClassList"]`, `preferOverNative: true`); `NotionParser.frameClasses = ["notion-frame", "notion-peek-renderer"]`; `NotionParser.skippedClasses = ["layout-margin-right", "notion-page-properties"]`; `NotionParser.topbarClass = "notion-topbar"`; `NotionParser.pageRoot(in:) -> AXNode?`; `NotionParser.pageTitle(in:windowTitle:) -> String`; `NotionParser.blocks(under root: AXNode) -> [Block]`; `NotionParser.parseStructured(window:app:)`.
- `parse(window:app:)` (and its `notion:<slug>` key) is untouched.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/NotionStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class NotionStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, url: String? = nil,
              domClassList: [String]? = nil, headingLevel: Int? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: url, frame: frame, focused: false,
               children: children, identifier: nil, label: nil, subrole: nil,
               headingLevel: headingLevel, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat, classes: [String]? = nil) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 400, height: 20))
    }

    /// A Notion window: topbar, page frame with two blocks, a right margin and a property group.
    func window(frameClass: String = "notion-frame", origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1400, height: 900)),
                    children: [
            node("AXWebArea", url: "https://www.notion.so/acme/Roadmap-1",
                 frame: CGRect(x: x, y: y, width: 1400, height: 900), children: [
                node("AXGroup", domClassList: ["notion-topbar"],
                     frame: CGRect(x: x, y: y, width: 1400, height: 44), children: [
                    text("Roadmap", y: y + 12, x: x + 20),
                ]),
                node("AXGroup", domClassList: [frameClass],
                     frame: CGRect(x: x, y: y + 44, width: 1400, height: 856), children: [
                    node("AXHeading", value: "Q3 plan", headingLevel: 1,
                         frame: CGRect(x: x + 300, y: y + 100, width: 400, height: 30)),
                    text("Ship the index rebuild.", y: y + 150, x: x + 300),
                    node("AXGroup", domClassList: ["notion-page-properties"],
                         frame: CGRect(x: x + 300, y: y + 60, width: 400, height: 30), children: [
                        text("Status: In progress", y: y + 60, x: x + 300),
                    ]),
                    node("AXGroup", domClassList: ["layout-margin-right"],
                         frame: CGRect(x: x + 1100, y: y + 100, width: 280, height: 700),
                         children: [text("Comments", y: y + 100, x: x + 1100)]),
                ]),
            ]),
        ])
    }

    func context(_ title: String?, url: String? = nil) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.notionBundleID, name: "Notion",
                                  windowTitle: title), url: url)
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(NotionParser.config.bundleIDs, [ParserRegistry.notionBundleID])
        XCTAssertEqual(NotionParser.config.hosts, ["www.notion.so", "notion.so", ".notion.site"])
        XCTAssertEqual(NotionParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(NotionParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.notionBundleID) is NotionParser)
        XCTAssertTrue(registry.structuredParser(forHost: "www.notion.so") is NotionParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.notion.site") is NotionParser)
    }

    func testPageRootIsTheNotionFrame() throws {
        let root = try XCTUnwrap(NotionParser.pageRoot(in: window()))
        XCTAssertEqual(root.domClassList, ["notion-frame"])
    }

    func testPeekRendererIsAlsoAValidPageRoot() throws {
        let root = try XCTUnwrap(NotionParser.pageRoot(in: window(frameClass: "notion-peek-renderer")))
        XCTAssertEqual(root.domClassList, ["notion-peek-renderer"])
    }

    func testTitleComesFromTheTopbar() {
        XCTAssertEqual(NotionParser.pageTitle(in: window(), windowTitle: "Roadmap — Notion"),
                       "Roadmap")
    }

    func testTitleFallsBackToTheWindowTitleWithoutATopbar() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(NotionParser.pageTitle(in: bare, windowTitle: "Roadmap"), "Roadmap")
        XCTAssertEqual(NotionParser.pageTitle(in: bare, windowTitle: nil), "untitled")
    }

    func testHeadingsKeepTheirLevelAndBodyBecomesParagraphs() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertEqual(doc.title, "Roadmap")
        XCTAssertEqual(doc.blocks.map(\.type), [.heading(level: 1), .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["Q3 plan", "Ship the index rebuild."])
        XCTAssertEqual(doc.author, .user)
    }

    func testRightMarginAndPropertyGroupsAreSkipped() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Comments" },
                       "layout-margin-right is chrome")
        XCTAssertFalse(doc.blocks.contains { $0.text.hasPrefix("Status:") },
                       "page properties are metadata, not page body")
    }

    func testTopbarTextIsNotDuplicatedIntoTheBody() throws {
        let doc = try document(NotionParser().parse(window(), context: context("Roadmap — Notion")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Roadmap" })
    }

    func testUrlComesFromTheContextWhenPresent() throws {
        let doc = try document(NotionParser().parse(
            window(), context: context("Roadmap — Notion", url: "https://www.notion.so/acme/R-1")))
        XCTAssertEqual(doc.url, "https://www.notion.so/acme/R-1")
    }

    func testNoNotionFrameIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [text("loading", y: 0, x: 0)])
        XCTAssertNil(NotionParser().parse(bare, context: context("Notion")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(NotionParser().parse(window(), context: context("Roadmap — Notion")),
                       NotionParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                            context: context("Roadmap — Notion")))
    }

    func testNotionFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotionParser().parse(try fixture("notion-page"),
                                                       context: context("Roadmap — Notion"))),
                     matches: "notion-page-golden")
    }

    func testOffsetNotionPeekFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(NotionParser().parse(try fixture("notion-offset-peek"),
                                                       context: context("Roadmap — Notion"))),
                     matches: "notion-offset-peek-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotionStructuredTests`
Expected: FAIL to compile — "type 'NotionParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/NotionParser.swift`:

```swift
extension NotionParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Notion",
        bundleIDs: [ParserRegistry.notionBundleID],
        hosts: ["www.notion.so", "notion.so", ".notion.site"],
        // Notion's Electron shell does not always expose an AXWebArea above the page.
        attributeSet: ["AXDOMClassList"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: true
    )

    /// The page body, in the main view or in a peek (side-panel) view.
    static let frameClasses = ["notion-frame", "notion-peek-renderer"]
    /// Chrome that lives INSIDE the frame: the comment/backlink rail, and the property table.
    static let skippedClasses = ["layout-margin-right", "notion-page-properties"]
    static let topbarClass = "notion-topbar"

    static func pageRoot(in snapshot: AXNode) -> AXNode? {
        for pageClass in frameClasses {
            if let root = AXQuery.find("//*[domClass*=\"\(pageClass)\"]", in: snapshot) {
                return root
            }
        }
        return nil
    }

    static func pageTitle(in snapshot: AXNode, windowTitle: String?) -> String {
        if let topbar = AXQuery.find("//*[domClass*=\"\(topbarClass)\"]", in: snapshot),
           let first = AXQuery.collectStaticTexts(in: topbar).first {
            return first
        }
        let fallback = (windowTitle ?? "")
            .replacingOccurrences(of: " — Notion", with: "")
            .replacingOccurrences(of: " - Notion", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "untitled" : fallback
    }

    /// Text-bearing nodes under the page root, skipping the chrome subtrees. Headings keep their
    /// level; everything else is a paragraph.
    static func blocks(under root: AXNode) -> [Block] {
        var found: [AXNode] = []
        func visit(_ node: AXNode) {
            if node.hidden { return }
            let classes = (node.domClassList ?? []).map { $0.lowercased() }
            if skippedClasses.contains(where: { skipped in
                classes.contains { $0.contains(skipped) }
            }) { return }
            if node.role == "AXHeading" || node.role == "AXStaticText" {
                found.append(node)
                // A text-bearing node stops recursion, so a paragraph and its runs do not both
                // appear (the Phase A generic-extractor rule, applied here too).
                return
            }
            for child in node.children { visit(child) }
        }
        for child in root.children { visit(child) }
        var seen = Set<String>()
        return AXQuery.sortedByVisualOrder(found, relativeTo: root.frame)
            .compactMap { node -> Block? in
                guard let text = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, seen.insert(text).inserted else { return nil }
                let type: BlockType = node.role == "AXHeading"
                    ? .heading(level: min(max(node.headingLevel ?? 2, 1), 6))
                    : .paragraph
                return Block(type: type, text: text, authoredByUser: false)
            }
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let root = Self.pageRoot(in: snapshot) else { return nil }
        let title = Self.pageTitle(in: snapshot, windowTitle: context.windowTitle)
        let blocks = Self.blocks(under: root).filter { $0.text != title }
        guard !blocks.isEmpty else { return nil }
        return .document(Document(title: title, blocks: blocks, author: .user, url: context.url))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `NotionParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotionStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter DocumentParsersTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift notion.id /tmp/notion-page.json
```

Record a normal page flush at the origin, and a **peek** (open a database row so the side panel appears) with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `notion-offset-peek.json`),
- one node whose `domClassList` contains `notion-topbar`, holding the page title as an `AXStaticText`,
- one node whose `domClassList` contains `notion-frame` (`notion-peek-renderer` for the peek fixture), holding at least one `AXHeading` with a `headingLevel` and two body `AXStaticText`s,
- **kept inside that frame**: one subtree whose `domClassList` contains `layout-margin-right` and one whose `domClassList` contains `notion-page-properties`, each with an `AXStaticText`, so both skip rules are real assertions.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter NotionStructuredTests`
Expected: PASS, 13 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/NotionParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/NotionStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/notion-page.json \
        Tests/MaxMiCaptureTests/Fixtures/notion-page-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/notion-offset-peek.json \
        Tests/MaxMiCaptureTests/Fixtures/notion-offset-peek-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Anchor Notion pages on the notion frame class"
```

---

### Task 17: Obsidian → `.document`

**Files:**
- Modify: `Sources/MaxMiCapture/ObsidianParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `ObsidianParser()` in `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/obsidian-editor.json`, `obsidian-editor-golden.json`, `obsidian-offset-preview.json`, `obsidian-offset-preview-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/ObsidianStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)`, `AXQuery.all(in:where:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Document`, `Block`, `CapturedContent` (Phase A); `NotionParser.blocks(under:)` is **not** reused — Obsidian has no skip classes, so it gets its own three-line collector.
- Produces: `ObsidianParser: StructuredParser`; `ObsidianParser.config` (bundle ID `ParserRegistry.obsidianBundleID`, `attributeSet: ["AXDOMClassList"]`); `ObsidianParser.editorClass = "cm-editor"`; `ObsidianParser.previewClass = "markdown-preview-view"`; `ObsidianParser.noteName(fromTitle:) -> String` (the same title split `key(fromTitle:)` already performs); `ObsidianParser.paneRoot(in:) -> AXNode?`; `ObsidianParser.parseStructured(window:app:)`.
- `key(fromTitle:)` and `parse(window:app:)` are untouched — `DocumentParsersTests` keeps passing verbatim.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/ObsidianStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class ObsidianStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, domClassList: [String]? = nil,
              headingLevel: Int? = nil, frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: nil, label: nil, subrole: nil,
               headingLevel: headingLevel, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func window(paneClass: String, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1300, height: 850)),
                    children: [
            node("AXGroup", domClassList: ["nav-files-container"],
                 frame: CGRect(x: x, y: y, width: 260, height: 850), children: [
                node("AXStaticText", value: "Daily notes",
                     frame: CGRect(x: x + 10, y: y + 20, width: 200, height: 16)),
            ]),
            node("AXGroup", domClassList: [paneClass],
                 frame: CGRect(x: x + 300, y: y + 40, width: 1000, height: 810), children: [
                node("AXHeading", value: "Index rebuild", headingLevel: 2,
                     frame: CGRect(x: x + 320, y: y + 80, width: 400, height: 28)),
                node("AXStaticText", value: "vec0 uses L2, not cosine.",
                     frame: CGRect(x: x + 320, y: y + 120, width: 600, height: 20)),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.obsidianBundleID, name: "Obsidian",
                                  windowTitle: title))
    }

    func document(_ content: CapturedContent?) throws -> Document {
        guard case .document(let doc) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .document, got \(String(describing: content))")
        }
        return doc
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(ObsidianParser.config.bundleIDs, [ParserRegistry.obsidianBundleID])
        XCTAssertEqual(ObsidianParser.config.attributeSet, ["AXDOMClassList"])
        XCTAssertTrue(ObsidianParser.config.hosts.isEmpty, "Obsidian has no web client")
        XCTAssertTrue(ParserRegistry().structuredParser(for: ParserRegistry.obsidianBundleID)
                        is ObsidianParser)
    }

    func testNoteNameStripsTheVaultAndVersionSuffixes() {
        XCTAssertEqual(
            ObsidianParser.noteName(fromTitle: "Index rebuild - Research - Obsidian v1.5.3"),
            "Index rebuild")
        XCTAssertEqual(
            ObsidianParser.noteName(fromTitle: "Weekly - review - Research - Obsidian v1.5.3"),
            "Weekly - review", "a note name may itself contain \" - \"")
        XCTAssertEqual(ObsidianParser.noteName(fromTitle: "Obsidian"), "Obsidian")
        XCTAssertEqual(ObsidianParser.noteName(fromTitle: nil), "untitled")
    }

    func testEditorPaneIsAnAnchor() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "cm-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertEqual(doc.title, "Index rebuild")
        XCTAssertEqual(doc.blocks.map(\.type), [.heading(level: 2), .paragraph])
        XCTAssertEqual(doc.blocks.map(\.text), ["Index rebuild", "vec0 uses L2, not cosine."])
        XCTAssertEqual(doc.author, .user)
        XCTAssertNil(doc.url)
    }

    func testPreviewPaneIsAlsoAnAnchor() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "markdown-preview-view"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertEqual(doc.blocks.map(\.text), ["Index rebuild", "vec0 uses L2, not cosine."])
    }

    func testTheFileNavigatorIsStructurallyExcluded() throws {
        let doc = try document(ObsidianParser().parse(
            window(paneClass: "cm-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3")))
        XCTAssertFalse(doc.blocks.contains { $0.text == "Daily notes" })
    }

    func testTheEditorPaneWinsWhenBothPanesArePresent() throws {
        let both = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1300, height: 850), children: [
            node("AXGroup", domClassList: ["markdown-preview-view"],
                 frame: CGRect(x: 800, y: 40, width: 500, height: 810), children: [
                node("AXStaticText", value: "preview copy",
                     frame: CGRect(x: 820, y: 80, width: 400, height: 20)),
            ]),
            node("AXGroup", domClassList: ["cm-editor"],
                 frame: CGRect(x: 300, y: 40, width: 500, height: 810), children: [
                node("AXStaticText", value: "editor copy",
                     frame: CGRect(x: 320, y: 80, width: 400, height: 20)),
            ]),
        ])
        let doc = try document(ObsidianParser().parse(both, context: context("Note - V - Obsidian v1")))
        XCTAssertEqual(doc.blocks.map(\.text), ["editor copy"],
                       "in split view the editor is what the user is editing")
    }

    func testNeitherPaneIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [node("AXStaticText", value: "loading vault",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 16))])
        XCTAssertNil(ObsidianParser().parse(bare, context: context("Obsidian")))
    }

    func testAnEmptyPaneIsNotHandled() {
        let empty = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                         children: [node("AXGroup", domClassList: ["cm-editor"],
                                         frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertNil(ObsidianParser().parse(empty, context: context("Note - V - Obsidian v1")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        let title = "Index rebuild - Research - Obsidian v1.5.3"
        XCTAssertEqual(
            ObsidianParser().parse(window(paneClass: "cm-editor"), context: context(title)),
            ObsidianParser().parse(window(paneClass: "cm-editor", origin: CGPoint(x: 1440, y: 220)),
                                   context: context(title)))
    }

    func testObsidianEditorFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(ObsidianParser().parse(
            try fixture("obsidian-editor"),
            context: context("Index rebuild - Research - Obsidian v1.5.3"))),
                     matches: "obsidian-editor-golden")
    }

    func testOffsetObsidianPreviewFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(ObsidianParser().parse(
            try fixture("obsidian-offset-preview"),
            context: context("Index rebuild - Research - Obsidian v1.5.3"))),
                     matches: "obsidian-offset-preview-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ObsidianStructuredTests`
Expected: FAIL to compile — "type 'ObsidianParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/ObsidianParser.swift`:

```swift
extension ObsidianParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Obsidian",
        bundleIDs: [ParserRegistry.obsidianBundleID],
        // Obsidian is Electron and does not always expose an AXWebArea above the vault view.
        attributeSet: ["AXDOMClassList"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3)
    )

    /// CodeMirror's editor root (edit mode) and the rendered pane (reading mode).
    static let editorClass = "cm-editor"
    static let previewClass = "markdown-preview-view"

    /// "<note> - <vault> - Obsidian <version>" -> "<note>". Same split `key(fromTitle:)` uses:
    /// parsed from the end, because a note name may itself contain " - ".
    static func noteName(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "untitled" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last?.hasPrefix("Obsidian") == true {
            return parts.dropLast(2).joined(separator: " - ")
        }
        return title
    }

    /// Edit mode wins over reading mode: in split view, the editor is what the user is changing.
    static func paneRoot(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[domClass*=\"\(editorClass)\"]", in: snapshot)
            ?? AXQuery.find("//*[domClass*=\"\(previewClass)\"]", in: snapshot)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        guard let pane = Self.paneRoot(in: snapshot) else { return nil }
        let texts = AXQuery.all(in: pane) {
            ($0.role == "AXHeading" || $0.role == "AXStaticText") && !$0.hidden
        }
        var seen = Set<String>()
        let blocks = AXQuery.sortedByVisualOrder(texts, relativeTo: pane.frame)
            .compactMap { node -> Block? in
                guard let text = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, seen.insert(text).inserted else { return nil }
                let type: BlockType = node.role == "AXHeading"
                    ? .heading(level: min(max(node.headingLevel ?? 2, 1), 6))
                    : .paragraph
                return Block(type: type, text: text, authoredByUser: false)
            }
        guard !blocks.isEmpty else { return nil }
        return .document(Document(title: Self.noteName(fromTitle: context.windowTitle),
                                  blocks: blocks, author: .user, url: nil))
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `ObsidianParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ObsidianStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter DocumentParsersTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift md.obsidian /tmp/obsidian-editor.json
```

Record edit mode flush at the origin, and reading mode (Cmd-E) with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `obsidian-offset-preview.json`) and a `title` of the form `<note> - <vault> - Obsidian v1.x.y`,
- one node whose `domClassList` contains `cm-editor` (`markdown-preview-view` for the reading-mode fixture) holding at least one `AXHeading` with a `headingLevel` and two body `AXStaticText`s,
- the file navigator (`nav-files-container`) **kept** with at least one `AXStaticText`, so structural exclusion is a real assertion.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter ObsidianStructuredTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/ObsidianParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/ObsidianStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/obsidian-editor.json \
        Tests/MaxMiCaptureTests/Fixtures/obsidian-editor-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/obsidian-offset-preview.json \
        Tests/MaxMiCaptureTests/Fixtures/obsidian-offset-preview-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Anchor Obsidian on the CodeMirror editor and preview panes"
```

---

### Task 18: Finder → `.generic` with table rows, selection and a sidebar region

**Files:**
- Create: `Sources/MaxMiCapture/FinderParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `FinderParser()` in both `parsers` and `structured`)
- Modify: `Sources/MaxMiCore/ApplicationRegistry.swift` (Finder descriptor, `.nativeParser`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/finder-list.json`, `finder-list-golden.json`, `finder-offset-copy.json`, `finder-offset-copy-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/FinderStructuredTests.swift`

**Interfaces:**
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)` and its `Options` (Phase A — Finder's regions and joined rows are exactly what the §4e rules already produce, so this parser adds a path, not a second walk); `AXQuery.find(_:in:)` (Task 3); `StructuredParser`, `ParserConfig`, `ParseContext`, `ParserRegistry.finderBundleID` (Task 5); `GenericPage`, `RegionKind`, `BlockType`, `CapturedContent` (Phase A).
- Produces: `FinderParser: SourceParser, StructuredParser`; `FinderParser.config`; `FinderParser.folderPath(in: AXNode, windowTitle: String?) -> String?`; `FinderParser.key(fromPath:windowTitle:) -> String` producing `"finder:<slug>"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/FinderStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class FinderStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, url: String? = nil,
              identifier: String? = nil, selected: Bool = false,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil, subrole: nil,
               headingLevel: nil, selected: selected)
    }

    func cell(_ text: String, x: CGFloat, y: CGFloat) -> AXNode {
        node("AXCell", frame: CGRect(x: x, y: y, width: 160, height: 20), children: [
            node("AXStaticText", value: text, frame: CGRect(x: x, y: y, width: 160, height: 16)),
        ])
    }

    /// Window 1200 wide: a source-list sidebar on the left, a file table in the middle, and a
    /// toolbar carrying a copy-progress status line.
    func window(status: String?, origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        var toolbarKids = [node("AXButton", title: "Back",
                                frame: CGRect(x: x + 20, y: y + 8, width: 40, height: 24))]
        if let status {
            toolbarKids.append(node("AXStaticText", value: status,
                                    frame: CGRect(x: x + 400, y: y + 8, width: 260, height: 20)))
        }
        return node("AXWindow", title: "sample", url: "file:///Users/ada/code/sample",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXToolbar", frame: CGRect(x: x, y: y, width: 1200, height: 40),
                 children: toolbarKids),
            node("AXSplitGroup", frame: CGRect(x: x, y: y + 40, width: 1200, height: 760),
                 children: [
                node("AXGroup", identifier: "Finder.sidebar",
                     frame: CGRect(x: x, y: y + 40, width: 240, height: 760), children: [
                    node("AXOutline", frame: CGRect(x: x, y: y + 40, width: 240, height: 760),
                         children: [
                        node("AXRow", frame: CGRect(x: x + 10, y: y + 80, width: 220, height: 20),
                             children: [node("AXStaticText", value: "Downloads",
                                             frame: CGRect(x: x + 10, y: y + 80,
                                                           width: 200, height: 16))]),
                    ]),
                ]),
                node("AXTable", frame: CGRect(x: x + 240, y: y + 40, width: 960, height: 760),
                     children: [
                    node("AXRow", frame: CGRect(x: x + 240, y: y + 100, width: 960, height: 20),
                         children: [cell("Package.swift", x: x + 240, y: y + 100),
                                    cell("3 KB", x: x + 600, y: y + 100)]),
                    node("AXRow", selected: true,
                         frame: CGRect(x: x + 240, y: y + 130, width: 960, height: 20),
                         children: [cell("README.md", x: x + 240, y: y + 130),
                                    cell("12 KB", x: x + 600, y: y + 130)]),
                ]),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                                  windowTitle: title))
    }

    func page(_ content: CapturedContent?) throws -> GenericPage {
        guard case .generic(let page) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .generic, got \(String(describing: content))")
        }
        return page
    }

    func blocks(_ page: GenericPage, _ kind: RegionKind) -> [Block] {
        page.regions.first { $0.kind == kind }?.blocks ?? []
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(FinderParser.config.bundleIDs, [ParserRegistry.finderBundleID])
        XCTAssertEqual(FinderParser.config.app, "Finder")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.finderBundleID) is FinderParser)
        XCTAssertTrue(registry.parser(for: ParserRegistry.finderBundleID) is FinderParser)
        XCTAssertEqual(ApplicationRegistry.descriptor(for: ParserRegistry.finderBundleID)?
                        .captureStrategy, .nativeParser)
    }

    func testFolderPathComesFromAXDocumentThenTheWindowTitle() {
        XCTAssertEqual(FinderParser.folderPath(in: window(status: nil), windowTitle: "sample"),
                       "/Users/ada/code/sample")
        let noDocument = node("AXWindow", title: "Downloads",
                              frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(FinderParser.folderPath(in: noDocument, windowTitle: "Downloads"),
                       "Downloads")
        XCTAssertNil(FinderParser.folderPath(
            in: node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            windowTitle: nil))
    }

    func testKeyIsPathScoped() {
        XCTAssertEqual(FinderParser.key(fromPath: "/Users/ada/code/sample", windowTitle: "sample"),
                       "finder:/users/ada/code/sample")
        XCTAssertEqual(FinderParser.key(fromPath: nil, windowTitle: "Downloads"),
                       "finder:downloads")
        XCTAssertEqual(FinderParser.key(fromPath: nil, windowTitle: nil), "finder:unknown")
    }

    func testFileRowsLandInMainAsJoinedTableRowsWithSelection() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(blocks(page, .main).map(\.type), [
            .tableRow(cells: ["Package.swift", "3 KB"], selected: false),
            .tableRow(cells: ["README.md", "12 KB"], selected: true),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(blocks(page, .main)[1]), "* README.md | 12 KB")
    }

    func testSidebarFoldersLandInTheSidebarRegion() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(blocks(page, .sidebar).map(\.text), ["Downloads"])
        XCTAssertFalse(blocks(page, .main).contains { $0.text.contains("Downloads") },
                       "the source list is not part of the folder listing")
    }

    func testTheCopyProgressStatusLandsInTheToolbarRegion() throws {
        let page = try page(FinderParser().parse(window(status: "Uploading 34 items"),
                                                context: context("sample")))
        XCTAssertEqual(blocks(page, .toolbar).map(\.text), ["Back", "Uploading 34 items"])
    }

    func testTheFolderPathIsCarriedAsTheUrl() throws {
        let page = try page(FinderParser().parse(window(status: nil), context: context("sample")))
        XCTAssertEqual(page.url, "/Users/ada/code/sample")
    }

    func testRegionsAreIdenticalAtANonzeroWindowOrigin() throws {
        let flush = try page(FinderParser().parse(window(status: "Uploading 34 items"),
                                                context: context("sample")))
        let offset = try page(FinderParser().parse(
            window(status: "Uploading 34 items", origin: CGPoint(x: 1440, y: 220)),
            context: context("sample")))
        XCTAssertEqual(flush.regions, offset.regions,
                       "the sidebar heuristic is window-relative (spec §4e)")
    }

    func testAnEmptyWindowIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertNil(FinderParser().parse(bare, context: context("sample")))
    }

    func testSourceParserSuppliesTheKeyAndTheGenericKind() throws {
        let app = AppInfo(bundleID: ParserRegistry.finderBundleID, name: "Finder",
                          windowTitle: "sample")
        let parsed = try XCTUnwrap(try FinderParser().parse(window: window(status: nil), app: app))
        XCTAssertEqual(parsed.sourceApp, "Finder")
        XCTAssertEqual(parsed.sourceKey, "finder:/users/ada/code/sample")
        XCTAssertEqual(parsed.contentKind, .generic)
        XCTAssertEqual(parsed.accumulationPolicy, .replace)
    }

    func testFinderListFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(FinderParser().parse(try fixture("finder-list"),
                                                       context: context("sample"))),
                     matches: "finder-list-golden")
    }

    func testOffsetFinderCopyFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(FinderParser().parse(try fixture("finder-offset-copy"),
                                                       context: context("sample"))),
                     matches: "finder-offset-copy-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FinderStructuredTests`
Expected: FAIL to compile — "cannot find 'FinderParser' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/FinderParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Finder. A Finder window is exactly what `GenericPageExtractor` was designed for: a source
/// list that must become a `.sidebar` region, a table whose rows must join into one
/// `.tableRow` block each (not one block per cell), and a toolbar whose progress text must not
/// be mixed into the listing. So this parser adds identity — the folder path — and delegates
/// the walk, rather than re-implementing the §4e rules.
public struct FinderParser: SourceParser, StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Finder",
        bundleIDs: [ParserRegistry.finderBundleID],
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    /// `AXDocument` on the window is a file URL; the window title is only a folder name.
    static func folderPath(in snapshot: AXNode, windowTitle: String?) -> String? {
        if let raw = snapshot.url, !raw.isEmpty {
            if let url = URL(string: raw), url.isFileURL { return url.path }
            return raw
        }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    static func key(fromPath path: String?, windowTitle: String?) -> String {
        if let path, !path.isEmpty { return "finder:\(path.lowercased())" }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "finder:unknown" : "finder:\(docSlug(title))"
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = Self.config.offscreenPolicy
        let page = GenericPageExtractor.extract(
            window: snapshot,
            focusedElement: nil,
            url: Self.folderPath(in: snapshot, windowTitle: context.windowTitle),
            options: options
        ).page
        guard !page.regions.isEmpty else { return nil }
        return .generic(page)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = parse(window, context: ParseContext(app: app)) else { return nil }
        let path = Self.folderPath(in: window, windowTitle: app.windowTitle)
        return ParsedCapture(
            sourceApp: "Finder",
            sourceKey: Self.key(fromPath: path, windowTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .generic,
            parserVersion: 1,
            // §4d: .generic accumulates by replace.
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: structured
        )
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`:

```swift
            Self.finderBundleID: FinderParser(),
```

(inside the `p` dictionary literal, next to the other native entries) and append `FinderParser()` to `structured`.

In `Sources/MaxMiCore/ApplicationRegistry.swift`, add to `highValueApps`:

```swift
        native("com.apple.finder", "Finder", .system),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FinderStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter ApplicationRegistryTests`
Expected: PASS.

Run: `swift test --filter GenericPageRegionTests`
Expected: PASS — Phase A's own Finder region test (`finder-offset-window.json`) is unaffected; this task adds a parser on top of the same extractor.

- [ ] **Step 5: Record the two fixtures and their goldens**

```bash
swift tools/ax-snapshot-record.swift com.apple.finder /tmp/finder-list.json
```

Record a list-view folder flush at the origin with **one row selected**, and a second recording during a copy (so the toolbar carries a progress status) with the window at a nonzero origin.

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `finder-offset-copy.json`) and its `AXDocument` file URL as `url`,
- an `AXToolbar` holding at least one `AXStaticText`; for `finder-offset-copy.json` that text must be a copy-progress line such as `Uploading 34 items`,
- an `AXSplitGroup` whose left child is narrower than 0.35 × the window width, is within 0.05 × the window width of the left edge, and contains an `AXOutline` with at least one `AXRow` — that is exactly §4e sidebar rule 5,
- an `AXTable` with **two** `AXRow`s, each holding two `AXCell`s, one row with `selected: true`.

Hand-scrub, move into `Fixtures/`, print and save the goldens, and add four README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter FinderStructuredTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/FinderParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Sources/MaxMiCore/ApplicationRegistry.swift \
        Tests/MaxMiCaptureTests/FinderStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/finder-list.json \
        Tests/MaxMiCaptureTests/Fixtures/finder-list-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/finder-offset-copy.json \
        Tests/MaxMiCaptureTests/Fixtures/finder-offset-copy-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture Finder windows as sidebar, listing and toolbar regions"
```

---

### Task 19: Calendar and Fantastical → `.calendar`

**Files:**
- Modify: `Sources/MaxMiCapture/StructuredNativeParsers.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register both in `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/calendar-offset-event.json`, `calendar-offset-event-golden.json`, `calendar-event-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/CalendarStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)` (Task 3); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `CalendarEvent`, `CapturedContent` (Phase A); `StructuredEntityExtraction.preferredDetailRoot(in:hints:)`, `.orderedFields(in:)`, `.Field`, `.firstValue(_:metadataHints:)`, `.looksLikeDateOrTime(_:)`, `.isChrome(_:)` — **all six promoted from `private` to `internal`** so the retyped parser reuses the anchor the existing tests already cover.
- Produces: `CalendarStructuredExtraction.events(in: AXNode, windowTitle: String?) -> [CalendarEvent]`; `CalendarParser: StructuredParser` and `FantasticalParser: StructuredParser`, each with `config` and the `parseStructured` bridge.
- The two `parse(window:app:)` methods and their `calendar:event:<hash>` keys are untouched — `StructuredNativeParserTests` keeps passing verbatim. The existing `calendar-event.json` fixture is reused; only its golden is new.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/CalendarStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class CalendarStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func field(_ role: String, _ value: String, _ identifier: String,
               y: CGFloat, x: CGFloat) -> AXNode {
        node(role, value: value, identifier: identifier,
             frame: CGRect(x: x, y: y, width: 300, height: 20))
    }

    /// A Calendar window with a sidebar and an event-detail popover.
    func window(origin: CGPoint = .zero, conference: Bool = false) -> AXNode {
        let x = origin.x
        let y = origin.y
        var detail = [
            field("AXHeading", "Design review", "event-title", y: y + 140, x: x + 420),
            field("AXStaticText", "Thursday 12 September, 14:00 to 15:00", "event-date",
                  y: y + 180, x: x + 420),
            field("AXStaticText", "Room 4", "event-location", y: y + 210, x: x + 420),
            field("AXStaticText", "ada@example.com", "event-organizer", y: y + 240, x: x + 420),
        ]
        if conference {
            detail.append(field("AXLink", "Join video call", "event-conference",
                                y: y + 270, x: x + 420))
        }
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1200, height: 800)),
                    children: [
            node("AXGroup", identifier: "calendar-sidebar",
                 frame: CGRect(x: x, y: y, width: 220, height: 800), children: [
                node("AXStaticText", value: "Today",
                     frame: CGRect(x: x + 20, y: y + 80, width: 100, height: 20)),
            ]),
            node("AXPopover", identifier: "event-detail",
                 frame: CGRect(x: x + 400, y: y + 120, width: 480, height: 420),
                 children: detail),
        ])
    }

    func context(_ bundleID: String, _ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: bundleID, name: "Calendar", windowTitle: title))
    }

    func events(_ content: CapturedContent?) throws -> [CalendarEvent] {
        guard case .calendar(let events) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .calendar, got \(String(describing: content))")
        }
        return events
    }

    func testConfigsAndRegistration() {
        XCTAssertEqual(CalendarParser.config.bundleIDs, ParserRegistry.calendarBundleIDs)
        XCTAssertEqual(CalendarParser.config.app, "Calendar")
        XCTAssertEqual(FantasticalParser.config.bundleIDs, ParserRegistry.fantasticalBundleIDs)
        XCTAssertEqual(FantasticalParser.config.app, "Fantastical")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: "com.apple.iCal") is CalendarParser)
        XCTAssertTrue(registry.structuredParser(for: "com.flexibits.fantastical2.mac")
                        is FantasticalParser)
    }

    func testEventDetailBecomesOneCalendarEvent() throws {
        let list = try events(CalendarParser().parse(window(),
                                                   context: context("com.apple.iCal", "Calendar")))
        XCTAssertEqual(list.count, 1)
        let event = list[0]
        XCTAssertEqual(event.title, "Design review")
        XCTAssertEqual(event.dateString, "Thursday 12 September, 14:00 to 15:00")
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.organizer, "ada@example.com")
        XCTAssertFalse(event.hasConference)
        XCTAssertNil(event.start, "M8 stores the date STRING; parsing it is not in scope")
        XCTAssertNil(event.end)
    }

    func testAConferenceLinkSetsHasConference() throws {
        let list = try events(CalendarParser().parse(window(conference: true),
                                                    context: context("com.apple.iCal", "Calendar")))
        XCTAssertTrue(list[0].hasConference)
    }

    func testDateFallsBackToADateLookingFieldWithoutAMetadataHint() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXPopover", identifier: "event-detail",
                 frame: CGRect(x: 400, y: 120, width: 480, height: 420), children: [
                field("AXHeading", "Standup", "no-hint-title", y: 140, x: 420),
                field("AXStaticText", "Tomorrow 09:30 AM", "unlabelled", y: 180, x: 420),
            ]),
        ])
        let list = try events(CalendarParser().parse(win, context: context("com.apple.iCal", nil)))
        XCTAssertEqual(list[0].dateString, "Tomorrow 09:30 AM")
    }

    func testSidebarChromeNeverBecomesAnEventTitle() throws {
        let list = try events(CalendarParser().parse(window(),
                                                   context: context("com.apple.iCal", "Calendar")))
        XCTAssertFalse(list.contains { $0.title == "Today" })
    }

    func testNoDetailRootIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                        children: [node("AXGroup", identifier: "calendar-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 220, height: 800))])
        XCTAssertNil(CalendarParser().parse(bare, context: context("com.apple.iCal", "Calendar")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(CalendarParser().parse(window(), context: context("com.apple.iCal", "Calendar")),
                       CalendarParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                              context: context("com.apple.iCal", "Calendar")))
    }

    func testFantasticalUsesTheSameExtraction() throws {
        let list = try events(FantasticalParser().parse(
            window(), context: context("com.flexibits.fantastical2.mac", "Fantastical")))
        XCTAssertEqual(list[0].title, "Design review")
    }

    func testRenderedCalendarLine() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(CalendarParser().parse(window(conference: true),
                                                 context: context("com.apple.iCal", "Calendar"))),
            style: .full)
        XCTAssertEqual(rendered,
                       "Thursday 12 September, 14:00 to 15:00 — Design review @Room 4 "
                       + "/ ada@example.com [conference]")
    }

    func testCalendarEventFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(CalendarParser().parse(try fixture("calendar-event"),
                                                         context: context("com.apple.iCal",
                                                                          "Calendar"))),
                     matches: "calendar-event-golden")
    }

    func testOffsetCalendarFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(CalendarParser().parse(try fixture("calendar-offset-event"),
                                                         context: context("com.apple.iCal",
                                                                          "Calendar"))),
                     matches: "calendar-offset-event-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarStructuredTests`
Expected: FAIL to compile — "type 'CalendarParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/StructuredNativeParsers.swift`, remove `private` from these six members of `StructuredEntityExtraction` so the retyped parsers reuse the already-tested anchor: `preferredDetailRoot(in:hints:)`, `isPreferred(_:hints:)`, `orderedFields(in:)`, `firstValue(_:metadataHints:)`, `looksLikeDateOrTime(_:)`, `isChrome(_:)`. Also remove `private` from `struct Field`'s declaration line (the struct is already internal; its stored properties stay as they are).

Then append to the same file:

```swift
/// The `.calendar` retyping of `StructuredEntityExtraction.calendar`, reusing the same detail-root
/// anchor and the same field-hint scoring — only the OUTPUT type changes (spec §7c).
enum CalendarStructuredExtraction {
    static let conferenceHints = ["conference", "video call", "join", "meet", "zoom", "teams"]

    static func events(in window: AXNode, windowTitle: String?) -> [CalendarEvent] {
        let root = StructuredEntityExtraction.preferredDetailRoot(
            in: window, hints: ["event", "detail", "popover"]
        )
        let fields = StructuredEntityExtraction.orderedFields(in: root)
        guard !fields.isEmpty else { return [] }

        let title = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["title", "summary", "event-name"]
        ) ?? fields.first {
            $0.role == "AXHeading" && !StructuredEntityExtraction.isChrome($0.value)
        }?.value
        guard let title, !title.isEmpty else { return [] }

        let dateString = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["date", "time", "start", "end"]
        ) ?? fields.first { StructuredEntityExtraction.looksLikeDateOrTime($0.value) }?.value ?? ""
        let location = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["location", "place"]
        )
        let organizer = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["organizer", "organiser", "invitee", "account"]
        )
        let hasConference = fields.contains { field in
            conferenceHints.contains { field.metadata.contains($0) || field.value.lowercased().contains($0) }
        }
        // M8 stores the date STRING; turning a localised human date into a Date is out of scope
        // (spec §4a: `dateString` is required, `start`/`end` are optional).
        return [CalendarEvent(title: title, dateString: dateString, start: nil, end: nil,
                              organizer: organizer, location: location,
                              hasConference: hasConference)]
    }
}

extension CalendarParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Calendar",
        bundleIDs: ParserRegistry.calendarBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let events = CalendarStructuredExtraction.events(in: snapshot,
                                                        windowTitle: context.windowTitle)
        return events.isEmpty ? nil : .calendar(events)
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}

extension FantasticalParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Fantastical",
        bundleIDs: ParserRegistry.fantasticalBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let events = CalendarStructuredExtraction.events(in: snapshot,
                                                        windowTitle: context.windowTitle)
        return events.isEmpty ? nil : .calendar(events)
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `CalendarParser(), FantasticalParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter StructuredNativeParserTests`
Expected: PASS, unchanged — only access modifiers changed on the existing extraction.

- [ ] **Step 5: Record the second fixture and both goldens**

The existing `calendar-event.json` is the flush-at-origin fixture. Record the nonzero-origin one:

```bash
swift tools/ax-snapshot-record.swift com.apple.iCal /tmp/calendar-offset-event.json
```

with the Calendar window dragged to a nonzero origin and an event's detail popover open.

`calendar-offset-event.json` must retain at minimum:
- the `AXWindow` root with a nonzero `frame` `x`/`y`,
- one `AXPopover` (or `AXSheet`) whose `identifier` or `label` contains `event` or `detail`,
- inside it, an `AXHeading` title field, a date field whose `identifier` contains `date` or `time`, a location field, an organizer field, and a `Join`-shaped conference link,
- the calendar sidebar **kept** with at least one chrome `AXStaticText` (`Today`), so chrome filtering is a real assertion.

Hand-scrub, move it into `Fixtures/`, then print and save both goldens (`calendar-event-golden.json` for the existing fixture and `calendar-offset-event-golden.json` for the new one) and add three README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter CalendarStructuredTests`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/StructuredNativeParsers.swift \
        Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/CalendarStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/calendar-event-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/calendar-offset-event.json \
        Tests/MaxMiCaptureTests/Fixtures/calendar-offset-event-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Retype calendar event details as calendar captures"
```

---

### Task 20: Reminders → `.tasks` with status from the row checkbox

**Files:**
- Modify: `Sources/MaxMiCapture/StructuredNativeParsers.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (register `RemindersParser()` in `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/reminder-task-golden.json`, `reminders-offset-list.json`, `reminders-offset-list-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/RemindersStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); the six `StructuredEntityExtraction` members made internal in Task 19; `TaskItem`, `TaskStatus`, `CapturedContent` (Phase A).
- Produces: `TaskStructuredExtraction.completedValues: Set<String>` (`["1", "true", "yes", "checked"]`, matching the existing string test in `StructuredEntityExtraction.task`); `TaskStructuredExtraction.status(ofRow: AXNode) -> TaskStatus`; `TaskStructuredExtraction.tasks(in: AXNode, windowTitle: String?) -> [TaskItem]`; `RemindersParser: StructuredParser` with `config` and the bridge.
- `RemindersParser.parse(window:app:)` and its `reminder:task:<hash>` key are untouched. The four other task apps (`MicrosoftToDoParser`, `TodoistParser`, `OmniFocusParser`, `TogglParser`) keep Phase A's `.tasks` output — spec §7c lists only Reminders.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/RemindersStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class RemindersStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, identifier: String? = nil,
              frame: CGRect, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: nil)
    }

    func row(_ title: String, checkbox: String, due: String?, y: CGFloat,
             x: CGFloat) -> AXNode {
        var kids = [
            node("AXCheckBox", value: checkbox, identifier: "completed-checkbox",
                 frame: CGRect(x: x, y: y, width: 20, height: 20)),
            node("AXStaticText", value: title, identifier: "reminder-title",
                 frame: CGRect(x: x + 30, y: y, width: 300, height: 20)),
        ]
        if let due {
            kids.append(node("AXStaticText", value: due, identifier: "due-date",
                             frame: CGRect(x: x + 30, y: y + 22, width: 200, height: 16)))
        }
        return node("AXRow", frame: CGRect(x: x, y: y, width: 600, height: 44), children: kids)
    }

    func window(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        return node("AXWindow", frame: CGRect(origin: origin,
                                             size: CGSize(width: 1100, height: 760)),
                    children: [
            node("AXGroup", identifier: "reminders-sidebar",
                 frame: CGRect(x: x, y: y, width: 240, height: 760), children: [
                node("AXStaticText", value: "Scheduled",
                     frame: CGRect(x: x + 20, y: y + 60, width: 120, height: 20)),
            ]),
            node("AXTable", identifier: "reminder-list",
                 frame: CGRect(x: x + 280, y: y + 60, width: 700, height: 660), children: [
                row("Submit project notes", checkbox: "0", due: "Today 17:00",
                    y: y + 100, x: x + 300),
                row("Book the flights", checkbox: "1", due: nil, y: y + 160, x: x + 300),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.apple.reminders", name: "Reminders",
                                  windowTitle: title))
    }

    func tasks(_ content: CapturedContent?) throws -> [TaskItem] {
        guard case .tasks(let items) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .tasks, got \(String(describing: content))")
        }
        return items
    }

    func testConfigAndRegistration() {
        XCTAssertEqual(RemindersParser.config.bundleIDs, ParserRegistry.remindersBundleIDs)
        XCTAssertEqual(RemindersParser.config.app, "Reminders")
        XCTAssertTrue(ParserRegistry().structuredParser(for: "com.apple.reminders")
                        is RemindersParser)
    }

    func testStatusComesFromTheRowsCheckboxValue() {
        for checked in ["1", "true", "yes", "checked", "TRUE", "Yes"] {
            XCTAssertEqual(
                TaskStructuredExtraction.status(ofRow: row("t", checkbox: checked, due: nil,
                                                           y: 0, x: 0)),
                .completed, checked)
        }
        XCTAssertEqual(
            TaskStructuredExtraction.status(ofRow: row("t", checkbox: "0", due: nil, y: 0, x: 0)),
            .open)
    }

    func testARowWithNoCheckboxHasUnknownStatus() {
        let noCheckbox = node("AXRow", frame: CGRect(x: 0, y: 0, width: 600, height: 20),
                              children: [node("AXStaticText", value: "t",
                                              frame: CGRect(x: 0, y: 0, width: 100, height: 16))])
        XCTAssertEqual(TaskStructuredExtraction.status(ofRow: noCheckbox), .unknown)
    }

    func testEveryRowBecomesOneTaskItemInVisualOrder() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertEqual(items.map(\.title), ["Submit project notes", "Book the flights"])
        XCTAssertEqual(items.map(\.status), [.open, .completed])
        XCTAssertEqual(items.map(\.dueString), ["Today 17:00", nil])
        XCTAssertEqual(items.map(\.due), [nil, nil], "M8 stores the due STRING, not a parsed Date")
        XCTAssertEqual(items.map(\.tags), [[], []])
    }

    func testTheDueStringIsNotDuplicatedIntoTheTitle() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertFalse(items[0].title.contains("Today 17:00"))
    }

    func testTheListNameFromTheSidebarSelectionBecomesTheProject() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1100, height: 760), children: [
            node("AXTable", identifier: "reminder-list",
                 frame: CGRect(x: 280, y: 60, width: 700, height: 660), children: [
                node("AXRow", frame: CGRect(x: 300, y: 100, width: 600, height: 44), children: [
                    node("AXCheckBox", value: "0", identifier: "completed-checkbox",
                         frame: CGRect(x: 300, y: 100, width: 20, height: 20)),
                    node("AXStaticText", value: "Submit notes", identifier: "reminder-title",
                         frame: CGRect(x: 330, y: 100, width: 300, height: 20)),
                    node("AXStaticText", value: "Work", identifier: "list-name",
                         frame: CGRect(x: 330, y: 122, width: 120, height: 16)),
                ]),
            ]),
        ])
        let items = try tasks(RemindersParser().parse(win, context: context("Reminders")))
        XCTAssertEqual(items[0].project, "Work")
    }

    func testSidebarChromeNeverBecomesATask() throws {
        let items = try tasks(RemindersParser().parse(window(), context: context("Reminders")))
        XCTAssertFalse(items.contains { $0.title == "Scheduled" })
    }

    func testNoRowsFallsBackToTheSingleDetailShape() throws {
        // The existing fixture is a reminder DETAIL pane, not a list of rows. The parser must
        // still produce one task from it, which is what keeps reminder-task.json meaningful.
        let items = try tasks(RemindersParser().parse(try fixture("reminder-task"),
                                                     context: context("Reminders")))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Submit project notes")
    }

    func testNothingUsableIsNotHandled() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1100, height: 760),
                        children: [node("AXGroup", identifier: "reminders-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 240, height: 760))])
        XCTAssertNil(RemindersParser().parse(bare, context: context("Reminders")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() {
        XCTAssertEqual(RemindersParser().parse(window(), context: context("Reminders")),
                       RemindersParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
                                               context: context("Reminders")))
    }

    func testRenderedTaskLines() throws {
        let rendered = ContentRenderer.render(
            try XCTUnwrap(RemindersParser().parse(window(), context: context("Reminders"))),
            style: .full)
        XCTAssertTrue(rendered.contains("- [ ] Submit project notes (due Today 17:00)"))
        XCTAssertTrue(rendered.contains("- [x] Book the flights"))
    }

    func testReminderTaskFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(RemindersParser().parse(try fixture("reminder-task"),
                                                          context: context("Reminders"))),
                     matches: "reminder-task-golden")
    }

    func testOffsetRemindersFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(RemindersParser().parse(try fixture("reminders-offset-list"),
                                                          context: context("Reminders"))),
                     matches: "reminders-offset-list-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemindersStructuredTests`
Expected: FAIL to compile — "cannot find 'TaskStructuredExtraction' in scope".

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MaxMiCapture/StructuredNativeParsers.swift`:

```swift
/// The `.tasks` retyping of `StructuredEntityExtraction.task`. A Reminders window is a LIST of
/// rows, so unlike the v1 extraction (which produced one blob for the selected reminder) this
/// yields one `TaskItem` per row, with status read from the row's own `AXCheckBox` (spec §7c).
enum TaskStructuredExtraction {
    /// The same truthy set `StructuredEntityExtraction.task` already tests against.
    static let completedValues: Set<String> = ["1", "true", "yes", "checked"]

    static func status(ofRow row: AXNode) -> TaskStatus {
        guard let checkbox = AXQuery.findAll("//AXCheckBox", in: row).first,
              let value = checkbox.value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else { return .unknown }
        return completedValues.contains(value) ? .completed : .open
    }

    static func tasks(in window: AXNode, windowTitle: String?) -> [TaskItem] {
        let rows = AXQuery.findAll("//AXRow", in: window)
            .filter { !AXQuery.findAll("//AXCheckBox", in: $0).isEmpty }
        if !rows.isEmpty {
            return AXQuery.sortedByVisualOrder(rows, relativeTo: window.frame)
                .compactMap { item(fromRow: $0) }
        }
        // No rows with checkboxes: this is a single reminder's detail pane, which is the shape
        // the v1 extraction was written for. Reuse its anchor rather than returning nothing.
        return detailItem(in: window, windowTitle: windowTitle).map { [$0] } ?? []
    }

    static func item(fromRow row: AXNode) -> TaskItem? {
        let fields = StructuredEntityExtraction.orderedFields(in: row)
        let title = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["title", "name", "task-title", "reminder-title"]
        ) ?? fields.first { $0.role == "AXStaticText" }?.value
        guard let title, !title.isEmpty else { return nil }
        let dueString = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["due", "date", "time"]
        )
        let project = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["list", "project", "section"]
        )
        let notes = fields
            .filter { $0.value != title && $0.value != dueString && $0.value != project }
            .filter { !StructuredEntityExtraction.isChrome($0.value) }
            .map(\.value)
        return TaskItem(title: title, status: status(ofRow: row), due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    static func detailItem(in window: AXNode, windowTitle: String?) -> TaskItem? {
        let root = StructuredEntityExtraction.preferredDetailRoot(
            in: window, hints: ["task", "reminder", "detail"]
        )
        let fields = StructuredEntityExtraction.orderedFields(in: root)
        guard !fields.isEmpty else { return nil }
        let title = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["title", "name", "task-title", "reminder-title"]
        ) ?? fields.first {
            $0.role == "AXHeading" && !StructuredEntityExtraction.isChrome($0.value)
        }?.value
        guard let title, !title.isEmpty else { return nil }
        let dueString = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["due", "date", "time"]
        ) ?? fields.first { StructuredEntityExtraction.looksLikeDateOrTime($0.value) }?.value
        let project = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["list", "project", "section"]
        )
        let checkboxValue = fields.first { $0.role == "AXCheckBox" }?.value.lowercased()
        let status: TaskStatus = checkboxValue.map {
            completedValues.contains($0) ? .completed : .open
        } ?? .unknown
        let notes = fields
            .filter { $0.value != title && $0.value != dueString && $0.value != project }
            .filter { $0.role != "AXCheckBox" && !StructuredEntityExtraction.isChrome($0.value) }
            .map(\.value)
        return TaskItem(title: title, status: status, due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
}

extension RemindersParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Reminders",
        bundleIDs: ParserRegistry.remindersBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent? {
        let items = TaskStructuredExtraction.tasks(in: snapshot, windowTitle: context.windowTitle)
        return items.isEmpty ? nil : .tasks(items)
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        parse(window, context: ParseContext(app: app))
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `RemindersParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RemindersStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter StructuredNativeParserTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Record the second fixture and both goldens**

The existing `reminder-task.json` is the flush-at-origin detail-pane fixture. Record the nonzero-origin list one:

```bash
swift tools/ax-snapshot-record.swift com.apple.reminders /tmp/reminders-offset-list.json
```

with the Reminders window at a nonzero origin, a list open, **one reminder completed and one open**.

`reminders-offset-list.json` must retain at minimum:
- the `AXWindow` root with a nonzero `frame` `x`/`y`,
- an `AXTable` or `AXOutline` with **two** `AXRow`s, each holding an `AXCheckBox` (one value truthy, one `"0"`) and a title `AXStaticText`; at least one row must also carry a due-date `AXStaticText` whose `identifier` contains `due` or `date`,
- the list sidebar **kept** with at least one chrome `AXStaticText` (`Scheduled`), so chrome filtering is a real assertion.

Hand-scrub, move it into `Fixtures/`, then print and save both goldens (`reminder-task-golden.json` and `reminders-offset-list-golden.json`) and add three README rows.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter RemindersStructuredTests`
Expected: PASS, 13 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/StructuredNativeParsers.swift \
        Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/RemindersStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/reminder-task-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/reminders-offset-list.json \
        Tests/MaxMiCaptureTests/Fixtures/reminders-offset-list-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Retype reminder rows as task captures with checkbox status"
```

---

### Task 21: Full suite, rebuild ritual and live verification

**Files:**
- Create: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md` (final table check only, if any row is missing)

**Interfaces:**
- Consumes: `ParserRegistry` and every `StructuredParser` registered in Tasks 7-20; `fixture(_:)` and `goldenCapturedContent(_:)` (Task 6).
- Produces: `PhaseDCoverageTests` — a machine check that spec §11 item 8 actually holds, so the exit criterion is not a manual eyeball.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Spec §11 item 8 as a test: every rewritten parser is registered, and every one has at least
/// two fixtures with goldens, at least one of them recorded at a nonzero window origin.
final class PhaseDCoverageTests: XCTestCase {
    /// Parser type name -> its two (fixture, golden) pairs.
    static let coverage: [String: [(fixture: String, golden: String)]] = [
        "TerminalParser": [("warp-session", "warp-session-golden"),
                           ("iterm-offset-session", "iterm-offset-session-golden")],
        "EditorParser": [("vscode-editor", "vscode-editor-golden"),
                         ("cursor-offset-editor", "cursor-offset-editor-golden")],
        "SlackParser": [("slack-dom-messages", "slack-dom-messages-golden"),
                        ("slack-offset-no-dom", "slack-offset-no-dom-golden")],
        "DiscordParser": [("discord-messages", "discord-messages-golden"),
                          ("discord-offset-messages", "discord-offset-messages-golden")],
        "MessagesParser": [("messages-thread", "messages-thread-golden"),
                           ("messages-offset-thread", "messages-offset-thread-golden")],
        "WhatsAppParser": [("whatsapp-bubbles", "whatsapp-bubbles-golden"),
                           ("whatsapp-offset-bubbles", "whatsapp-offset-bubbles-golden")],
        "NotesParser": [("notes-body", "notes-body-golden"),
                        ("notes-offset-shared", "notes-offset-shared-golden")],
        "NotionParser": [("notion-page", "notion-page-golden"),
                         ("notion-offset-peek", "notion-offset-peek-golden")],
        "ObsidianParser": [("obsidian-editor", "obsidian-editor-golden"),
                           ("obsidian-offset-preview", "obsidian-offset-preview-golden")],
        "FinderParser": [("finder-list", "finder-list-golden"),
                         ("finder-offset-copy", "finder-offset-copy-golden")],
        "CalendarParser": [("calendar-event", "calendar-event-golden"),
                           ("calendar-offset-event", "calendar-offset-event-golden")],
        "RemindersParser": [("reminder-task", "reminder-task-golden"),
                            ("reminders-offset-list", "reminders-offset-list-golden")],
    ]

    func testEveryCoveredParserIsRegisteredAsAStructuredParser() {
        let registry = ParserRegistry()
        var registered = Set<String>()
        for bundleID in [
            ParserRegistry.slackBundleID, ParserRegistry.notionBundleID,
            ParserRegistry.obsidianBundleID, ParserRegistry.notesBundleID,
            ParserRegistry.discordBundleID, ParserRegistry.messagesBundleID,
            ParserRegistry.finderBundleID, ParserRegistry.cursorBundleID,
            ParserRegistry.vsCodeBundleID,
        ] + ParserRegistry.terminalBundleIDs + ParserRegistry.whatsAppBundleIDs
          + ParserRegistry.calendarBundleIDs + ParserRegistry.fantasticalBundleIDs
          + ParserRegistry.remindersBundleIDs {
            guard let parser = registry.structuredParser(for: bundleID) else {
                return XCTFail("no structured parser registered for \(bundleID)")
            }
            registered.insert(String(describing: type(of: parser)))
        }
        for name in Self.coverage.keys {
            XCTAssertTrue(registered.contains(name), "\(name) is not reachable from the registry")
        }
    }

    func testEveryCoveredParserHasTwoFixturesAndTwoGoldens() throws {
        for (parser, pairs) in Self.coverage {
            XCTAssertGreaterThanOrEqual(pairs.count, 2, "\(parser) needs at least two fixtures")
            for pair in pairs {
                XCTAssertNoThrow(try fixture(pair.fixture), "\(parser): \(pair.fixture)")
                XCTAssertNoThrow(try goldenCapturedContent(pair.golden), "\(parser): \(pair.golden)")
            }
        }
    }

    func testEveryCoveredParserHasAtLeastOneNonzeroOriginFixture() throws {
        for (parser, pairs) in Self.coverage {
            var sawNonzeroOrigin = false
            for pair in pairs {
                let frame = try fixture(pair.fixture).frame
                if let frame, frame.minX != 0 || frame.minY != 0 { sawNonzeroOrigin = true }
            }
            XCTAssertTrue(sawNonzeroOrigin,
                          "\(parser) has no fixture recorded at a nonzero window origin — "
                          + "AXFrame is global, so a flush-at-origin fixture cannot catch a "
                          + "missing window-relative conversion")
        }
    }

    func testNoFixtureCarriesASecureFieldValue() throws {
        // Spec §8: a secure field's value is never read, so it can never reach a fixture either.
        for pairs in Self.coverage.values {
            for pair in pairs {
                var offenders: [String] = []
                func visit(_ node: AXNode) {
                    if node.subrole == "AXSecureTextField", let value = node.value, !value.isEmpty {
                        offenders.append(value)
                    }
                    for child in node.children { visit(child) }
                }
                visit(try fixture(pair.fixture))
                XCTAssertTrue(offenders.isEmpty,
                              "\(pair.fixture) carries a secure field value")
            }
        }
    }

    func testTheBinaryContainsNoKeystrokeTap() throws {
        // Spec §11 item 5, asserted here because Phase D is the last phase to touch capture.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaxMiCaptureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("CGEventTap"), "\(url.lastPathComponent)")
            XCTAssertFalse(text.contains("addGlobalMonitorForEvents"), "\(url.lastPathComponent)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PhaseDCoverageTests`
Expected: FAIL on the first missing fixture, golden or registration. Fix by completing whichever Task 7-20 item it names — this test is the gate, not a new feature.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS, zero failures. The count is the 506 pre-M8 tests plus Phase A's plus this phase's.

Run: `swift build 2>&1 | grep -i warning; echo "exit=$?"`
Expected: no warning lines (spec §11 item 10: "zero warnings").

- [ ] **Step 4: Rebuild the app**

Run, exactly as written — **no `tccutil reset`**, because a signed build keeps its Accessibility grant across rebuilds and resetting it would silently break capture:

```bash
./packaging/make-app.sh && pkill -9 -x MaxMi && sleep 2 && open MaxMi.app
```

Note the wall-clock time of the `open`. Every verification below must be confirmed against a capture whose timestamp is **strictly after** that moment; an older row proves nothing.

- [ ] **Step 5: Live-verify each parser**

For each row: focus the app, do the listed action, wait for a capture tick, then read the capture back with the MCP tool `get_latest_context` using the listed arguments and check the listed expectation against the returned `content`. `get_latest_context` renders `ContentRenderer.render(structured, .full)`, so the shapes below are what the rendering looks like.

| # | App | Action | `get_latest_context` arguments | Expect in `content` |
|---|---|---|---|---|
| 1 | Warp | Run `swift build`, let it finish, leave the prompt idle | `{"source": "Warp", "content_kinds": ["terminal"], "limit": 1}` | `$ swift build` on its own line followed by the build output; no `… (running)` |
| 2 | Warp | Start `swift test` and read while it runs | `{"source": "Warp", "content_kinds": ["terminal"], "limit": 1}` | the last segment ends with `… (running)` |
| 3 | VS Code | Open a file with the integrated terminal visible | `{"source": "Visual Studio Code", "content_kinds": ["document"], "limit": 1}` | `# <filename>` then the file's lines; **no** shell prompt text |
| 4 | Cursor | Open a file | `{"source": "Cursor", "content_kinds": ["document"], "limit": 1}` | `# <filename>` then the file's lines |
| 5 | Chrome | Open a docs page with a sidebar | `{"source": "Web", "content_kinds": ["webpage"], "limit": 1}` | first line `URL: https://…`, then the article, then a `## Sidebar` header; **no** address-bar text |
| 6 | Safari | Same, window on a second display | `{"source": "Web", "content_kinds": ["webpage"], "limit": 1}` | the article body, not one alphabet-soup paragraph |
| 7 | Slack (app) | Open a channel, type a draft, do not send | `{"source": "Slack", "content_kinds": ["conversation"], "limit": 1}` | `(From: <name>)(sent <time>): <message>` lines, then `(From: You (draft)): <your draft>` |
| 8 | Slack (web) | Same channel in a browser tab | `{"source": "Web", "content_kinds": ["conversation"], "limit": 1}` | the same message-line shape (host routing worked) |
| 9 | Discord | Open a channel with two consecutive messages from one person | `{"source": "Discord", "content_kinds": ["conversation"], "limit": 1}` | **both** lines carry the same `(From: <name>)`; no line reads `(From: unknown)` |
| 10 | Messages | Open a 1:1 chat you have replied in | `{"source": "Messages", "content_kinds": ["conversation"], "limit": 1}` | your messages render `(From: You)`, theirs `(From: <contact>)` |
| 11 | WhatsApp | Open a chat you have replied in | `{"source": "WhatsApp", "content_kinds": ["conversation"], "limit": 1}` | `(From: You)(sent 16:04): …` for your own messages |
| 12 | Mail | Open a compose window, type a subject and a body | `{"source": "Mail", "content_kinds": ["email"], "limit": 1}` | `(From: You (draft)): <your body>` |
| 13 | Notes | Open a note | `{"source": "Notes", "content_kinds": ["document"], "limit": 1}` | `# <note title>` then the body; **no** folder or note-list text |
| 14 | Notion | Open a page with properties and comments | `{"source": "Notion", "content_kinds": ["document"], "limit": 1}` | `# <page title>` then `## `-prefixed headings and body; **no** property values, no comment rail |
| 15 | Obsidian | Open a note in edit mode | `{"source": "Obsidian", "content_kinds": ["document"], "limit": 1}` | `# <note name>` then the note; **no** file-navigator names |
| 16 | Finder | Open a folder in list view, select one file, start a large copy | `{"source": "Finder", "content_kinds": ["generic"], "limit": 1}` | pipe-joined cell rows (`name`, `size`, `date` separated by ` &#124; `) with `* ` on the selected one, a `## Sidebar` header, and the copy status under `## Toolbar` |
| 17 | Calendar | Open an event with a video link | `{"source": "Calendar", "content_kinds": ["calendar"], "limit": 1}` | `<date> — <title> @<location> / <organizer> [conference]` |
| 18 | Reminders | Open a list with one completed and one open item | `{"source": "Reminders", "content_kinds": ["task"], "limit": 1}` | one `- [x] ` line and one `- [ ] ` line |

Then check the two cross-cutting behaviours:

| # | Check | How |
|---|---|---|
| 19 | The fall-through marker is visible | Open the Capture Health window. Any app whose parser returned nil shows a `parser` value starting `GenericPageExtractor.v2/fallback/`. If nothing does, that is fine — it means no parser degraded. |
| 20 | No secure field ever reached storage | Focus any app with a password field, type into it, wait for a capture, then `get_latest_context` with `{"limit": 5}` and confirm no returned `content` contains the typed value; a masked `«secure field»` is the expected representation. |

- [ ] **Step 6: Commit**

```bash
git add Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Assert Phase D parser fixture and origin coverage"
```

---

## Self-Review

Run after the plan is written, before execution. This is the author's checklist, not a subagent dispatch.

### 1. Spec coverage

| Spec requirement | Task |
|---|---|
| §7a `AXNode.domClassList` / `domIdentifier`, read only under an `AXWebArea` | 1 |
| §7a grammar: `/Role`, `//Role`, `*`, `[attr="v"]`, `[attr^="p"]`, `[attr*="s"]`, `[n]` | 2 |
| §7a attributes `role`, `subrole`, `title`, `description` (alias of `label`), `label`, `value`, `identifier`, `domId`, `domClass`; predicates ANDed; `domClass` case-insensitive | 2 (grammar), 3 (resolution) |
| §7a paths parsed once into `[Step]`, lock-guarded LRU capacity 128 | 2 |
| §7a total API: `preconditionFailure` in debug, nil / `[]` in release, never throws | 2 (policy), 3 (evaluation) |
| §7a `find`, `findAll` | 3 |
| §7a `Matchers.hasRole/hasIdentifierPrefix/hasClass/hasTitleContaining/and/or/not` | 4 |
| §7a `sortedByVisualOrder(_:relativeTo:)` translation-invariant | 4 |
| §7a `collectStaticTexts(in:)`, `formatTable(_:) -> Block` | 4 |
| §7b `ParserConfig`, `ParseContext`, `StructuredParser` | 5 |
| §7b `nil` = NOT_HANDLED routing to `GenericPageExtractor` | 5 |
| §7b registry map by bundle ID, third map by host, `preferOverNative` ordering | 5 |
| §7b `ParserConfig.attributeSet` keeps extra AX reads off apps that do not need them | 1 (`forcedAttributes` mechanism), 5 (`forcedAttributes(for:)`) |
| §7b host routing replaces the `WebAppKind` switch as the content-shape decision | 9 |
| §7c Warp / Terminal.app / iTerm2 `.terminal`, prompt-shape segmentation, `isRunning`, `cwd`, failure → one `command: nil` segment | 7 |
| §7c Cursor / VS Code `.document`, editor identifier anchor, panel dropped | 8 |
| §7c Chrome / Safari / Zen / Arc `.generic` via landmarks with `url` from the scored web area | 9 |
| §7c Slack `.conversation`, DOM-class anchors, composer draft, x-band fallback | 10 |
| §7c Discord `.conversation` with sender attribution, no geometry | 11 |
| §7c Messages `.conversation`, `isUser` from bubble side | 12 |
| §7c WhatsApp `.conversation` via `WAMessageBubbleTableViewCell` | 13 |
| §7c Mail keeps AppleScript; AX only for the compose `Mail.subjectField` (§12 Q6) | 14 |
| §7c Notes `.document`, `Note Body Text View`, title from first line, `— Shared` authorship | 15 |
| §7c Notion `.document`, `notion-frame`/`notion-peek-renderer`, skip `layout-margin-right` and property groups, title from `notion-topbar` | 16 |
| §7c Obsidian `.document`, `cm-editor` / `markdown-preview-view`, vault-stripped title | 17 |
| §7c Finder `.generic`, `AXOutline`/`AXTable` rows → `.tableRow` with `selected`, path, sidebar region, toolbar status | 18 |
| §7c Calendar `.calendar` from the existing `preferredDetailRoot` anchor, retyped | 19 |
| §7c Reminders `.tasks`, status from the row's `AXCheckBox` | 20 |
| §7d `tools/ax-snapshot-record.swift <bundle-id> <out.json>`, same budgets as `AXReader`, hand-scrub rule | 6 |
| §7d the six duplicated `fixture(_:)` helpers consolidated into `FixtureLoading.swift` | 6 |
| §8 fall-through is not silent: `"GenericPageExtractor.v2/fallback/<ParserTypeName>"` in `capture_health_events.parser`, no new column | 5 |
| §8 DOM attribute reads bounded by the web-area gate plus `ParserConfig.attributeSet`; `AXQuery` path parsing cached | 1, 2 |
| §8 secure fields never read | 6 (the recorder refuses), 21 (fixture + live assertion) |
| §9 each grammar token, predicate ANDing, index selection, `domClass` case-insensitivity, cache hit does not change results, invalid path returns nil | 2, 3 |
| §9 ≥2 recorded hand-scrubbed fixtures with golden `CapturedContent` per parser, ≥1 at a nonzero window origin | 7-20, machine-checked in 21 |
| §9 live verification ritual, no `tccutil reset`, verify by timestamp | 21 |
| §11 item 8 (AXQuery powers the rewritten parsers; ≥2 goldens each, one nonzero origin) | 21 |
| §11 item 5 (no `CGEventTap` in the binary, grep-asserted) | 21 |
| §11 item 10 (full suite green, zero warnings, live verification passed) | 21 |

Not in this plan, by design: §4 (Phase A), §5 (Phase B), §6 (Phase C), §9's Finder and dialog-over-window **generic-extractor** fixtures (Phase A's `finder-offset-window.json` and `dialog-over-window.json` — Task 18 adds the Finder *parser* on top of them), §9's `GenericPageExtractor` 150 ms / 20k-node bound (Phase A), §12 Q7-Q10 and Q12-Q15 (Phases A-C). **No gaps.**

### 2. Placeholder scan

Searched for `TBD`, `TODO`, `implement later`, `fill in details`, `add appropriate error handling`, `add validation`, `handle edge cases`, `write tests for the above`, `similar to Task`. None present. Every code step carries a runnable code block; every run step names an exact `swift test --filter <TestClass>` or `swift build`; every fixture that cannot be recorded while planning carries the exact recording command **and** the minimum node set the test needs, so the executor cannot record something the test does not exercise.

### 3. Type consistency

Checked across tasks:

- `ParserConfig(app:bundleIDs:hosts:attributeSet:offscreenPolicy:preferOverNative:minAppVersion:)` — Task 5 defines it; Tasks 7-20 all construct it with that exact label order and rely on the same defaults.
- `ParseContext(app:url:previousStructured:now:)` convenience init — Task 5 defines it; every `parseStructured` bridge in Tasks 7-20 calls `ParseContext(app: app)`, and every test calls `ParseContext(app:..., url:...)`.
- `StructuredParser.parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?` — one spelling everywhere. `SourceParser.parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?` keeps its own labels, and the two never collide because the argument labels differ.
- `AXQuery.Step(axis:role:predicates:index:)` and `AXQuery.Predicate(attribute:op:expected:)` — Task 2 defines them; Task 2's test constructs both with those labels; Task 3 reads `step.axis`, `step.role`, `step.predicates`, `step.index`, `predicate.attribute`, `predicate.op`, `predicate.expected`.
- `AXQuery.menuRoles` is declared once, in Task 4's `AXQueryHelpers.swift`, as a computed `static var` on the extension; Task 4's `collectStaticTexts` and `formatTable` are its only users. `GenericPageExtractor.menuRoles` (Phase A) is a separate, private-to-that-file set and is not referenced here.
- `AXQuery.all(in:where:)` / `first(in:where:)` — Task 4 produces them; Task 12 (`MessagesParser.bubbles`) and Task 17 (`ObsidianParser.parse`) consume them.
- `AXQuery.sortedByVisualOrder(_:relativeTo:)` takes `CGRect?` — Tasks 4, 10, 12, 13, 16, 17, 20 all pass a `node.frame`, which is `CGRect?`. Consistent.
- `MessagesParser.isUserBubble(_:window:)` — Task 12 produces it, Task 13 consumes it. One spelling.
- `NativeConversationExtraction.conversationName(window:app:)` — Task 13 both promotes and consumes it; no other task touches it.
- `StructuredEntityExtraction.preferredDetailRoot(in:hints:)`, `orderedFields(in:)`, `firstValue(_:metadataHints:)`, `looksLikeDateOrTime(_:)`, `isChrome(_:)`, `isPreferred(_:hints:)`, `struct Field` — Task 19 promotes all seven to internal; Tasks 19 and 20 consume them with exactly those labels.
- `TaskStructuredExtraction.completedValues` is the single source of the truthy set; `status(ofRow:)` and `detailItem(in:windowTitle:)` both read it. No second copy.
- `CaptureDispatch.fallbackParserID(notHandledBy:)` — one spelling in Task 5's implementation, its test, and the §8 table row.
- `ParserRegistry.host(fromURL:)` — Task 5 produces it; Task 9 consumes it. `structuredParser(forHost:)` likewise.
- `BrowserTabExtractor.primaryWebArea(in:windowTitle:engine:)` — produced by Phase A Task 15, consumed by Task 9 only; `WebPageParser.parse(window:tab:)` passes `engine: nil`, which Phase A's `engine: BrowserEngine? = nil` default already tolerates.
- `EditorParser.activeTabTitle(fromWindowTitle:)` / `workspaceName(fromWindowTitle:)` / `titleComponents(_:)` / `looksLikeFilename(_:)` / `key(fromTitle:)` — five names, each used consistently inside Task 8.
- Fixture and golden names: the 24 `(fixture, golden)` pairs listed in Task 21's `coverage` dictionary are character-for-character the names used in Tasks 7-20's `assertGolden` calls and `git add` lines. `calendar-event` and `reminder-task` are pre-existing fixtures reused with new goldens; the other 22 are new.
- Phase A names consumed and never redefined: `CapturedContent`, `Document`, `Conversation`, `Message`, `Message.makeID`, `TaskItem`, `TaskStatus`, `CalendarEvent`, `TerminalSegment`, `TerminalSession`, `GenericPage`, `Region`, `RegionKind`, `Block`, `BlockType`, `Authorship`, `CapturedContentEnvelope`, `ContentRenderer.render/renderBlock`, `GenericPageExtractor.extract/Options/Result`, `LegacyContentAdapter`, `ParsedCapture.structured`, `SourceParser.parseStructured`, `AXNode.subrole/headingLevel/selected/placeholder/selectedText/hidden`, `AXReader.textEntryRoles`. All spelled as the spec §4 and the Phase A plan spell them.

No inconsistencies found.
