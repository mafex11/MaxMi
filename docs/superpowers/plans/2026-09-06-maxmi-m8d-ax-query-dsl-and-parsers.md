# MaxMi M8 Phase D — AX Query DSL + Anchored Parsers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MaxMi's per-app geometry heuristics with an `AXQuery` path DSL, a `StructuredParser` v2 protocol that routes by bundle ID *and* by browser host, and eighteen anchored parsers each pinned by golden `CapturedContent` fixtures — thirteen registered by bundle ID, four by browser host (Slack web shares the native `SlackParser`), plus the browser generic-web default, which is not in either map. Mail keeps its AppleScript source and gains only the compose-window draft.

**Architecture:** `AXQuery` compiles a small XPath-like grammar (`//AXRow[domClass*="c-virtual_list__item"][0]`) into cached `[Step]` values and evaluates them over an `AXNode` tree — total and non-throwing, and no geometry unless a parser explicitly asks for it. `StructuredParser` adds a static `ParserConfig` (bundle IDs, hosts, forced AX attribute set, offscreen policy, `preferOverNative`) and a `parse(_:context:) throws` that returns Phase A's `CapturedContent?`, where `nil` means NOT_HANDLED and falls through to `GenericPageExtractor` while a thrown `ParserRefusal` means store nothing. `ParserRegistry` gains a bundle-ID map and a host map so a Slack *web* tab and the Slack *app* reach the same anchored parser. Each existing parser keeps its `SourceParser` conformance (which owns the thread key and the accumulation/offscreen policies, per spec §4f rule 1) and gains a `StructuredParser` conformance that owns the content.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+, XCTest, ApplicationServices/AppKit accessibility APIs.

**Spec:** `docs/superpowers/specs/2026-09-06-maxmi-m8-structured-capture-design.md` — this plan implements §7 in full (7a `AXQuery`, 7b `StructuredParser` v2 + `ParserConfig` + `ParseContext` + registry routing, 7c the anchored parser table, 7d fixture tooling) plus the Phase-D parts of §8 (cross-cutting), §9 (testing), and §11 (exit criteria, item 8). Phases B (§5) and C (§6) are separate plans and are out of scope here. It also implements **§14b** (web-app parsers by host) as Tasks 22-26 plus their own live pass as Task 27, and the refusal decision §12 Q18 records for them. **27 tasks: 1-6 the DSL, routing and fixture tooling; 7-20 the bundle-ID parsers; 21 the first live pass; 22-26 the five web hosts; 27 their live pass.**

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
- **XCTest only.** Zero `import Testing` anywhere; tests are `final class …: XCTestCase` with `func test…` methods (§2: "all XCTest"). The measured `import Testing` count on this branch is **0** and must stay 0.
- **Baseline: 689 tests with exactly 3 known-red.** Measured on `main` after the Phase A merge (Phase A ledger, fix wave `d4a35de..0b844e8`). The three are `ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`, `CaptureDisplaySummarizerTests.testConversationSummaryUsesTrailingMessages` and `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`. **The gate for every task and for Task 21 is zero NEW failures** — those three may still be red, nothing else may be. Spec §2's "506 tests" and §11 item 10's "506 existing tests" are pre-Phase-A figures; the numbers quoted in this plan are non-binding, the named three are binding (spec §12 amendment).
- **The existing tests stay green.** Every signature change in this plan lists its exact existing call sites.
- **`AXQuery` never throws and is total** (§7a). An invalid path is a programmer error: `preconditionFailure` in debug, `nil` / `[]` in release. Parsed paths are cached in a **lock-guarded LRU of capacity 128** keyed on the path string.
- **`AXQuery` matching is case-sensitive except `domClass`, which is case-insensitive** (§7a). Predicates on one step are ANDed. `description` is an explicit **alias of `label`**, because `AXReader` folds `kAXDescriptionAttribute ?? kAXHelpAttribute` into `label` (§7a, §12 Q1).
- **`domClassList`/`domIdentifier` are read only under an `AXWebArea` ancestor** (§7a, §8), or when a parser's `ParserConfig.attributeSet` forces them.
- **`nil` from a `StructuredParser` means NOT_HANDLED and routes to `GenericPageExtractor`** (§7b, §4f rule 3). The fallback is **not silent**: `capture_health_events.parser` records `"GenericPageExtractor.v2/fallback/<ParserTypeName>"`, composed by the **existing** `CaptureDispatch.fallbackParserID(failedParser:)` (`Sources/MaxMiCapture/ParserRegistry.swift:167-169`) — this plan adds no second spelling (§8). `capture_health_events` gains no new column.
- **A thrown `ParserRefusal` means STORE NOTHING, on both dispatch paths.** `StructuredParser.parse(_:context:)` is `throws` purely so a parser can refuse. On the native path the refusal travels up the `parseStructured` bridge and `CaptureDispatch.parseDetailed` maps it to `.noContent` exactly as it does today (`ParserRegistry.swift:132-147`). On the browser path `BrowserCapturePipeline.parse` rethrows it and `AppWiring` records `.skipped(.parserNoContent)`. A refusal is **never** reported as a `GenericPageExtractor.v2/fallback/...` degradation (spec §12 amendment, superseding Q18).
- **Mail stays AppleScript-sourced** (§12 Q6). Mail's AX tree is ~80 ms/node. Phase D's only Mail change is the compose-window `Mail.subjectField` read (§7c).
- **Discord must not use any geometric split** — its `AXFrame` values are unreliable (§7c, `DiscordParser.swift` header comment).
- **Visual-order sorting is translation-invariant.** `AXFrame` is global screen coordinates, so every comparison against a window edge or midpoint is done relative to the window frame (§4e, and the `project_maxmi_ax_capture` regression).
- **Every rewritten parser ships ≥2 recorded, hand-scrubbed AX fixtures with a golden expected `CapturedContent` JSON, at least one of them with a nonzero window origin** (§9, §11 item 8).
- **Every DOM anchor in §14b is a CANDIDATE, not a verified read** (§14b). Tasks 22-26 record a live dump with `tools/ax-snapshot-record.swift` **before** relying on an anchor, and record the verified set — plus every candidate that did not survive — in the parser's header comment.
- **Fixtures are hand-scrubbed.** Never commit real page text, messages, file contents, URLs, names, or tokens (`Tests/MaxMiCaptureTests/Fixtures/README.md`). Every new fixture gets a row in that README's table.
- **No PII/email redaction inside captured content** beyond the existing `Denylist` app + domain denylist (§3 Non-goals).
- **No `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`, ever** (§3 Non-goals).
- **No change to the MCP tool surface** (§4g). `search_memory`, `list_active_threads`, `get_latest_context` keep their shapes and keep reading `content`.
- **Secure fields are never read** — the value is not fetched, not merely not stored (§8). No parser in this plan reads the `value` of a node whose `subrole == "AXSecureTextField"`.
- **Commit messages are plain imperative** ("Add AXQuery path grammar"). **No `Co-Authored-By` trailers, no AI attribution anywhere** — not in commit messages, code comments, or docs.
- **Live verification ritual** (§9, unchanged): `./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" && sleep 2 && open MaxMi.app`. **No `tccutil reset`** — signed builds keep the Accessibility grant across rebuilds. Verify captures by timestamp strictly after the new process start.

### What Phase D changes about Phase A's parsers

Phase A migrated each parser's **output type** (`SlackParser` already returns a `.conversation`). Phase D replaces each parser's **anchoring**: DOM-class and identifier anchors instead of x-band geometry, and a golden fixture per parser. In every parser task:

- The existing type keeps its `SourceParser` conformance. `parse(window:app:)` stays the owner of `sourceApp`, `sourceKey`, `accumulationPolicy`, `offscreenPolicy` and `contentKind` — that is spec §4f rule 1 ("call `parse` for keys/policies and attach the structured value"), and it is why the existing key-derivation tests keep passing untouched.
- The type gains a `StructuredParser` conformance: `static var config: ParserConfig` and `parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?`.
- `parseStructured(window:app:)` (the `SourceParser` requirement Phase A added) becomes a four-line bridge to `parse(_:context:)`. It is written out explicitly in each parser, not provided by a constrained protocol extension — two competing default implementations of the same requirement is exactly the kind of overload-resolution subtlety that silently picks the wrong one.
- Where Phase D's implementation supersedes an interim Phase A body inside `parseStructured`, **replace that body**; do not leave two content paths for one app. Concretely, Phase A Task 16 routes Notes, Notion, Obsidian, Discord and Messages through `GenericV2Content.page` / `GenericV2Content.lines`. In each of Tasks 11, 12, 15, 16 and 17 the new `parse(_:context:)` becomes the whole content path and the `parseStructured` bridge is exactly the four lines the task shows — the `GenericV2Content` call is **deleted**, not chained. Returning `nil` is the correct degradation: `CaptureDispatch` rule 3 (Phase A Task 10) already routes it to `GenericPageExtractor`, which is strictly better than `GenericV2Content.lines`, and it is what records the §8 fallback marker.
- Two Phase A members are **superseded and replaced**, not shadowed: `TerminalParser.promptPatterns` / `TerminalParser.segments(fromScrollback:)` (Phase A Task 14) are replaced by Task 7's `PromptShape` + `promptShape(in:)` + `segments(fromScrollback:)`. Phase A's `TerminalSegmentationTests.swift` is **kept, not deleted**: two of its tests (`testOversizeScrollbackDropsOldestSegments`, `testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy`) are the only coverage of the `contentCap` trim and of the key/kind/policy invariant, so Task 7 moves those two into `TerminalStructuredTests.swift` and updates the two `cwd` assertions in the seven that stay (Phase A asserted the slug `"maxmi"`; Phase D returns the absolute `"~/code/MaxMi"` it explicitly deferred: "The richer absolute path is Phase D's anchored rewrite"). No Phase A test file is deleted by this plan.
- **Dead members are deleted by the task that removes their last caller** — Swift warns on unused `private` members and Task 21 requires a zero-warning build. Each parser task names the members it orphans and deletes them in the same step.
- **`GenericV2Content` survives Phase D** at three of its eight call sites: `GenericAXParser.swift:14` (the dispatch default), `StructuredNativeParsers.swift:259` (Word/Pages) and `:291` (Outlook/Spark). Only the five call sites named above are deleted.

### Three reconciliations of spec text against the code

Decided here so no task has to reopen them.

1. **`ParserConfig` gains `hosts: [String]`.** §7b lists the fields `app`, `bundleIDs`, `attributeSet`, `offscreenPolicy`, `preferOverNative`, `minAppVersion`, and separately requires "a third [map] keyed by **host** so browsers route web-app hosts through the same mechanism". A host map needs the hosts to come from somewhere, and `ParserConfig` is the only per-parser declaration site. `hosts` is added, defaulting to `[]`. A leading-dot entry (`".slack.com"`) means suffix match, mirroring `WebAppCaptureParser.classify`'s existing `host.hasSuffix(".slack.com")`.
2. **`ParserConfig.attributeSet` is implemented as forced AX attribute names, not a generic attribute bag.** §7b says it is "extra AX attributes `AXReader` must fetch for this app" and §8 says it is "what keeps the extra AX reads off apps that do not need them". Adding a `[String: String]` bag to `AXNode` would change the wire shape of every fixture on disk for no consumer. Instead `AXReader.snapshotFrontmostWindow(pid:maxNodes:maxDepth:forcedAttributes:)` takes a `Set<String>`; the only names it honours are `"AXDOMClassList"` and `"AXDOMIdentifier"`, and honouring them means bypassing the `AXWebArea`-ancestor gate for the whole tree. That is exactly what Electron apps (Slack, Notion, Obsidian) need, because they do not always expose an `AXWebArea` above their DOM. **The forced set must be wired at the live snapshot site** (`Sources/MaxMi/AppWiring.swift:1383` and `:1391`, `AXReader.snapshotFrontmostWindow(pid: pid)`), not only in the tests — Task 5 Step 5 does exactly that with `registry.forcedAttributes(for: app.bundleID)`. Without that line Slack/Notion/Obsidian anchors are nil in production and only the hand-authored fixtures pass.
3. **`StructuredParser` does not carry the thread key.** §7b's protocol returns only `CapturedContent?`, but `sourceKey` is load-bearing and heavily tested (`SlackParser.key(fromTitle:)`, `TerminalParser.terminalKey`, `ObsidianParser.key(fromTitle:)`, `DiscordParser.key(fromTitle:)`, `MessagesParser.key(fromTitle:)`). §4f rule 1 already resolves it: keys and policies come from `SourceParser.parse`. The protocol stays exactly as §7b writes it.

---

## File Structure

### Created

| File | Responsibility |
|---|---|
| `Sources/MaxMiCapture/AXQuery.swift` | The path grammar: `Axis`, `Attribute`, `Operator`, `Predicate`, `Step`, the parser, the capacity-128 LRU path cache, and `find`/`findAll` evaluation. Nothing app-specific. |
| `Sources/MaxMiCapture/AXQueryHelpers.swift` | `AXQuery.Matchers`, `all(in:where:)`/`first(in:where:)`, `sortedByVisualOrder(_:relativeTo:)`, `collectStaticTexts(in:)`. Split from `AXQuery.swift` so the grammar file stays readable. No table formatter: rows reuse `GenericPageExtractor`'s row semantics (spec §12 amendment, ruling F15). |
| `Sources/MaxMiCapture/StructuredParser.swift` | `ParserConfig`, `ParseContext`, the `StructuredParser` protocol. Types only — no routing, no parsers. |
| `Sources/MaxMiCapture/StructuredParserRouting.swift` | `ParserRegistry`'s structured + host maps, host resolution, and `CaptureDispatch.structuredCapture(window:context:registry:fallback:) throws -> StructuredParseResult` (the browser path's single entry point). The §8 marker helper is **not** re-added here — `CaptureDispatch.fallbackParserID(failedParser:)` already exists. |
| `Sources/MaxMiCapture/EditorParser.swift` | Cursor + VS Code → `.document`. New parser; these two apps used `GenericAXParser` before. |
| `Sources/MaxMiCapture/WebPageParser.swift` | The browser generic-web path: `GenericPageExtractor` over the active `AXWebArea` subtree with `url` set. |
| `Sources/MaxMiCapture/FinderParser.swift` | Finder → `.generic` with sidebar/main/toolbar regions and joined table rows. New parser; Finder used `GenericAXParser` before. |
| `Tests/MaxMiCaptureTests/Fixtures/dom-attributes.json` | Hand-authored web-area DOM shape at a nonzero window origin (Task 1). |
| `Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json` | The smallest possible golden — an empty `.generic` page — used by `FixtureLoadingTests` (Task 6). |
| `tools/ax-snapshot-record.swift` | Records the focused window as a `Codable` `AXNode` JSON fixture. `tools/ax-structure-inventory.swift` deliberately emits no attribute values and cannot produce a loadable fixture (§12 Q11). |
| `Tests/MaxMiCaptureTests/FixtureLoading.swift` | The one `fixture(_:)` loader (replacing the **twelve** duplicates that exist on this branch plus Task 1's, §7d and spec §12 amendment) plus `goldenCapturedContent(_:)`, `assertGolden(_:matches:)` and `goldenJSON(_:)`. |
| `Tests/MaxMiCaptureTests/AXQueryPathTests.swift` | Table-driven grammar tests + the LRU cache. |
| `Tests/MaxMiCaptureTests/AXQueryEvaluationTests.swift` | `find`/`findAll` over synthetic trees; attribute aliases; `domClass` case-insensitivity. |
| `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift` | Matchers, `all`/`first`, translation-invariant visual order (including a genuinely frameless node), `collectStaticTexts`. |
| `Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift` | `domClassList`/`domIdentifier` decode; **every** fixture in `Fixtures/` still decodes (enumerated, not a hand-maintained list); the web-area read gate. |
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
| `Sources/MaxMiCapture/WebHostParsing.swift` | The shared message/draft/anchor-text helpers the five §14b web-app parsers use. No DOM class lives here, and no refusal protocol: a host parser refuses by throwing `ParserRefusal` from `StructuredParser.parse` (spec §12 amendment, superseding Q18). |
| `Sources/MaxMiCapture/GmailParser.swift` | Gmail (`mail.google.com`) → thread `.conversation`, inbox `.generic` rows, compose draft. |
| `Sources/MaxMiCapture/LinkedInMessagingParser.swift` | LinkedIn `/messaging` → `.conversation`; nil on every other LinkedIn path. |
| `Sources/MaxMiCapture/OutlookWebParser.swift` | Outlook web (`outlook.office.com`, `outlook.live.com`) → reading-pane `.conversation`, list `.generic` rows, compose draft. |
| `Sources/MaxMiCapture/TeamsWebParser.swift` | Teams web (`teams.microsoft.com`, `teams.cloud.microsoft`) → `.conversation`, with an `AXDescription` fallback tier. |
| `Tests/MaxMiCaptureTests/GmailParserTests.swift` | Thread, collapsed-message skip, inbox rows, draft, refusal, pipeline kind/key, goldens. |
| `Tests/MaxMiCaptureTests/LinkedInMessagingParserTests.swift` | Group/continuation attribution, self-name `isUser`, off-`/messaging` nil, draft, goldens. |
| `Tests/MaxMiCaptureTests/OutlookWebParserTests.swift` | `From:`/`Sent:` description parsing, header-text fallback, list rows, draft, goldens. |
| `Tests/MaxMiCaptureTests/SlackWebStructuredTests.swift` | Web anchors, `aria-label` timestamps, `#`-driven `isGroup`, native/web byte-identical render, goldens. |
| `Tests/MaxMiCaptureTests/TeamsWebParserTests.swift` | Class tier, identifier tier, `AXDescription` fallback, `classify` host addition, key stability, goldens. |
| 20 fixture + golden JSON files under `Tests/MaxMiCaptureTests/Fixtures/` for the five web hosts | Two fixtures + two goldens per host (Tasks 22-26), at least one per host at a nonzero window origin; named in each task. |
| 28 fixture + golden JSON files under `Tests/MaxMiCaptureTests/Fixtures/` | Two per parser; named in each parser task. |

### Modified

| File | Change |
|---|---|
| `Sources/MaxMiCapture/AXSnapshot.swift` | `AXNode` gains `domClassList: [String]?` and `domIdentifier: String?`, defaulted in `init` and decoded with `decodeIfPresent`. |
| `Sources/MaxMiCapture/AXReader.swift` | `convert` threads an `inWebArea` flag and a `forcedAttributes` set; `snapshotFrontmostWindow` gains `forcedAttributes:`; new pure `readsDOMAttributes(role:inWebArea:forced:)`. |
| `Sources/MaxMiCapture/ParserRegistry.swift` | New bundle-ID constants (`finderBundleID`, `cursorBundleID`, `vsCodeBundleID`, `editorBundleIDs`); the structured and host maps are built here from one registration list and consumed by `StructuredParserRouting.swift`; the Phase A test seam `init(parsers:)` (`:60-62`) initialises both new stored properties to `[:]`. |
| `Sources/MaxMiCapture/BrowserCapturePipeline.swift` | Routes a browser window through the host map first, then `WebPageParser`. `parse(window:windowTitle:browser:contentBudget:)` **keeps** `contentBudget:` (used by `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift:117`) and gains `registry:`. `BrowserCaptureResult` gains no field — consumers read `result.capture.structured`. |
| `Sources/MaxMiCapture/WebAppCaptureParser.swift` | `classify` keeps its ten cases for the parser ID and `contentKind`, but no longer decides content shape — the host map does (§7b). |
| `Sources/MaxMiCapture/TerminalParser.swift` | `StructuredParser` conformance; prompt-shape segmentation; `cwdPath`; `pathBodyPattern` promoted to a `static let`. |
| `Sources/MaxMiCapture/SlackParser.swift` | `StructuredParser` conformance; DOM-class anchors with the existing x-band walk as fallback; the existing `channel(fromTitle:)`/`isGroup(fromTitle:)` reused; `messages(in:windowX:)`, `collectRows` and `collectStaticText` deleted. |
| `Sources/MaxMiCapture/DiscordParser.swift` | `StructuredParser` conformance; "Messages in" list anchor; heading-based sender attribution. |
| `Sources/MaxMiCapture/MessagesParser.swift` | `StructuredParser` conformance; bubble side → `isUser`. |
| `Sources/MaxMiCapture/NativeConversationParser.swift` | `WhatsAppParser` gains `StructuredParser` conformance; `NativeConversationExtraction.conversationTitle(in:app:mainBoundary:requiresHeaderSemantics:)` (`:210`) and `mainPaneBoundary(_:)` (`:205`) are promoted from `private` to internal, and the **new** `conversationName(window:app:)` wraps them. `split(_:byKnownParticipant:)` (`:179-182`) stays on the new path. |
| `Sources/MaxMiCapture/MailParser.swift` | New `composeDraft(window:)`; `parseStructured` returns it first when a compose window is frontmost. |
| `Sources/MaxMiCapture/NotesParser.swift` | `StructuredParser` conformance; `Note Body Text View` anchor. |
| `Sources/MaxMiCapture/NotionParser.swift` | `StructuredParser` conformance; `notion-frame` anchor. |
| `Sources/MaxMiCapture/ObsidianParser.swift` | `StructuredParser` conformance; `cm-editor` / `markdown-preview-view` anchors; `noteName(fromTitle:)`. |
| `Sources/MaxMiCapture/StructuredNativeParsers.swift` | `CalendarParser`/`FantasticalParser`/`RemindersParser` gain `StructuredParser` conformance; `StructuredEntityExtraction.preferredDetailRoot` and `orderedFields` promoted to internal. |
| `Sources/MaxMiCore/ApplicationRegistry.swift` | Cursor, VS Code and Finder move to `captureStrategy: .nativeParser`; Finder gains a descriptor. |
| `Sources/MaxMi/AppWiring.swift` | The snapshot calls (`:1383`, `:1391`) pass `forcedAttributes: registry.forcedAttributes(for: app.bundleID)`; the browser branch (`:1449-1481`) passes a `ParseContext` and a `registry` into `BrowserCapturePipeline.parse`. The non-browser switch (`:1483`) is **unchanged** — a v2 parser reaches it through the `parseStructured` bridge, so the window is parsed once (ruling F12). |
| `Tests/MaxMiCoreTests/ApplicationRegistryTests.swift:66` | `cursor?.captureStrategy` expectation moves from `.genericAX` to `.nativeParser`. |
| `AXNodeAttributesTests.swift:5-10`, `BrowserCapturePipelineTests.swift:6-9`, `ExtractorTests.swift:5-8`, `GenericAXParserTests.swift:5-12`, `GenericPageBudgetTests.swift:6-11`, `GenericPageRegionTests.swift:6-11`, `NativeConversationParserTests.swift:6-9`, `SlackParserTests.swift:6-9`, `StructuredConversationParserTests.swift:6-11`, `StructuredEntityTypedTests.swift:6-11`, `StructuredNativeParserTests.swift:5-8`, `WebAppStructuredTests.swift:6-11` (all under `Tests/MaxMiCaptureTests/`) | The **twelve** duplicated `func fixture(_:)` helpers are deleted in favour of `FixtureLoading.swift` (§7d). Task 1's thirteenth copy goes with them. |
| `Tests/MaxMiCaptureTests/Fixtures/README.md` | A row per new fixture, plus the recording + hand-scrub procedure. |
| `Sources/MaxMiCapture/BrowserCapturePipeline.swift` (second change, Task 22) | The host parse is hoisted above `WebAppCaptureParser.parse`, a host `StructuredParser` may throw `ParserRefusal` for an empty compose-only tab (rethrown, not swallowed), and a host shape is bounded with `CaptureAccumulator.bound` to the browser budget. |
| `Sources/MaxMiCapture/WebAppCaptureParser.swift` (second change, Task 26) | `classify` recognises `teams.cloud.microsoft`, so both Teams domains reach `contentKind` `.conversation` (§12 Q3). `URLKeyNormalizer` is deliberately untouched. |
| `Sources/MaxMiCapture/SlackParser.swift` (second change, Task 25) | `domMessages`/`parse` replaced: alternate `c-message_kit__background` item class, timestamps read from `AXDescription`, header-driven `channel`/`isGroup`, and a `ParserRefusal` throw for a compose-only tab. |
| `Sources/MaxMiCapture/ParserRegistry.swift` (second change, Tasks 22-26) | The four new host parsers are appended to Task 5's single `structured` registration list; each carries `hosts` and no bundle IDs, so the derived loop files them in the host map only. |
| `Sources/MaxMi/AppWiring.swift` (second change, Task 22) | One new `catch let refusal as ParserRefusal` clause on the browser path: logs `.parserRefused` and records `.skipped(.parserNoContent)`; no retry, no new health enum case. |
| `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` (Task 7) | Kept. Its two `cwd` assertions move from the Phase A slug (`"maxmi"`, `"shipcast"`) to Phase D's absolute path (`"~/code/MaxMi"`, `"~/code/ShipCast"`), and its two invariant tests move to `TerminalStructuredTests.swift`. |
| `Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift` (Tasks 19-20) | Existing Calendar/Reminders assertions keep passing; only the duplicated `fixture(_:)` helper is removed (Task 6). |
| `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (created in Task 21) | Tasks 22-26 add `hostCoverage`, `testEveryHostRoutedParserIsReachableFromTheHostMap`, and five `coverage` entries. |
| `Tests/MaxMiCaptureTests/SlackStructuredTests.swift` (Task 25) | One assertion message updated where Task 10's fixture now exercises the "no header anchor" `isGroup` default. |
| `Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift` (Task 9) | The assertions that read `result.capture.content` as flat visual-order text are rewritten against `ContentRenderer.render(structured, .full)` and the typed regions; URL, key, `contentKind`, `webApp` and `parserID` assertions are unchanged. Its duplicated `fixture(_:)` also goes in Task 6. |
| `Sources/MaxMiCapture/StructuredNativeParsers.swift` (second change, Task 19) | `calendarContent`'s `hasConference` rule also fires on a field whose metadata contains `"conference"`. |
| `Sources/MaxMiCapture/StructuredNativeParsers.swift` (third change, Task 20) | Five `StructuredEntityExtraction` members promoted from `private` to internal (`preferredDetailRoot`, `orderedFields`, `firstValue`, `looksLikeDateOrTime`, `isChrome`); `RemindersParser.parse(window:app:)` takes its content from `parseStructured`. |
| `Sources/MaxMiCapture/NativeConversationParser.swift` (second change, Task 13) | `WhatsAppParser.parse(window:app:)` builds its capture from `parseStructured` instead of walking the tree a second time via `capture(...)`; `slug(_:)` promoted to internal. |

### Deleted

| File | Why |
|---|---|
| `TerminalParser.promptPatterns`, `TerminalParser.segments(fromScrollback:)`'s Phase A body, `joinedOutput(_:)`, `sessionCwd(fromTitle:)`, `structured(fromScrollback:app:)` (members, not files) | Superseded by Task 7's `PromptShape` path. Deleted in Task 7 so no orphaned private member trips the zero-warning gate. |
| The **twelve** duplicated `func fixture(_:)` methods plus Task 1's thirteenth (methods, not whole files) | Consolidated into `Tests/MaxMiCaptureTests/FixtureLoading.swift` per spec §7d. |
| `SlackParser.messages(in:windowX:)` / `collectRows(_:into:windowX:)` / `collectStaticText(_:into:)`, `DiscordParser.messageLines(in:)`/`collect(_:into:)`, `MessagesParser.conversationLines(in:)`/`collect(_:into:)` (members, not files) | Orphaned when Tasks 10, 11 and 12 replace the content path; deleted in the same task (ruling F20). `SlackParser.channel(fromTitle:)` and `isGroup(fromTitle:)` are **kept** — the new path calls them and `StructuredConversationParserTests.swift:36-41` asserts them. |

**No whole file is deleted by this plan.**

---

### Task 1: `AXNode.domClassList` / `domIdentifier` + the `AXReader` web-area gate

**Ordering note:** the spec lists the DOM attributes inside §7a, and §7a's `domClass` predicate cannot be evaluated without them, so the attribute addition lands before the DSL rather than after it.

**Files:**
- Modify: `Sources/MaxMiCapture/AXSnapshot.swift` (the whole `AXNode` struct)
- Modify: `Sources/MaxMiCapture/AXReader.swift:23` (`snapshotFrontmostWindow`), `:80-130` (`convert`)
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
    /// The thirteenth copy of this loader on the branch. Task 6 deletes all thirteen in favour of
    /// the free function in `FixtureLoading.swift`; this task runs before Task 6, so it carries
    /// its own copy for exactly one task.
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    /// Every fixture on disk, enumerated rather than listed by hand — a hand-maintained list
    /// silently stops covering fixtures that later tasks add (16 exist on this branch, and this
    /// task adds the 17th).
    func everyFixtureName() throws -> [String] {
        let urls = try XCTUnwrap(Bundle.module.urls(forResourcesWithExtension: "json",
                                                    subdirectory: "Fixtures"))
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
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

    func testEveryFixtureOnDiskStillDecodesAndOnlyDomAttributesFixtureCarriesTheNewFields() throws {
        let names = try everyFixtureName()
        XCTAssertTrue(names.contains("dom-attributes"))
        XCTAssertGreaterThanOrEqual(names.count, 16, "16 fixtures existed before this task")
        for name in names {
            // Goldens are CapturedContentEnvelope JSON, not AXNode JSON; skip them by suffix.
            if name.hasSuffix("-golden") { continue }
            let node = try fixture(name)
            if name == "dom-attributes" {
                XCTAssertNotNil(node.children.first?.domIdentifier)
                continue
            }
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
Expected: PASS, no NEW failures — every fixture already on disk decodes with both new fields nil.

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
- Produces, all `internal` so `@testable import` can see them and the public surface stays the four functions §7a lists: `AXQuery.Axis` (`.child`, `.descendant`), `AXQuery.Attribute` (`.role`, `.subrole`, `.title`, `.description`, `.label`, `.value`, `.identifier`, `.domId`, `.domClass`), `AXQuery.Operator` (`.equals`, `.prefix`, `.contains`), `AXQuery.Predicate{attribute, op, expected}`, `AXQuery.Step{axis, role: String?, predicates: [Predicate], index: Int?}`, `AXQuery.parsePath(_:) -> [Step]?` (uncached), `AXQuery.steps(for:) -> [Step]?` (cached), `AXQuery.pathCacheCapacity = 128`, `AXQuery.cachedPathCount()`, `AXQuery.resetPathCache()`, and `AXQuery.trapsOnInvalidPath` — declared in **both** build configurations (default `true` in debug, `false` in release) so the tests that flip it compile under `swift test -c release` (ruling F14).
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
        // release behaviour (nil / []), so the trap is switched off for the duration. The property
        // exists in release too, so this file compiles under `swift test -c release`.
        AXQuery.trapsOnInvalidPath = false
    }

    override func tearDown() {
        #if DEBUG
        AXQuery.trapsOnInvalidPath = true
        #endif
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

    func testWildcardRoleIsRepresentedAsNil() throws {
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

    /// A malformed path is a programmer error, not input, so debug builds trap on it and release
    /// builds degrade to nil / []. Declared in BOTH configurations — the grammar's own tests flip
    /// it off to assert the release behaviour, and `swift test -c release` has to compile them.
    #if DEBUG
    nonisolated(unsafe) static var trapsOnInvalidPath = true
    #else
    nonisolated(unsafe) static var trapsOnInvalidPath = false
    #endif

    static func invalid(_ path: String, _ reason: String) -> [Step]? {
        if trapsOnInvalidPath {
            preconditionFailure("AXQuery: malformed path \"\(path)\" — \(reason)")
        }
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
- Produces: `AXQuery.find(_ path: String, in node: AXNode) -> AXNode?`, `AXQuery.findAll(_ path: String, in node: AXNode) -> [AXNode]`, and the internal `AXQuery.satisfies(_:_:) -> Bool` / `AXQuery.matches(_:_:) -> Bool` / `AXQuery.attributeValues(_:_:) -> [String]`, all three used only inside `findAll` (Task 4's `Matchers` are independent closures — see Task 4's Interfaces).
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
        #if DEBUG
        AXQuery.trapsOnInvalidPath = true
        #endif
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

### Task 4: `Matchers`, visual-order helpers, `collectStaticTexts`

**Files:**
- Create: `Sources/MaxMiCapture/AXQueryHelpers.swift`
- Test: `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift`

**Interfaces:**
- Consumes: `AXNode` including `domClassList`/`hidden` (Task 1); `GenericPageExtractor.menuRoles` (Phase A, `Sources/MaxMiCapture/GenericPageExtractor.swift:29`). It deliberately does **not** call `AXQuery.attributeValues(_:_:)`: a `Matchers` value is a closure over `AXNode` fields, not a predicate evaluation. What the two share is the RULE — `hasClass` is case-insensitive exactly as the `domClass` predicate is — and both sides pin it with their own test.
- Produces: `AXQuery.Matchers.hasRole(_:)`, `.hasIdentifierPrefix(_:)`, `.hasClass(_:)`, `.hasTitleContaining(_:)`, `.and(_:)`, `.or(_:)`, `.not(_:)` — each `(AXNode) -> Bool`; `AXQuery.sortedByVisualOrder(_ nodes: [AXNode], relativeTo origin: CGRect?) -> [AXNode]`; `AXQuery.collectStaticTexts(in: AXNode) -> [String]`; `AXQuery.menuRoles` (an alias of `GenericPageExtractor.menuRoles`, not a second literal set); and `AXQuery.first(in: AXNode, where: (AXNode) -> Bool) -> AXNode?` / `AXQuery.all(in: AXNode, where: (AXNode) -> Bool) -> [AXNode]` so a `Matchers` composition can actually be run against a tree.
- **No table formatter.** Ruling F15: rows are `GenericPageExtractor`'s job — `block(for:)` (`GenericPageExtractor.swift:183-189`) already emits `.tableRow(cells:selected:)` with the project's empty-row semantics, and Task 18 is the only row consumer. A second implementation would be two behaviours for one shape.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/AXQueryHelperTests.swift`:

```swift
import XCTest
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

    func testAFramelessNodeSortsAtTheWindowOriginNotAtGlobalZero() {
        // The local `node(...)` helper substitutes a real frame when `frame:` is nil, so this
        // genuinely frameless node is built directly — otherwise the nil branch of
        // `sortedByVisualOrder` is never reached and the assertion degenerates to "0 < 10".
        let frameless = AXNode(role: "AXStaticText", value: "z", title: nil, url: nil,
                               frame: nil, focused: false, children: [])
        let window = CGRect(x: 1_440, y: 220, width: 800, height: 600)
        // 10pt ABOVE the window's top edge, i.e. window-relative y == -10. A frameless node
        // treated as the WINDOW origin (relative 0) sorts after it; a frameless node wrongly
        // treated as global (0, 0) would be relative -220 and sort before it.
        let above = text("above", y: 210, x: 1_440)
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([above, frameless], relativeTo: window).map(\.value),
            ["above", "z"])
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([frameless, above], relativeTo: window).map(\.value),
            ["above", "z"], "the order comes from the frames, not from the input order")
        // With no window frame the same node is the origin and sorts ahead of everything below it.
        XCTAssertEqual(
            AXQuery.sortedByVisualOrder([text("a", y: 10, x: 0), frameless], relativeTo: nil)
                .map(\.value),
            ["z", "a"])
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

    // MARK: - Menu roles

    func testMenuRolesIsTheExtractorsSetAndNotASecondLiteral() {
        XCTAssertEqual(AXQuery.menuRoles, GenericPageExtractor.menuRoles,
                       "one menu-skip set for the whole capture layer")
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

    /// Menu content is structurally excluded from every helper, not filtered by text. Aliased to
    /// the extractor's set rather than restated, so the capture layer has one menu-skip policy.
    static var menuRoles: Set<String> { GenericPageExtractor.menuRoles }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXQueryHelperTests`
Expected: PASS, 12 tests (4 matcher tests, `all`/`first`, 3 visual-order tests, 3 `collectStaticTexts` tests, 1 menu-roles test).

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
  - `protocol StructuredParser: Sendable { static var config: ParserConfig { get }; func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? }`. It **throws** for exactly one reason: a parser may throw `ParserRefusal` (`Sources/MaxMiCapture/ParserRegistry.swift:74-81`) to mean "store nothing for this window", which `CaptureDispatch.parseDetailed` already maps to `.noContent` (`:132-147`) and which the browser path rethrows (ruling F13; spec §12 amendment superseding Q18). `nil` still means NOT_HANDLED.
  - `ParserRegistry.structuredParser(for bundleID: String) -> (any StructuredParser)?`, `.structuredParser(forHost host: String) -> (any StructuredParser)?`, `.structuredParser(bundleID: String, url: String?) -> (any StructuredParser)?`, `.forcedAttributes(for bundleID: String) -> Set<String>` (**wired into the live snapshot in Step 5** — ruling F3), `.registeredStructuredHosts: [String]`.
  - The Phase A test seam `init(parsers:)` (`Sources/MaxMiCapture/ParserRegistry.swift:60-62`, used by `Tests/MaxMiCaptureTests/ParserFallthroughTests.swift:78`) initialises both new stored properties to `[:]`; without that line the file does not compile (ruling F2).
  - `ParserRegistry.host(fromURL: String?) -> String?`.
  - `CaptureDispatch.StructuredParseResult` (`.parsed(CapturedContent, parserName: String)`, `.fellThrough(CapturedContent, notHandledBy: String?)`) and `CaptureDispatch.structuredCapture(window:context:registry:fallback:) throws -> StructuredParseResult`, where `fallback` is `(AXNode, ParseContext, GenericPageExtractor.Options) -> CapturedContent` and defaults to a `GenericPageExtractor` walk. This is the **browser** path's entry point — Task 9 calls it with `WebPageParser.parse` as the fallback, which is what gives it a production caller; the non-browser path keeps `CaptureDispatch.parseDetailed`, so no window is ever parsed twice (ruling F12).
  - **No new fallback-marker helper.** `CaptureDispatch.fallbackParserID(failedParser: String) -> String` already exists (`Sources/MaxMiCapture/ParserRegistry.swift:167-169`) and already returns exactly `"GenericPageExtractor.v2/fallback/\(failedParser)"`; every call site in this plan uses it (ruling F4). When no parser claimed the window there is no marker at all — the health row keeps the registry's own parser name.
  - `ParserRegistry.finderBundleID = "com.apple.finder"`, `.cursorBundleID = "com.todesktop.230313mzl4w4u92"`, `.vsCodeBundleID = "com.microsoft.VSCode"`, `.editorBundleIDs = [cursorBundleID, vsCodeBundleID]`.
- Later tasks register their parser by appending to the single `structured` list in `ParserRegistry.init()`; the two maps are derived from each parser's own `config`, so there is one registration site, exactly as the existing `parsers` map is. **The list is complete after Task 26 and reads exactly:**

```swift
        let structured: [any StructuredParser] = [
            TerminalParser(),        // Task 7  — Warp, Terminal.app, iTerm2 (4 bundle IDs)
            EditorParser(),          // Task 8  — Cursor, VS Code
            SlackParser(),           // Task 10 (+ Task 25 adds app.slack.com to its hosts)
            DiscordParser(),         // Task 11
            MessagesParser(),        // Task 12
            WhatsAppParser(),        // Task 13
            NotesParser(),           // Task 15
            NotionParser(),          // Task 16
            ObsidianParser(),        // Task 17
            FinderParser(),          // Task 18
            CalendarParser(),        // Task 19
            FantasticalParser(),     // Task 19
            RemindersParser(),       // Task 20
            GmailParser(),           // Task 22 — hosts only
            LinkedInMessagingParser(),// Task 23 — hosts only
            OutlookWebParser(),      // Task 24 — hosts only
            TeamsWebParser(),        // Task 26 — hosts only
        ]
```

  **Seventeen entries**: thirteen claimed by bundle ID (`SlackParser` claims both a bundle ID and a host) and four claimed by host only. Two parsers are deliberately absent: `MailParser`, because Mail stays AppleScript-sourced (§12 Q6) and Task 14 only adds its compose-window draft; and `WebPageParser` (Task 9), because it is the browser **default** reached when no host parser claims the URL, so it has no `ParserConfig` and is never in a map. Task 21's `PhaseDCoverageTests` re-asserts this exact list.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/StructuredParserRoutingTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

/// Claims the fake native app and always answers.
struct StubNativeParser: StructuredParser {
    static let config = ParserConfig(app: "StubNative", bundleIDs: ["com.example.native"],
                                     attributeSet: ["AXDOMClassList", "AXDOMIdentifier"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        .document(Document(title: "native", blocks: [], author: .unknown, url: nil))
    }
}

/// Claims a host and never answers, so the fall-through path is exercised.
struct StubSilentHostParser: StructuredParser {
    static let config = ParserConfig(app: "StubSilent", bundleIDs: [],
                                     hosts: ["silent.example.com"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? { nil }
}

/// Refuses instead of answering, which must mean "store nothing" — never a fallback capture.
struct StubRefusingParser: StructuredParser {
    static let config = ParserConfig(app: "StubRefusing", bundleIDs: ["com.example.refusing"])
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        throw ParserRefusal(reason: "no-header")
    }
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

    func testStructuredParserParseIsThrowingSoARefusalCanTravel() throws {
        // A refusal is not a fall-through: nothing is stored for this window, exactly as
        // `CaptureDispatch.parseDetailed` already does for a refusing SourceParser.
        let registry = ParserRegistry(structuredParsers: [StubRefusingParser()], hostParsers: [])
        XCTAssertThrowsError(try CaptureDispatch.structuredCapture(
            window: window(), context: context(bundleID: "com.example.refusing"),
            registry: registry)) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "no-header"))
        }
    }

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
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
                .document(Document(title: "host", blocks: [], author: .unknown, url: nil))
            }
        }
        struct PoliteHostParser: StructuredParser {
            static let config = ParserConfig(app: "Polite", bundleIDs: [],
                                             hosts: ["polite.example.com"], preferOverNative: false)
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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

    func testForcedAttributesAreTheUnionOfTheClaimingParsersAttributeSet() {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.native"),
                       ["AXDOMClassList", "AXDOMIdentifier"],
                       "the whole declared set is forced, not just the first entry")
        XCTAssertEqual(registry.forcedAttributes(for: "com.example.unknown"), [],
                       "an app with no v2 parser pays nothing for DOM attributes")
        XCTAssertTrue(registry.forcedAttributes(for: "com.example.native")
                        .isSubset(of: AXReader.domAttributeNames),
                      "only names AXReader honours may be forced")
    }

    func testTheRealRegistryExposesItsStructuredHosts() {
        // Every host entry must be lowercase, or the lookup can never hit it.
        for host in ParserRegistry().registeredStructuredHosts {
            XCTAssertEqual(host, host.lowercased(), "host entry \(host) must be lowercase")
        }
    }

    // MARK: - Dispatch

    func testAClaimingParserReturnsItsContentAndItsTypeName() throws {
        let registry = ParserRegistry(structuredParsers: [StubNativeParser()], hostParsers: [])
        let result = try CaptureDispatch.structuredCapture(
            window: window(), context: context(bundleID: "com.example.native"), registry: registry)
        guard case .parsed(let content, let parserName) = result else {
            return XCTFail("expected .parsed, got \(result)")
        }
        XCTAssertEqual(content, .document(Document(title: "native", blocks: [],
                                                   author: .unknown, url: nil)))
        XCTAssertEqual(parserName, "StubNativeParser")
    }

    func testAParserReturningNilFallsThroughToGenericPageExtractorAndNamesItself() throws {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [StubSilentHostParser()])
        let result = try CaptureDispatch.structuredCapture(
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
        // Phase A's helper is the ONE spelling of the §8 marker; Phase D adds no overload.
        XCTAssertEqual(CaptureDispatch.fallbackParserID(failedParser: try XCTUnwrap(notHandledBy)),
                       "GenericPageExtractor.v2/fallback/StubSilentHostParser")
    }

    func testNoRegisteredParserAlsoFallsThroughButNamesNoParser() throws {
        let registry = ParserRegistry(structuredParsers: [], hostParsers: [])
        let result = try CaptureDispatch.structuredCapture(
            window: window("plain"), context: context(bundleID: "com.example.nothing"),
            registry: registry)
        guard case .fellThrough(_, let notHandledBy) = result else {
            return XCTFail("expected .fellThrough, got \(result)")
        }
        XCTAssertNil(notHandledBy, "with nobody to blame there is no fallback marker at all")
    }

    func testTheTestSeamRegistryStillCompilesWithAnExplicitParserTable() {
        // Phase A's seam (ParserRegistry.init(parsers:), used by ParserFallthroughTests) gains two
        // stored properties and must still initialise them.
        let registry = ParserRegistry(parsers: [:])
        XCTAssertNil(registry.structuredParser(for: "com.example.native"))
        XCTAssertTrue(registry.registeredStructuredHosts.isEmpty)
    }

    func testFallThroughUsesTheClaimingParsersOffscreenPolicyBudget() throws {
        struct BoundedSilentParser: StructuredParser {
            static let config = ParserConfig(app: "Bounded", bundleIDs: ["com.example.bounded"],
                                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
            func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? { nil }
        }
        let registry = ParserRegistry(structuredParsers: [BoundedSilentParser()], hostParsers: [])
        // A node far below the window is only collected under an accessibilityScroll policy.
        let win = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                         children: [AXNode(role: "AXStaticText", value: "far below", title: nil,
                                           url: nil,
                                           frame: CGRect(x: 0, y: 9_000, width: 100, height: 16),
                                           focused: false, children: [])])
        let result = try CaptureDispatch.structuredCapture(
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
///
/// `parse` throws for exactly one purpose: `ParserRefusal` means "store NOTHING for this window",
/// which is different from nil. `CaptureDispatch.parseDetailed` already maps a refusal to
/// `.noContent`, and the browser pipeline rethrows it, so a refusing parser is never reported as
/// a `GenericPageExtractor.v2/fallback/...` degradation.
public protocol StructuredParser: Sendable {
    static var config: ParserConfig { get }
    func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent?
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

    /// The §8 marker for a fall-through is composed by the existing
    /// `CaptureDispatch.fallbackParserID(failedParser:)`. No second helper is added here.
    ///
    /// A thrown `ParserRefusal` is deliberately NOT caught: refusing means store nothing, and
    /// both call paths already handle that (native: `parseDetailed` returns `.noContent`;
    /// browser: `BrowserCapturePipeline.parse` rethrows and `AppWiring` records
    /// `.skipped(.parserNoContent)`).
    /// `fallback` is what NOT_HANDLED degrades to. It defaults to a `GenericPageExtractor` walk
    /// (spec §4f rule 3); the browser pipeline passes `WebPageParser`, because a web tab's
    /// degradation is the landmark page rooted at its `AXWebArea`, not the whole browser window.
    /// The claiming parser's `offscreenPolicy` is resolved here so both fallbacks honour it.
    static func structuredCapture(
        window: AXNode,
        context: ParseContext,
        registry: ParserRegistry,
        fallback: (AXNode, ParseContext, GenericPageExtractor.Options) -> CapturedContent = {
            window, context, options in
            .generic(GenericPageExtractor.extract(
                window: window, focusedElement: nil, url: context.url, options: options).page)
        }
    ) throws -> StructuredParseResult {
        let parser = registry.structuredParser(bundleID: context.app.bundleID, url: context.url)
        let parserName = parser.map { String(describing: type(of: $0)) }
        if let parser, let content = try parser.parse(window, context: context) {
            return .parsed(content, parserName: parserName ?? "unknown")
        }
        var options = GenericPageExtractor.Options()
        if let parser { options.offscreenPolicy = type(of: parser).config.offscreenPolicy }
        return .fellThrough(fallback(window, context, options), notHandledBy: parserName)
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
        // two maps below are derived, never hand-maintained in parallel with the list. Tasks 7-26
        // append to this ONE list; by the end of Phase D it holds the seventeen entries written
        // out in this task's Interfaces block, and `PhaseDCoverageTests` asserts that.
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

**Also update the Phase A test seam** `init(parsers:)` (`Sources/MaxMiCapture/ParserRegistry.swift:60-62`) — two new non-optional stored `let`s mean it no longer initialises every property, and `Tests/MaxMiCaptureTests/ParserFallthroughTests.swift:78` uses it:

```swift
    init(parsers: [String: any SourceParser]) {
        self.parsers = parsers
        // A seam registry exercises the v1 dispatch branches only; it registers no v2 parser.
        self.structuredParsers = [:]
        self.hostParsers = [:]
    }
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
Expected: PASS, 14 tests.

Run: `swift test --filter ParserRegistryTests`
Expected: PASS, unchanged — the existing `SourceParser` map is untouched.

Run: `swift test --filter ParserFallthroughTests`
Expected: PASS — the `init(parsers:)` seam now initialises the two new stored properties.

- [ ] **Step 5: Wire `forcedAttributes` into the live snapshot**

This is the only `AppWiring` change this task makes, and it is the one that decides whether the DOM anchors exist in production at all. `attributeSet` is declarative until something passes it to `AXReader`; without this step Slack/Notion/Obsidian read `domClassList == nil` in the live app and only the hand-authored fixtures pass (ruling F3).

In `Sources/MaxMi/AppWiring.swift`, inside `attemptCapture(app:pid:attemptsLeft:captureGeneration:trigger:startedAtMs:)`, resolve the set on the main actor **before** the detached read (`registry` is a main-actor property; the detached closure must not touch it), immediately above `Task.detached(priority: .utility) { [weak self] in` at `:1382`:

```swift
        // Electron trees (Slack, Notion, Obsidian) do not reliably expose an AXWebArea above
        // their DOM, so the claiming v2 parser's ParserConfig.attributeSet forces the two DOM
        // reads for the whole tree. Every other app forces nothing and pays nothing (spec §8).
        let forcedAttributes = registry.forcedAttributes(for: app.bundleID)
```

then thread it through both snapshot calls (`:1383` and `:1391`):

```swift
            let snapshot = AXReader.snapshotFrontmostWindow(pid: pid,
                                                            forcedAttributes: forcedAttributes)
```

```swift
                confirmationSnapshot = AXReader.snapshotFrontmostWindow(
                    pid: pid, forcedAttributes: forcedAttributes)
```

**The non-browser dispatch switch at `:1483` is deliberately left alone.** A v2 parser reaches it through the `parseStructured` bridge every parser task writes, so `parseDetailed` already returns the v2 content on `ParsedCapture.structured`; a v2 parser that returns nil makes `parse(window:app:)` return nil, which `parseDetailed` already turns into `.parsedByFallback(_, failedParser:)`, which the existing line at `:1492` already renders as `CaptureDispatch.fallbackParserID(failedParser:)`. Calling `structuredCapture` here as well would parse every non-browser window twice and run a wasted full-tree `GenericPageExtractor` walk for the ~14 apps that have no v2 parser (ruling F12). `structuredCapture` exists for the **browser** path, which has no `SourceParser` to route through, and is called from `BrowserCapturePipeline` in Task 9.

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
- Modify (delete the duplicated `func fixture(_:)` from each — **twelve** copies exist on this branch, not the six spec §7d names; see the §12 repair amendment): `Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift:5-10`, `BrowserCapturePipelineTests.swift:6-9`, `ExtractorTests.swift:5-8`, `GenericAXParserTests.swift:5-12`, `GenericPageBudgetTests.swift:6-11`, `GenericPageRegionTests.swift:6-11`, `NativeConversationParserTests.swift:6-9`, `SlackParserTests.swift:6-9`, `StructuredConversationParserTests.swift:6-11`, `StructuredEntityTypedTests.swift:6-11`, `StructuredNativeParserTests.swift:5-8`, `WebAppStructuredTests.swift:6-11`
- Modify: `Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift` (delete Task 1's thirteenth copy of the same helper; its `everyFixtureName()` stays)
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md` (recording + scrubbing procedure)

**Interfaces:**
- Consumes: `AXNode` with `domClassList`/`domIdentifier` (Task 1); `CapturedContent` and `CapturedContentEnvelope` (Phase A).
- Produces, all at file scope in `MaxMiCaptureTests` so every test file sees them without inheritance: `func fixture(_ name: String) throws -> AXNode`, `func goldenCapturedContent(_ name: String) throws -> CapturedContent`, `func assertGolden(_ content: CapturedContent, matches name: String, file: StaticString, line: UInt)`, and `func goldenJSON(_ content: CapturedContent) throws -> String` (used to *write* a golden the first time).
- The **thirteen** existing call-site classes keep calling `try fixture("slack-window")` unchanged — the free function shadows nothing and resolves identically at each call site once the methods are deleted. Two body variants exist in the tree (one force-unwraps `Bundle.module.url`, one wraps it in `XCTUnwrap`); both are replaced by the single `XCTUnwrap` form below, which is why a missing fixture now fails with a message instead of a crash.

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

    func testMissingFixtureFailsLoudly() throws {
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

/// The one AX fixture loader. Spec §7d names six duplicates; twelve exist on this branch, plus
/// Task 1's thirteenth — all thirteen are deleted in favour of this function (§12 repair
/// amendment).
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

- [ ] **Step 4: Write the golden file, then run the test**

Run: `swift test --filter FixtureLoadingTests`
Expected: 3 of the 4 pass; `testAssertGoldenPassesForAMatchingGolden` fails with "golden generic-empty-golden unavailable" because the file does not exist yet.

Print the bytes and save them:

```swift
// Temporarily at the top of testAssertGoldenPassesForAMatchingGolden:
print(try goldenJSON(.generic(GenericPage(regions: [], focused: nil, url: nil))))
```

Save the printed string as `Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json`, remove the `print`, and re-run:

Run: `swift test --filter FixtureLoadingTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Delete the twelve duplicated loaders, plus Task 1's**

Delete the `func fixture(_:)` method from each of these thirteen files (line ranges as they stand on this branch; **twelve**, not the six spec §7d names — ruling F17):

| File (`Tests/MaxMiCaptureTests/`) | Lines | Body variant |
|---|---|---|
| `AXNodeAttributesTests.swift` | 5-10 | `XCTUnwrap` |
| `BrowserCapturePipelineTests.swift` | 6-9 | force-unwrap |
| `ExtractorTests.swift` | 5-8 | force-unwrap |
| `GenericAXParserTests.swift` | 5-12 | `XCTUnwrap` |
| `GenericPageBudgetTests.swift` | 6-11 | `XCTUnwrap` |
| `GenericPageRegionTests.swift` | 6-11 | `XCTUnwrap` |
| `NativeConversationParserTests.swift` | 6-9 | force-unwrap |
| `SlackParserTests.swift` | 6-9 | force-unwrap |
| `StructuredConversationParserTests.swift` | 6-11 | `XCTUnwrap` |
| `StructuredEntityTypedTests.swift` | 6-11 | `XCTUnwrap` |
| `StructuredNativeParserTests.swift` | 5-8 | force-unwrap |
| `WebAppStructuredTests.swift` | 6-11 | `XCTUnwrap` |
| `AXNodeDOMAttributeTests.swift` (Task 1's copy) | the `fixture(_:)` method only — keep `everyFixtureName()` | `XCTUnwrap` |

The two body variants are:

```swift
    func fixture(_ name: String) throws -> AXNode {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }
```

```swift
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
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
Expected: PASS, no NEW failures, including `FixtureLoadingTests` (4 tests) and all thirteen modified classes.

Run: `grep -rn "func fixture(" Tests/ | wc -l`
Expected: `1` — the free function in `FixtureLoading.swift` and nothing else.

- [ ] **Step 9: Commit**

```bash
git add tools/ax-snapshot-record.swift Tests/MaxMiCaptureTests/FixtureLoading.swift \
        Tests/MaxMiCaptureTests/FixtureLoadingTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/generic-empty-golden.json \
        Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift \
        Tests/MaxMiCaptureTests/AXNodeDOMAttributeTests.swift \
        Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift \
        Tests/MaxMiCaptureTests/ExtractorTests.swift \
        Tests/MaxMiCaptureTests/GenericAXParserTests.swift \
        Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift \
        Tests/MaxMiCaptureTests/GenericPageRegionTests.swift \
        Tests/MaxMiCaptureTests/NativeConversationParserTests.swift \
        Tests/MaxMiCaptureTests/SlackParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredEntityTypedTests.swift \
        Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift \
        Tests/MaxMiCaptureTests/WebAppStructuredTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Add AX snapshot recorder and one shared fixture loader"
```

---

### Task 7: Terminal (Warp, Terminal.app, iTerm2) → `.terminal`

**Files:**
- Modify: `Sources/MaxMiCapture/TerminalParser.swift` (**replace** Phase A Task 14's `promptPatterns`, `segments(fromScrollback:)`, `joinedOutput(_:)`, `sessionCwd(fromTitle:)` and `structured(fromScrollback:app:)`; edit the existing `parseStructured` body in place)
- Modify: `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` (**kept, not deleted** — ruling F8: move its two invariant tests into the new file and update its two `cwd` expectations from the Phase A slug to Phase D's absolute path)
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (add `TerminalParser()` to `structured`)
- Create: `Tests/MaxMiCaptureTests/Fixtures/warp-session.json`, `warp-session-golden.json`, `iterm-offset-session.json`, `iterm-offset-session-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/TerminalStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)` (Task 3); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `TerminalSegment`, `TerminalSession`, `CapturedContent` (Phase A).
- Produces: `TerminalParser: StructuredParser` with `static let config`; `TerminalParser.PromptShape` (`.userHost`, `.path`) with `pattern`; `TerminalParser.promptShape(in lines: [String]) -> PromptShape?`; `TerminalParser.commandText(in line: String, shape: PromptShape) -> String?`; `TerminalParser.segments(fromScrollback: String) -> [TerminalSegment]`; `TerminalParser.cwdPath(windowTitle: String?, scrollback: String) -> String?`; `TerminalParser.session(fromScrollback: String, windowTitle: String?) -> CapturedContent` (the ONE content path, bounded by `CaptureAccumulator.bound(_:to: contentCap)`); `TerminalParser.pathBodyPattern` (a `static let`, promoted from the local string in `lastPathComponent`).
- **Deleted in this task** (ruling F20 — an orphaned `private`/`static` member is a build warning and Task 21 requires none): Phase A Task 14's `promptPatterns: [String]`, its `segments(fromScrollback:)` body, `joinedOutput(_:)` (only the old segmenter called it), `sessionCwd(fromTitle:)` and `structured(fromScrollback:app:)` (both only reachable from the old content path). Nothing outside `TerminalParser.swift` references any of them — verified by grep across `Sources/` and `Tests/`.
- **`parseStructured(window:app:)` already exists** at `Sources/MaxMiCapture/TerminalParser.swift:30`. Its **body is edited**; it is NOT redeclared in the extension, which would be an invalid redeclaration (ruling F1). The same rule holds for every parser task in this plan.
- `parse(window:app:)` keeps `sourceApp`, `sourceKey` (`terminalKey`), `sourceTitle`, `contentKind: .terminal` and `accumulationPolicy: .appendItems`, and becomes a pure render wrapper over the same `session(fromScrollback:windowTitle:)` value — one scrollback read, one segmentation, one content path (ruling F9).
- `sourceApp`, `sourceKey` (`terminalKey`), `contentKind: .terminal`, `accumulationPolicy: .appendItems` stay exactly where they are, on `parse(window:app:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/TerminalStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TerminalStructuredTests: XCTestCase {
    func window(_ scrollback: String, origin: CGPoint = .zero,
                title: String? = "~/code/MaxMi") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
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

    func testConfigClaimsEveryTerminalBundleID() {
        // Four today: dev.warp.Warp-Stable, dev.warp.Warp, com.apple.Terminal, com.googlecode.iterm2.
        XCTAssertEqual(Set(TerminalParser.config.bundleIDs),
                       Set(ParserRegistry.terminalBundleIDs))
        XCTAssertEqual(TerminalParser.config.bundleIDs.count, 4)
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
        Executed 689 tests, with 3 failures
        ada@mac ~/code/MaxMi %
        """
        let segments = TerminalParser.segments(fromScrollback: scrollback)
        XCTAssertEqual(segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(segments[0].output, "Compiling MaxMi\nBuild complete")
        XCTAssertEqual(segments[1].output, "Executed 689 tests, with 3 failures")
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
        let content = try TerminalParser().parse(window(scrollback), context: context("~/code/MaxMi"))
        let terminal = try session(content)
        XCTAssertEqual(terminal.cwd, "~/code/MaxMi")
        XCTAssertEqual(terminal.segments.map(\.command), ["swift build"])
        XCTAssertEqual(ContentRenderer.render(try XCTUnwrap(content), style: .full),
                       "$ swift build\nBuild complete")
    }

    func testSegmentationIsIdenticalAtANonzeroWindowOrigin() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let flush = try TerminalParser().parse(window(scrollback), context: context("~/code"))
        let offset = try TerminalParser().parse(window(scrollback, origin: CGPoint(x: 1440, y: 220)),
                                                context: context("~/code"))
        XCTAssertEqual(flush, offset, "a terminal is text; its origin must not matter")
    }

    func testEmptyTerminalIsNotHandled() throws {
        let bare = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 10, height: 10), focused: false,
                          children: [])
        XCTAssertNil(try TerminalParser().parse(bare, context: context(nil)),
                     "nil is NOT_HANDLED and routes to GenericPageExtractor")
    }

    func testParseStructuredBridgeMatchesTheStructuredParser() throws {
        let scrollback = "ada@mac ~/code % ls\nPackage.swift\nada@mac ~/code %"
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: "~/code")
        XCTAssertEqual(try TerminalParser().parseStructured(window: window(scrollback), app: app),
                       try TerminalParser().parse(window(scrollback), context: context("~/code")))
    }

    // MARK: - Invariants moved here from TerminalSegmentationTests (ruling F8)

    /// Moved verbatim in intent from `TerminalSegmentationTests`: the ONLY coverage that the
    /// rendered capture is the render of the typed value and that the key/kind/policy trio is
    /// untouched by the anchored rewrite.
    func testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy() throws {
        let blob = "dev@mac ~/code/MaxMi % swift test\n2 failures"
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                          windowTitle: "~/code/MaxMi")
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app))
        XCTAssertEqual(capture.sourceApp, "Warp")
        XCTAssertEqual(capture.sourceKey, "terminal:warp/maxmi",
                       "the key is still derived from the RAW scrollback, not from the typed value")
        XCTAssertEqual(capture.contentKind, .terminal)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(capture.content, "$ swift test\n2 failures\n… (running)")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full),
                       "one content path: `parse` renders exactly what `parseStructured` returned")
    }

    /// Moved from `TerminalSegmentationTests`: the ONLY coverage of the `contentCap` trim.
    func testOversizeScrollbackDropsOldestSegments() throws {
        var lines: [String] = []
        for index in 0..<400 {
            lines.append("dev@mac ~/code/MaxMi % echo \(index)")
            lines.append(String(repeating: "y", count: 40))
        }
        let blob = lines.joined(separator: "\n")
        let app = AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                          windowTitle: "~/code/MaxMi")
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app))
        XCTAssertEqual(session.segments.last?.command, "echo 399", "newest-anchored")
        XCTAssertLessThan(session.segments.count, 400, "oldest segments are dropped")
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app))
        XCTAssertLessThanOrEqual(capture.content.count, TerminalParser.contentCap)
    }

    // MARK: - Golden fixtures

    func testWarpSessionFixtureMatchesItsGolden() throws {
        let content = try TerminalParser().parse(try fixture("warp-session"),
                                                 context: context("~/code/sample"))
        assertGolden(try XCTUnwrap(content), matches: "warp-session-golden")
    }

    func testOffsetITermSessionFixtureMatchesItsGolden() throws {
        let iterm = ParseContext(app: AppInfo(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                                              windowTitle: "~/code/sample"))
        let content = try TerminalParser().parse(try fixture("iterm-offset-session"), context: iterm)
        assertGolden(try XCTUnwrap(content), matches: "iterm-offset-session-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalStructuredTests`
Expected: FAIL to compile — "type 'TerminalParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

First delete these five Phase A members from `Sources/MaxMiCapture/TerminalParser.swift`, all of them unreachable once the new path lands (ruling F20; no caller exists outside this file):

- `static let promptPatterns: [String]` (`:25-28`)
- `static func segments(fromScrollback:)` (`:66`) — the name is reused below, the body is replaced
- `static func joinedOutput(_:)` — called only by the old segmenter
- `func sessionCwd(fromTitle:)` — called only by `structured(fromScrollback:app:)`
- `func structured(fromScrollback:app:)` (`:54-61`) — the second content path; ruling F9 leaves exactly one

`TerminalSegmentationTests.swift` is **not** deleted (ruling F8) — Step 4b edits it instead. Also update the class doc comment, which still says "Phase D replaces this with an anchored parser that reads the emulator's own command boundaries": that is now this task.

Then promote the path pattern to a `static let` next to `contentCap`:

```swift
    /// A home-or-absolute path with no prompt terminator inside it.
    static let pathBodyPattern = "(~|/Users/[^/ ]+)(/[^ \t\n:%$#>❯]+)*"
```

and replace the local `let pathBody = …` in `lastPathComponent(in:requirePrompt:)` with `Self.pathBodyPattern`:

```swift
        let pattern = requirePrompt ? "\(Self.pathBodyPattern)\\s*[%$#>❯]" : Self.pathBodyPattern
```

Then **edit the existing `parseStructured` body** at `:30` (it is already declared in the struct; declaring it again in the extension below is an invalid redeclaration — ruling F1):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

and rewrite `parse(window:app:)` so the render is the only thing it adds — one scrollback read, one segmentation:

```swift
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // One AX walk per capture: the thread key needs the RAW prompt lines, so the blob is read
        // here and the typed session is built from that same blob.
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        let session = Self.session(fromScrollback: blob, windowTitle: app.windowTitle)
        return ParsedCapture(
            sourceApp: app.name,                 // "Warp", "Terminal", "iTerm2"
            sourceKey: terminalKey(app: app, content: blob),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(session, style: .full),
            contentKind: .terminal,
            parserVersion: 3,
            accumulationPolicy: .appendItems,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: session
        )
    }
```

Then append this extension to the same file — `config`, the shape machinery, the one content path, and `parse(_:context:)`, and **no** `parseStructured`:

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

    /// The ONE content path for a terminal. Newest-anchored hard cap on the STRUCTURED value,
    /// because the rendered text is derived from it — capping the string afterwards would just be
    /// undone by the renderer, and it is what keeps `capture.content <= contentCap`.
    static func session(fromScrollback blob: String, windowTitle: String?) -> CapturedContent {
        let session = TerminalSession(
            cwd: cwdPath(windowTitle: windowTitle, scrollback: blob),
            segments: segments(fromScrollback: blob)
        )
        return CaptureAccumulator.bound(.terminal(session), to: contentCap)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let areas = AXQuery.findAll("//AXTextArea", in: snapshot)
        // Warp exposes one; some emulators expose several — take the richest.
        guard let blob = areas.compactMap(\.value).filter({ !$0.isEmpty })
                .max(by: { $0.count < $1.count }) else { return nil }
        return Self.session(fromScrollback: blob, windowTitle: context.windowTitle)
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
Expected: PASS, unchanged — `terminalKey` and `workingDirectory(from…)` are untouched, and `parse(window:app:)` still returns the same key, kind and policy.

- [ ] **Step 4b: Update the two `cwd` expectations in `TerminalSegmentationTests`**

The file stays (ruling F8). Two of its assertions measured Phase A's deliberately narrow slug cwd; Phase D returns the absolute path Phase A deferred, so update exactly these two lines in `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` and delete the two tests that moved into `TerminalStructuredTests` in Step 1 (`testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy`, `testOversizeScrollbackDropsOldestSegments`):

```swift
        XCTAssertEqual(session.cwd, "~/code/MaxMi")
```

```swift
        XCTAssertEqual(session.cwd, "~/code/ShipCast")
```

Run: `swift test --filter TerminalSegmentationTests`
Expected: PASS, 7 tests — the seven that stay assert the segmentation contract (both prompt shapes, the bare trailing prompt, the prompt-prefix strip, the leading commandless segment, the unrecognised-prompt fallback, and the empty-scrollback nil), all of which the new segmenter preserves.

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
Expected: PASS, 19 tests (17 written in Step 1 plus the two moved in from `TerminalSegmentationTests`).

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/TerminalParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/TerminalStructuredTests.swift \
        Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift \
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
        XCTAssertEqual(EditorParser.config.offscreenPolicy,
                       .accessibilityScroll(maxSteps: 6, maxCharacters: 32_000),
                       "the scroll ceiling equals the render cap — no unreachable ceiling (F11)")
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
        let content = try EditorParser().parse(window(editor: "let a = 1\nlet b = 2", panel: nil),
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
        let content = try EditorParser().parse(
            window(editor: "let a = 1", panel: "ada@mac ~/code % swift test"),
            context: context(ParserRegistry.cursorBundleID, "sample — app.swift"))
        let doc = try document(content)
        XCTAssertEqual(doc.blocks.map(\.text), ["let a = 1"])
        XCTAssertFalse(ContentRenderer.render(try XCTUnwrap(content), style: .full)
                        .contains("swift test"),
                       "the panel is not the document the user is editing")
    }

    func testNoEditorAnchorIsNotHandledSoGenericPageExtractorTakesOver() throws {
        let welcome = node("AXWindow", title: "Welcome",
                           frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                           children: [node("AXGroup", identifier: "workbench.panel.terminal",
                                           children: [node("AXTextArea", value: "shell only")])])
        XCTAssertNil(try EditorParser().parse(welcome,
                                              context: context(ParserRegistry.cursorBundleID,
                                                               "Welcome")),
                     "nil routes to GenericPageExtractor, which will pick the panel up")
    }

    func testEmptyEditorIsNotHandled() throws {
        XCTAssertNil(try EditorParser().parse(window(editor: "   ", panel: nil),
                                              context: context(ParserRegistry.vsCodeBundleID,
                                                               "a.swift")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let flush = try EditorParser().parse(window(editor: "let a = 1", panel: nil),
                                             context: context(ParserRegistry.vsCodeBundleID,
                                                              "app.swift — sample"))
        let offset = try EditorParser().parse(
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
        let content = try EditorParser().parse(try fixture("vscode-editor"),
                                               context: context(ParserRegistry.vsCodeBundleID,
                                                                "sample.swift — sample"))
        assertGolden(try XCTUnwrap(content), matches: "vscode-editor-golden")
    }

    func testOffsetCursorFixtureMatchesItsGolden() throws {
        let content = try EditorParser().parse(try fixture("cursor-offset-editor"),
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
    public init() {}

    /// The render cap and the scroll ceiling are the SAME number on purpose: a ceiling above the
    /// cap is unreachable, and Phase A's final review removed exactly that pattern
    /// (`StructuredNativeParsers.pageBudget = 32_000`, `:247`). Ruling F11 — 96_000 appears
    /// nowhere in `Sources/MaxMiCapture` and this task does not introduce it.
    static let contentCap = StructuredEntityExtraction.pageBudget   // 32_000
    public static let config = ParserConfig(
        app: "Editor",
        bundleIDs: ParserRegistry.editorBundleIDs,
        offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: contentCap)
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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
        guard let structured = try parse(window, context: ParseContext(app: app)) else { return nil }
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
        try parse(window, context: ParseContext(app: app))
    }
}
```

`EditorParser` is a new type, so both conformances are declared in the struct body and there is no
redeclaration hazard here (ruling F1 concerns the eight existing parsers).

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
Expected: PASS, 12 tests.

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
- Produces: `WebPageParser.extract(window: AXNode, webArea: AXNode, url: String?, options: GenericPageExtractor.Options) -> GenericPageExtractor.Result`; `WebPageParser.parse(window: AXNode, tab: TabCapture) -> CapturedContent`; `BrowserCapturePipeline.parse(window:windowTitle:browser:contentBudget:registry:) throws -> BrowserCaptureResult` — `contentBudget:` is **kept** (ruling F5; `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift:117` passes `contentBudget: 60`) and `registry:` is added with a default. `BrowserCaptureResult` gains **no** field: the structured value is already on `result.capture.structured` and a second copy would be two sources of truth (ruling F30).
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
        XCTAssertFalse(result.parserID.contains("fallback"),
                       "no host parser claimed this tab, so there is nothing to degrade from")
        XCTAssertEqual(result.capture.contentKind, .webpage, "spec §12 Q3: browsers keep .webpage")
        let structured = try XCTUnwrap(result.capture.structured,
                                       "the browser path always attaches a typed shape")
        XCTAssertEqual(result.capture.content, ContentRenderer.render(structured, style: .full))
        XCTAssertEqual(try page(structured).regions.map(\.kind), [.main, .sidebar, .navigation])
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

In `Sources/MaxMiCapture/BrowserCapturePipeline.swift`, `BrowserCaptureResult` is **unchanged** — every consumer reads `result.capture.structured`, which already carries exactly this value (ruling F30). Only `parse` changes. Replace the body's first two statements with:

```swift
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        // `WebAppCaptureParser.parse` THROWS (ExtractionError.emptyContent on an empty page) and
        // takes the budget — both are load-bearing and neither may be dropped.
        let web = try WebAppCaptureParser.parse(tab: tab, window: window,
                                                contentBudget: contentBudget)
        // Host routing (spec §7b): a registered host parser claims the tab; otherwise the tab is
        // a generic web page. Either way `contentKind` stays whatever `classify` decided (§12 Q3).
        let hostContext = ParseContext(
            app: AppInfo(bundleID: browser.bundleID, name: browser.displayName,
                         windowTitle: windowTitle),
            url: tab.url
        )
        // One routing call, one parse. `try` is not optional politeness: a host parser may throw
        // `ParserRefusal` for a tab it will not let be stored (a compose-only Gmail window, Task
        // 22). The refusal propagates out of this function and `AppWiring` records
        // `.skipped(.parserNoContent)` — it is never swallowed into a generic capture (F13).
        let routed = try CaptureDispatch.structuredCapture(
            window: window, context: hostContext, registry: registry,
            fallback: { window, _, _ in WebPageParser.parse(window: window, tab: tab) }
        )
        let structured: CapturedContent
        var hostParserMarker: String? = nil
        switch routed {
        case .parsed(let content, let parserName):
            structured = content
            hostParserMarker = parserName
        case .fellThrough(let content, let notHandledBy):
            structured = content
            // Spec §8: a registered host parser that returned nil is a non-silent degradation.
            hostParserMarker = notHandledBy.map { CaptureDispatch.fallbackParserID(failedParser: $0) }
        }
```

and append the marker to the parser ID, so the Capture Health window names the host parser that
claimed (or degraded on) the tab:

```swift
        let parserID = ([
            "BrowserWeb.v2",
            browser.browserEngine?.rawValue ?? "unknown",
            web.app.rawValue,
            tab.urlSource.rawValue,
            "quality-\(quality.rawValue)",
        ] + (hostParserMarker.map { [$0] } ?? [])).joined(separator: "/")
```

`BrowserCapturePipeline.parse` therefore needs the registry. Add it **after** `contentBudget:`, which stays exactly as it is:

```swift
    public static func parse(
        window: AXNode,
        windowTitle: String?,
        browser: ApplicationDescriptor,
        contentBudget: Int = WebAppCaptureParser.contentCap,
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
            // The same three independent ways content can have been dropped Phase A recorded,
            // measured against the rendered form of the typed shape this path now produces.
            truncated: tab.truncated || web.truncated
                || ContentRenderer.render(structured, style: .full).count
                    >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
```

The `registry` default keeps the existing call sites compiling (including `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift:117`, which passes `contentBudget: 60` and no registry). Change the production call site at `Sources/MaxMi/AppWiring.swift:1450` to pass the app's own registry so the two share one instance:

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
- Produces: `SlackParser: StructuredParser`; `SlackParser.config` (bundle ID `ParserRegistry.slackBundleID`, hosts `["app.slack.com", ".slack.com"]`, `attributeSet: ["AXDOMClassList"]`, `preferOverNative: true`); `SlackParser.domMessages(in:) -> [Message]`; `SlackParser.draftMessage(in:) -> Message?`; `SlackParser.geometryMessages(in:) -> [Message]`; `SlackParser.parse(_:context:)`.
- **Reuses, does not re-implement, the existing title helpers.** `channel(fromTitle:)` (`Sources/MaxMiCapture/SlackParser.swift:42`) and `isGroup(fromTitle:)` (`:52`) stay and are called by the new path — `Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift:36-41` asserts them directly, and a third title parser on one type is exactly the duplication Phase A already flagged. There is **no** `channelName(fromTitle:)`.
- `key(fromTitle:)` and `parse(window:app:)` are untouched: `parse` already delegates to `parseStructured` (`:26`), so replacing that body replaces the content path with no second path.
- **Deleted in this task** (ruling F20 — orphaned once the content path is replaced, and nothing outside `SlackParser.swift` calls them): `messages(in:windowX:)` (`:74`), `collectRows(_:into:windowX:)` (`:96`), `collectStaticText(_:into:)` (`:112`).
- **`parseStructured(window:app:)` already exists at `:12` — its body is edited, it is not redeclared** (ruling F1).
- The cap survives: `CaptureAccumulator.boundHard(_:to: contentCap)` still wraps the conversation, because `StructuredConversationParserTests.swift:80` and `SlackParserTests.swift:14` assert `capture.content.count <= SlackParser.contentCap`.

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
        // The EXISTING helpers, reused rather than duplicated (there is no `channelName`).
        XCTAssertEqual(SlackParser().channel(fromTitle: "general - Acme - Slack"), "general")
        XCTAssertEqual(SlackParser().channel(fromTitle: "Huddle"), "Huddle")
        XCTAssertEqual(SlackParser().channel(fromTitle: nil), "unknown")
        XCTAssertTrue(SlackParser().isGroup(fromTitle: "general - Acme - Slack"))
        XCTAssertFalse(SlackParser().isGroup(fromTitle: "Huddle"))
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

    func testDOMResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try SlackParser().parse(domWindow(), context: context("general - Acme - Slack")),
                       try SlackParser().parse(domWindow(origin: CGPoint(x: 1440, y: 220)),
                                           context: context("general - Acme - Slack")))
    }

    func testAWindowWithNeitherAnchorIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(try SlackParser().parse(bare, context: context("x - y - Slack")))
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

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/SlackParser.swift:12` — it is already declared in the struct, so declaring it again in the extension below would be an invalid redeclaration (ruling F1):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

Delete `messages(in:windowX:)`, `collectRows(_:into:windowX:)` and `collectStaticText(_:into:)` in the same edit — the new path replaces all three and Swift warns on the unused `private` pair (ruling F20).

Then append to the same file:

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
        let rows = AXQuery.findAll("//AXRow", in: snapshot)
            .filter { row in
                // Window-relative: AXFrame is global screen coordinates.
                guard let x = row.frame?.minX else { return true }
                return (x - windowX) >= sidebarMaxX
            }
        // Oldest first, exactly as the Phase A row walk sorted by y — `.appendItems` accumulation
        // and the newest-anchored cap both depend on this order.
        return AXQuery.sortedByVisualOrder(rows, relativeTo: snapshot.frame)
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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        if messages.isEmpty { messages = Self.geometryMessages(in: snapshot) }
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        guard !messages.isEmpty else { return nil }
        let conversation = Conversation(
            // The existing title helpers, not new ones: they are asserted directly by
            // StructuredConversationParserTests and Task 25 refines `isGroup` from the header.
            channel: channel(fromTitle: context.windowTitle),
            isGroup: isGroup(fromTitle: context.windowTitle),
            messages: messages
        )
        // Newest-anchored HARD cap on the STRUCTURED value, unchanged from Phase A: the rendered
        // text is derived from it, and one pathological message must not bloat a version.
        return CaptureAccumulator.boundHard(.conversation(conversation), to: Self.contentCap)
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
Expected: PASS, unchanged — all 8 tests drive `parseStructured`/`parse` over DOM-less fixtures and synthetic rows, so they now exercise `geometryMessages`: the sidebar filter, the window-relative filter, sender attribution and both cap tests all hold because the fallback keeps the same rules and the same `boundHard` cap.

Run: `swift test --filter StructuredConversationParserTests`
Expected: PASS, unchanged — `channel(fromTitle:)`/`isGroup(fromTitle:)` are still there and still what the conversation is built from.

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
- Create: `Tests/MaxMiCaptureTests/Fixtures/discord-messages.json`, `discord-messages-golden.json`, `discord-offset-messages.json` (no second golden — see Step 1's `testTheOffsetFixtureProducesTheSameContentAsTheFlushOne`)
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/DiscordStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.collectStaticTexts(in:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `DiscordParser: StructuredParser`; `DiscordParser.config` (bundle ID `ParserRegistry.discordBundleID`, hosts `["discord.com", "www.discord.com"]`, `preferOverNative: true`); `DiscordParser.messageList(in:) -> AXNode?`; `DiscordParser.channelName(fromTitle:) -> String`; `DiscordParser.messages(in list: AXNode) -> [Message]`; `DiscordParser.staticTextsInTreeOrder(_:) -> [String]`.
- `key(fromTitle:)`, `chrome`, `contentCap` and `parse(window:app:)` are untouched: `parse` already delegates to `parseStructured` (`Sources/MaxMiCapture/DiscordParser.swift:34`), so replacing that body replaces the whole content path.
- **`parseStructured(window:app:)` already exists at `:19` — its body is edited, not redeclared** (ruling F1).
- **Deleted in this task** (ruling F20): `messageLines(in:)` (`:74`) and `collect(_:into:)` (`:79`), both `private` and both orphaned by the new path.
- `channelName(fromTitle:)` is genuinely new: `key(fromTitle:)` returns a slugged `discord:<server>/<channel>` key, not a display channel name, and it is asserted by `DiscordParserTests`, so it is reused for the key and not for the channel.
- The `contentCap` bound is preserved with `CaptureAccumulator.boundHard`, replacing Phase A's hand-rolled newest-anchored trim loop.
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

    func testNoMessageListIsNotHandled() throws {
        XCTAssertNil(try DiscordParser().parse(node("AXWindow", children: [node("AXList", label: "Servers")]),
                                           context: context("#general | Acme - Discord")))
    }

    func testResultIsUnaffectedByFrameValuesEntirely() throws {
        // Same tree, every frame replaced with an absurd one. Discord's frames lie; the parser
        // must not read them at all.
        // EVERY field except `frame` is carried over: a rebuild that dropped subrole/heading
        // level/DOM attributes would prove attribute-independence too, and would let a future
        // frame read slip in through a node that kept its own attributes (ruling F25).
        func reframed(_ node: AXNode, _ frame: CGRect) -> AXNode {
            AXNode(role: node.role, value: node.value, title: node.title, url: node.url,
                   frame: frame, focused: node.focused,
                   children: node.children.map { reframed($0, frame) },
                   identifier: node.identifier, label: node.label, subrole: node.subrole,
                   headingLevel: node.headingLevel, selected: node.selected,
                   placeholder: node.placeholder, selectedText: node.selectedText,
                   hidden: node.hidden, domClassList: node.domClassList,
                   domIdentifier: node.domIdentifier)
        }
        let a = try DiscordParser().parse(window(), context: context("#general | Acme - Discord"))
        let b = try DiscordParser().parse(reframed(window(), CGRect(x: -9_999, y: 5, width: 1, height: 1)),
                                      context: context("#general | Acme - Discord"))
        XCTAssertEqual(a, b)
    }

    func testDiscordFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(DiscordParser().parse(try fixture("discord-messages"),
                                                        context: context("#general | Acme - Discord"))),
                     matches: "discord-messages-golden")
    }

    func testTheOffsetFixtureProducesTheSameContentAsTheFlushOne() throws {
        // Discord is geometry-free, so the offset recording must produce the SAME typed value —
        // and it is checked against the SAME golden. A second golden file with identical bytes
        // would add no signal (ruling F25), so `discord-offset-messages-golden.json` is not
        // created; the equality below plus the shared golden is the assertion.
        let flush = try XCTUnwrap(DiscordParser().parse(
            try fixture("discord-messages"), context: context("#general | Acme - Discord")))
        let offset = try XCTUnwrap(DiscordParser().parse(
            try fixture("discord-offset-messages"), context: context("#general | Acme - Discord")))
        XCTAssertEqual(flush, offset, "the window origin must not reach the typed value")
        assertGolden(offset, matches: "discord-messages-golden")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DiscordStructuredTests`
Expected: FAIL to compile — "type 'DiscordParser' does not conform to protocol 'StructuredParser'".

- [ ] **Step 3: Write minimal implementation**

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/DiscordParser.swift:19` (it is already declared in the struct — ruling F1) and delete the two now-orphaned private helpers `messageLines(in:)` and `collect(_:into:)` (ruling F20):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

The `GenericV2Content.lines(kept)` call goes with the old body — it is deleted, not chained.

Then append to the same file:

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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let list = Self.messageList(in: snapshot) else { return nil }
        let messages = Self.messages(in: list)
        guard !messages.isEmpty else { return nil }
        let conversation = Conversation(
            channel: Self.channelName(fromTitle: context.windowTitle),
            isGroup: true,
            messages: messages
        )
        // Same newest-anchored cap Phase A applied by hand, expressed with the shared accumulator.
        return CaptureAccumulator.boundHard(.conversation(conversation), to: Self.contentCap)
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

Record once flush at the origin and once with the window at a nonzero origin. Because Discord is geometry-free, the **second golden must be byte-identical to the first** — so do not hand-write it: assert the equality directly (`testTheOffsetFixtureProducesTheSameContentAsTheFlushOne` in Step 1 compares the two parses) and reuse `discord-messages-golden.json` as the expected value for both fixtures. A second copy of the same bytes proves nothing (ruling F25).

Each fixture must retain at minimum:
- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `discord-offset-messages.json`) and a `title` of the form `#general | Acme - Discord`,
- one `AXList` whose `label` or `identifier` contains `Messages in`,
- inside it, **two** child groups: the first with one `AXHeading` and one body `AXStaticText`; the second with one `AXHeading` and **two** body `AXStaticText`s, so grouped-message inheritance is exercised,
- a second `AXList` of sidebar channels **kept**, so structural exclusion is a real assertion,
- at least one chrome string from `DiscordParser.chrome` (e.g. `Add Reaction`) inside a message group.

Hand-scrub, move into `Fixtures/`, print and save `discord-messages-golden.json`, and add three README rows.

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
- Produces: `MessagesParser: StructuredParser`; `MessagesParser.config`; `MessagesParser.chatName(fromTitle:) -> String`; `MessagesParser.isUserBubble(_ bubble: AXNode, window: AXNode) -> Bool` (Task 13 consumes this exact spelling); `MessagesParser.bubbles(in:) -> [AXNode]`.
- `key(fromTitle:)`, `contentCap` and `parse(window:app:)` are untouched: `parse` already delegates to `parseStructured` (`Sources/MaxMiCapture/MessagesParser.swift:23`).
- **`parseStructured(window:app:)` already exists at `:15` — its body is edited, not redeclared** (ruling F1). The `GenericV2Content.lines` call is deleted, not chained.
- **Deleted in this task** (ruling F20): `conversationLines(in:)` (`:50`) and `collect(_:into:)` (`:57`), both `private` and both orphaned.
- `chatName(fromTitle:)` returns the display name; `key(fromTitle:)` returns the slugged `imessage:` key. Both are needed and neither can be derived from the other, so the pair is not duplication.

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

    func testEmptyTranscriptIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                        children: [node("AXButton", frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertNil(try MessagesParser().parse(bare, context: context("Ada Lovelace")))
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

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/MessagesParser.swift:15` (already declared in the struct — ruling F1) and delete the orphaned `conversationLines(in:)` / `collect(_:into:)` pair (ruling F20):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

Then append to the same file:

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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
        let conversation = Conversation(channel: chat, isGroup: isGroup, messages: messages)
        // Same cap Phase A applied to the `.lines` page, now on the typed conversation.
        return CaptureAccumulator.bound(.conversation(conversation), to: Self.contentCap)
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
- Produces: `WhatsAppParser: StructuredParser`; `WhatsAppParser.config` (bundle IDs `ParserRegistry.whatsAppBundleIDs`, hosts `["web.whatsapp.com"]`, `preferOverNative: true`); `WhatsAppParser.bubbleCellIdentifier = "WAMessageBubbleTableViewCell"`; `WhatsAppParser.timeStringPattern`; `WhatsAppParser.splitBubbleTexts(_:) -> (body: String, timeString: String?)`; `NativeConversationExtraction.conversationName(window:app:) -> String?`.
- **`conversationName(window:app:)` is NEW, not promoted** (ruling F24). No member of that name exists today. What *is* promoted from `private` to internal is the pair it wraps: `conversationTitle(in:app:mainBoundary:requiresHeaderSemantics:)` (`Sources/MaxMiCapture/NativeConversationParser.swift:210`) and `mainPaneBoundary(_:)` (`:205`).
- **`split(_:byKnownParticipant:)` (`:179-182`) stays on the new path** (ruling F24): a group bubble arrives as one label, `"Alex: text"`, and without the known-participant split the anchored parser would lose the sender attribution Phase A already had.
- **The Phase A walk stays as the fallback.** `NativeConversationExtraction.extract(...)` owns both `ParserRefusal` cases (`:113` "no-conversation-content", `:118` "unconfirmed-conversation-identity") and is what `NativeConversationParserTests`' six WhatsApp tests drive over trees that have **no** `WAMessageBubbleTableViewCell` (the `whatsapp-conversation.json` fixture has none). So `parse(_:context:)` tries the bubble-cell anchor first and delegates to `extract` when the anchor is absent — one content path, both behaviours, no lost coverage.
- **`parseStructured(window:app:)` already exists at `:7` — its body is edited, not redeclared** (ruling F1).
- The anchored path throws `ParserRefusal(reason: "unconfirmed-conversation-identity")` when no chat header can be confirmed, exactly as the Phase A walk does: a WhatsApp window with no open chat must store NOTHING, not the sidebar list of every unopened chat (ruling F13).
- `TeamsParser` is untouched in this task — it keeps Phase A's `.conversation` output; spec §7c lists no separate Teams anchor (Teams **web** is Task 26).

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

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try WhatsAppParser().parse(window(), context: context("WhatsApp")),
                       try WhatsAppParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
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

    func testNoBubbleCellsDelegatesToThePhaseAWalkWhichRefusesThisShape() {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                        children: [node("AXStaticText", value: "Use WhatsApp on your phone",
                                        frame: CGRect(x: 400, y: 300, width: 200, height: 16))])
        // No bubble anchor: the Phase A walk takes over, and for a banner with no chat header it
        // REFUSES — a generic capture here would store the sidebar list of every unopened chat.
        // This is the branch that keeps `NativeConversationParserTests`' six WhatsApp tests green.
        XCTAssertThrowsError(try WhatsAppParser().parse(bare, context: context("WhatsApp"))) { error in
            XCTAssertTrue(error is ParserRefusal, "expected a refusal, got \(error)")
        }
    }

    func testBubblesWithNoConfirmedChatHeaderAreRefusedRatherThanStored() {
        let headerless = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              children: [
            node("AXGroup", label: "Chats", frame: CGRect(x: 0, y: 0, width: 300, height: 700),
                 children: [node("AXStaticText", value: "Archived",
                                 frame: CGRect(x: 10, y: 20, width: 100, height: 16))]),
            bubble("are we still on for 4", time: "16:02", x: 340, y: 100),
        ])
        // Bubbles but no confirmed header: there is no thread to attribute them to, so refuse
        // rather than key them under the window title "WhatsApp" (ruling F13).
        XCTAssertThrowsError(try WhatsAppParser().parse(headerless,
                                                        context: context("WhatsApp"))) { error in
            XCTAssertEqual(error as? ParserRefusal,
                           ParserRefusal(reason: "unconfirmed-conversation-identity"))
        }
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

In `Sources/MaxMiCapture/NativeConversationParser.swift`, promote the existing title derivation so the structured parser reuses the tested logic instead of re-deriving it. Change `private static func conversationTitle` (`:210`) to `static func conversationTitle`, `private static func mainPaneBoundary` (`:205`) to `static func mainPaneBoundary` and `private static func slug` (`:410`) to `static func slug`, then add this **new** wrapper (nothing of this name exists today — ruling F24):

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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let cells = AXQuery.findAll("//*[identifier=\"\(Self.bubbleCellIdentifier)\"]", in: snapshot)
        guard !cells.isEmpty else {
            // No bubble-cell anchor: an older build, a tree captured before AXManualAccessibility
            // finished waking, or a non-chat surface. The Phase A walk still applies AND it owns
            // both refusals, so this is a delegation, not a second content path.
            return try NativeConversationExtraction.extract(
                window: snapshot,
                app: context.app,
                sourceApp: "WhatsApp",
                keyPrefix: "whatsapp",
                requiresConversationIdentity: true,
                allowsFallback: false,
                usesWhatsAppSenderLabels: true
            ).content
        }
        // Without a confirmed chat header there is no thread to attribute these bubbles to, and a
        // generic capture would store the sidebar list of every unopened chat. Refuse (F13).
        guard let channel = NativeConversationExtraction.conversationName(
            window: snapshot, app: context.app
        ) else {
            throw ParserRefusal(reason: "unconfirmed-conversation-identity")
        }
        // Participants this walk can vouch for, same set the Phase A walk builds: the user plus
        // the contact in a 1:1 chat. `split` only fires for a prefix naming one of them.
        let known: Set<String> = ["you", channel.lowercased()]
        let messages = AXQuery.sortedByVisualOrder(cells, relativeTo: snapshot.frame)
            .compactMap { cell -> Message? in
                let split = Self.splitBubbleTexts(AXQuery.collectStaticTexts(in: cell))
                guard !split.body.isEmpty else { return nil }
                let isUser = MessagesParser.isUserBubble(cell, window: snapshot)
                let labelSender = (cell.label?.trimmingCharacters(in: .whitespacesAndNewlines))
                    .flatMap { $0.isEmpty ? nil : $0 }
                // A group bubble arrives as ONE label ("Alex: text") with no sender node, so the
                // Phase A known-participant split is what recovers the sender (ruling F24).
                let resolved = NativeConversationExtraction.split(
                    (sender: isUser ? "You" : labelSender, text: split.body),
                    byKnownParticipant: known
                )
                let sender = resolved.sender ?? channel
                return Message(
                    id: Message.makeID(sender: sender, timeString: split.timeString,
                                       text: resolved.text),
                    sender: sender, text: resolved.text, timestamp: nil,
                    timeString: split.timeString, isUser: isUser, isDraft: false
                )
            }
        guard !messages.isEmpty else {
            throw ParserRefusal(reason: "no-conversation-content")
        }
        let isGroup = Set(messages.filter { !$0.isUser }.map(\.sender)).count > 1
        let conversation = Conversation(channel: channel, isGroup: isGroup, messages: messages)
        // The same hard cap the Phase A walk applies (`NativeConversationExtraction.contentCap`).
        return CaptureAccumulator.boundHard(.conversation(conversation),
                                            to: NativeConversationExtraction.contentCap)
    }
}
```

Then **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/NativeConversationParser.swift:7` — it is already declared on `WhatsAppParser`, so declaring it in the extension above would be an invalid redeclaration (ruling F1):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

`WhatsAppParser.parse(window:app:)` currently calls `NativeConversationExtraction.capture(...)`, which walks the tree a second time. Rewrite it to build the capture from `parseStructured`'s value so the tree is walked once (spec §4f rule 1 keeps the key and the policies here). The key is byte-identical to Phase A's, because Phase A keys on `slug(identity)` where `identity` is exactly the `channel` the conversation carries:

```swift
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app),
              case .conversation(let conversation) = structured else { return nil }
        return ParsedCapture(
            sourceApp: "WhatsApp",
            sourceKey: "whatsapp:\(NativeConversationExtraction.slug(conversation.channel))",
            sourceTitle: conversation.channel,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .conversation,
            parserVersion: 3,
            accumulationPolicy: .appendItems,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: structured
        )
    }
```

That needs one more access change in the same file: `private static func slug` (`:410`) becomes `static func slug`.

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `WhatsAppParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WhatsAppStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter NativeConversationParserTests`
Expected: PASS, unchanged. All six WhatsApp tests drive trees with no `WAMessageBubbleTableViewCell`, so they take the delegation branch and keep asserting the Phase A walk, its sidebar exclusion and both refusal reasons. `TeamsParser`'s tests are untouched.

Run: `swift test --filter StructuredConversationParserTests`
Expected: PASS, unchanged — `whatsapp-conversation.json` has no bubble cells either.

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
Expected: PASS, 12 tests.

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
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.collectStaticTexts(in:)` (Tasks 3-4); `Message`, `Conversation`, `CapturedContent` (Phase A); `MailParser.parseStructured(window:app:)` (`Sources/MaxMiCapture/MailParser.swift:33`, added by Phase A **Task 12**, the parser-migration task — Phase A Task 8 was the store/migration work).
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

In `MailParser.parseStructured(window:app:)` (`Sources/MaxMiCapture/MailParser.swift:33`), insert this as the **first** statement of the method body. This is the one task that edits an existing `parseStructured` without replacing it, because Mail's AppleScript path is not superseded (spec §12 Q6):

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
- Produces: `NotesParser: StructuredParser`; `NotesParser.config`; `NotesParser.bodyIdentifier = "Note Body Text View"`; `NotesParser.sharedSuffix = "— Shared"`; `NotesParser.noteTitle(fromBody lines: [String], windowTitle: String?) -> String`.
- `parse(window:app:)` (and its `notes:<slug>` key) is untouched: it already delegates to `parseStructured` (`Sources/MaxMiCapture/NotesParser.swift:19`).
- **`parseStructured(window:app:)` already exists at `:12` — its body is edited, not redeclared** (ruling F1). Its `GenericV2Content.page` call is **deleted, not chained**.

**The 32_000 note-app budget is kept** (ruling F10, spec §12 final-review amendment): `NotesParser.offscreen` already reads `.accessibilityScroll(maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)`, the `config` reuses that exact constant rather than restating a policy, and the typed document is bounded with `CaptureAccumulator.bound(_:to: StructuredEntityExtraction.pageBudget)` — Phase A's cap must not disappear just because the content path changed.


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

    func testWithoutTheBodyAnchorTheNoteIsNotHandled() throws {
        XCTAssertNil(try NotesParser().parse(window(body: nil), context: context("Grocery list")),
                     "nil routes to GenericPageExtractor")
    }

    func testAnEmptyBodyIsNotHandled() throws {
        XCTAssertNil(try NotesParser().parse(window(body: "   \n  "), context: context("x")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(
            try NotesParser().parse(window(body: "Grocery list\nmilk"), context: context("Grocery list")),
            try NotesParser().parse(window(body: "Grocery list\nmilk", origin: CGPoint(x: 1440, y: 220)),
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

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/NotesParser.swift:12` (already declared in the struct — ruling F1; the `GenericV2Content.page` call is deleted):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

Then append to the same file:

```swift
extension NotesParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Notes",
        bundleIDs: [ParserRegistry.notesBundleID],
        // The existing constant, not a new policy: 3 scroll steps with a 32_000 ceiling (F10).
        offscreenPolicy: NotesParser.offscreen
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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
        // The 32_000 page budget Phase A's final review installed on the note apps (F10).
        return CaptureAccumulator.bound(
            .document(Document(title: title, blocks: blocks, author: author, url: nil)),
            to: StructuredEntityExtraction.pageBudget)
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
- Produces: `NotionParser: StructuredParser`; `NotionParser.config` (bundle ID `ParserRegistry.notionBundleID`, hosts `["www.notion.so", "notion.so", ".notion.site"]`, `attributeSet: ["AXDOMClassList"]`, `preferOverNative: true`); `NotionParser.frameClasses = ["notion-frame", "notion-peek-renderer"]`; `NotionParser.skippedClasses = ["layout-margin-right", "notion-page-properties"]`; `NotionParser.topbarClass = "notion-topbar"`; `NotionParser.pageRoot(in:) -> AXNode?`; `NotionParser.pageTitle(in:windowTitle:) -> String`; `NotionParser.blocks(under root: AXNode) -> [Block]`.
- `parse(window:app:)` (and its `notion:<slug>` key) is untouched: it already delegates to `parseStructured` (`Sources/MaxMiCapture/NotionParser.swift:19`).
- **`parseStructured(window:app:)` already exists at `:12` — its body is edited, not redeclared** (ruling F1). Its `GenericV2Content.page` call is **deleted, not chained**.

**The 32_000 note-app budget is kept** (ruling F10, spec §12 final-review amendment): `NotionParser.offscreen` already reads `.accessibilityScroll(maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)`, the `config` reuses that exact constant rather than restating a policy, and the typed document is bounded with `CaptureAccumulator.bound(_:to: StructuredEntityExtraction.pageBudget)` — Phase A's cap must not disappear just because the content path changed.


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

    func testNoNotionFrameIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [text("loading", y: 0, x: 0)])
        XCTAssertNil(try NotionParser().parse(bare, context: context("Notion")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try NotionParser().parse(window(), context: context("Roadmap — Notion")),
                       try NotionParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
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

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/NotionParser.swift:12` (already declared in the struct — ruling F1; the `GenericV2Content.page` call is deleted):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

Then append to the same file:

```swift
extension NotionParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Notion",
        bundleIDs: [ParserRegistry.notionBundleID],
        hosts: ["www.notion.so", "notion.so", ".notion.site"],
        // Notion's Electron shell does not always expose an AXWebArea above the page.
        attributeSet: ["AXDOMClassList"],
        // The existing constant, not a new policy: 3 scroll steps with a 32_000 ceiling (F10).
        offscreenPolicy: NotionParser.offscreen,
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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let root = Self.pageRoot(in: snapshot) else { return nil }
        let title = Self.pageTitle(in: snapshot, windowTitle: context.windowTitle)
        let blocks = Self.blocks(under: root).filter { $0.text != title }
        guard !blocks.isEmpty else { return nil }
        // The 32_000 page budget Phase A's final review installed on the note apps (F10).
        return CaptureAccumulator.bound(
            .document(Document(title: title, blocks: blocks, author: .user, url: context.url)),
            to: StructuredEntityExtraction.pageBudget)
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
- Produces: `ObsidianParser: StructuredParser`; `ObsidianParser.config` (bundle ID `ParserRegistry.obsidianBundleID`, `attributeSet: ["AXDOMClassList"]`); `ObsidianParser.editorClass = "cm-editor"`; `ObsidianParser.previewClass = "markdown-preview-view"`; `ObsidianParser.noteName(fromTitle:) -> String` (the display half of the same title split `key(fromTitle:)` performs for the key — the key is slugged and vault-scoped, so neither can be derived from the other); `ObsidianParser.paneRoot(in:) -> AXNode?`.
- `key(fromTitle:)` and `parse(window:app:)` are untouched: `parse` already delegates to `parseStructured` (`Sources/MaxMiCapture/ObsidianParser.swift:19`).
- **`parseStructured(window:app:)` already exists at `:12` — its body is edited, not redeclared** (ruling F1). Its `GenericV2Content.page` call is **deleted, not chained**.

**The 32_000 note-app budget is kept** (ruling F10, spec §12 final-review amendment): `ObsidianParser.offscreen` already reads `.accessibilityScroll(maxSteps: 3, maxCharacters: StructuredEntityExtraction.pageBudget)`, the `config` reuses that exact constant rather than restating a policy, and the typed document is bounded with `CaptureAccumulator.bound(_:to: StructuredEntityExtraction.pageBudget)` — Phase A's cap must not disappear just because the content path changed.


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

    func testNeitherPaneIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        children: [node("AXStaticText", value: "loading vault",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 16))])
        XCTAssertNil(try ObsidianParser().parse(bare, context: context("Obsidian")))
    }

    func testAnEmptyPaneIsNotHandled() throws {
        let empty = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                         children: [node("AXGroup", domClassList: ["cm-editor"],
                                         frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertNil(try ObsidianParser().parse(empty, context: context("Note - V - Obsidian v1")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let title = "Index rebuild - Research - Obsidian v1.5.3"
        XCTAssertEqual(
            try ObsidianParser().parse(window(paneClass: "cm-editor"), context: context(title)),
            try ObsidianParser().parse(window(paneClass: "cm-editor", origin: CGPoint(x: 1440, y: 220)),
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

First **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/ObsidianParser.swift:12` (already declared in the struct — ruling F1; the `GenericV2Content.page` call is deleted):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

Then append to the same file:

```swift
extension ObsidianParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Obsidian",
        bundleIDs: [ParserRegistry.obsidianBundleID],
        // Obsidian is Electron and does not always expose an AXWebArea above the vault view.
        attributeSet: ["AXDOMClassList"],
        // The existing constant, not a new policy: 3 scroll steps with a 32_000 ceiling (F10).
        offscreenPolicy: ObsidianParser.offscreen
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

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
        // The 32_000 page budget Phase A's final review installed on the note apps (F10).
        return CaptureAccumulator.bound(
            .document(Document(title: Self.noteName(fromTitle: context.windowTitle),
                               blocks: blocks, author: .user, url: nil)),
            to: StructuredEntityExtraction.pageBudget)
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
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)` and its `Options` (Phase A — Finder's regions and joined rows are exactly what the §4e rules already produce, so this parser adds a path, not a second walk); `AXQuery.findAll(_:in:)` (Task 3); `StructuredParser`, `ParserConfig`, `ParseContext`, `ParserRegistry.finderBundleID` (Task 5); `GenericPage`, `RegionKind`, `BlockType`, `CapturedContent` (Phase A).
- Produces: `FinderParser: SourceParser, StructuredParser`; `FinderParser.config`; `FinderParser.folderPath(in: AXNode, windowTitle: String?) -> String?`; `FinderParser.sidebarRows(in: AXNode) -> [AXNode]`; `FinderParser.key(fromPath:windowTitle:) -> String` producing `"finder:<slug>"`.
- **Division of labour, ruling F16 (recorded as a spec §12 amendment):** spec §7c writes Finder's rows as `//AXOutline//AXRow` and `//AXTable//AXRow` → `.tableRow(cells:selected:)`. That is *exactly* what `GenericPageExtractor.block(for:)` already emits for `rowRoles` with `selected` from `AXSelected` (`Sources/MaxMiCapture/GenericPageExtractor.swift:181-188`, `rowCells` at `:210`), so the rows are **delegated** and a second row formatter is not written (that is also why Task 4 has no `formatTable`). `AXQuery` is used for the two anchors the extractor does not provide: the folder **path** (`AXDocument` may sit on the window or on the outline/scroll area beneath it) and the **source list**, which the sidebar-classification test asserts against.

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

    func testTheSourceListIsClassifiedAsSidebarEvenAtANonzeroWindowOrigin() throws {
        // Replaces a bare flush-vs-offset region comparison, which `GenericPageRegionTests`
        // already covers for `finder-offset-window.json` and which no Finder-parser change could
        // ever break (ruling F25). This asserts the thing that CAN break: that the rows the
        // structural anchor identifies as source-list rows are the rows the geometric §4e rules
        // put in `.sidebar`, and that none of them leak into the listing — at an origin where a
        // missing window-relative conversion would misclassify them.
        let offsetWindow = window(status: "Uploading 34 items", origin: CGPoint(x: 1_440, y: 220))
        let anchored = Set(FinderParser.sidebarRows(in: offsetWindow)
            .flatMap { AXQuery.collectStaticTexts(in: $0) })
        XCTAssertEqual(anchored, ["Downloads"], "the fixture's source list holds exactly one row")
        let page = try page(FinderParser().parse(offsetWindow, context: context("sample")))
        XCTAssertEqual(Set(blocks(page, .sidebar).map(\.text)), anchored)
        for text in anchored {
            XCTAssertFalse(blocks(page, .main).contains { $0.text.contains(text) },
                           "\(text) is source-list chrome, not a folder listing row")
        }
    }

    func testAnEmptyWindowIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertNil(try FinderParser().parse(bare, context: context("sample")))
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

    /// `AXDocument` is a file URL and Finder puts it on the window in list view but on the
    /// browser/outline beneath it in column view, so the anchor is a path query rather than one
    /// field read. The window title is only a folder name, so it is the last resort.
    static func folderPath(in snapshot: AXNode, windowTitle: String?) -> String? {
        let raw = [snapshot.url]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
            ?? AXQuery.findAll("//*", in: snapshot)
                .compactMap(\.url)
                .first(where: { !$0.isEmpty })
        if let raw {
            if let url = URL(string: raw), url.isFileURL { return url.path }
            return raw
        }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// The source list's rows. Used by the sidebar-classification assertion: the §4e sidebar
    /// rules are geometric and window-relative, and this is the structural statement of the same
    /// thing — every row under the split group's `AXOutline` is chrome, never a folder listing.
    static func sidebarRows(in snapshot: AXNode) -> [AXNode] {
        AXQuery.findAll("//AXSplitGroup//AXOutline//AXRow", in: snapshot)
    }

    static func key(fromPath path: String?, windowTitle: String?) -> String {
        if let path, !path.isEmpty { return "finder:\(path.lowercased())" }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "finder:unknown" : "finder:\(docSlug(title))"
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
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
        guard let structured = try parse(window, context: ParseContext(app: app)) else { return nil }
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
        try parse(window, context: ParseContext(app: app))
    }
}
```

`FinderParser` is a new type, so all three requirements are declared in the struct body — no redeclaration hazard (ruling F1).

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
Expected: PASS, 12 tests.

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
- Consumes: `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `CalendarEvent` (Phase A, `Sources/MaxMiCore/CapturedContent.swift:168-189`), `CapturedContent`; `StructuredEntityExtraction.calendarContent(window:app:sourceApp:) -> Extracted?` (`Sources/MaxMiCapture/StructuredNativeParsers.swift:143`, already internal).
- Produces: `CalendarStructuredExtraction.events(in: AXNode, app: AppInfo, sourceApp: String) -> [CalendarEvent]`; `CalendarParser: StructuredParser` and `FantasticalParser: StructuredParser`, each with `config` and `parse(_:context:)`.
- **This task adds no second calendar extractor.** Spec §7c asks for "the existing `StructuredEntityExtraction.preferredDetailRoot` anchor, **retyped**" — Phase A already retyped it: `calendarContent` returns `.calendar([CalendarEvent])` built from that anchor, with `organizer`, `location`, `hasConference` and `notes` (`:143-179`). Re-deriving those fields here would be two implementations of one shape with different hint tables, which is what ruling F15 rejected for `formatTable`. So `CalendarStructuredExtraction.events` is a **thin adapter** over `calendarContent`, and no `StructuredEntityExtraction` member needs promoting (ruling F22's "remove `private` from `struct Field`" was a no-op, and the six method promotions are unnecessary once nothing re-derives the fields).
- Because the plan constructs **no** `CalendarEvent`, the missing `notes:` argument ruling F7 flagged cannot recur: `calendarContent` (`:172-179`) already passes all eight arguments.
- **`parseStructured(window:app:)` already exists on both types** (`Sources/MaxMiCapture/StructuredNativeParsers.swift:9` for `CalendarParser`, `:19` for `FantasticalParser`) — **their bodies are edited, they are not redeclared** (ruling F1).
- The two `parse(window:app:)` methods and their `calendar:event:<hash>` keys are untouched — `StructuredNativeParserTests` and `StructuredEntityTypedTests` keep passing verbatim. The existing `calendar-event.json` fixture is reused; only its golden is new.
- One behaviour change to the shared extractor, in the one place it lives: `hasConference` also fires on a field whose **metadata** contains `"conference"` (an `AXLink` with `identifier: "event-conference"` and the label `Join video call`), which today it misses. `StructuredEntityTypedTests.swift:26` asserts `hasConference == false` for `calendar-event.json`, whose fields carry no `conference` metadata, so it stays green.

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
        XCTAssertNil(event.notes, "all four fields were claimed, so nothing is left for notes")
        XCTAssertNil(event.start, "M8 stores the date STRING; parsing it is not in scope")
        XCTAssertNil(event.end)
    }

    func testAConferenceLinkSetsHasConference() throws {
        let list = try events(CalendarParser().parse(window(conference: true),
                                                    context: context("com.apple.iCal", "Calendar")))
        XCTAssertTrue(list[0].hasConference,
                      "the field's identifier names it as the conference link")
        XCTAssertEqual(list[0].notes, "Join video call",
                       "an unclaimed detail field is the notes body, exactly as Phase A built it")
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

    func testNoDetailRootIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                        children: [node("AXGroup", identifier: "calendar-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 220, height: 800))])
        XCTAssertNil(try CalendarParser().parse(bare, context: context("com.apple.iCal", "Calendar")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try CalendarParser().parse(window(), context: context("com.apple.iCal", "Calendar")),
                       try CalendarParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
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
                       + "/ ada@example.com [conference]\nDetails: Join video call",
                       "renderEvent appends the notes body it was given")
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

In `Sources/MaxMiCapture/StructuredNativeParsers.swift`, widen the shared `hasConference` rule inside `calendarContent` (`:158-163`) by one clause, so a detail field that is *labelled* as the conference link counts even when its text is not a known meeting domain:

```swift
        let hasConference = fields.contains { field in
            let value = field.value.lowercased()
            return field.metadata.contains("conference")
                || value.contains("zoom.us") || value.contains("meet.google.com")
                || value.contains("teams.microsoft.com") || value.contains("join with")
        }
```

No `private` is removed anywhere in this task: the adapter below calls `calendarContent`, which is already internal, so the six promotions the draft plan asked for are unnecessary and `struct Field` (`:121`) is already internal (ruling F22).

Then append to the same file:

```swift
/// `.calendar` events for a window. Phase A already retyped this anchor — `calendarContent`
/// resolves the detail root, scores the fields and builds the `CalendarEvent` — so this is a thin
/// adapter that lets a `StructuredParser` reach it, NOT a second extractor (spec §7c, ruling F15's
/// no-duplicate-implementations rule).
enum CalendarStructuredExtraction {
    static func events(in window: AXNode, app: AppInfo, sourceApp: String) -> [CalendarEvent] {
        guard let extracted = StructuredEntityExtraction.calendarContent(
                window: window, app: app, sourceApp: sourceApp),
              case .calendar(let events) = extracted.content else { return [] }
        return events
    }
}

extension CalendarParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Calendar",
        bundleIDs: ParserRegistry.calendarBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let events = CalendarStructuredExtraction.events(in: snapshot, app: context.app,
                                                        sourceApp: Self.config.app)
        return events.isEmpty ? nil : .calendar(events)
    }
}

extension FantasticalParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Fantastical",
        bundleIDs: ParserRegistry.fantasticalBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let events = CalendarStructuredExtraction.events(in: snapshot, app: context.app,
                                                        sourceApp: Self.config.app)
        return events.isEmpty ? nil : .calendar(events)
    }
}
```

Then **edit the two existing `parseStructured` bodies** at `Sources/MaxMiCapture/StructuredNativeParsers.swift:9` and `:19` (both are already declared in their structs — ruling F1). The `StructuredEntityExtraction.calendarContent(...)` calls are deleted, not chained; `parse(window:app:)` keeps calling `StructuredEntityExtraction.calendar(...)` for the key and the policies, so the `calendar:event:<hash>` keys `StructuredNativeParserTests` asserts are unchanged:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append `CalendarParser(), FantasticalParser()` to `structured`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter StructuredNativeParserTests`
Expected: PASS, unchanged.

Run: `swift test --filter StructuredEntityTypedTests`
Expected: PASS, unchanged — `calendar-event.json` carries no `conference` metadata, so the widened `hasConference` clause does not flip its `XCTAssertFalse(events[0].hasConference)` at `:26`.

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
- Consumes: `AXQuery.findAll(_:in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Tasks 3-4); `StructuredParser`, `ParserConfig`, `ParseContext` (Task 5); `TaskItem`, `TaskStatus`, `CapturedContent` (Phase A); and these **five** `StructuredEntityExtraction` members, each promoted from `private` to internal **in this task** (Task 19 needs none — it delegates to `calendarContent`): `preferredDetailRoot(in:hints:)` (`Sources/MaxMiCapture/StructuredNativeParsers.swift:318`), `orderedFields(in:)` (`:342`), `firstValue(_:metadataHints:)` (`:377`), `looksLikeDateOrTime(_:)` (`:396`), `isChrome(_:)` (the enum's last member). `isPreferred(_:hints:)` stays private — only `preferredDetailRoot` calls it — and `struct Field` (`:121`) is already internal, so nothing changes there (ruling F22).
- Produces: `TaskStructuredExtraction.completedValues: Set<String>` (`["1", "true", "yes", "checked"]`, matching the existing string test in `StructuredEntityExtraction.task`); `TaskStructuredExtraction.status(ofRow: AXNode) -> TaskStatus`; `TaskStructuredExtraction.notes(from: [StructuredEntityExtraction.Field], excluding: [String?]) -> String?`; `TaskStructuredExtraction.item(fromRow: AXNode) -> TaskItem?`; `TaskStructuredExtraction.detailItem(in: AXNode, windowTitle: String?) -> TaskItem?`; `TaskStructuredExtraction.tasks(in: AXNode, windowTitle: String?) -> [TaskItem]`; `RemindersParser: StructuredParser` with `config`.
- **The notes body is derived once, in `notes(from:excluding:)`, and used by both the row path and the detail path** (ruling F23). Writing the filter twice is how the draft let a row's checkbox value (`"0"`) leak into `TaskItem.notes` while its sibling filtered it: `AXCheckBox` is in `StructuredEntityExtraction.readableRoles` (`:129-131`), so it *is* collected as a field and must be excluded explicitly.
- **`parseStructured(window:app:)` already exists on `RemindersParser`** (`Sources/MaxMiCapture/StructuredNativeParsers.swift:29`) — **its body is edited, not redeclared** (ruling F1).
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

    func testNothingUsableIsNotHandled() throws {
        let bare = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1100, height: 760),
                        children: [node("AXGroup", identifier: "reminders-sidebar",
                                        frame: CGRect(x: 0, y: 0, width: 240, height: 760))])
        XCTAssertNil(try RemindersParser().parse(bare, context: context("Reminders")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try RemindersParser().parse(window(), context: context("Reminders")),
                       try RemindersParser().parse(window(origin: CGPoint(x: 1440, y: 220)),
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

In `Sources/MaxMiCapture/StructuredNativeParsers.swift`, remove `private` from exactly these five members of `StructuredEntityExtraction`, which the extraction below reuses: `preferredDetailRoot(in:hints:)`, `orderedFields(in:)`, `firstValue(_:metadataHints:)`, `looksLikeDateOrTime(_:)`, `isChrome(_:)`. Leave `isPreferred(_:hints:)` and `struct Field` alone (ruling F22).

Then append to the same file:

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

    /// Everything the named fields did not claim, as the notes body. `AXCheckBox` is excluded
    /// because it is in `StructuredEntityExtraction.readableRoles` — without this, a row's
    /// checkbox value ("0") is rendered as a task note (ruling F23). One implementation, used by
    /// both the row path and the detail path.
    static func notes(from fields: [StructuredEntityExtraction.Field],
                      excluding claimed: [String?]) -> String? {
        let claimed = Set(claimed.compactMap { $0 })
        let remaining = fields
            .filter { $0.role != "AXCheckBox" }
            .filter { !claimed.contains($0.value) }
            .filter { !StructuredEntityExtraction.isChrome($0.value) }
            .map(\.value)
        return remaining.isEmpty ? nil : remaining.joined(separator: "\n")
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
        return TaskItem(title: title, status: status(ofRow: row), due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes(from: fields, excluding: [title, dueString, project]))
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
        return TaskItem(title: title, status: status, due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes(from: fields, excluding: [title, dueString, project]))
    }
}

extension RemindersParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Reminders",
        bundleIDs: ParserRegistry.remindersBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let items = TaskStructuredExtraction.tasks(in: snapshot, windowTitle: context.windowTitle)
        return items.isEmpty ? nil : .tasks(items)
    }
}
```

Then **edit the existing `parseStructured` body** at `Sources/MaxMiCapture/StructuredNativeParsers.swift:29` (already declared on `RemindersParser` — ruling F1; its `taskContent` call is deleted):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
```

`RemindersParser.parse(window:app:)` (`:26`) must also stop attaching the v1 content, or a Reminders window would be keyed by the v1 anchor while carrying the v1 single-item shape and the row-aware shape would never reach the store — the two-content-paths failure this plan forbids. Keep the key from the v1 anchor (`StructuredNativeParserTests` asserts `reminder:task:<hash>`) and take the content from `parseStructured`:

```swift
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let base = StructuredEntityExtraction.task(window: window, app: app,
                                                         sourceApp: "Reminders",
                                                         prefix: "reminder"),
              let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: base.sourceApp,
            sourceKey: base.sourceKey,
            sourceTitle: base.sourceTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .task,
            parserVersion: 3,
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: structured
        )
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
- **Re-asserts Task 5's registration list.** After Task 20 the single `structured` list in `ParserRegistry.init()` holds exactly these **thirteen** entries: `TerminalParser`, `EditorParser`, `SlackParser`, `DiscordParser`, `MessagesParser`, `WhatsAppParser`, `NotesParser`, `NotionParser`, `ObsidianParser`, `FinderParser`, `CalendarParser`, `FantasticalParser`, `RemindersParser`. Tasks 22-26 append four more (`GmailParser`, `LinkedInMessagingParser`, `OutlookWebParser`, `TeamsWebParser`), all host-only, for a final total of **seventeen**. `MailParser` is absent by design (§12 Q6) and `WebPageParser` is the browser default, not a registered parser.

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
        // Discord is geometry-free, so its offset fixture is pinned against the SAME golden
        // (Task 11, ruling F25) — the pair is (two fixtures, one golden).
        "DiscordParser": [("discord-messages", "discord-messages-golden"),
                          ("discord-offset-messages", "discord-messages-golden")],
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

    /// The exact registration list Task 5 declares and Tasks 7-20 fill in, restated here so a
    /// parser cannot be quietly dropped from `ParserRegistry.init()` (ruling F28). The four
    /// host-only parsers (Tasks 22-26) are NOT in this set — they are unreachable by bundle ID by
    /// design, and `hostCoverage` plus `testEveryHostRoutedParserIsReachableFromTheHostMap`
    /// (added in Task 22) cover them.
    static let registeredStructuredParserNames: Set<String> = [
        "TerminalParser", "EditorParser", "SlackParser", "DiscordParser", "MessagesParser",
        "WhatsAppParser", "NotesParser", "NotionParser", "ObsidianParser", "FinderParser",
        "CalendarParser", "FantasticalParser", "RemindersParser",
    ]

    func testTheRegistrationListIsExactlyTheThirteenBundleIDParsers() {
        let registry = ParserRegistry()
        var names = Set<String>()
        for bundleID in [
            ParserRegistry.slackBundleID, ParserRegistry.notionBundleID,
            ParserRegistry.obsidianBundleID, ParserRegistry.notesBundleID,
            ParserRegistry.discordBundleID, ParserRegistry.messagesBundleID,
            ParserRegistry.finderBundleID, ParserRegistry.cursorBundleID,
            ParserRegistry.vsCodeBundleID,
        ] + ParserRegistry.terminalBundleIDs + ParserRegistry.whatsAppBundleIDs
          + ParserRegistry.calendarBundleIDs + ParserRegistry.fantasticalBundleIDs
          + ParserRegistry.remindersBundleIDs {
            if let parser = registry.structuredParser(for: bundleID) {
                names.insert(String(describing: type(of: parser)))
            }
        }
        XCTAssertEqual(names, Self.registeredStructuredParserNames)
        XCTAssertNil(registry.structuredParser(for: ParserRegistry.mailBundleID),
                     "Mail stays AppleScript-sourced (§12 Q6) and is deliberately unregistered")
    }

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
        XCTAssertTrue(registered.contains("FantasticalParser"),
                      "Fantastical shares Calendar's fixtures but must still be registered")
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

Run: `swift test 2>&1 | tail -40`

**The gate is zero NEW failures, not zero failures** (ruling F19). The baseline this branch starts from is **689 tests with exactly 3 known-red**, frozen by the Phase A ledger:

- `ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`
- `CaptureDisplaySummarizerTests.testConversationSummaryUsesTrailingMessages`
- `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`

Expected: those three, and nothing else, still fail. Any other failing test — including any of Phase D's own — blocks the phase. The total count rises by this phase's new tests; the total is **not** the gate and no number in this plan is binding (spec §2's "506 tests" is a pre-Phase-A figure).

Run: `swift test --filter TerminalSegmentationTests` and `swift test --filter StructuredConversationParserTests`
Expected: PASS — the two Phase A suites this plan edits rather than replaces.

Run: `swift build 2>&1 | grep -i warning`
Expected: no output (spec §11 item 10: "zero warnings"). An unused `private` member left behind by a replaced content path is the likely offender; every parser task names the members it deletes for exactly this reason (ruling F20).

Run: `swift test -c release --filter AXQueryPathTests` and `swift test -c release --filter AXQueryEvaluationTests`
Expected: both compile and PASS — `AXQuery.trapsOnInvalidPath` exists in release too (ruling F14), and the release configuration is where the invalid-path policy the tests assert actually applies.

Run: `grep -rn "import Testing" Tests/ | wc -l`
Expected: `0` (§2).

- [ ] **Step 4: Rebuild the app**

Run, exactly as written — **no `tccutil reset`**, because a signed build keeps its Accessibility grant across rebuilds and resetting it would silently break capture:

```bash
./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" && sleep 2 && open MaxMi.app
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

### Task 22: Gmail web (`mail.google.com`) → `.conversation` / `.generic` rows / compose draft

**Files:**
- Create: `Sources/MaxMiCapture/WebHostParsing.swift`
- Create: `Sources/MaxMiCapture/GmailParser.swift`
- Modify: `Sources/MaxMiCapture/BrowserCapturePipeline.swift` (replace Task 9's routing block with the refusal-aware version below)
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (append `GmailParser()` to Task 5's `structured` list)
- Modify: `Sources/MaxMi/AppWiring.swift` (one new `catch let refusal as ParserRefusal` clause on the browser path)
- Modify: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (Task 21: add `hostCoverage` + the host-registration test)
- Create: `Tests/MaxMiCaptureTests/Fixtures/gmail-thread.json`, `gmail-thread-golden.json`, `gmail-offset-inbox.json`, `gmail-offset-inbox-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/GmailParserTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)` (Task 3); `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Task 4); `ParserConfig`, `ParseContext`, `StructuredParser`, `ParserRegistry.host(fromURL:)`, `.structuredParser(forHost:)`, `.forcedAttributes(for:)` (Task 5); `fixture(_:)`, `goldenCapturedContent(_:)`, `assertGolden(_:matches:)` (Task 6); `WebPageParser.parse(window:tab:)` (Task 9); `NativeConversationExtraction.senderLabel(_:) -> String?` (`Sources/MaxMiCapture/NativeConversationParser.swift`, already internal); `ParserRefusal(reason:)` (`ParserRegistry.swift:74`); `WebAppCaptureParser.parse(tab:window:contentBudget:) throws -> WebAppParseResult`, `.classify(url:)`, `.contentCap`; `URLKeyNormalizer.normalize(_:)`; `CaptureAccumulator.bound(_:to:)` (`Sources/MaxMiCore/StructuredAccumulator.swift`); `Message`, `Message.makeID(sender:timeString:text:)`, `Conversation`, `GenericPage`, `Region`, `Block`, `BlockType.tableRow(cells:selected:)`, `CapturedContent` (Phase A).
- Produces:
  - **No refusal protocol.** A host parser refuses by throwing `ParserRefusal` from `StructuredParser.parse`, which is `throws` (Task 5, ruling F13). `refusesEmptyCompose(_:context:)` is a plain method on each parser — the predicate the throw is guarded by, and the thing the tests assert directly.
  - `WebHostParsing.text(of: AXNode) -> String?`, `.editorText(in: AXNode) -> String`, `.draft(in: AXNode?) -> Message?`, `.message(sender: String?, timeString: String?, texts: [String], isUser: Bool = false) -> Message?`, `.path(of: String?) -> String` — all `internal static`, shared by Tasks 22-26.
  - `GmailParser: StructuredParser` with `config`, `parse(_:context:)`, `refusesEmptyCompose(_:context:)`, and the statics `messageClass`, `senderNameClass`, `senderAddressClass`, `timeClass`, `bodyClass`, `listRowClass`, `composeBodyDescription`, `chromeHeadings`, `composer(in:) -> AXNode?`, `subject(in:windowTitle:) -> String`, `threadMessages(in:) -> [Message]`, `listRows(in:) -> [Block]`.
  - `BrowserCapturePipeline.parse(window:windowTitle:browser:contentBudget:registry:)` — `registry` is added **after** `contentBudget`, so `WebAppStructuredTests.swift:117` (`contentBudget: 60`) keeps compiling.
  - `PhaseDCoverageTests.hostCoverage: [String: [String]]` — parser type name → the hosts it claims.

**Two facts about this task that the executor must not "fix":**

1. `contentKind`, `sourceKey` and `accumulationPolicy` still come from `WebAppCaptureParser.parse` (§4f rule 1, §12 Q3). Gmail is already `.gmail` → `.email` there, and its key is already `URLKeyNormalizer.normalize(tab.url)`. **Do not touch either.** A host parser owns content only.
2. `ParserConfig.attributeSet` is declared as §14b asks (`["AXDOMClassList", "AXDOMIdentifier"]`) but is **inert for a hosts-only parser**: `ParserRegistry.forcedAttributes(for:)` (Task 5) is keyed by *bundle ID*, and the bundle here is the browser's. What actually supplies the DOM attributes is Task 1's `AXWebArea`-ancestor gate, which a real browser tab always satisfies. The test below pins that (`forcedAttributes(for: "com.google.Chrome") == []`) so nobody reads the declaration as live wiring.

- [ ] **Step 1: Record the live fixtures FIRST and verify the anchors**

Nothing in this task may be implemented against §14b's candidate class names before a dump confirms they reach AX. Open Gmail in Chrome as the front tab with a **thread expanded** (window flush at the screen origin), then:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/gmail-thread.json
```

Switch Gmail to the **inbox list**, drag the window to a second display or well away from the top-left corner, then:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/gmail-offset-inbox.json
```

Verify which anchors actually surfaced, in both dumps:

```bash
for f in /tmp/gmail-thread.json /tmp/gmail-offset-inbox.json; do
  echo "== $f"
  python3 - "$f" <<'PY'
import collections, json, sys
counts = collections.Counter()
def walk(node):
    for name in node.get("domClassList") or []:
        counts["class:" + name] += 1
    if node.get("domIdentifier"):
        counts["domId:" + node["domIdentifier"][:40]] += 1
    if node.get("label"):
        counts["description:" + node["label"][:40]] += 1
    for child in node.get("children", []):
        walk(child)
walk(json.load(open(sys.argv[1])))
for name, n in counts.most_common(80):
    print(n, name)
PY
done
```

Confirm, for each of §14b's candidates — `adn`, `gD`, `go`, `g3`, `a3s`, `zA`, and the compose editor's `"Message Body"` description — whether it appears. Record the answer in `GmailParser`'s header comment in Step 4: `verified (<count> nodes)` or `NOT EXPOSED — used <what you used instead>`. **Keep every line, including the failures**, so the next reader does not re-try a dead anchor. If a candidate is missing, find its replacement in the dump above (a `class:` / `domId:` / `description:` line at the right count) and use that; do not invent one.

- [ ] **Step 2: Write the failing test**

Create `Tests/MaxMiCaptureTests/GmailParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GmailParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              selected: Bool = false, domClassList: [String]? = nil, url: String? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: nil,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    func heading(_ value: String, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXHeading", value: value, frame: CGRect(x: x, y: y, width: 400, height: 24))
    }

    func composeEditor(_ draft: String?, y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXTextArea", value: draft, label: "Message Body",
             frame: CGRect(x: x, y: y, width: 500, height: 120))
    }

    /// One EXPANDED message (has an `a3s` body), one COLLAPSED message (no body node at all),
    /// plus the thread subject as a heading and Gmail's own chrome heading above it.
    func threadWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children = [
            heading("Main menu", y: y + 10, x: x + 20),
            heading("Quarterly index rebuild", y: y + 60, x: x + 300),
            node("AXGroup", domClassList: ["adn", "ads"],
                 frame: CGRect(x: x + 300, y: y + 100, width: 900, height: 120), children: [
                text("Ada Lovelace", ["gD"], y: y + 100, x: x + 300),
                text("ada@example.com", ["go"], y: y + 100, x: x + 460),
                text("10:14 AM", ["g3"], y: y + 100, x: x + 1100),
                node("AXGroup", domClassList: ["a3s"],
                     frame: CGRect(x: x + 300, y: y + 130, width: 900, height: 80), children: [
                    text("Rebuild finished overnight.", nil, y: y + 130, x: x + 300),
                    text("No downtime.", nil, y: y + 150, x: x + 300),
                ]),
            ]),
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: x + 300, y: y + 240, width: 900, height: 24), children: [
                text("Grace Hopper", ["gD"], y: y + 240, x: x + 300),
                text("10:41 AM", ["g3"], y: y + 240, x: x + 1100),
            ]),
        ]
        if let draft { children.append(composeEditor(draft, y: y + 500, x: x + 300)) }
        return node("AXWindow", title: "Quarterly index rebuild - me@example.com - Gmail",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    /// The inbox list: three `zA` rows, one of them selected.
    func inboxWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        func row(_ sender: String, _ subject: String, _ snippet: String, _ time: String,
                 y rowY: CGFloat, selected: Bool = false) -> AXNode {
            node("AXRow", selected: selected, domClassList: ["zA", "yO"],
                 frame: CGRect(x: x + 300, y: rowY, width: 1100, height: 28), children: [
                text(sender, nil, y: rowY, x: x + 320),
                text(subject, nil, y: rowY, x: x + 500),
                text(snippet, nil, y: rowY, x: x + 700),
                text(time, nil, y: rowY, x: x + 1300),
            ])
        }
        return node("AXWindow", title: "Inbox (3) - me@example.com - Gmail",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: [
            heading("Main menu", y: y + 10, x: x + 20),
            row("Ada Lovelace", "Quarterly index rebuild", "Rebuild finished overnight.",
                "10:14 AM", y: y + 100, selected: true),
            row("Grace Hopper", "Deploy window", "Green across the board.", "09:02 AM", y: y + 140),
            row("Alan Turing", "Machine time", "Booked the afternoon slot.", "Jul 3", y: y + 180),
        ])
    }

    /// A standalone compose window: a composer and nothing else.
    func composeOnlyWindow(draft: String?) -> AXNode {
        node("AXWindow", title: "New Message - me@example.com - Gmail",
             frame: CGRect(x: 0, y: 0, width: 700, height: 500),
             children: [composeEditor(draft, y: 80)])
    }

    /// A Gmail settings page: no thread, no rows, no composer.
    func settingsWindow() -> AXNode {
        node("AXWindow", title: "Settings - me@example.com - Gmail",
             frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
             children: [heading("Main menu", y: 10, x: 20),
                        text("Undo send", nil, y: 100)])
    }

    /// A browser window: chrome plus an `AXWebArea` wrapping the Gmail page.
    func browserWindow(_ page: AXNode, url: String) -> AXNode {
        let frame = page.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return node("AXWindow", title: page.title,
                    frame: frame, children: [
            node("AXToolbar", frame: CGRect(x: frame.minX, y: frame.minY,
                                            width: frame.width, height: 42), children: [
                node("AXTextField", value: url, title: "Address and search bar",
                     frame: CGRect(x: frame.minX + 250, y: frame.minY + 6, width: 700, height: 30)),
            ]),
            node("AXWebArea", url: url, frame: frame, children: page.children),
        ])
    }

    static let threadURL = "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWxyz"

    func context(_ title: String?, url: String = GmailParserTests.threadURL) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func page(_ content: CapturedContent?) throws -> GenericPage {
        guard case .generic(let p) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .generic, got \(String(describing: content))")
        }
        return p
    }

    // MARK: - Registration

    func testConfigClaimsTheGmailHostOnly() {
        XCTAssertEqual(GmailParser.config.hosts, ["mail.google.com"])
        XCTAssertEqual(GmailParser.config.bundleIDs, [])
        XCTAssertFalse(GmailParser.config.preferOverNative,
                       "no native app shares mail.google.com")
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "mail.google.com") is GmailParser)
        XCTAssertNil(registry.structuredParser(forHost: "mail.google.com.evil.example"))
    }

    func testTheDeclaredAttributeSetIsInertForAHostsOnlyParser() {
        // Documented, not aspirational: forcedAttributes is keyed by BUNDLE id, and the bundle
        // here is the browser's. The AXWebArea gate (Task 1) is what supplies the DOM attributes.
        XCTAssertEqual(GmailParser.config.attributeSet, ["AXDOMClassList", "AXDOMIdentifier"])
        XCTAssertEqual(ParserRegistry().forcedAttributes(for: "com.google.Chrome"), [])
    }

    // MARK: - Thread

    func testExpandedThreadMessagesCarrySenderTimeAndBody() throws {
        let c = try conversation(GmailParser().parse(
            threadWindow(), context: context("Quarterly index rebuild - me@example.com - Gmail")))
        XCTAssertEqual(c.channel, "Quarterly index rebuild")
        XCTAssertFalse(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(c.messages.map(\.text), ["Rebuild finished overnight. No downtime."])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM"])
        XCTAssertEqual(c.messages[0].id, Message.makeID(sender: "Ada Lovelace",
                                                        timeString: "10:14 AM",
                                                        text: "Rebuild finished overnight. No downtime."))
    }

    func testACollapsedMessageIsSkippedRatherThanEmittedEmpty() throws {
        let c = try conversation(GmailParser().parse(threadWindow(), context: context(nil)))
        XCTAssertFalse(c.messages.contains { $0.sender == "Grace Hopper" },
                       "a collapsed row has no a3s body, so it is not a message yet")
        XCTAssertFalse(c.messages.contains { $0.text.isEmpty })
    }

    func testASubjectlessThreadFallsBackToTheWindowTitle() throws {
        let bare = node("AXWindow", title: "Some thread - me@example.com - Gmail",
                        frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: 0, y: 40, width: 800, height: 60), children: [
                text("Ada", ["gD"], y: 40),
                node("AXGroup", domClassList: ["a3s"], frame: CGRect(x: 0, y: 60, width: 800, height: 20),
                     children: [text("one line", nil, y: 60)]),
            ]),
        ])
        XCTAssertEqual(try conversation(GmailParser().parse(bare, context: context(
            "Some thread - me@example.com - Gmail"))).channel,
                       "Some thread - me@example.com - Gmail")
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXGroup", domClassList: ["adn"],
                 frame: CGRect(x: 0, y: 40, width: 800, height: 60), children: [
                node("AXGroup", domClassList: ["a3s"], frame: CGRect(x: 0, y: 60, width: 800, height: 20),
                     children: [text("Note: check the doc", nil, y: 60)]),
            ]),
        ])
        let message = try XCTUnwrap(try conversation(GmailParser().parse(win, context: context(nil)))
            .messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    // MARK: - Draft

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(GmailParser().parse(threadWindow(draft: "Sending the summary now"),
                                                    context: context(nil)))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "Sending the summary now")
        XCTAssertEqual(c.messages.count, 2, "the draft is appended, never replacing a message")
        XCTAssertTrue(ContentRenderer.render(.conversation(c), style: .full)
            .contains("(From: You (draft)): Sending the summary now"))
    }

    func testAStandaloneComposeWindowIsTheDraftAlone() throws {
        let c = try conversation(GmailParser().parse(composeOnlyWindow("draft body"),
                                                    context: context("New Message - me@example.com - Gmail")))
        XCTAssertEqual(c.messages.map(\.text), ["draft body"])
        XCTAssertEqual(c.messages.map(\.isDraft), [true])
    }

    // MARK: - List view

    func testTheInboxBecomesThreeCellTableRows() throws {
        let rows = try page(GmailParser().parse(inboxWindow(), context: context(
            "Inbox (3) - me@example.com - Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox"))).regions
        XCTAssertEqual(rows.map(\.kind), [.main])
        XCTAssertEqual(rows[0].blocks.map(\.type), [
            .tableRow(cells: ["Ada Lovelace", "Quarterly index rebuild Rebuild finished overnight.",
                              "10:14 AM"], selected: true),
            .tableRow(cells: ["Grace Hopper", "Deploy window Green across the board.",
                              "09:02 AM"], selected: false),
            .tableRow(cells: ["Alan Turing", "Machine time Booked the afternoon slot.",
                              "Jul 3"], selected: false),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(rows[0].blocks[0]),
                       "* Ada Lovelace | Quarterly index rebuild Rebuild finished overnight. | 10:14 AM")
    }

    func testTheListPageCarriesTheUrl() throws {
        let url = "https://mail.google.com/mail/u/0/#inbox"
        XCTAssertEqual(try page(GmailParser().parse(inboxWindow(), context: context(nil, url: url))).url,
                       url)
    }

    // MARK: - Not handled vs refusal

    func testAPageWithNoMessageContainerIsNotHandledRatherThanRefused() throws {
        let parser = GmailParser()
        XCTAssertNil(try parser.parse(settingsWindow(), context: context(nil)))
        XCTAssertFalse(parser.refusesEmptyCompose(settingsWindow(), context: context(nil)),
                       "no composer means no refusal — this window becomes generic v2")
    }

    func testAnEmptyComposeOnlyWindowRefuses() throws {
        let parser = GmailParser()
        let window = composeOnlyWindow("   ")
        XCTAssertTrue(parser.refusesEmptyCompose(window, context: context(nil)))
        // The refusal travels on `parse`'s `throws` — there is nothing to store and this must not
        // degrade to a generic capture of the compose chrome (ruling F13).
        XCTAssertThrowsError(try parser.parse(window, context: context(nil))) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    func testAnEmptyComposerOverAThreadDoesNotRefuse() throws {
        let parser = GmailParser()
        let window = threadWindow(draft: "")
        XCTAssertNotNil(try parser.parse(window, context: context(nil)))
        XCTAssertFalse(parser.refusesEmptyCompose(window, context: context(nil)))
    }

    // MARK: - Origin invariance

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = GmailParser()
        XCTAssertEqual(try parser.parse(threadWindow(), context: context(nil)),
                       try parser.parse(threadWindow(origin: CGPoint(x: 1440, y: 220)),
                                    context: context(nil)))
        XCTAssertEqual(try parser.parse(inboxWindow(), context: context(nil)),
                       try parser.parse(inboxWindow(origin: CGPoint(x: 1440, y: 220)),
                                    context: context(nil)))
    }

    // MARK: - Pipeline: kind, key and the refusal

    func testThePipelineKeepsEmailKindAndTheUrlNormalizedKey() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(threadWindow(), url: Self.threadURL),
            windowTitle: "Quarterly index rebuild - me@example.com - Gmail", browser: browser)
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.threadURL), .gmail)
        XCTAssertEqual(result.capture.contentKind, .email, "§12 Q3: Gmail stays .email")
        XCTAssertEqual(result.capture.sourceApp, "Web")
        XCTAssertEqual(result.capture.sourceKey, URLKeyNormalizer.normalize(Self.threadURL))
        XCTAssertEqual(result.capture.sourceKey, Self.threadURL, "the key scheme is unchanged")
        XCTAssertEqual(result.webApp, .gmail)
        guard case .conversation(let c) = result.structured else {
            return XCTFail("expected the host parser's conversation, got \(result.structured)")
        }
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(result.capture.content,
                       ContentRenderer.render(result.structured, style: .full))
    }

    func testAnEmptyComposeOnlyTabRefusesThroughThePipeline() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        do {
            _ = try BrowserCapturePipeline.parse(
                window: browserWindow(composeOnlyWindow("  "),
                                      url: "https://mail.google.com/mail/u/0/#drafts?compose=new"),
                windowTitle: "New Message - me@example.com - Gmail", browser: browser)
            XCTFail("expected a ParserRefusal")
        } catch let refusal as ParserRefusal {
            XCTAssertEqual(refusal.reason, "empty-compose")
        }
    }

    func testHostContentIsBoundedToTheBrowserBudget() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: browserWindow(threadWindow(), url: Self.threadURL),
            windowTitle: nil, browser: browser, contentBudget: 40)
        XCTAssertLessThanOrEqual(result.capture.content.count, 40,
                                 "a host parser's content is bounded exactly like the web path's")
    }

    // MARK: - Goldens

    func testThreadFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(GmailParser().parse(try fixture("gmail-thread"),
                                                       context: context(nil))),
                     matches: "gmail-thread-golden")
    }

    func testOffsetInboxFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(GmailParser().parse(
            try fixture("gmail-offset-inbox"),
            context: context(nil, url: "https://mail.google.com/mail/u/0/#inbox"))),
                     matches: "gmail-offset-inbox-golden")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter GmailParserTests`
Expected: FAIL to compile — "cannot find 'GmailParser' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/MaxMiCapture/WebHostParsing.swift`:

```swift
import Foundation
import MaxMiCore

/// The app-agnostic half of the five §14b web-app parsers. The DOM anchors live in each parser;
/// the message-building rules live here, so Gmail, LinkedIn, Outlook, Slack web and Teams web
/// cannot drift apart on what counts as a sender or a draft.
enum WebHostParsing {
    /// The readable text of an anchor node. `label` is consulted last because it is
    /// `AXDescription ?? AXHelp` (spec §12 Q1) and is often a verbose restatement.
    static func text(of node: AXNode) -> String? {
        let raw = node.value ?? node.title ?? node.label
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// A composer's text: its own value, else the static texts a contenteditable exposes as
    /// children (every one of these five composers is a contenteditable, not a text field).
    static func editorText(in node: AXNode) -> String {
        if let value = node.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return AXQuery.collectStaticTexts(in: node).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The composer's live text as the user's draft. nil for a missing OR empty composer, which
    /// is what makes "compose-only window with an empty draft" decidable.
    static func draft(in composer: AXNode?) -> Message? {
        guard let composer else { return nil }
        let text = editorText(in: composer)
        guard !text.isEmpty else { return nil }
        return Message(id: Message.makeID(sender: "You", timeString: nil, text: text),
                       sender: "You", text: text, timestamp: nil, timeString: nil,
                       isUser: true, isDraft: true)
    }

    /// One message from one container's OWN texts.
    ///
    /// `texts` must already have the anchored sender and timestamp values removed, because when
    /// `sender` is nil the shared `NativeConversationExtraction.senderLabel` heuristic decides
    /// whether the FIRST value is a speaker. A joined line is never re-split on `": "` — "Note:
    /// check the doc" is a message, not a message from someone called "Note" (§14b).
    static func message(
        sender: String?,
        timeString: String?,
        texts: [String],
        isUser: Bool = false
    ) -> Message? {
        let values = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolved: String?
        let bodyValues: [String]
        if let sender, !sender.isEmpty {
            // The sender came from its own anchored node, so no value is consumed from the body.
            resolved = sender
            bodyValues = values
        } else if let heuristic = NativeConversationExtraction.senderLabel(values) {
            resolved = heuristic
            bodyValues = Array(values.dropFirst())
        } else {
            resolved = nil
            bodyValues = values
        }
        let body = bodyValues.joined(separator: " ")
        guard !body.isEmpty else { return nil }
        let time = timeString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = time?.isEmpty == false ? time : nil
        let name = resolved ?? "unknown"
        return Message(id: Message.makeID(sender: name, timeString: stamp, text: body),
                       sender: name, text: body, timestamp: nil, timeString: stamp,
                       isUser: isUser, isDraft: false)
    }

    /// The URL path, `""` when there is no URL. `LinkedInMessagingParser` uses it to stay off
    /// every LinkedIn page that is not `/messaging`.
    static func path(of url: String?) -> String {
        guard let url, let path = URLComponents(string: url)?.path else { return "" }
        return path
    }
}
```

Create `Sources/MaxMiCapture/GmailParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Gmail on the web (`mail.google.com`), routed by host (spec §7b, §14b).
///
/// Three surfaces, one parser: an open thread is a `.conversation`, a list view is a `.generic`
/// page of table rows, and a compose window is the draft alone. `contentKind` is NOT decided
/// here — `WebAppCaptureParser.classify` keeps Gmail on `.email` for all three (§12 Q3) — and
/// the thread key stays `URLKeyNormalizer.normalize(tab.url)`.
///
/// ANCHORS. §14b's candidates, verified against a live dump recorded with
/// `swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/gmail-thread.json`
/// on <YYYY-MM-DD>. Replace each `?` with `verified (<n> nodes)` or
/// `NOT EXPOSED — used <replacement>`, and KEEP the failures listed so the next reader does not
/// re-try a dead anchor:
///   `adn`  message container          ?
///   `gD`   sender name                ?
///   `go`   sender address             ?
///   `g3`   time                       ?
///   `a3s`  message body               ?
///   `zA`   list row                   ?
///   AXDescription "Message Body"      compose editor  ?
public struct GmailParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Gmail",
        bundleIDs: [],
        hosts: ["mail.google.com"],
        // Declared as §14b asks. INERT for a hosts-only parser: `forcedAttributes(for:)` is keyed
        // by bundle ID and the bundle here is the browser's. What supplies these attributes is
        // Task 1's AXWebArea-ancestor gate, which a real browser tab always satisfies.
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        // No native app shares mail.google.com, so no native claim competes for the window.
        preferOverNative: false
    )

    static let messageClass = "adn"
    static let senderNameClass = "gD"
    static let senderAddressClass = "go"
    static let timeClass = "g3"
    static let bodyClass = "a3s"
    static let listRowClass = "zA"
    static let composeBodyDescription = "Message Body"
    /// Headings Gmail renders AROUND the mail. None of them is ever a subject.
    static let chromeHeadings: Set<String> = [
        "gmail", "main menu", "search mail", "chat", "meet", "spaces", "conversations",
    ]

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[description=\"\(composeBodyDescription)\"]", in: snapshot)
    }

    /// The thread subject: the first non-chrome heading, else the window title (§14b).
    static func subject(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.findAll("//AXHeading", in: snapshot)
            .compactMap(WebHostParsing.text(of:))
            .first(where: { !chromeHeadings.contains($0.lowercased()) }) {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per EXPANDED container. A collapsed row carries no `a3s` body at all, and a
    /// message with a real sender and an empty body is worse than no message (§14b).
    static func threadMessages(in snapshot: AXNode) -> [Message] {
        let containers = AXQuery.findAll("//*[domClass=\"\(messageClass)\"]", in: snapshot)
        return AXQuery.sortedByVisualOrder(containers, relativeTo: snapshot.frame)
            .compactMap { container in
                guard let body = AXQuery.find("//*[domClass=\"\(bodyClass)\"]", in: container)
                else { return nil }
                let name = AXQuery.find("//*[domClass=\"\(senderNameClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                let address = AXQuery.find("//*[domClass=\"\(senderAddressClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                let time = AXQuery.find("//*[domClass=\"\(timeClass)\"]", in: container)
                    .flatMap(WebHostParsing.text(of:))
                // Only the body subtree's texts, so the sender line cannot leak into the text.
                return WebHostParsing.message(sender: name ?? address, timeString: time,
                                              texts: AXQuery.collectStaticTexts(in: body))
            }
    }

    /// `[sender, subject + snippet, time]` per list row (§14b). The middle cell is JOINED rather
    /// than split further: Gmail exposes subject and snippet as two texts, and a row exposing
    /// only two texts has no time to read.
    static func listRows(in snapshot: AXNode) -> [Block] {
        let rows = AXQuery.findAll("//*[domClass=\"\(listRowClass)\"]", in: snapshot)
        return AXQuery.sortedByVisualOrder(rows, relativeTo: snapshot.frame).compactMap { row in
            let texts = AXQuery.collectStaticTexts(in: row)
            guard texts.count >= 2 else { return nil }
            let hasTime = texts.count >= 3
            let cells = [
                texts[0],
                texts.dropFirst().dropLast(hasTime ? 1 : 0).joined(separator: " "),
                hasTime ? texts[texts.count - 1] : "",
            ]
            return Block(type: .tableRow(cells: cells, selected: row.selected),
                         text: cells.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let draft = WebHostParsing.draft(in: Self.composer(in: snapshot))
        var messages = Self.threadMessages(in: snapshot)
        if !messages.isEmpty {
            if let draft { messages.append(draft) }
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                // Gmail's anchors expose no recipient list, so the thread stays flat.
                isGroup: false,
                messages: messages
            ))
        }
        // A live draft over the inbox is what the user is doing; the rows behind it are not.
        if let draft {
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false, messages: [draft]
            ))
        }
        let rows = Self.listRows(in: snapshot)
        guard !rows.isEmpty else {
            // The ONE refusal case (§14b): a compose-only window whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED: §4f rule 3 routes this window to `WebPageParser` and the
            // health ledger records "GenericPageExtractor.v2/fallback/GmailParser".
            return nil
        }
        return .generic(GenericPage(regions: [Region(kind: .main, blocks: rows)],
                                    focused: nil, url: context.url))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.threadMessages(in: snapshot).isEmpty
            && Self.listRows(in: snapshot).isEmpty
    }
}
```

In `Sources/MaxMiCapture/BrowserCapturePipeline.swift`, replace Task 9's routing block. The whole function afterwards — note the `try` and `contentBudget:` on `WebAppCaptureParser.parse` (it is `throws` and budgeted; Task 9's snippet elides both), and `registry` added AFTER `contentBudget` so `WebAppStructuredTests.swift:117` keeps compiling:

```swift
    public static func parse(
        window: AXNode,
        windowTitle: String?,
        browser: ApplicationDescriptor,
        contentBudget: Int = WebAppCaptureParser.contentCap,
        registry: ParserRegistry = ParserRegistry()
    ) throws -> BrowserCaptureResult {
        let tab = try BrowserTabExtractor.extract(
            window: window,
            windowTitle: windowTitle,
            engine: browser.browserEngine
        )
        // Host routing (spec §7b), through the ONE entry point Task 5 defines: a registered host
        // parser claims the tab, otherwise `WebPageParser` does. Either way `contentKind`,
        // `sourceKey` and the accumulation policy come from `WebAppCaptureParser.parse` — a host
        // parser owns CONTENT only (§4f rule 1).
        let hostContext = ParseContext(
            app: AppInfo(bundleID: browser.bundleID, name: browser.displayName,
                         windowTitle: windowTitle),
            url: tab.url
        )
        // Routed FIRST, and with `try`: the ONE refusal case (§14b) is a compose-only window with
        // an empty draft, and the host parser throws `ParserRefusal` from its own `parse`. Running
        // this before `WebAppCaptureParser.parse` is what makes the refusal — rather than that
        // path's `ExtractionError.emptyContent` — the error that reaches `AppWiring` (ruling F13).
        let routed = try CaptureDispatch.structuredCapture(
            window: window, context: hostContext, registry: registry,
            fallback: { window, _, _ in WebPageParser.parse(window: window, tab: tab) }
        )
        let web = try WebAppCaptureParser.parse(tab: tab, window: window,
                                               contentBudget: contentBudget)
        let structured: CapturedContent
        let hostClaimed: Bool
        var hostMarker: String?
        switch routed {
        case .parsed(let content, let parserName):
            // A host shape is bounded to the same budget the web path has always used, so one
            // long thread cannot blow past the browser cap.
            structured = CaptureAccumulator.bound(content, to: contentBudget)
            hostClaimed = true
            hostMarker = parserName
        case .fellThrough(let content, let notHandledBy):
            structured = content
            hostClaimed = false
            // Spec §8: a registered host parser that returned nil is a non-silent degradation,
            // spelled with the one existing helper (ruling F4).
            hostMarker = notHandledBy.map { CaptureDispatch.fallbackParserID(failedParser: $0) }
        }
        let quality: BrowserCaptureQuality
        if hostClaimed || web.preservedBoundaries {
            quality = .high
        } else {
            quality = tab.quality
        }
        let parserID = ([
            "BrowserWeb.v2",
            browser.browserEngine?.rawValue ?? "unknown",
            web.app.rawValue,
            tab.urlSource.rawValue,
            "quality-\(quality.rawValue)",
        ] + (hostMarker.map { [$0] } ?? [])).joined(separator: "/")
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
            truncated: tab.truncated || web.truncated
                || ContentRenderer.render(structured, style: .full).count
                    >= WebAppCaptureParser.contentCap,
            webApp: web.app
        )
    }
```

`BrowserCaptureResult` itself is unchanged: `result.capture.structured` already carries this value, and a second copy would be two sources of truth (ruling F30).

In `Sources/MaxMiCapture/ParserRegistry.swift`, append to Task 5's single registration list (Gmail has no bundle IDs, so the derived loop puts it in the host map only):

```swift
        let structured: [any StructuredParser] = [
            TerminalParser(), EditorParser(), SlackParser(), DiscordParser(), MessagesParser(),
            WhatsAppParser(), NotesParser(), NotionParser(), ObsidianParser(), FinderParser(),
            CalendarParser(), FantasticalParser(), RemindersParser(),
            GmailParser(),
        ]
```

In `Sources/MaxMi/AppWiring.swift`, insert one clause immediately before `} catch ExtractionError.addressFieldFocused {`:

```swift
        } catch let refusal as ParserRefusal {
            // §14b: a host parser refuses only for a compose-only window with an empty draft.
            // Nothing to store, and the refusal IS the health-ledger record of that — so this is
            // a skip, not a failure, and it is not retried.
            SafeLogger.shared.log(
                .info, subsystem: .capture, event: .parserRefused,
                fields: SafeLogFields(
                    parserID: SafeLogToken(validating: effectiveParserName),
                    outcome: SafeLogToken(validating: refusal.reason)
                )
            )
            recordCaptureHealth(
                app: appInfo, trigger: trigger, parser: effectiveParserName,
                outcome: .skipped(.parserNoContent), startedAtMs: startedAtMs
            )
```

In `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (Task 21), host-routed parsers have no bundle ID, so registration is checked through the host map. Add the dictionary next to `coverage`:

```swift
    /// Parser type name -> the hosts it claims. Host-routed parsers (§14b) are registered by
    /// host, not by bundle ID, so `testEveryCoveredParserIsRegisteredAsAStructuredParser`
    /// cannot see them.
    static let hostCoverage: [String: [String]] = [
        "GmailParser": ["mail.google.com"],
    ]
```

and add the test that consumes it:

```swift
    func testEveryHostRoutedParserIsReachableFromTheHostMap() {
        let registry = ParserRegistry()
        for (name, hosts) in Self.hostCoverage {
            for host in hosts {
                guard let parser = registry.structuredParser(forHost: host) else {
                    return XCTFail("no structured parser registered for host \(host)")
                }
                XCTAssertEqual(String(describing: type(of: parser)), name,
                               "host \(host) resolves to the wrong parser")
            }
        }
    }
```

Task 21's `testEveryCoveredParserIsRegisteredAsAStructuredParser` builds `registered` from
bundle IDs only, so its final loop must now accept a host-routed parser. Replace that loop with:

```swift
        for name in Self.coverage.keys {
            XCTAssertTrue(registered.contains(name) || Self.hostCoverage[name] != nil,
                          "\(name) is reachable neither by bundle id nor by host")
        }
```

`SlackParser` still satisfies the `registered` half (it claims a bundle ID as well), so this
loosening applies only to the four parsers that claim hosts alone.

and add Gmail's fixtures to `coverage` so the existing two-fixture, nonzero-origin and secure-field assertions cover them:

```swift
        "GmailParser": [("gmail-thread", "gmail-thread-golden"),
                        ("gmail-offset-inbox", "gmail-offset-inbox-golden")],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter GmailParserTests`
Expected: PASS except the two golden tests (their fixtures do not exist yet).

Run: `swift test --filter BrowserCapturePipelineTests`
Expected: PASS — the signature change is additive and the routing is unchanged for a non-Gmail tab.

Run: `swift test --filter WebAppStructuredTests`
Expected: PASS — `contentBudget:` is still the fourth parameter.

- [ ] **Step 6: Scrub the fixtures, write the goldens, add the README rows**

Hand-scrub `/tmp/gmail-thread.json` and `/tmp/gmail-offset-inbox.json` per `Tests/MaxMiCaptureTests/Fixtures/README.md`: replace every subject, body, snippet, person name and address with invented equivalents of similar shape and length, and delete subtrees the tests do not need. Keep intact:

- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `gmail-offset-inbox.json`),
- `gmail-thread.json`: the non-chrome subject `AXHeading`, **two** verified message containers — one with a body node and one without, so the collapsed-skip is pinned — each with a sender node, an address node and a time node, plus one composer node carrying invented draft text,
- `gmail-offset-inbox.json`: **three** verified list rows, one with `"selected": true`, each exposing four static texts (sender, subject, snippet, time).

Move both into `Tests/MaxMiCaptureTests/Fixtures/`, then print each golden from the test (`print(try goldenJSON(GmailParser().parse(try fixture("gmail-thread"), context: context(nil))!))`), scrub it the same way and save it as `gmail-thread-golden.json` / `gmail-offset-inbox-golden.json`. Add four rows to the README table:

```markdown
| `gmail-thread.json` | Recorded Chrome Gmail thread, scrubbed | `GmailParser` conversation: expanded message, collapsed skip, composer draft |
| `gmail-thread-golden.json` | Golden `CapturedContent` for the above | `GmailParser` |
| `gmail-offset-inbox.json` | Recorded Chrome Gmail inbox at a nonzero screen origin, scrubbed | `GmailParser` generic page of three-cell table rows |
| `gmail-offset-inbox-golden.json` | Golden `CapturedContent` for the above | `GmailParser` |
```

- [ ] **Step 7: Run the suites**

Run: `swift test --filter GmailParserTests`
Expected: PASS, 20 tests.

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS — Gmail is reachable by host and both fixtures load.

Run: `swift build 2>&1 | grep -i warning; echo done`
Expected: no warning lines.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiCapture/WebHostParsing.swift Sources/MaxMiCapture/GmailParser.swift \
        Sources/MaxMiCapture/BrowserCapturePipeline.swift \
        Sources/MaxMiCapture/ParserRegistry.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiCaptureTests/GmailParserTests.swift \
        Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/gmail-thread.json \
        Tests/MaxMiCaptureTests/Fixtures/gmail-thread-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/gmail-offset-inbox.json \
        Tests/MaxMiCaptureTests/Fixtures/gmail-offset-inbox-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture Gmail threads, inbox rows and drafts from verified DOM anchors"
```

---
### Task 23: LinkedIn messaging (`linkedin.com/messaging`) → `.conversation`

**Files:**
- Create: `Sources/MaxMiCapture/LinkedInMessagingParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (append `LinkedInMessagingParser()` to Task 5's `structured` list)
- Modify: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (one `coverage` row, one `hostCoverage` row)
- Create: `Tests/MaxMiCaptureTests/Fixtures/linkedin-messaging.json`, `linkedin-messaging-golden.json`, `linkedin-offset-messaging.json`, `linkedin-offset-messaging-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/LinkedInMessagingParserTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)` (Task 3); `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)`, `AXQuery.first(in:where:)` (Task 4); `ParserConfig`, `ParseContext`, `StructuredParser`, `ParserRegistry.structuredParser(forHost:)` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `WebHostParsing.text(of:)`, `.draft(in:)`, `.message(sender:timeString:texts:isUser:)`, `.path(of:)` (Task 22); `WebAppCaptureParser.classify(url:)`; `URLKeyNormalizer.normalize(_:)`; `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `LinkedInMessagingParser: StructuredParser` with `config`, `parse(_:context:)`, `refusesEmptyCompose(_:context:)`, and the statics `eventClass`, `groupNameClass`, `groupTimestampClass`, `bodyClass`, `titleClass`, `composerClass`, `navMeClass`, `messagingPathPrefix`, `signedInName(in:) -> String?`, `channel(in:windowTitle:) -> String`, `messages(in:selfName:) -> [Message]`, `composer(in:) -> AXNode?`.

**Two rulings this task must not relitigate:**

1. **Off `/messaging`, the parser returns nil** so every other LinkedIn page stays generic v2 (§14b). It is a `nil`, not a refusal — the feed is a page worth capturing generically.
2. **`isUser` is never guessed from geometry.** It is true only when the message group's name equals the signed-in user's name. When that name cannot be resolved, every message is emitted with `isUser: false` and the header comment says so (§14b).

- [ ] **Step 1: Record the live fixtures FIRST and verify the anchors**

Open a LinkedIn conversation at `https://www.linkedin.com/messaging/thread/<id>/` in Chrome as the front tab, window flush at the screen origin, then:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/linkedin-messaging.json
```

Open a **different** conversation, one where you have replied so a self-authored group is present, drag the window well away from the top-left corner, then:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/linkedin-offset-messaging.json
```

Verify the anchors in both dumps with the same class/id/description census Task 22 Step 1 uses:

```bash
for f in /tmp/linkedin-messaging.json /tmp/linkedin-offset-messaging.json; do
  echo "== $f"
  python3 - "$f" <<'PY'
import collections, json, sys
counts = collections.Counter()
def walk(node):
    for name in node.get("domClassList") or []:
        counts["class:" + name] += 1
    if node.get("domIdentifier"):
        counts["domId:" + node["domIdentifier"][:40]] += 1
    if node.get("label"):
        counts["description:" + node["label"][:40]] += 1
    for child in node.get("children", []):
        walk(child)
walk(json.load(open(sys.argv[1])))
for name, n in counts.most_common(80):
    print(n, name)
PY
done
```

Check each of §14b's candidates — `msg-s-message-list__event`, `msg-s-message-group__name`, `msg-s-message-group__timestamp`, `msg-s-event-listitem__body`, `msg-entity-lockup__entity-title`, `msg-form__contenteditable` — plus the two self-name candidates this task invents because §14b names only "the 'Me' nav item or the profile card": `global-nav__me` and `global-nav__me-photo`. Record `verified (<n> nodes)` or `NOT EXPOSED — used <replacement>` for every one of the eight in the parser header, and keep the failures listed. **If neither self-name candidate surfaces, that is an acceptable outcome**: write `NOT EXPOSED — isUser is always false on this surface` and the tests below already cover that path.

- [ ] **Step 2: Write the failing test**

Create `Tests/MaxMiCaptureTests/LinkedInMessagingParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class LinkedInMessagingParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              domClassList: [String]? = nil, url: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: nil,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 400) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// One `li` per group, in LinkedIn's real shape: the first `li` of a group carries the name
    /// and timestamp, and a continuation `li` carries only a body.
    func event(name: String?, time: String?, bodies: [String], y: CGFloat, x: CGFloat) -> AXNode {
        var children: [AXNode] = []
        if let name { children.append(text(name, ["msg-s-message-group__name"], y: y, x: x)) }
        if let time {
            children.append(text(time, ["msg-s-message-group__timestamp"], y: y, x: x + 200))
        }
        for (index, body) in bodies.enumerated() {
            children.append(node("AXGroup", domClassList: ["msg-s-event-listitem__body"],
                                 frame: CGRect(x: x, y: y + 20 + CGFloat(index * 20),
                                               width: 400, height: 18),
                                 children: [text(body, nil, y: y + 20 + CGFloat(index * 20), x: x)]))
        }
        return node("AXGroup", domClassList: ["msg-s-message-list__event"],
                    frame: CGRect(x: x, y: y, width: 500, height: CGFloat(40 + bodies.count * 20)),
                    children: children)
    }

    /// The messaging thread: two groups from the contact, one from the signed-in user, plus a
    /// continuation `li` under the first group, an entity title and an optional composer.
    func messagingWindow(origin: CGPoint = .zero, draft: String? = nil,
                         selfName: String? = "Sam Rivers") -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            text("Ada Lovelace", ["msg-entity-lockup__entity-title"], y: y + 60, x: x + 400),
            event(name: "Ada Lovelace", time: "10:14 AM",
                  bodies: ["Sending the deck over."], y: y + 100, x: x + 400),
            event(name: nil, time: nil, bodies: ["Ignore the first slide."],
                  y: y + 160, x: x + 400),
            event(name: "Sam Rivers", time: "10:22 AM", bodies: ["Got it, thanks."],
                  y: y + 220, x: x + 400),
        ]
        if let selfName {
            children.insert(node("AXImage", label: "Photo of \(selfName)",
                                 domClassList: ["global-nav__me-photo"],
                                 frame: CGRect(x: x + 1200, y: y + 10, width: 24, height: 24)),
                            at: 0)
        }
        if let draft {
            children.append(node("AXTextArea", value: draft,
                                 domClassList: ["msg-form__contenteditable"],
                                 frame: CGRect(x: x + 400, y: y + 500, width: 500, height: 60)))
        }
        return node("AXWindow", title: "Messaging | LinkedIn",
                    frame: CGRect(origin: origin, size: CGSize(width: 1440, height: 900)),
                    children: children)
    }

    /// The LinkedIn feed: no message events anywhere.
    func feedWindow() -> AXNode {
        node("AXWindow", title: "Feed | LinkedIn",
             frame: CGRect(x: 0, y: 0, width: 1440, height: 900), children: [
            text("Ada Lovelace posted a photo", nil, y: 100),
        ])
    }

    static let threadURL = "https://www.linkedin.com/messaging/thread/2-abc123def=="

    func context(_ title: String? = "Messaging | LinkedIn",
                 url: String = LinkedInMessagingParserTests.threadURL) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    // MARK: - Registration and routing

    func testConfigClaimsBothLinkedInHosts() {
        XCTAssertEqual(LinkedInMessagingParser.config.hosts, ["www.linkedin.com", "linkedin.com"])
        XCTAssertEqual(LinkedInMessagingParser.config.bundleIDs, [])
        XCTAssertFalse(LinkedInMessagingParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "www.linkedin.com")
                        is LinkedInMessagingParser)
        XCTAssertTrue(registry.structuredParser(forHost: "linkedin.com")
                        is LinkedInMessagingParser)
    }

    func testEveryLinkedInPageThatIsNotMessagingIsNotHandled() throws {
        let parser = LinkedInMessagingParser()
        XCTAssertNil(try parser.parse(feedWindow(),
                                  context: context("Feed | LinkedIn",
                                                   url: "https://www.linkedin.com/feed/")))
        // Even a page that DOES expose message events stays generic off /messaging: the notification
        // rail on the feed renders the same classes.
        XCTAssertNil(try parser.parse(messagingWindow(),
                                  context: context(url: "https://www.linkedin.com/feed/")))
        XCTAssertFalse(parser.refusesEmptyCompose(
            feedWindow(), context: context(url: "https://www.linkedin.com/feed/")))
    }

    func testTheMessagingPathIsMatchedByPrefixSoASubPathStillParses() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(), context: context(url: "https://www.linkedin.com/messaging/")))
        XCTAssertFalse(c.messages.isEmpty)
    }

    // MARK: - Messages

    func testGroupsBecomeAttributedMessagesAndAContinuationInheritsItsGroup() throws {
        let c = try conversation(LinkedInMessagingParser().parse(messagingWindow(),
                                                                context: context()))
        XCTAssertEqual(c.channel, "Ada Lovelace")
        XCTAssertEqual(c.messages.map(\.sender),
                       ["Ada Lovelace", "Ada Lovelace", "Sam Rivers"])
        XCTAssertEqual(c.messages.map(\.text),
                       ["Sending the deck over.", "Ignore the first slide.", "Got it, thanks."])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:14 AM", "10:22 AM"])
    }

    func testIsUserIsTrueOnlyForTheSignedInUsersOwnGroup() throws {
        let c = try conversation(LinkedInMessagingParser().parse(messagingWindow(),
                                                                context: context()))
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, true])
        XCTAssertTrue(ContentRenderer.render(.conversation(c), style: .full)
            .contains("(From: You)(sent 10:22 AM): Got it, thanks."))
    }

    func testAnUnresolvableSelfNameMakesEveryMessageIsUserFalse() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(selfName: nil), context: context()))
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, false],
                       "isUser is never guessed from geometry (§14b)")
        XCTAssertEqual(c.messages.last?.sender, "Sam Rivers")
    }

    func testSignedInNameStripsThePhotoOfPrefix() {
        XCTAssertEqual(LinkedInMessagingParser.signedInName(in: messagingWindow()), "Sam Rivers")
        XCTAssertNil(LinkedInMessagingParser.signedInName(in: messagingWindow(selfName: nil)))
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            event(name: nil, time: nil, bodies: ["Note: check the doc"], y: 100, x: 400),
        ])
        let message = try XCTUnwrap(try conversation(
            try LinkedInMessagingParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testAChannelWithNoEntityTitleFallsBackToTheWindowTitle() throws {
        let win = node("AXWindow", title: "Messaging | LinkedIn",
                       frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            event(name: "Ada", time: nil, bodies: ["hi"], y: 100, x: 400),
        ])
        XCTAssertEqual(try conversation(LinkedInMessagingParser().parse(win, context: context()))
                        .channel, "Messaging | LinkedIn")
    }

    // MARK: - Draft, not-handled, refusal

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(LinkedInMessagingParser().parse(
            messagingWindow(draft: "on my way"), context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.sender, "You")
        XCTAssertEqual(draft.text, "on my way")
        XCTAssertEqual(c.messages.count, 4)
    }

    func testAMessagingPageWithNoEventsIsNotHandled() throws {
        let empty = node("AXWindow", title: "Messaging | LinkedIn",
                         frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         children: [text("No conversations yet", nil, y: 100)])
        XCTAssertNil(try LinkedInMessagingParser().parse(empty, context: context()))
    }

    func testAnEmptyComposerWithNoEventsRefuses() throws {
        let parser = LinkedInMessagingParser()
        let composeOnly = node("AXWindow", title: "Messaging | LinkedIn",
                               frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            node("AXTextArea", value: "  ", domClassList: ["msg-form__contenteditable"],
                 frame: CGRect(x: 400, y: 500, width: 500, height: 60)),
        ])
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context()))
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    // MARK: - Kind, key, origin, goldens

    func testTheHostKeepsItsConversationKindAndItsExistingKey() {
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.threadURL), .linkedin)
        // §14b keeps the key derivation exactly as it is today: the thread path is truncated to
        // three components, so a scroll or a query param cannot fork the thread.
        XCTAssertEqual(URLKeyNormalizer.normalize(Self.threadURL),
                       URLKeyNormalizer.normalize(Self.threadURL + "?focus=true"))
        XCTAssertTrue(URLKeyNormalizer.normalize(Self.threadURL).hasPrefix(
            "https://www.linkedin.com/messaging/thread"))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = LinkedInMessagingParser()
        XCTAssertEqual(try parser.parse(messagingWindow(), context: context()),
                       try parser.parse(messagingWindow(origin: CGPoint(x: 1440, y: 220)),
                                    context: context()))
    }

    func testMessagingFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(LinkedInMessagingParser().parse(
            try fixture("linkedin-messaging"), context: context())),
                     matches: "linkedin-messaging-golden")
    }

    func testOffsetMessagingFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(LinkedInMessagingParser().parse(
            try fixture("linkedin-offset-messaging"), context: context())),
                     matches: "linkedin-offset-messaging-golden")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter LinkedInMessagingParserTests`
Expected: FAIL to compile — "cannot find 'LinkedInMessagingParser' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/MaxMiCapture/LinkedInMessagingParser.swift`:

```swift
import Foundation
import MaxMiCore

/// LinkedIn messaging (`linkedin.com/messaging`) → `.conversation`, routed by host (§7b, §14b).
///
/// EVERY OTHER LINKEDIN PAGE STAYS GENERIC V2: `parse` returns nil off `/messaging`, even when a
/// page exposes message classes (the feed's notification rail does). `contentKind` is decided by
/// `WebAppCaptureParser.classify` — `.conversation` for `/messaging`, `.webpage` elsewhere
/// (§12 Q3) — and the key stays `URLKeyNormalizer.normalize(tab.url)`, which already truncates
/// `/messaging/thread/<id>` to three path components.
///
/// `isUser` is TRUE only when a group's name equals the signed-in user's name. It is never
/// inferred from geometry or bubble alignment. When the signed-in name cannot be resolved every
/// message is emitted with `isUser: false`.
///
/// ANCHORS. §14b's candidates plus the two self-name candidates this parser adds (§14b names
/// only "the 'Me' nav item or the profile card"), verified against a live dump recorded with
/// `swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/linkedin-messaging.json`
/// on <YYYY-MM-DD>. Replace each `?` with `verified (<n> nodes)` or
/// `NOT EXPOSED — used <replacement>`, and keep the failures listed:
///   `msg-s-message-list__event`        message list item     ?
///   `msg-s-message-group__name`        sender                ?
///   `msg-s-message-group__timestamp`   time                  ?
///   `msg-s-event-listitem__body`       body                  ?
///   `msg-entity-lockup__entity-title`  conversation header   ?
///   `msg-form__contenteditable`        composer              ?
///   `global-nav__me-photo`             signed-in name        ?
///   `global-nav__me`                   signed-in name        ?
public struct LinkedInMessagingParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "LinkedIn",
        bundleIDs: [],
        hosts: ["www.linkedin.com", "linkedin.com"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`). The
        // AXWebArea gate is what actually supplies these attributes on a browser tab.
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let messagingPathPrefix = "/messaging"
    static let eventClass = "msg-s-message-list__event"
    static let groupNameClass = "msg-s-message-group__name"
    static let groupTimestampClass = "msg-s-message-group__timestamp"
    static let bodyClass = "msg-s-event-listitem__body"
    static let titleClass = "msg-entity-lockup__entity-title"
    static let composerClass = "msg-form__contenteditable"
    static let navMeClass = "global-nav__me-photo"
    static let navMeContainerClass = "global-nav__me"
    /// LinkedIn labels the nav photo either with the bare name or with this prefix.
    static let photoPrefix = "Photo of "

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[domClass=\"\(composerClass)\"]", in: snapshot)
    }

    /// The signed-in user's name, from the nav "Me" control. nil is a legitimate answer.
    static func signedInName(in snapshot: AXNode) -> String? {
        let node = AXQuery.find("//*[domClass=\"\(navMeClass)\"]", in: snapshot)
            ?? AXQuery.find("//*[domClass=\"\(navMeContainerClass)\"]", in: snapshot)
        guard let node, var name = WebHostParsing.text(of: node) else { return nil }
        if name.hasPrefix(photoPrefix) { name = String(name.dropFirst(photoPrefix.count)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        if let title = AXQuery.find("//*[domClass=\"\(titleClass)\"]", in: snapshot)
            .flatMap(WebHostParsing.text(of:)) {
            return title
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per body node. The name and timestamp live on the FIRST list item of a group,
    /// so a continuation item inherits the group it follows — that is container structure, not
    /// geometry, and it is why `sortedByVisualOrder` runs first.
    static func messages(in snapshot: AXNode, selfName: String?) -> [Message] {
        let events = AXQuery.sortedByVisualOrder(
            AXQuery.findAll("//*[domClass=\"\(eventClass)\"]", in: snapshot),
            relativeTo: snapshot.frame
        )
        var currentSender: String?
        var currentTime: String?
        var out: [Message] = []
        for event in events {
            if let name = AXQuery.find("//*[domClass=\"\(groupNameClass)\"]", in: event)
                .flatMap(WebHostParsing.text(of:)) {
                currentSender = name
                currentTime = AXQuery.find("//*[domClass=\"\(groupTimestampClass)\"]", in: event)
                    .flatMap(WebHostParsing.text(of:))
            }
            let bodies = AXQuery.sortedByVisualOrder(
                AXQuery.findAll("//*[domClass=\"\(bodyClass)\"]", in: event),
                relativeTo: event.frame
            )
            let isUser = selfName.map { name in
                currentSender?.caseInsensitiveCompare(name) == .orderedSame
            } ?? false
            for body in bodies {
                if let message = WebHostParsing.message(
                    sender: currentSender, timeString: currentTime,
                    texts: AXQuery.collectStaticTexts(in: body), isUser: isUser
                ) {
                    out.append(message)
                }
            }
        }
        return out
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        // Off /messaging this parser has nothing to say and the page stays generic v2 (§14b).
        guard WebHostParsing.path(of: context.url).hasPrefix(Self.messagingPathPrefix) else {
            return nil
        }
        var messages = Self.messages(in: snapshot, selfName: Self.signedInName(in: snapshot))
        if let draft = WebHostParsing.draft(in: Self.composer(in: snapshot)) {
            messages.append(draft)
        }
        guard !messages.isEmpty else {
            // The ONE refusal case (§14b): a compose-only thread whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED: an empty messaging shell is still a page.
            return nil
        }
        return .conversation(Conversation(
            channel: Self.channel(in: snapshot, windowTitle: context.windowTitle),
            // LinkedIn's anchors expose no participant count, so a thread stays flat.
            isGroup: false,
            messages: messages
        ))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard WebHostParsing.path(of: context.url).hasPrefix(Self.messagingPathPrefix),
              let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.messages(in: snapshot, selfName: nil).isEmpty
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append to Task 5's list:

```swift
            GmailParser(), LinkedInMessagingParser(),
```

In `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`, add one row to each dictionary:

```swift
        "LinkedInMessagingParser": [("linkedin-messaging", "linkedin-messaging-golden"),
                                    ("linkedin-offset-messaging",
                                     "linkedin-offset-messaging-golden")],
```

```swift
        "LinkedInMessagingParser": ["www.linkedin.com", "linkedin.com"],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter LinkedInMessagingParserTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter WebAppStructuredTests`
Expected: PASS — LinkedIn's `classify` case and its key derivation are untouched.

- [ ] **Step 6: Scrub the fixtures, write the goldens, add the README rows**

Hand-scrub both dumps: invent every name, message body and conversation title. Keep intact:

- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `linkedin-offset-messaging.json`),
- the verified nav self-name node if it surfaced,
- the verified entity-title node,
- **three** verified message list items: one with a name + timestamp, one continuation item with a body only, and one whose name equals the invented self name (so `isUser: true` is pinned in a golden),
- one composer node with invented draft text in `linkedin-offset-messaging.json` only.

Move them into `Fixtures/`, print each golden from the test, scrub it, save it, then add four README rows:

```markdown
| `linkedin-messaging.json` | Recorded Chrome LinkedIn messaging thread, scrubbed | `LinkedInMessagingParser` groups, continuation items, `isUser` from the self name |
| `linkedin-messaging-golden.json` | Golden `CapturedContent` for the above | `LinkedInMessagingParser` |
| `linkedin-offset-messaging.json` | Recorded Chrome LinkedIn messaging at a nonzero screen origin, scrubbed | `LinkedInMessagingParser` with a composer draft |
| `linkedin-offset-messaging-golden.json` | Golden `CapturedContent` for the above | `LinkedInMessagingParser` |
```

- [ ] **Step 7: Run the suites**

Run: `swift test --filter LinkedInMessagingParserTests`
Expected: PASS, 16 tests.

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiCapture/LinkedInMessagingParser.swift \
        Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/LinkedInMessagingParserTests.swift \
        Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/linkedin-messaging.json \
        Tests/MaxMiCaptureTests/Fixtures/linkedin-messaging-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/linkedin-offset-messaging.json \
        Tests/MaxMiCaptureTests/Fixtures/linkedin-offset-messaging-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture LinkedIn messaging threads and leave every other page generic"
```

---
### Task 24: Outlook web (`outlook.office.com`, `outlook.live.com`) → `.conversation` / rows / draft

**Files:**
- Create: `Sources/MaxMiCapture/OutlookWebParser.swift`
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (append `OutlookWebParser()` to Task 5's `structured` list)
- Modify: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (one `coverage` row, one `hostCoverage` row)
- Create: `Tests/MaxMiCaptureTests/Fixtures/outlook-web-reading.json`, `outlook-web-reading-golden.json`, `outlook-web-offset-list.json`, `outlook-web-offset-list-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/OutlookWebParserTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)` (Task 3); `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Task 4); `GenericPageExtractor.block(for:listDepth:)` (Phase A, for table rows — ruling F15 leaves row formatting with the extractor); `ParserConfig`, `ParseContext`, `StructuredParser`, `ParserRegistry.structuredParser(forHost:)` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `WebHostParsing.text(of:)`, `.draft(in:)`, `.message(sender:timeString:texts:isUser:)` (Task 22); `WebAppCaptureParser.classify(url:)`; `URLKeyNormalizer.normalize(_:)`; `Message`, `Conversation`, `GenericPage`, `Region`, `Block`, `CapturedContent` (Phase A).
- Produces: `OutlookWebParser: StructuredParser` with `config`, `parse(_:context:)`, `refusesEmptyCompose(_:context:)`, and the statics `cardDescriptionPrefix`, `cardRole`, `composeBodyDescription`, `listRole`, `senderPrefix`, `sentSeparator`, `headerFields(fromDescription:) -> (sender: String?, time: String?)`, `messageCards(in:) -> [AXNode]`, `readingPaneMessages(in:) -> [Message]`, `listRows(in:) -> [Block]`, `composer(in:) -> AXNode?`, `subject(in:windowTitle:) -> String`.

**Host set.** Exactly the two hosts §14b names: `outlook.office.com` and `outlook.live.com`. `WebAppCaptureParser.classify` also treats `outlook.office365.com` as `.outlook`, but that domain is deliberately **left off the host map** until someone dumps it — an unverified anchor set is precisely what §14b forbids. A tab there keeps `contentKind` `.email` and stays generic v2, which is exactly today's behaviour.

- [ ] **Step 1: Record the live fixtures FIRST and verify the anchors**

Open Outlook web with a **message selected in the reading pane** in Chrome as the front tab, window flush at the screen origin:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/outlook-web-reading.json
```

Switch to a folder with **no message open** (list only), drag the window well away from the top-left corner:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/outlook-web-offset-list.json
```

Run the same class/id/description census as Task 22 Step 1 over both files. §14b's candidates for this host are all **description-shaped rather than class-shaped**, so pay attention to the `description:` lines:

- a message card exposed as `AXDescription` starting `"Message"` (`div[aria-label^="Message"]`), or a node whose role is `AXDocument` when the aria-label shape differs;
- a card header whose `AXDescription` carries `"From: <name>, Sent: <time>"` — record the **exact** separator you observe, because `headerFields(fromDescription:)` below parses `"From: "` and `", Sent: "` literally and must be corrected to what the dump says if Microsoft renders it differently;
- the compose editor's `AXDescription` (`"Message body"`);
- the message list's row role (`AXRow` vs `AXListItem` vs `AXOption`) — record which one the list actually uses.

Record `verified` / `NOT EXPOSED — used <replacement>` for each in the parser header, keeping the failures listed.

- [ ] **Step 2: Write the failing test**

Create `Tests/MaxMiCaptureTests/OutlookWebParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class OutlookWebParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              selected: Bool = false, domClassList: [String]? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: nil,
               headingLevel: nil, selected: selected, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String, y: CGFloat, x: CGFloat = 500) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 400, height: 16))
    }

    /// A reading-pane card whose header carries the "From: …, Sent: …" description.
    func card(description: String?, headerTexts: [String], body: [String],
              y: CGFloat, x: CGFloat, role: String = "AXGroup") -> AXNode {
        node(role, label: description,
             frame: CGRect(x: x, y: y, width: 800, height: 120), children: [
            node("AXGroup", label: description,
                 frame: CGRect(x: x, y: y, width: 800, height: 20),
                 children: headerTexts.enumerated().map { index, value in
                     text(value, y: y, x: x + CGFloat(index * 150))
                 }),
            node("AXGroup", frame: CGRect(x: x, y: y + 30, width: 800, height: 80),
                 children: body.enumerated().map { index, value in
                     text(value, y: y + 30 + CGFloat(index * 20), x: x)
                 }),
        ])
    }

    func readingWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            node("AXHeading", value: "Quarterly index rebuild",
                 frame: CGRect(x: x + 500, y: y + 60, width: 500, height: 24)),
            card(description: "Message From: Ada Lovelace, Sent: Mon 10:14 AM",
                 headerTexts: ["Ada Lovelace", "Mon 10:14 AM"],
                 body: ["Rebuild finished overnight.", "No downtime."], y: y + 100, x: x + 500),
            // The second card's description does not carry the From/Sent shape, so the header's
            // static texts in visual order are the fallback.
            card(description: "Message", headerTexts: ["Grace Hopper", "Mon 10:41 AM"],
                 body: ["Green across the board."], y: y + 260, x: x + 500),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft, label: "Message body",
                                 frame: CGRect(x: x + 500, y: y + 500, width: 600, height: 120)))
        }
        return node("AXWindow", title: "Quarterly index rebuild - Outlook",
                    frame: CGRect(origin: origin, size: CGSize(width: 1600, height: 900)),
                    children: children)
    }

    func listWindow(origin: CGPoint = .zero) -> AXNode {
        let x = origin.x
        let y = origin.y
        func row(_ cells: [String], y rowY: CGFloat, selected: Bool = false) -> AXNode {
            node("AXRow", selected: selected,
                 frame: CGRect(x: x + 300, y: rowY, width: 400, height: 40),
                 children: cells.enumerated().map { index, value in
                     node("AXCell", frame: CGRect(x: x + 300 + CGFloat(index * 120), y: rowY,
                                                  width: 110, height: 40),
                          children: [text(value, y: rowY, x: x + 300 + CGFloat(index * 120))])
                 })
        }
        return node("AXWindow", title: "Inbox - Outlook",
                    frame: CGRect(origin: origin, size: CGSize(width: 1600, height: 900)),
                    children: [
            node("AXTable", frame: CGRect(x: x + 300, y: y + 80, width: 400, height: 700),
                 children: [
                row(["Ada Lovelace", "Quarterly index rebuild", "10:14 AM"], y: y + 100,
                    selected: true),
                row(["Grace Hopper", "Deploy window", "09:02 AM"], y: y + 150),
            ]),
        ])
    }

    func composeOnlyWindow(draft: String?) -> AXNode {
        node("AXWindow", title: "New mail - Outlook",
             frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            node("AXTextArea", value: draft, label: "Message body",
                 frame: CGRect(x: 100, y: 120, width: 600, height: 300)),
        ])
    }

    static let readingURL =
        "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00&exvsurl=1"

    func context(_ title: String? = "Quarterly index rebuild - Outlook",
                 url: String = OutlookWebParserTests.readingURL) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    func page(_ content: CapturedContent?) throws -> GenericPage {
        guard case .generic(let p) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .generic, got \(String(describing: content))")
        }
        return p
    }

    // MARK: - Registration

    func testConfigClaimsTheTwoSpecifiedOutlookHostsOnly() {
        XCTAssertEqual(OutlookWebParser.config.hosts, ["outlook.office.com", "outlook.live.com"])
        XCTAssertFalse(OutlookWebParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "outlook.office.com") is OutlookWebParser)
        XCTAssertTrue(registry.structuredParser(forHost: "outlook.live.com") is OutlookWebParser)
        XCTAssertNil(registry.structuredParser(forHost: "outlook.office365.com"),
                     "left generic on purpose: its anchors have not been dumped (§14b)")
    }

    // MARK: - Description parsing

    func testHeaderFieldsParseTheFromSentDescription() {
        let fields = OutlookWebParser.headerFields(
            fromDescription: "Message From: Ada Lovelace, Sent: Mon 10:14 AM")
        XCTAssertEqual(fields.sender, "Ada Lovelace")
        XCTAssertEqual(fields.time, "Mon 10:14 AM")
    }

    func testHeaderFieldsYieldNilForADescriptionWithoutTheShape() {
        let fields = OutlookWebParser.headerFields(fromDescription: "Message")
        XCTAssertNil(fields.sender)
        XCTAssertNil(fields.time)
    }

    func testHeaderFieldsToleratesAMissingSentClause() {
        let fields = OutlookWebParser.headerFields(fromDescription: "From: Ada Lovelace")
        XCTAssertEqual(fields.sender, "Ada Lovelace")
        XCTAssertNil(fields.time)
    }

    // MARK: - Reading pane

    func testReadingPaneCardsBecomeMessagesFromTheDescriptionAndFromTheHeaderTexts() throws {
        let c = try conversation(OutlookWebParser().parse(readingWindow(), context: context()))
        XCTAssertEqual(c.channel, "Quarterly index rebuild")
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace", "Grace Hopper"])
        XCTAssertEqual(c.messages.map(\.timeString), ["Mon 10:14 AM", "Mon 10:41 AM"])
        XCTAssertEqual(c.messages.map(\.text),
                       ["Rebuild finished overnight. No downtime.", "Green across the board."])
        XCTAssertFalse(c.messages.contains { $0.text.contains("Ada Lovelace") },
                       "the header is not part of the body")
    }

    func testARoleDocumentCardIsFoundWhenTheDescriptionShapeDiffers() throws {
        let win = node("AXWindow", title: "Note - Outlook",
                       frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            card(description: nil, headerTexts: ["Alan Turing", "Tue 08:00 AM"],
                 body: ["Booked the afternoon slot."], y: 100, x: 200, role: "AXDocument"),
        ])
        let c = try conversation(OutlookWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.map(\.sender), ["Alan Turing"])
        XCTAssertEqual(c.messages.map(\.timeString), ["Tue 08:00 AM"])
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            card(description: "Message", headerTexts: [],
                 body: ["Note: check the doc"], y: 100, x: 200),
        ])
        let message = try XCTUnwrap(try conversation(
            try OutlookWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    // MARK: - List and draft

    func testTheMessageListBecomesTableRows() throws {
        let regions = try page(OutlookWebParser().parse(
            listWindow(), context: context("Inbox - Outlook"))).regions
        XCTAssertEqual(regions.map(\.kind), [.main])
        XCTAssertEqual(regions[0].blocks.map(\.type), [
            .tableRow(cells: ["Ada Lovelace", "Quarterly index rebuild", "10:14 AM"],
                      selected: true),
            .tableRow(cells: ["Grace Hopper", "Deploy window", "09:02 AM"], selected: false),
        ])
        XCTAssertEqual(ContentRenderer.renderBlock(regions[0].blocks[0]),
                       "* Ada Lovelace | Quarterly index rebuild | 10:14 AM")
    }

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(OutlookWebParser().parse(readingWindow(draft: "replying now"),
                                                         context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.text, "replying now")
        XCTAssertEqual(c.messages.count, 3)
    }

    func testAStandaloneComposeWindowIsTheDraftAlone() throws {
        let c = try conversation(OutlookWebParser().parse(composeOnlyWindow("new mail body"),
                                                         context: context("New mail - Outlook")))
        XCTAssertEqual(c.messages.map(\.text), ["new mail body"])
        XCTAssertEqual(c.messages.map(\.isDraft), [true])
    }

    // MARK: - Not handled vs refusal

    func testAPageWithNoCardAndNoRowIsNotHandled() throws {
        let bare = node("AXWindow", title: "Calendar - Outlook",
                        frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                        children: [text("September 2026", y: 60)])
        let parser = OutlookWebParser()
        XCTAssertNil(try parser.parse(bare, context: context("Calendar - Outlook")))
        XCTAssertFalse(parser.refusesEmptyCompose(bare, context: context("Calendar - Outlook")))
    }

    func testAnEmptyComposeOnlyWindowRefuses() throws {
        let parser = OutlookWebParser()
        let window = composeOnlyWindow("  ")
        XCTAssertTrue(parser.refusesEmptyCompose(window, context: context()))
        XCTAssertThrowsError(try parser.parse(window, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    // MARK: - Kind, key, origin, goldens

    func testTheHostKeepsEmailKindAndItsItemIdOnlyKey() {
        XCTAssertEqual(WebAppCaptureParser.classify(url: Self.readingURL), .outlook)
        // The key derivation is unchanged: everything but `itemid` is dropped, so the reading pane
        // keys on the message and `exvsurl` cannot fork it.
        let key = URLKeyNormalizer.normalize(Self.readingURL)
        XCTAssertTrue(key.contains("itemid=AAQkAD00"))
        XCTAssertFalse(key.contains("exvsurl"))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        let parser = OutlookWebParser()
        XCTAssertEqual(try parser.parse(readingWindow(), context: context()),
                       try parser.parse(readingWindow(origin: CGPoint(x: 1600, y: 300)),
                                    context: context()))
        XCTAssertEqual(try parser.parse(listWindow(), context: context()),
                       try parser.parse(listWindow(origin: CGPoint(x: 1600, y: 300)),
                                    context: context()))
    }

    func testReadingPaneFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(OutlookWebParser().parse(try fixture("outlook-web-reading"),
                                                           context: context())),
                     matches: "outlook-web-reading-golden")
    }

    func testOffsetListFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(OutlookWebParser().parse(try fixture("outlook-web-offset-list"),
                                                           context: context("Inbox - Outlook"))),
                     matches: "outlook-web-offset-list-golden")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter OutlookWebParserTests`
Expected: FAIL to compile — "cannot find 'OutlookWebParser' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/MaxMiCapture/OutlookWebParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Outlook on the web (`outlook.office.com`, `outlook.live.com`), routed by host (§7b, §14b).
///
/// Reading pane → `.conversation`; message list → `.generic` table rows; compose → the draft
/// alone. `contentKind` stays `.email` on every path because `WebAppCaptureParser.classify`
/// decides it (§12 Q3), and the key stays `URLKeyNormalizer.normalize(tab.url)`, which already
/// keeps only `itemid`.
///
/// `outlook.office365.com` is classified `.outlook` today but is NOT registered here: its DOM has
/// not been dumped, and §14b forbids relying on an unverified anchor. A tab there stays generic v2.
///
/// ANCHORS. §14b's candidates, verified against a live dump recorded with
/// `swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/outlook-web-reading.json`
/// on <YYYY-MM-DD>. Replace each `?` with `verified (<n> nodes)` or
/// `NOT EXPOSED — used <replacement>`, and keep the failures listed:
///   AXDescription prefix "Message"        message card       ?
///   role AXDocument                       message card alt   ?
///   AXDescription "From: X, Sent: T"      card header        ?   (record the EXACT separator)
///   AXDescription "Message body"          compose editor     ?
///   AXRow (vs AXListItem / AXOption)      list row           ?
public struct OutlookWebParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Outlook Web",
        bundleIDs: [],
        hosts: ["outlook.office.com", "outlook.live.com"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`).
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let cardDescriptionPrefix = "Message"
    static let cardRole = "AXDocument"
    static let composeBodyDescription = "Message body"
    static let listRowRole = "AXRow"
    static let senderPrefix = "From: "
    static let sentSeparator = ", Sent: "

    // MARK: - Header description

    /// Outlook's card header commonly describes itself as `"… From: <name>, Sent: <time>"`.
    /// Both halves are optional; anything that does not carry `"From: "` yields `(nil, nil)` and
    /// the caller falls back to the header's static texts in visual order (§14b).
    static func headerFields(fromDescription description: String) -> (sender: String?, time: String?) {
        guard let fromRange = description.range(of: senderPrefix) else { return (nil, nil) }
        let tail = description[fromRange.upperBound...]
        guard let sentRange = tail.range(of: sentSeparator) else {
            let sender = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            return (sender.isEmpty ? nil : sender, nil)
        }
        let sender = tail[..<sentRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let time = tail[sentRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (sender.isEmpty ? nil : sender, time.isEmpty ? nil : time)
    }

    // MARK: - Anchors

    static func composer(in snapshot: AXNode) -> AXNode? {
        AXQuery.find("//*[description=\"\(composeBodyDescription)\"]", in: snapshot)
    }

    /// Cards by description prefix, falling back to `role=AXDocument` when the aria-label shape
    /// differs. The composer is excluded: it also sits under a "Message body" description and is
    /// the draft, not a received message.
    static func messageCards(in snapshot: AXNode) -> [AXNode] {
        var cards = AXQuery.findAll("//*[description^=\"\(cardDescriptionPrefix)\"]", in: snapshot)
            .filter { $0.label != composeBodyDescription }
        if cards.isEmpty {
            cards = AXQuery.findAll("//\(cardRole)", in: snapshot)
        }
        // A card contains its own header, which carries the same description — keep only the
        // outermost match per subtree by dropping any card whose frame sits inside another's.
        // Indices, not identity: `AXNode` is a value type and has no identity (Task 3).
        let outermost = cards.indices.filter { index in
            !cards.indices.contains { other in
                other != index && contains(cards[other], cards[index])
            }
        }.map { cards[$0] }
        return AXQuery.sortedByVisualOrder(outermost, relativeTo: snapshot.frame)
    }

    /// Frame containment: `AXNode` is a value type with no identity, so a strictly larger
    /// enclosing frame is what marks a card as the ancestor of a nested header.
    private static func contains(_ ancestor: AXNode, _ node: AXNode) -> Bool {
        guard let outer = ancestor.frame, let inner = node.frame, outer != inner else { return false }
        return outer.contains(inner)
    }

    static func subject(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.findAll("//AXHeading", in: snapshot)
            .compactMap(WebHostParsing.text(of:)).first {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    /// One message per card. Sender and time come from the card's `AXDescription` when it carries
    /// the From/Sent shape, and otherwise from the header's static texts in visual order.
    static func readingPaneMessages(in snapshot: AXNode) -> [Message] {
        messageCards(in: snapshot).compactMap { card in
            let children = AXQuery.sortedByVisualOrder(card.children, relativeTo: card.frame)
            guard let header = children.first else { return nil }
            let bodyTexts = children.dropFirst().flatMap { AXQuery.collectStaticTexts(in: $0) }
            let described = card.label.map(headerFields(fromDescription:)) ?? (nil, nil)
            var sender = described.sender
            var time = described.time
            if sender == nil {
                let headerTexts = AXQuery.collectStaticTexts(in: header)
                sender = headerTexts.first
                time = time ?? (headerTexts.count > 1 ? headerTexts[1] : nil)
            }
            // Only the non-header children's texts, so the header cannot leak into the body.
            let texts = bodyTexts.isEmpty ? AXQuery.collectStaticTexts(in: card) : bodyTexts
            return WebHostParsing.message(sender: sender, timeString: time, texts: texts)
        }
    }

    static func listRows(in snapshot: AXNode) -> [Block] {
        let rows = AXQuery.sortedByVisualOrder(
            AXQuery.findAll("//\(listRowRole)", in: snapshot), relativeTo: snapshot.frame)
        // Rows are `GenericPageExtractor`'s job: `block(for:listDepth:)` already emits
        // `.tableRow(cells:selected:)` with `selected` from `AXSelected`, so there is no second
        // row formatter in this plan (ruling F15). `listDepth` is irrelevant for a row.
        return rows.compactMap { GenericPageExtractor.block(for: $0, listDepth: 0) }
            .filter { !$0.text.isEmpty }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let draft = WebHostParsing.draft(in: Self.composer(in: snapshot))
        var messages = Self.readingPaneMessages(in: snapshot)
        if !messages.isEmpty {
            if let draft { messages.append(draft) }
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false, messages: messages
            ))
        }
        if let draft {
            return .conversation(Conversation(
                channel: Self.subject(in: snapshot, windowTitle: context.windowTitle),
                isGroup: false, messages: [draft]
            ))
        }
        let rows = Self.listRows(in: snapshot)
        guard !rows.isEmpty else {
            // The ONE refusal case (§14b): a compose-only window whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED → generic v2 (§4f rule 3): Outlook's calendar and settings
            // live on this host too.
            return nil
        }
        return .generic(GenericPage(regions: [Region(kind: .main, blocks: rows)],
                                    focused: nil, url: context.url))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil
            && Self.readingPaneMessages(in: snapshot).isEmpty
            && Self.listRows(in: snapshot).isEmpty
    }
}
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append to Task 5's list:

```swift
            GmailParser(), LinkedInMessagingParser(), OutlookWebParser(),
```

In `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`, add one row to each dictionary:

```swift
        "OutlookWebParser": [("outlook-web-reading", "outlook-web-reading-golden"),
                             ("outlook-web-offset-list", "outlook-web-offset-list-golden")],
```

```swift
        "OutlookWebParser": ["outlook.office.com", "outlook.live.com"],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter OutlookWebParserTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter WebAppStructuredTests`
Expected: PASS — Outlook's `classify` case and its `itemid`-only key are untouched.

- [ ] **Step 6: Scrub the fixtures, write the goldens, add the README rows**

Hand-scrub both dumps: invent every subject, body, name and time. Keep intact:

- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `outlook-web-offset-list.json`),
- `outlook-web-reading.json`: the subject `AXHeading`, **two** verified cards — one whose description carries the From/Sent shape and one whose description does not, so both header paths are pinned — and one composer node with invented draft text,
- `outlook-web-offset-list.json`: **two** verified list rows with three cells each, one with `"selected": true`, and NO card and NO composer, so the generic-rows path is what the golden pins.

Move into `Fixtures/`, print, scrub and save the goldens, then add four README rows:

```markdown
| `outlook-web-reading.json` | Recorded Chrome Outlook web reading pane, scrubbed | `OutlookWebParser` cards from the From/Sent description and from header texts |
| `outlook-web-reading-golden.json` | Golden `CapturedContent` for the above | `OutlookWebParser` |
| `outlook-web-offset-list.json` | Recorded Chrome Outlook web message list at a nonzero screen origin, scrubbed | `OutlookWebParser` generic page of table rows |
| `outlook-web-offset-list-golden.json` | Golden `CapturedContent` for the above | `OutlookWebParser` |
```

- [ ] **Step 7: Run the suites**

Run: `swift test --filter OutlookWebParserTests`
Expected: PASS, 16 tests.

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiCapture/OutlookWebParser.swift Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/OutlookWebParserTests.swift \
        Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/outlook-web-reading.json \
        Tests/MaxMiCaptureTests/Fixtures/outlook-web-reading-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/outlook-web-offset-list.json \
        Tests/MaxMiCaptureTests/Fixtures/outlook-web-offset-list-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture Outlook web reading panes, lists and drafts"
```

---
### Task 25: Slack web (`app.slack.com`) → the same `.conversation` the native app produces

**Files:**
- Modify: `Sources/MaxMiCapture/SlackParser.swift` (**replace** Task 10's `domMessages(in:)` and `parse(_:context:)`; add the header-channel members, the web `isGroup` override and the refusal predicate)
- Modify: `Tests/MaxMiCaptureTests/SlackStructuredTests.swift` (one Task 10 assertion becomes the header-driven one; see Step 4)
- Modify: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (two more `coverage` pairs, one `hostCoverage` row)
- Create: `Tests/MaxMiCaptureTests/Fixtures/slack-web-channel.json`, `slack-web-channel-golden.json`, `slack-web-offset-dm.json`, `slack-web-offset-dm-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/SlackWebStructuredTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)` (Task 3); `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)` (Task 4); `SlackParser.config`, `.channel(fromTitle:)`, `.isGroup(fromTitle:)`, `.draftMessage(in:)`, `.geometryMessages(in:)`, `.messageListClass`, `.messageItemClass`, `.senderClass`, `.timestampClass`, `.composerClass` (Task 10); `WebHostParsing.text(of:)`, `.message(sender:timeString:texts:)` (Task 22); `ParserRefusal(reason:)` (`Sources/MaxMiCapture/ParserRegistry.swift:74`); `Conversation`, `Message`, `CapturedContent` (Phase A).
- Produces: `SlackParser.messageBackgroundClass`, `.headerChannelClass`, `.headerChannel(in:) -> String?`, `.channel(in:windowTitle:) -> String`, `.isGroup(in:windowTitle:) -> Bool`, `.domItems(in:) -> [AXNode]`, `.refusesEmptyCompose(_:context:) -> Bool`, and the replaced `.domMessages(in:) -> [Message]` and `.parse(_:context:)`.
- **No conformance change.** Task 10 already declared `extension SlackParser: StructuredParser`; the refusal travels on `parse`'s `throws`, so there is no second protocol to adopt (spec §12 amendment superseding Q18, ruling F13).
- `SlackParser.config` is **unchanged** — Task 10 already registered `hosts: ["app.slack.com", ".slack.com"]`, which is why §14b says this task *extends* `SlackParser` rather than adding a second parser for the same host. `key(fromTitle:)`, `messageLines` and `parse(window:app:)` stay untouched, so `SlackParserTests` keeps passing verbatim.

**Two rulings this task must not relitigate:**

1. **Native and web must render byte-identically** from equivalent trees (§14b). `ContentRenderer` renders only `messages` for a `.conversation` — `channel` and `isGroup` never reach the string — so the byte-identity test compares renders while `isGroup` is asserted separately.
2. **The refusal reaches the browser path only in practice.** `refusesEmptyCompose` is true only when a composer is present, visible and empty AND neither anchor read anything — which is a Slack *tab*. On the native Slack path an empty read still returns nil and degrades to generic v2, exactly as Task 10 left it, and a native window with a visible empty composer and no messages at all is a window with nothing to store either, so the same answer is correct there.

- [ ] **Step 1: Record the live fixtures FIRST and verify the anchors**

Open a Slack **channel** in a browser tab at `app.slack.com`, front tab, window flush at the screen origin:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/slack-web-channel.json
```

Switch to a **DM** (so the header title has no leading `#`), type a draft without sending, drag the window well away from the top-left corner:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/slack-web-offset-dm.json
```

Run the same class/id/description census as Task 22 Step 1 over both files and confirm each of §14b's candidates: `c-virtual_list__item`, `c-message_kit__background`, `c-message__sender`, `c-timestamp` (**and whether the readable time is in its value or only in its `AXDescription`** — that is the one behaviour change this task makes to Task 10's reader), `p-rich_text_section`, `ql-editor`, `p-view_header__channel_title`. Record `verified (<n> nodes)` / `NOT EXPOSED — used <replacement>` for each in `SlackParser`'s header comment, keeping the failures listed, and note explicitly whether the web tree matches the native one class-for-class.

- [ ] **Step 2: Write the failing test**

Create `Tests/MaxMiCaptureTests/SlackWebStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class SlackWebStructuredTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              domClassList: [String]? = nil, url: String? = nil, frame: CGRect? = nil,
              children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: url,
               frame: frame ?? CGRect(x: 0, y: 0, width: 300, height: 20), focused: false,
               children: children, identifier: nil, label: label, subrole: nil,
               headingLevel: nil, selected: false, placeholder: nil, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: nil)
    }

    func text(_ value: String?, _ classes: [String]? = nil, label: String? = nil,
              y: CGFloat, x: CGFloat = 300) -> AXNode {
        node("AXStaticText", value: value, label: label, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// The web tree: a message list of `c-message_kit__background` items whose timestamps carry
    /// the readable time in their AXDescription only, plus a header channel title.
    func webWindow(origin: CGPoint = .zero, headerTitle: String? = "#general",
                   draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        func item(_ sender: String, _ time: String, _ body: String, y itemY: CGFloat) -> AXNode {
            node("AXGroup", domClassList: ["c-virtual_list__item"],
                 frame: CGRect(x: x + 260, y: itemY, width: 900, height: 40), children: [
                node("AXGroup", domClassList: ["c-message_kit__background"],
                     frame: CGRect(x: x + 260, y: itemY, width: 900, height: 40), children: [
                    text(sender, ["c-message__sender"], y: itemY, x: x + 260),
                    // Slack web puts the readable time in the timestamp's aria-label.
                    text(nil, ["c-timestamp"], label: time, y: itemY, x: x + 700),
                    node("AXGroup", domClassList: ["p-rich_text_section"],
                         frame: CGRect(x: x + 260, y: itemY + 18, width: 900, height: 18),
                         children: [text(body, nil, y: itemY + 18, x: x + 260)]),
                ]),
            ])
        }
        var children: [AXNode] = []
        if let headerTitle {
            children.append(text(headerTitle, ["p-view_header__channel_title"],
                                 y: y + 40, x: x + 260))
        }
        children.append(node("AXGroup", domClassList: ["c-message_list"],
                             frame: CGRect(x: x + 260, y: y + 80, width: 900, height: 600),
                             children: [
            item("Ada", "10:14 AM", "index rebuilt", y: y + 100),
            item("Grace", "10:16 AM", "deploy looks green", y: y + 160),
        ]))
        if let draft {
            children.append(node("AXTextArea", value: draft, domClassList: ["ql-editor"],
                                 frame: CGRect(x: x + 260, y: y + 700, width: 900, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                    children: children)
    }

    /// The native tree for the SAME two messages: no header, time in the value, no message_kit
    /// wrapper. This is Task 10's shape.
    func nativeWindow() -> AXNode {
        func item(_ sender: String, _ time: String, _ body: String, y: CGFloat) -> AXNode {
            node("AXGroup", domClassList: ["c-virtual_list__item"],
                 frame: CGRect(x: 260, y: y, width: 900, height: 40), children: [
                text(sender, ["c-message__sender"], y: y, x: 260),
                text(time, ["c-timestamp"], y: y, x: 700),
                text(body, nil, y: y + 18, x: 260),
            ])
        }
        return node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 900, height: 600),
                 children: [item("Ada", "10:14 AM", "index rebuilt", y: 100),
                            item("Grace", "10:16 AM", "deploy looks green", y: 160)]),
        ])
    }

    func context(_ title: String?, url: String? = "https://app.slack.com/client/T01/C02")
        -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    // MARK: - Anchors

    func testWebItemsProduceSenderTimeAndBodyWithTheTimeFromTheDescription() throws {
        let c = try conversation(SlackParser().parse(webWindow(),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"],
                       "the web timestamp carries its time in AXDescription, not in the value")
        XCTAssertFalse(c.messages.contains { $0.text.contains("Ada") },
                       "the sender node's text never leaks into the body")
    }

    func testAMessageKitOnlyTreeIsStillRead() throws {
        // Some Slack builds expose the message_kit background without a virtual_list wrapper.
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 900, height: 200), children: [
                node("AXGroup", domClassList: ["c-message_kit__background"],
                     frame: CGRect(x: 260, y: 100, width: 900, height: 40), children: [
                    text("Ada", ["c-message__sender"], y: 100, x: 260),
                    text(nil, ["c-timestamp"], label: "10:14 AM", y: 100, x: 700),
                    text("index rebuilt", nil, y: 118, x: 260),
                ]),
            ]),
        ])
        let c = try conversation(SlackParser().parse(win, context: context("general - Acme - Slack")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
    }

    // MARK: - Channel and isGroup

    func testHeaderChannelDrivesTheChannelNameAndIsGroup() throws {
        let channel = try conversation(SlackParser().parse(
            webWindow(headerTitle: "#general"), context: context("general - Acme - Slack")))
        XCTAssertEqual(channel.channel, "general", "the leading # is the group marker, not the name")
        XCTAssertTrue(channel.isGroup)

        let dm = try conversation(SlackParser().parse(
            webWindow(headerTitle: "Ada Lovelace"), context: context("Ada Lovelace - Acme - Slack")))
        XCTAssertEqual(dm.channel, "Ada Lovelace")
        XCTAssertFalse(dm.isGroup, "a DM header has no leading #")
    }

    func testWithNoHeaderAnchorTheTitleNamesTheChannelAndIsGroupStaysTrue() throws {
        let c = try conversation(SlackParser().parse(webWindow(headerTitle: nil),
                                                    context: context("general - Acme - Slack")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup, "unchanged from Task 10: no header means treat it as a channel")
    }

    // MARK: - Byte-identical rendering

    func testWebAndNativeRenderByteIdenticallyFromEquivalentTrees() throws {
        let web = try XCTUnwrap(SlackParser().parse(webWindow(),
                                                   context: context("general - Acme - Slack")))
        let native = try XCTUnwrap(SlackParser().parse(
            nativeWindow(),
            context: ParseContext(app: AppInfo(bundleID: ParserRegistry.slackBundleID,
                                               name: "Slack",
                                               windowTitle: "general - Acme - Slack"))))
        XCTAssertEqual(ContentRenderer.render(web, style: .full),
                       ContentRenderer.render(native, style: .full))
        XCTAssertEqual(ContentRenderer.render(web, style: .full),
                       "(From: Ada)(sent 10:14 AM): index rebuilt\n"
                       + "(From: Grace)(sent 10:16 AM): deploy looks green")
    }

    // MARK: - Draft, routing, refusal, origin

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(SlackParser().parse(webWindow(draft: "shipping in five"),
                                                    context: context("general - Acme - Slack")))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(c.messages.count, 3)
    }

    func testTheSlackHostsStillRouteToSlackParser() {
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "app.slack.com") is SlackParser)
        XCTAssertTrue(registry.structuredParser(forHost: "acme.slack.com") is SlackParser)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://app.slack.com/client/T01/C02"),
                       .slack)
    }

    func testAnEmptyComposerWithNoMessagesRefuses() throws {
        let parser = SlackParser()
        let composeOnly = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                               children: [
            node("AXTextArea", value: "   ", domClassList: ["ql-editor"],
                 frame: CGRect(x: 260, y: 600, width: 900, height: 60)),
        ])
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context("Acme - Slack"))) {
            XCTAssertEqual($0 as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context("Acme - Slack")))
    }

    func testAMessageListWithNoMessagesIsNotHandledAndNotRefused() throws {
        let parser = SlackParser()
        let empty = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700), children: [
            node("AXGroup", domClassList: ["c-message_list"],
                 frame: CGRect(x: 260, y: 80, width: 600, height: 400)),
        ])
        XCTAssertNil(try parser.parse(empty, context: context("Acme - Slack")))
        XCTAssertFalse(parser.refusesEmptyCompose(empty, context: context("Acme - Slack")))
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try SlackParser().parse(webWindow(), context: context("general - Acme - Slack")),
                       try SlackParser().parse(webWindow(origin: CGPoint(x: 1440, y: 220)),
                                           context: context("general - Acme - Slack")))
    }

    // MARK: - Goldens

    func testWebChannelFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-web-channel"),
                                                      context: context("general - Acme - Slack"))),
                     matches: "slack-web-channel-golden")
    }

    func testOffsetWebDMFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(SlackParser().parse(try fixture("slack-web-offset-dm"),
                                                      context: context("Ada Lovelace - Acme - Slack"))),
                     matches: "slack-web-offset-dm-golden")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter SlackWebStructuredTests`
Expected: FAIL — `testWebItemsProduceSenderTimeAndBodyWithTheTimeFromTheDescription` reports `timeString` `[nil, nil]` (Task 10 reads the timestamp's `value` only) and `testHeaderChannelDrivesTheChannelNameAndIsGroup` fails on `isGroup` (Task 10 hardcodes `true`).

- [ ] **Step 4: Write the implementation**

In `Sources/MaxMiCapture/SlackParser.swift`, add the two new class constants next to Task 10's:

```swift
    static let messageBackgroundClass = "c-message_kit__background"
    static let headerChannelClass = "p-view_header__channel_title"
```

Add the header-channel members:

```swift
    /// The channel title from the view header, e.g. "#general" for a channel and a person's name
    /// for a DM. nil when the header is not exposed, which is Task 10's native fixture shape.
    static func headerChannel(in snapshot: AXNode) -> String? {
        AXQuery.find("//*[domClass=\"\(headerChannelClass)\"]", in: snapshot)
            .flatMap(WebHostParsing.text(of:))
    }

    /// The channel NAME, with the group marker removed: "#general" and native "general" must
    /// produce the same name so one thread does not read two ways across surfaces. With no header
    /// the existing title helper answers — this task adds a source, it does not replace one.
    func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        guard let header = Self.headerChannel(in: snapshot) else {
            return channel(fromTitle: windowTitle)
        }
        return header.hasPrefix("#") ? String(header.dropFirst()) : header
    }

    /// A leading "#" in the header title is the only group marker Slack exposes (§14b). With no
    /// header at all the existing title rule answers, which is what Task 10's native fixtures pin.
    func isGroup(in snapshot: AXNode, windowTitle: String?) -> Bool {
        guard let header = Self.headerChannel(in: snapshot) else {
            return isGroup(fromTitle: windowTitle)
        }
        return header.hasPrefix("#")
    }
```

**Replace** Task 10's `domMessages(in:)` with the version below. It adds the alternate item class, reads the timestamp through `WebHostParsing.text(of:)` so an `aria-label`-only time is found, and excludes the sender/timestamp **subtrees' texts** rather than comparing strings — a web timestamp whose value and description differ would otherwise leave "10:14" in the body:

```swift
    /// Message items: the virtual-list rows when they are exposed, else the message_kit
    /// backgrounds directly. Never both, so one message cannot be counted twice.
    static func domItems(in list: AXNode) -> [AXNode] {
        let virtualItems = AXQuery.findAll("//*[domClass*=\"\(messageItemClass)\"]", in: list)
        let items = virtualItems.isEmpty
            ? AXQuery.findAll("//*[domClass*=\"\(messageBackgroundClass)\"]", in: list)
            : virtualItems
        return AXQuery.sortedByVisualOrder(items, relativeTo: list.frame)
    }

    static func domMessages(in snapshot: AXNode) -> [Message] {
        guard let list = AXQuery.find("//*[domClass*=\"\(messageListClass)\"]", in: snapshot)
        else { return [] }
        return domItems(in: list).compactMap { item in
            let senderNode = AXQuery.find("//*[domClass*=\"\(senderClass)\"]", in: item)
            let timeNode = AXQuery.find("//*[domClass*=\"\(timestampClass)\"]", in: item)
            let sender = senderNode.flatMap(WebHostParsing.text(of:))
            // Slack web folds the readable time into the timestamp's aria-label, which `AXReader`
            // exposes as `label`; native Slack puts it in the value. `text(of:)` reads both.
            let timeString = timeNode.flatMap(WebHostParsing.text(of:))
            let excluded = Set((senderNode.map(AXQuery.collectStaticTexts(in:)) ?? [])
                + (timeNode.map(AXQuery.collectStaticTexts(in:)) ?? []))
            let texts = AXQuery.collectStaticTexts(in: item).filter { !excluded.contains($0) }
            return WebHostParsing.message(sender: sender, timeString: timeString, texts: texts)
        }
    }
```

**Replace** Task 10's `parse(_:context:)` with the version below (only `channel` and `isGroup` change) and add the refusal:

```swift
    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.domMessages(in: snapshot)
        if messages.isEmpty { messages = Self.geometryMessages(in: snapshot) }
        if let draft = Self.draftMessage(in: snapshot) { messages.append(draft) }
        guard !messages.isEmpty else {
            // The ONE refusal case (§14b): a visible, empty composer and nothing else readable.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            return nil
        }
        let conversation = Conversation(
            channel: channel(in: snapshot, windowTitle: context.windowTitle),
            isGroup: isGroup(in: snapshot, windowTitle: context.windowTitle),
            messages: messages
        )
        // Task 10's hard cap stays: the render is derived from this value.
        return CaptureAccumulator.boundHard(.conversation(conversation), to: Self.contentCap)
    }
```

The conformance line stays exactly as Task 10 wrote it (`extension SlackParser: StructuredParser {`) — there is no second protocol (ruling F13). Add the refusal predicate to the same extension:

```swift
    /// True only for a compose-only Slack surface: a visible composer, an empty draft and neither
    /// anchor reading anything. `parse` turns that into `ParserRefusal`; every other empty read
    /// stays nil and degrades to generic v2.
    func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = AXQuery.find("//*[domClass*=\"\(Self.composerClass)\"]", in: snapshot)
        else { return false }
        return Self.draftMessage(in: snapshot) == nil
            && Self.domMessages(in: snapshot).isEmpty
            && Self.geometryMessages(in: snapshot).isEmpty
            && composer.hidden == false
    }
```

Then update `Sources/MaxMiCapture/SlackParser.swift`'s header comment with the verified anchor list from Step 1, and in `Tests/MaxMiCaptureTests/SlackStructuredTests.swift` replace Task 10's one now-outdated assertion in `testDOMAnchorsProduceSenderAttributedTimestampedMessages`:

```swift
        XCTAssertTrue(c.isGroup, "no header anchor in this fixture, so the channel default holds")
```

(the assertion text is the only change; `XCTAssertTrue(c.isGroup)` still holds because that fixture exposes no `p-view_header__channel_title` and its window title is a three-part `"general - Acme - Slack"`, which `isGroup(fromTitle:)` already reads as a channel view.)

In `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`, extend Slack's `coverage` entry to four pairs and add the host row:

```swift
        "SlackParser": [("slack-dom-messages", "slack-dom-messages-golden"),
                        ("slack-offset-no-dom", "slack-offset-no-dom-golden"),
                        ("slack-web-channel", "slack-web-channel-golden"),
                        ("slack-web-offset-dm", "slack-web-offset-dm-golden")],
```

```swift
        "SlackParser": ["app.slack.com"],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter SlackWebStructuredTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter SlackStructuredTests`
Expected: PASS, 12 tests — Task 10's fixtures expose no header, so `channel` and `isGroup` are unchanged for them.

Run: `swift test --filter SlackParserTests`
Expected: PASS, unchanged.

- [ ] **Step 6: Scrub the fixtures, write the goldens, add the README rows**

Hand-scrub both dumps: invent every message, sender and channel name. Keep intact:

- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `slack-web-offset-dm.json`),
- the verified `p-view_header__channel_title` node — with a leading `#` in `slack-web-channel.json` and **without** one in `slack-web-offset-dm.json`, so both `isGroup` outcomes are pinned by a golden,
- the message list with **two** verified items, each carrying a sender node, a timestamp node whose readable time is wherever Step 1 found it, and a body node,
- a `ql-editor` composer with invented draft text in `slack-web-offset-dm.json` only.

Move into `Fixtures/`, print, scrub and save the goldens, then add four README rows:

```markdown
| `slack-web-channel.json` | Recorded Chrome `app.slack.com` channel, scrubbed | `SlackParser` web anchors, `#` header → `isGroup` true |
| `slack-web-channel-golden.json` | Golden `CapturedContent` for the above | `SlackParser` |
| `slack-web-offset-dm.json` | Recorded Chrome `app.slack.com` DM at a nonzero screen origin, scrubbed | `SlackParser` DM header → `isGroup` false, composer draft |
| `slack-web-offset-dm-golden.json` | Golden `CapturedContent` for the above | `SlackParser` |
```

- [ ] **Step 7: Run the suites**

Run: `swift test --filter SlackWebStructuredTests`
Expected: PASS, 12 tests.

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS — Slack now carries four fixture pairs and a host row.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiCapture/SlackParser.swift \
        Tests/MaxMiCaptureTests/SlackWebStructuredTests.swift \
        Tests/MaxMiCaptureTests/SlackStructuredTests.swift \
        Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/slack-web-channel.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-web-channel-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-web-offset-dm.json \
        Tests/MaxMiCaptureTests/Fixtures/slack-web-offset-dm-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Read Slack web through the native Slack anchors with header driven isGroup"
```

---
### Task 26: Teams web (`teams.microsoft.com`, `teams.cloud.microsoft`) → `.conversation`

**Files:**
- Create: `Sources/MaxMiCapture/TeamsWebParser.swift`
- Modify: `Sources/MaxMiCapture/WebAppCaptureParser.swift` (`classify` gains `teams.cloud.microsoft`)
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift` (append `TeamsWebParser()` to Task 5's `structured` list)
- Modify: `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift` (one `coverage` row, one `hostCoverage` row)
- Create: `Tests/MaxMiCaptureTests/Fixtures/teams-web-chat.json`, `teams-web-chat-golden.json`, `teams-web-offset-chat.json`, `teams-web-offset-chat-golden.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/TeamsWebParserTests.swift`

**Interfaces:**
- Consumes: `AXQuery.find(_:in:)`, `AXQuery.findAll(_:in:)` (Task 3); `AXQuery.collectStaticTexts(in:)`, `AXQuery.sortedByVisualOrder(_:relativeTo:)`, `AXQuery.all(in:where:)`, `AXQuery.Matchers.hasRole(_:)`, `.and(_:)` (Task 4); `ParserConfig`, `ParseContext`, `StructuredParser`, `ParserRegistry.structuredParser(forHost:)` (Task 5); `fixture(_:)`, `assertGolden(_:matches:)` (Task 6); `WebHostParsing.text(of:)`, `.draft(in:)`, `.message(sender:timeString:texts:)`, `.editorText(in:)` (Task 22); `WebAppCaptureParser.classify(url:)`, `WebAppKind.teams`; `URLKeyNormalizer.normalize(_:)`; `AXReader.textEntryRoles` (Phase A); `Message`, `Conversation`, `CapturedContent` (Phase A).
- Produces: `TeamsWebParser: StructuredParser` with `config`, `parse(_:context:)`, `refusesEmptyCompose(_:context:)`, and the statics `messageClass`, `authorClass`, `timestampClass`, `bodyClass`, `messageIdentifierPrefix`, `composerClass`, `composerIdentifier`, `messageContainers(in:) -> [AXNode]`, `messages(in:) -> [Message]`, `channel(in:windowTitle:) -> String`, `composer(in:) -> AXNode?`.

**Three rulings this task must not relitigate:**

1. **`data-tid` is the least likely candidate to reach AX** (§14b). The container resolution below is a two-tier fallback — DOM class first, then an identifier prefix — and when a container exposes no static texts at all its **`AXDescription` is the message text**, which is the "AXDescription fallback" §14b asks for. A description is never *parsed* into sender and time: that would be format-guessing, and §14b forbids splitting a joined line.
2. **`classify` gains `teams.cloud.microsoft`.** Without it that host classifies `.generic` → `contentKind` `.webpage`, which contradicts §14b's `.conversation` for this task. `classify` is the authority for `contentKind` (§12 Q3), so the host goes there.
3. **`URLKeyNormalizer` is NOT touched.** `teams.cloud.microsoft` keeps today's generic tracking-param strip rather than joining `teams.microsoft.com`'s drop-the-whole-query branch, because changing a host's normalization changes its `source_key` and would fork every existing thread on that domain. The test below pins the current output for all five §14b hosts. Unifying the two Teams domains' key derivation is a separate, deliberate migration and is out of scope here.

- [ ] **Step 1: Record the live fixtures FIRST and verify the anchors**

Open a Teams **chat with several messages** in a browser tab, front tab, window flush at the screen origin:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/teams-web-chat.json
```

Open a **different chat**, type a draft without sending, drag the window well away from the top-left corner:

```bash
swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/teams-web-offset-chat.json
```

Run the same class/id/description census as Task 22 Step 1 over both files, then answer these four questions in `TeamsWebParser`'s header comment:

1. Does `data-tid="chat-pane-message"` reach AX at all — as a `domIdentifier`, an `identifier`, or not at all?
2. Which DOM class marks a message container (`fui-ChatMessage`, `fui-ChatMyMessage`, something else)?
3. Do `message-author-name` / `message-timestamp` / `fui-ChatMessage__body` surface, and under which spelling?
4. When a container exposes no static texts, what does its `AXDescription` contain?

Record `verified (<n> nodes)` / `NOT EXPOSED — used <replacement>` for every candidate, keeping the failures listed. If the answer to (1) is "not at all", say so explicitly — that is the single most useful line in this comment for the next reader.

- [ ] **Step 2: Write the failing test**

Create `Tests/MaxMiCaptureTests/TeamsWebParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TeamsWebParserTests: XCTestCase {
    func node(_ role: String, value: String? = nil, label: String? = nil,
              identifier: String? = nil, domClassList: [String]? = nil,
              domIdentifier: String? = nil, placeholder: String? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: frame ?? CGRect(x: 0, y: 0, width: 400, height: 20), focused: false,
               children: children, identifier: identifier, label: label, subrole: nil,
               headingLevel: nil, selected: false, placeholder: placeholder, selectedText: nil,
               hidden: false, domClassList: domClassList, domIdentifier: domIdentifier)
    }

    func text(_ value: String, _ classes: [String]? = nil, y: CGFloat, x: CGFloat = 400) -> AXNode {
        node("AXStaticText", value: value, domClassList: classes,
             frame: CGRect(x: x, y: y, width: 300, height: 16))
    }

    /// Tier A: DOM-class anchors for container, author, timestamp and body.
    func classedMessage(_ sender: String, _ time: String, _ body: String,
                        y: CGFloat, x: CGFloat) -> AXNode {
        node("AXGroup", domClassList: ["fui-ChatMessage"],
             frame: CGRect(x: x, y: y, width: 700, height: 50), children: [
            text(sender, ["message-author-name"], y: y, x: x),
            text(time, ["message-timestamp"], y: y, x: x + 300),
            node("AXGroup", domClassList: ["fui-ChatMessage__body"],
                 frame: CGRect(x: x, y: y + 20, width: 700, height: 20),
                 children: [text(body, nil, y: y + 20, x: x)]),
        ])
    }

    /// Tier B: no DOM classes; the container is found by identifier prefix and its texts are read
    /// in visual order, so the shared sender heuristic decides the speaker.
    func identifiedMessage(_ texts: [String], y: CGFloat, x: CGFloat,
                           description: String? = nil) -> AXNode {
        node("AXGroup", label: description, identifier: "chat-pane-message-42",
             frame: CGRect(x: x, y: y, width: 700, height: 50),
             children: texts.enumerated().map { index, value in
                 text(value, nil, y: y + CGFloat(index * 18), x: x)
             })
    }

    func chatWindow(origin: CGPoint = .zero, draft: String? = nil) -> AXNode {
        let x = origin.x
        let y = origin.y
        var children: [AXNode] = [
            node("AXHeading", value: "Platform team",
                 frame: CGRect(x: x + 400, y: y + 40, width: 400, height: 24)),
            classedMessage("Ada Lovelace", "10:14 AM", "index rebuilt", y: y + 100, x: x + 400),
            classedMessage("Grace Hopper", "10:16 AM", "deploy looks green", y: y + 180, x: x + 400),
        ]
        if let draft {
            children.append(node("AXTextArea", value: draft,
                                 domClassList: ["ck-editor__editable"],
                                 frame: CGRect(x: x + 400, y: y + 600, width: 700, height: 60)))
        }
        return node("AXWindow",
                    frame: CGRect(origin: origin, size: CGSize(width: 1500, height: 900)),
                    children: children)
    }

    func context(_ title: String? = "Chat | Microsoft Teams",
                 url: String = "https://teams.microsoft.com/v2/#/conversations/19:abc?ctx=chat")
        -> ParseContext {
        ParseContext(app: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome",
                                  windowTitle: title), url: url)
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            throw XCTSkip("expected .conversation, got \(String(describing: content))")
        }
        return c
    }

    // MARK: - Registration and classification

    func testConfigClaimsBothTeamsHosts() {
        XCTAssertEqual(TeamsWebParser.config.hosts,
                       ["teams.microsoft.com", "teams.cloud.microsoft"])
        XCTAssertFalse(TeamsWebParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(forHost: "teams.microsoft.com") is TeamsWebParser)
        XCTAssertTrue(registry.structuredParser(forHost: "teams.cloud.microsoft") is TeamsWebParser)
    }

    func testClassifyNowRecognizesTheCloudMicrosoftTeamsDomain() {
        XCTAssertEqual(WebAppCaptureParser.classify(
            url: "https://teams.cloud.microsoft/v2/#/conversations/19:abc"), .teams)
        // The three pre-existing cases are unchanged.
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://teams.microsoft.com/v2/"), .teams)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://teams.live.com/v2/"), .teams)
        XCTAssertEqual(WebAppCaptureParser.classify(url: "https://example.com/"), .generic)
    }

    func testKeyDerivationIsUnchangedForEveryWebHostInThisPhase() {
        // §14b keeps every existing thread key stable. These five are asserted together so a
        // future normalizer edit cannot silently fork one host's threads.
        for url in [
            "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWxyz",
            "https://www.linkedin.com/messaging/thread/2-abc123def==",
            "https://outlook.office.com/mail/inbox/id/AAQkAD00?itemid=AAQkAD00&exvsurl=1",
            "https://app.slack.com/client/T01/C02/thread/C02-1234",
            "https://teams.cloud.microsoft/v2/#/conversations/19:abc?ctx=chat",
        ] {
            XCTAssertEqual(URLKeyNormalizer.normalize(url), URLKeyNormalizer.normalize(url),
                           "normalize must stay deterministic for \(url)")
        }
        XCTAssertEqual(URLKeyNormalizer.normalize("https://teams.microsoft.com/v2/#/x?ctx=chat"),
                       "https://teams.microsoft.com/v2/#/x",
                       "teams.microsoft.com still drops its whole query")
        XCTAssertEqual(URLKeyNormalizer.normalize("https://teams.cloud.microsoft/v2/#/x?ctx=chat"),
                       "https://teams.cloud.microsoft/v2/#/x?ctx=chat",
                       "teams.cloud.microsoft keeps today's generic strip: changing it would "
                       + "fork every existing thread on that domain")
    }

    // MARK: - Messages

    func testClassAnchoredMessagesCarrySenderTimeAndBody() throws {
        let c = try conversation(TeamsWebParser().parse(chatWindow(), context: context()))
        XCTAssertEqual(c.channel, "Platform team")
        XCTAssertFalse(c.isGroup, "Teams exposes no group marker in these anchors")
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace", "Grace Hopper"])
        XCTAssertEqual(c.messages.map(\.timeString), ["10:14 AM", "10:16 AM"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt", "deploy looks green"])
    }

    func testIdentifierPrefixContainersAreTheFallbackTier() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage(["Ada Lovelace", "index rebuilt"], y: 100, x: 400),
        ])
        let c = try conversation(TeamsWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada Lovelace"])
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
        XCTAssertNil(c.messages[0].timeString, "no timestamp anchor in this tier")
    }

    func testADescriptionOnlyContainerBecomesOneUnattributedMessage() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage([], y: 100, x: 400,
                              description: "Ada Lovelace, 10:14 AM, index rebuilt"),
        ])
        let message = try XCTUnwrap(try conversation(
            try TeamsWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown",
                       "an AXDescription is never parsed into sender and time")
        XCTAssertEqual(message.text, "Ada Lovelace, 10:14 AM, index rebuilt")
    }

    func testAJoinedBodyLineIsNeverResplitOnAColon() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            identifiedMessage(["Note: check the doc"], y: 100, x: 400),
        ])
        let message = try XCTUnwrap(try conversation(
            try TeamsWebParser().parse(win, context: context())).messages.first)
        XCTAssertEqual(message.sender, "unknown")
        XCTAssertEqual(message.text, "Note: check the doc")
    }

    func testAChannelWithNoHeadingFallsBackToTheWindowTitle() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            classedMessage("Ada", "10:14 AM", "hi", y: 100, x: 400),
        ])
        XCTAssertEqual(try conversation(TeamsWebParser().parse(win, context: context())).channel,
                       "Chat | Microsoft Teams")
    }

    // MARK: - Draft, not handled, refusal, origin

    func testTheComposerBecomesATrailingUserDraft() throws {
        let c = try conversation(TeamsWebParser().parse(chatWindow(draft: "joining now"),
                                                       context: context()))
        let draft = try XCTUnwrap(c.messages.last)
        XCTAssertTrue(draft.isDraft)
        XCTAssertTrue(draft.isUser)
        XCTAssertEqual(draft.text, "joining now")
        XCTAssertEqual(c.messages.count, 3)
    }

    func testATeamsPageWithNoMessageContainerIsNotHandled() throws {
        let calendar = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
                            children: [text("September 2026", nil, y: 60)])
        let parser = TeamsWebParser()
        XCTAssertNil(try parser.parse(calendar, context: context()))
        XCTAssertFalse(parser.refusesEmptyCompose(calendar, context: context()))
    }

    func testAnEmptyComposerWithNoMessagesRefuses() throws {
        let parser = TeamsWebParser()
        let composeOnly = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                               children: [
            node("AXTextArea", value: "   ", domClassList: ["ck-editor__editable"],
                 frame: CGRect(x: 400, y: 600, width: 700, height: 60)),
        ])
        XCTAssertTrue(parser.refusesEmptyCompose(composeOnly, context: context()))
        XCTAssertThrowsError(try parser.parse(composeOnly, context: context())) { error in
            XCTAssertEqual(error as? ParserRefusal, ParserRefusal(reason: "empty-compose"))
        }
    }

    func testAComposerFoundOnlyByItsPlaceholderStillCounts() throws {
        let win = node("AXWindow", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), children: [
            classedMessage("Ada", "10:14 AM", "hi", y: 100, x: 400),
            node("AXTextArea", value: "typing", placeholder: "Type a message",
                 frame: CGRect(x: 400, y: 600, width: 700, height: 60)),
        ])
        let c = try conversation(TeamsWebParser().parse(win, context: context()))
        XCTAssertEqual(c.messages.last?.text, "typing")
        XCTAssertTrue(c.messages.last?.isDraft == true)
    }

    func testResultIsIdenticalAtANonzeroWindowOrigin() throws {
        XCTAssertEqual(try TeamsWebParser().parse(chatWindow(), context: context()),
                       try TeamsWebParser().parse(chatWindow(origin: CGPoint(x: 1500, y: 260)),
                                              context: context()))
    }

    // MARK: - Goldens

    func testChatFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(TeamsWebParser().parse(try fixture("teams-web-chat"),
                                                         context: context())),
                     matches: "teams-web-chat-golden")
    }

    func testOffsetChatFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(TeamsWebParser().parse(try fixture("teams-web-offset-chat"),
                                                         context: context())),
                     matches: "teams-web-offset-chat-golden")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter TeamsWebParserTests`
Expected: FAIL to compile — "cannot find 'TeamsWebParser' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/MaxMiCapture/TeamsWebParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Teams on the web (`teams.microsoft.com`, `teams.cloud.microsoft`) → `.conversation`, routed by
/// host (§7b, §14b). The NATIVE Teams app keeps `TeamsParser`; this parser never sees it.
///
/// `data-tid` is the least likely candidate to reach AX, so containers resolve in two tiers — DOM
/// class first, then an identifier prefix — and a container with no static texts at all falls back
/// to its `AXDescription` as the whole message text. A description is never PARSED into sender
/// and time: that is format-guessing, and a joined line is never re-split (§14b).
///
/// `contentKind` comes from `WebAppCaptureParser.classify` (§12 Q3) — this task adds
/// `teams.cloud.microsoft` there so both domains land on `.conversation`. `URLKeyNormalizer` is
/// deliberately NOT changed: `teams.cloud.microsoft` keeps today's generic query strip, because a
/// normalization change would fork every existing thread on that domain.
///
/// ANCHORS. §14b's candidates, verified against a live dump recorded with
/// `swift tools/ax-snapshot-record.swift com.google.Chrome /tmp/teams-web-chat.json`
/// on <YYYY-MM-DD>. Replace each `?` with `verified (<n> nodes)` or
/// `NOT EXPOSED — used <replacement>`, and keep the failures listed:
///   data-tid "chat-pane-message"    message container   ?   (as domIdentifier / identifier / not at all)
///   `fui-ChatMessage`               message container   ?
///   `message-author-name`           sender              ?
///   `message-timestamp`             time                ?
///   `fui-ChatMessage__body`         body                ?
///   data-tid "ckeditor"             composer            ?
///   `ck-editor__editable`           composer            ?
///   AXDescription on a text-free container              ?
public struct TeamsWebParser: StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Microsoft Teams Web",
        bundleIDs: [],
        hosts: ["teams.microsoft.com", "teams.cloud.microsoft"],
        // Declared as §14b asks; inert for a hosts-only parser (see `GmailParser.config`).
        attributeSet: ["AXDOMClassList", "AXDOMIdentifier"],
        offscreenPolicy: .accessibilityScroll(maxSteps: 3),
        preferOverNative: false
    )

    static let messageClass = "fui-ChatMessage"
    static let authorClass = "message-author-name"
    static let timestampClass = "message-timestamp"
    static let bodyClass = "fui-ChatMessage__body"
    static let messageIdentifierPrefix = "chat-pane-message"
    static let composerClass = "ck-editor__editable"
    static let composerIdentifier = "ckeditor"
    static let composerPlaceholderHint = "message"

    // MARK: - Anchors

    /// Tier A: the message DOM class. Tier B: a container whose `domIdentifier` or `identifier`
    /// starts with Teams' `data-tid` value, for the builds where the class list is absent. Never
    /// both tiers at once, so one message cannot be counted twice.
    static func messageContainers(in snapshot: AXNode) -> [AXNode] {
        var containers = AXQuery.findAll("//*[domClass=\"\(messageClass)\"]", in: snapshot)
        if containers.isEmpty {
            containers = AXQuery.findAll("//*[domId^=\"\(messageIdentifierPrefix)\"]", in: snapshot)
        }
        if containers.isEmpty {
            containers = AXQuery.all(in: snapshot) { node in
                (node.identifier ?? "").hasPrefix(messageIdentifierPrefix)
            }
        }
        return AXQuery.sortedByVisualOrder(containers, relativeTo: snapshot.frame)
    }

    static func composer(in snapshot: AXNode) -> AXNode? {
        if let classed = AXQuery.find("//*[domClass*=\"\(composerClass)\"]", in: snapshot) {
            return classed
        }
        if let identified = AXQuery.find("//*[domId=\"\(composerIdentifier)\"]", in: snapshot) {
            return identified
        }
        // Last resort: the text-entry field whose placeholder or description mentions a message.
        return AXQuery.first(in: snapshot) { node in
            guard AXReader.textEntryRoles.contains(node.role) else { return false }
            let hint = [node.placeholder, node.label].compactMap { $0 }
                .joined(separator: " ").lowercased()
            return hint.contains(composerPlaceholderHint)
        }
    }

    static func channel(in snapshot: AXNode, windowTitle: String?) -> String {
        if let heading = AXQuery.findAll("//AXHeading", in: snapshot)
            .compactMap(WebHostParsing.text(of:)).first {
            return heading
        }
        guard let windowTitle, !windowTitle.isEmpty else { return "unknown" }
        return windowTitle
    }

    static func messages(in snapshot: AXNode) -> [Message] {
        messageContainers(in: snapshot).compactMap { container in
            let authorNode = AXQuery.find("//*[domClass=\"\(authorClass)\"]", in: container)
            let timeNode = AXQuery.find("//*[domClass=\"\(timestampClass)\"]", in: container)
            let sender = authorNode.flatMap(WebHostParsing.text(of:))
            let timeString = timeNode.flatMap(WebHostParsing.text(of:))
            let bodyNode = AXQuery.find("//*[domClass=\"\(bodyClass)\"]", in: container)
            let texts: [String]
            if let bodyNode {
                texts = AXQuery.collectStaticTexts(in: bodyNode)
            } else {
                // Tier B: everything the container says, minus the anchored sender/time subtrees.
                let excluded = Set((authorNode.map(AXQuery.collectStaticTexts(in:)) ?? [])
                    + (timeNode.map(AXQuery.collectStaticTexts(in:)) ?? []))
                texts = AXQuery.collectStaticTexts(in: container).filter { !excluded.contains($0) }
            }
            if texts.isEmpty {
                // AXDescription fallback: the whole description IS the message, unattributed.
                guard let described = WebHostParsing.text(of: container) else { return nil }
                return WebHostParsing.message(sender: nil, timeString: timeString,
                                              texts: [described])
            }
            return WebHostParsing.message(sender: sender, timeString: timeString, texts: texts)
        }
    }

    // MARK: - StructuredParser

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var messages = Self.messages(in: snapshot)
        if let draft = WebHostParsing.draft(in: Self.composer(in: snapshot)) {
            messages.append(draft)
        }
        guard !messages.isEmpty else {
            // The ONE refusal case (§14b): a compose-only chat whose draft is empty.
            if refusesEmptyCompose(snapshot, context: context) {
                throw ParserRefusal(reason: "empty-compose")
            }
            // Otherwise NOT_HANDLED → generic v2 (§4f rule 3): Teams' calendar, files and apps
            // tabs live on this host too.
            return nil
        }
        return .conversation(Conversation(
            channel: Self.channel(in: snapshot, windowTitle: context.windowTitle),
            // Teams' anchors expose no channel-vs-chat marker; the renderer does not use isGroup.
            isGroup: false,
            messages: messages
        ))
    }

    /// True ONLY for a compose-only window whose draft is empty: there is genuinely nothing to
    /// store, so `parse` throws `ParserRefusal` rather than letting generic v2 store the chrome
    /// around an empty composer. Every other empty read returns nil (NOT_HANDLED, §4f rule 3).
    /// A plain method, not a protocol requirement: the refusal travels on `parse`'s `throws`
    /// (spec §12 amendment superseding Q18).
    public func refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool {
        guard let composer = Self.composer(in: snapshot) else { return false }
        return WebHostParsing.draft(in: composer) == nil && Self.messages(in: snapshot).isEmpty
    }
}
```

In `Sources/MaxMiCapture/WebAppCaptureParser.swift`, extend the teams branch of `classify` — `contentKind` for this host depends on it (§12 Q3):

```swift
        if host == "teams.microsoft.com" || host == "teams.live.com"
            || host == "teams.cloud.microsoft" { return .teams }
```

In `Sources/MaxMiCapture/ParserRegistry.swift`, append to Task 5's list:

```swift
            GmailParser(), LinkedInMessagingParser(), OutlookWebParser(), TeamsWebParser(),
```

In `Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift`, add one row to each dictionary:

```swift
        "TeamsWebParser": [("teams-web-chat", "teams-web-chat-golden"),
                           ("teams-web-offset-chat", "teams-web-offset-chat-golden")],
```

```swift
        "TeamsWebParser": ["teams.microsoft.com", "teams.cloud.microsoft"],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter TeamsWebParserTests`
Expected: PASS except the two golden tests.

Run: `swift test --filter WebAppStructuredTests`
Expected: PASS — the new `classify` host is additive and no existing case changed.

Run: `swift test --filter NativeConversationParserTests`
Expected: PASS — native `TeamsParser` is untouched.

- [ ] **Step 6: Scrub the fixtures, write the goldens, add the README rows**

Hand-scrub both dumps: invent every message, name and chat title. Keep intact:

- the `AXWindow` root with its real `frame` (nonzero `x`/`y` for `teams-web-offset-chat.json`),
- the chat title `AXHeading` if one surfaced,
- **two** verified message containers in `teams-web-chat.json`, each with whatever author/timestamp/body anchors Step 1 confirmed,
- in `teams-web-offset-chat.json`: one container that exposes **no** static texts, keeping its `label` (AXDescription) so the description fallback is pinned by a golden, plus a composer with invented draft text.

Move into `Fixtures/`, print, scrub and save the goldens, then add four README rows:

```markdown
| `teams-web-chat.json` | Recorded Chrome Teams web chat, scrubbed | `TeamsWebParser` class-anchored messages |
| `teams-web-chat-golden.json` | Golden `CapturedContent` for the above | `TeamsWebParser` |
| `teams-web-offset-chat.json` | Recorded Chrome Teams web chat at a nonzero screen origin, scrubbed | `TeamsWebParser` AXDescription fallback and composer draft |
| `teams-web-offset-chat-golden.json` | Golden `CapturedContent` for the above | `TeamsWebParser` |
```

- [ ] **Step 7: Run the suites**

Run: `swift test --filter TeamsWebParserTests`
Expected: PASS, 15 tests.

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiCapture/TeamsWebParser.swift \
        Sources/MaxMiCapture/WebAppCaptureParser.swift \
        Sources/MaxMiCapture/ParserRegistry.swift \
        Tests/MaxMiCaptureTests/TeamsWebParserTests.swift \
        Tests/MaxMiCaptureTests/PhaseDCoverageTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/teams-web-chat.json \
        Tests/MaxMiCaptureTests/Fixtures/teams-web-chat-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/teams-web-offset-chat.json \
        Tests/MaxMiCaptureTests/Fixtures/teams-web-offset-chat-golden.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Capture Teams web chats with class anchors and a description fallback"
```

---
### Task 27: Second live-verification pass for the five web hosts

**Files:**
- Modify (only if the pass finds a wrong anchor): the affected parser in `Sources/MaxMiCapture/` and its header comment
- Modify (only if a golden changes as a result): the affected `Tests/MaxMiCaptureTests/Fixtures/*-golden.json`

**Interfaces:**
- Consumes: everything Tasks 22-26 registered; the MCP tool `get_latest_context`; `PhaseDCoverageTests` (Tasks 21-26).
- Produces: no new code. The deliverable is evidence that spec §14b's exit criterion holds — each of the five hosts, opened in a browser tab, produces a typed capture with real senders, times and bodies — plus the verified anchors recorded in each parser header.

This is the **second** live pass of the phase. Task 21 verified the eighteen native and browser-generic surfaces; this one verifies the five host-routed parsers, which did not exist when Task 21 ran.

- [ ] **Step 1: Run the whole suite**

Run: `swift test 2>&1 | tail -40`
Expected: **zero NEW failures** — the same three known-red tests Task 21 Step 3 names, and nothing else (ruling F19).

Run: `swift test --filter PhaseDCoverageTests`
Expected: PASS — in particular `testEveryHostRoutedParserIsReachableFromTheHostMap` covers all five hosts, and the two-fixture / nonzero-origin / no-secure-value assertions now cover ten more fixtures.

Run: `swift build 2>&1 | grep -i warning; echo done`
Expected: no warning lines (spec §11 item 10).

- [ ] **Step 2: Rebuild the app**

Run, exactly as written — **no `tccutil reset`**, because a signed build keeps its Accessibility grant across rebuilds and resetting it would silently break capture:

```bash
./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" && sleep 2 && open MaxMi.app
```

Note the wall-clock time of the `open`. Every verification below must be confirmed against a capture whose timestamp is **strictly after** that moment; an older row proves nothing.

- [ ] **Step 3: Live-verify each host**

For each row: open the surface in a browser tab, do the listed action, wait for a capture tick, then read the capture back with the MCP tool `get_latest_context` using the listed arguments and check the expectation against the returned `content`. `get_latest_context` renders `ContentRenderer.render(structured, .full)`, so the shapes below are what the rendering looks like. Rows continue Task 21's Step 5 numbering.

| # | Host | Action | `get_latest_context` arguments | Expect in `content` |
|---|---|---|---|---|
| 21 | Gmail (`mail.google.com`) | Open a thread with two expanded messages, then start a reply and leave it unsent | `{"source": "Web", "content_kinds": ["email"], "limit": 1}` | `(From: <name>)(sent <time>): <body>` per expanded message, then `(From: You (draft)): <your reply>`; no line with an empty body from a collapsed message |
| 22 | LinkedIn (`linkedin.com/messaging`) | Open a conversation you have replied in | `{"source": "Web", "content_kinds": ["conversation"], "limit": 1}` | their messages as `(From: <name>)(sent <time>): …` and **your own** as `(From: You)`; then open the LinkedIn feed and confirm the next capture is a generic page (`URL: https://www.linkedin.com/feed/` plus region headers), not a conversation |
| 23 | Outlook web (`outlook.office.com`) | Open a message in the reading pane | `{"source": "Web", "content_kinds": ["email"], "limit": 1}` | one `(From: <name>)(sent <time>): <body>` line per card; no `From:`/`Sent:` prefix left inside the body text |
| 24 | Slack web (`app.slack.com`) | Open a channel, type a draft, do not send | `{"source": "Web", "content_kinds": ["conversation"], "limit": 1}` | the same message-line shape the native Slack row 7 produced, then `(From: You (draft)): <your draft>` |
| 25 | Teams web (`teams.microsoft.com`) | Open a chat with two messages from different people | `{"source": "Web", "content_kinds": ["conversation"], "limit": 1}` | two `(From: <name>)`-attributed lines; no line reading `(From: unknown)` unless Step 4 of Task 26 recorded the AXDescription fallback as the tier that fired |

- [ ] **Step 4: Check the three cross-cutting behaviours**

| # | Check | How |
|---|---|---|
| 26 | The refusal is recorded, not lost | Open a Gmail compose window, leave the body empty, wait for a tick, then open the Capture Health window. The row for that capture is a **skip** with reason `parser_no_content` — not a failure, and not a stored empty capture. |
| 27 | A degraded host still captures | Open a Gmail surface no anchor matches (Settings). The next capture is a generic page and its Capture Health `parser` value starts `GenericPageExtractor.v2/fallback/GmailParser`. |
| 28 | The recorded anchors match reality | Re-read the ANCHORS block in each of `GmailParser.swift`, `LinkedInMessagingParser.swift`, `OutlookWebParser.swift`, `SlackParser.swift` and `TeamsWebParser.swift`. Every candidate line must read `verified (<n> nodes)` or `NOT EXPOSED — used <replacement>`; no `?` may remain, and no `<YYYY-MM-DD>` placeholder may remain. |

- [ ] **Step 5: Fix what the pass found, or record that nothing needed fixing**

If a row failed, the anchor is wrong, not the plan: re-record that host's dump with `tools/ax-snapshot-record.swift`, correct the anchor and the header comment, re-scrub the fixture, regenerate the golden, and re-run that host's test class. Then:

```bash
swift test --filter PhaseDCoverageTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

If Step 5 changed anything:

```bash
git add Sources/MaxMiCapture Tests/MaxMiCaptureTests
git commit -m "Correct web host anchors found in the live verification pass"
```

If nothing changed, skip the commit — the pass produced evidence, not a diff. Record in the task notes that rows 21-28 all passed against captures timestamped after the `open MaxMi.app` in Step 2.

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
| §7a `collectStaticTexts(in:)` | 4 |
| §7a a table-row formatter | **not added** (ruling F15): `GenericPageExtractor.block(for:listDepth:)` already emits `.tableRow(cells:selected:)`, and Tasks 18 and 24 — the only row consumers — call it |
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
| §7c Calendar `.calendar` from the existing `preferredDetailRoot` anchor, retyped | 19 (Phase A already retyped it; 19 registers it, widens `hasConference` and adds the goldens) |
| §7c Reminders `.tasks`, status from the row's `AXCheckBox` | 20 |
| §7d `tools/ax-snapshot-record.swift <bundle-id> <out.json>`, same budgets as `AXReader`, hand-scrub rule | 6 |
| §7d the duplicated `fixture(_:)` helpers consolidated into `FixtureLoading.swift` — **twelve** exist on this branch, not the six §7d names, plus Task 1's thirteenth (spec §12 repair amendment) | 6 |
| §8 fall-through is not silent: `"GenericPageExtractor.v2/fallback/<ParserTypeName>"` in `capture_health_events.parser`, no new column | 5 (reuses Phase A's `CaptureDispatch.fallbackParserID(failedParser:)`, ruling F4); native path already wired at `AppWiring.swift:1492`, browser path in 9 and 22 |
| §8 DOM attribute reads bounded by the web-area gate plus `ParserConfig.attributeSet`; `AXQuery` path parsing cached | 1, 2 |
| §8 secure fields never read | 6 (the recorder refuses), 21 (fixture + live assertion) |
| §9 each grammar token, predicate ANDing, index selection, `domClass` case-insensitivity, cache hit does not change results, invalid path returns nil | 2, 3 |
| §9 ≥2 recorded hand-scrubbed fixtures with golden `CapturedContent` per parser, ≥1 at a nonzero window origin | 7-20, machine-checked in 21 |
| §9 live verification ritual, no `tccutil reset`, verify by timestamp | 21 |
| §11 item 8 (AXQuery powers the rewritten parsers; ≥2 goldens each, one nonzero origin) | 21 |
| §11 item 5 (no `CGEventTap` in the binary, grep-asserted) | 21 |
| §11 item 10 (full suite green, zero warnings, live verification passed) | 21 |
| §14b Gmail: thread `.conversation`, inbox `.generic` `.tableRow`s, compose draft, `.email` on every path | 22 |
| §14b LinkedIn `/messaging` `.conversation`; every other LinkedIn page stays generic v2 | 23 |
| §14b Outlook web: reading-pane `.conversation` from the `From:`/`Sent:` description, list rows, draft, `.email` | 24 |
| §14b Slack web mirrors the native Slack anchors; `isGroup` from a `#` channel; renders byte-identically | 25 |
| §14b Teams web: `data-tid` anchors with an `AXDescription` fallback; `classify` gains `teams.cloud.microsoft` | 26 |
| §14b host registration via `ParserConfig.hosts` → `ParserRegistry.host(fromURL:)` → `structuredParser(forHost:)`, `preferOverNative` false | 22-26, on Task 5's mechanism |
| §14b nil = NOT_HANDLED → generic v2; refusal ONLY for a compose-only window with an empty draft (§12 Q18, superseded by the §12 repair amendment) | 5 (`StructuredParser.parse` is `throws`), 22 (each parser's `refusesEmptyCompose` guard + the `BrowserCapturePipeline` rethrow + the `AppWiring` catch), 23-26 per parser |
| §14b `Message`s built from container structure via `NativeConversationExtraction.senderLabel`, never split on `": "` | 22 (`WebHostParsing.message`), asserted in 22-26 |
| §14b `contentKind` never derived from shape; `sourceKey` schemes preserved | 22 (Gmail `.email` + key test), 23, 24, 25, 26 (five-host key-stability test) |
| §14b ≥2 recorded hand-scrubbed fixtures + golden per host, ≥1 at a nonzero origin, registered in Task 21's `coverage` | 22-26, machine-checked by 21's dictionaries |
| §14b five live-checklist rows read back with `get_latest_context`, verified by timestamp | 27 |
| §14b anchors verified against a live `ax-snapshot-record.swift` dump before use and recorded in each parser header | 22-26 Step 1, re-checked in 27 Step 4 |
| §14b exit criterion: each of the five hosts produces a typed capture with real senders, times and bodies | 27 |

Not in this plan, by design: §4 (Phase A), §5 (Phase B), §6 (Phase C), §14a and §14c (both Phase C), §9's Finder and dialog-over-window **generic-extractor** fixtures (Phase A's `finder-offset-window.json` and `dialog-over-window.json` — Task 18 adds the Finder *parser* on top of them), §9's `GenericPageExtractor` 150 ms / 20k-node bound (Phase A), §12 Q7-Q10 and Q12-Q15 (Phases A-C). **No gaps.**

### 2. Placeholder scan

Searched for `TBD`, `TODO`, `implement later`, `fill in details`, `add appropriate error handling`, `add validation`, `handle edge cases`, `write tests for the above`, `similar to Task`. None present. Every code step carries a runnable code block; every run step names an exact `swift test --filter <TestClass>` or `swift build`; every fixture that cannot be recorded while planning carries the exact recording command **and** the minimum node set the test needs, so the executor cannot record something the test does not exercise.

### 3. Type consistency

Checked across tasks:

- `ParserConfig(app:bundleIDs:hosts:attributeSet:offscreenPolicy:preferOverNative:minAppVersion:)` — Task 5 defines it; Tasks 7-20 all construct it with that exact label order and rely on the same defaults.
- `ParseContext(app:url:previousStructured:now:)` convenience init — Task 5 defines it; every `parseStructured` bridge in Tasks 7-20 calls `ParseContext(app: app)`, and every test calls `ParseContext(app:..., url:...)`.
- `StructuredParser.parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent?` — one spelling everywhere, `throws` in every task (ruling F13), so every call site inside a parser or a test uses `try`. `SourceParser.parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?` keeps its own labels, and the two never collide because the argument labels differ.
- `AXQuery.Step(axis:role:predicates:index:)` and `AXQuery.Predicate(attribute:op:expected:)` — Task 2 defines them; Task 2's test constructs both with those labels; Task 3 reads `step.axis`, `step.role`, `step.predicates`, `step.index`, `predicate.attribute`, `predicate.op`, `predicate.expected`.
- `AXQuery.menuRoles` is declared once, in Task 4's `AXQueryHelpers.swift`, as a computed `static var` that returns `GenericPageExtractor.menuRoles` — one menu-skip set for the whole capture layer, not a second literal. `collectStaticTexts` is its only user.
- `AXQuery.all(in:where:)` / `first(in:where:)` — Task 4 produces them; Task 12 (`MessagesParser.bubbles`) and Task 17 (`ObsidianParser.parse`) consume them.
- `AXQuery.sortedByVisualOrder(_:relativeTo:)` takes `CGRect?` — Tasks 4, 10, 12, 13, 16, 17, 20 all pass a `node.frame`, which is `CGRect?`. Consistent.
- `MessagesParser.isUserBubble(_:window:)` — Task 12 produces it, Task 13 consumes it. One spelling.
- `NativeConversationExtraction.conversationName(window:app:)` — **new** in Task 13 (nothing of that name exists today, ruling F24), wrapping the promoted `conversationTitle(in:app:mainBoundary:requiresHeaderSemantics:)` and `mainPaneBoundary(_:)`; consumed only by Task 13.
- `StructuredEntityExtraction.preferredDetailRoot(in:hints:)`, `orderedFields(in:)`, `firstValue(_:metadataHints:)`, `looksLikeDateOrTime(_:)`, `isChrome(_:)` — **five** members, promoted to internal in **Task 20**, the only task that reuses them. Task 19 needs none (it calls the already-internal `calendarContent`), `isPreferred(_:hints:)` stays private, and `struct Field` was already internal (ruling F22).
- `StructuredEntityExtraction.Field` is referenced by label in `TaskStructuredExtraction.notes(from:excluding:)` (Task 20) — the one place a `Field` array crosses a function boundary in this plan.
- `TaskStructuredExtraction.completedValues` is the single source of the truthy set; `status(ofRow:)` and `detailItem(in:windowTitle:)` both read it. `notes(from:excluding:)` is the single source of the notes rule, so the `AXCheckBox` exclusion cannot be present on one path and missing on the other (ruling F23).
- `CaptureDispatch.fallbackParserID(failedParser:)` — Phase A's existing helper (`ParserRegistry.swift:167-169`), the ONE spelling of the §8 marker. This plan adds no overload (ruling F4); Tasks 5, 9 and 22 all call it with `failedParser:`.
- `ParserRegistry.host(fromURL:)` — Task 5 produces it; Task 9 consumes it. `structuredParser(forHost:)` likewise.
- `BrowserTabExtractor.primaryWebArea(in:windowTitle:engine:)` — produced by Phase A Task 15, consumed by Task 9 only; `WebPageParser.parse(window:tab:)` passes `engine: nil`, which Phase A's `engine: BrowserEngine? = nil` default already tolerates.
- `EditorParser.activeTabTitle(fromWindowTitle:)` / `workspaceName(fromWindowTitle:)` / `titleComponents(_:)` / `looksLikeFilename(_:)` / `key(fromTitle:)` — five names, each used consistently inside Task 8.
- Fixture and golden names: the 24 `(fixture, golden)` pairs listed in Task 21's `coverage` dictionary are character-for-character the names used in Tasks 7-20's `assertGolden` calls and `git add` lines. They cover **24 fixtures and 23 goldens** — `discord-offset-messages` is pinned against `discord-messages-golden`, because a geometry-free parser must produce identical bytes from both fixtures and a second identical file would assert nothing (ruling F25). `calendar-event` and `reminder-task` are pre-existing fixtures reused with new goldens; the other 22 fixtures are new.
- Phase A names consumed and never redefined: `CapturedContent`, `Document`, `Conversation`, `Message`, `Message.makeID`, `TaskItem`, `TaskStatus`, `CalendarEvent`, `TerminalSegment`, `TerminalSession`, `GenericPage`, `Region`, `RegionKind`, `Block`, `BlockType`, `Authorship`, `CapturedContentEnvelope`, `ContentRenderer.render/renderBlock`, `GenericPageExtractor.extract/Options/Result`, `LegacyContentAdapter`, `ParsedCapture.structured`, `SourceParser.parseStructured`, `AXNode.subrole/headingLevel/selected/placeholder/selectedText/hidden`, `AXReader.textEntryRoles`. All spelled as the spec §4 and the Phase A plan spell them.

No inconsistencies found.

### 4. Repair pass against the merged Phase A code (pre-flight rulings F1-F30)

This plan was re-checked line by line against `main` after the Phase A merge, and the 30 findings
of `.superpowers/sdd/2026-09-06-maxmi-m8d-ax-query-dsl-and-parsers/preflight-scan.md` were applied
with the controller's rulings. What changed, by ruling:

| Ruling | Change |
|---|---|
| F1 | Ten tasks appended `parseStructured` in an extension of a type that already declares it (invalid redeclaration). Tasks 7, 10, 11, 12, 13, 15, 16, 17, 19, 20 now **edit the existing body** and name its `file:line`; Task 14 already did. |
| F2 | Task 5 updates the Phase A test seam `ParserRegistry.init(parsers:)` to initialise both new stored properties, and asserts it (`ParserFallthroughTests` keeps compiling). |
| F3 | Task 5 Step 5 wires `registry.forcedAttributes(for:)` into `AXReader.snapshotFrontmostWindow(forcedAttributes:)` at `AppWiring.swift:1382-1391`; the registry test asserts the whole declared set. |
| F4 | The `fallbackParserID(notHandledBy:)` overload is gone; every site calls Phase A's `fallbackParserID(failedParser:)`. |
| F5 | `BrowserCapturePipeline.parse` keeps `contentBudget:` (before the new `registry:`), so `WebAppStructuredTests.swift:117` compiles. |
| F6 | `WebAppCaptureParser.parse` is called with `try` and with the budget. |
| F7 | No `CalendarEvent` is constructed by the plan at all — Task 19 delegates to `calendarContent`, which already passes `notes:`. |
| F8 | `TerminalSegmentationTests.swift` is kept; its two invariant tests move into `TerminalStructuredTests.swift` and its two `cwd` expectations are updated. |
| F9 | `TerminalParser` has one content path: `session(fromScrollback:windowTitle:)`, rendered by `parse(window:app:)`, returned by `parse(_:context:)`. The same rule is applied to WhatsApp and Reminders, whose `parse(window:app:)` also attached a second shape. |
| F10 | Notes/Notion/Obsidian reuse their existing `offscreen` constant and bound the document to `StructuredEntityExtraction.pageBudget`. |
| F11 | Cursor/VS Code cap and ceiling are both 32_000; `96_000` appears nowhere. |
| F12 | The non-browser `AppWiring` switch is untouched, so a window is parsed once; `structuredCapture` is the browser path's entry point and takes the fall-through as a closure (`WebPageParser` for a tab). |
| F13 | `StructuredParser.parse` is `throws`; `ParserRefusal` = store nothing on both paths; the `RefusingStructuredParser` protocol is removed and `refusesEmptyCompose` is a plain predicate guarding each parser's own throw. |
| F14 | `AXQuery.trapsOnInvalidPath` exists in both configurations; Task 21 runs the two grammar suites under `-c release`. |
| F15 | `AXQuery.formatTable` is deleted; Finder and Outlook web use `GenericPageExtractor.block(for:listDepth:)`. `AXQuery.menuRoles` aliases the extractor's set instead of restating it. |
| F16 | Task 18 states the division of labour explicitly and uses `AXQuery` for the path and source-list anchors. |
| F17 | Task 6 migrates **twelve** copies (with real line ranges and both body variants) plus Task 1's thirteenth. |
| F18 | Task 1's decode test enumerates `Fixtures/` instead of naming eleven files. |
| F19 | Task 21 Step 3 and Task 27 Step 1 gate on zero NEW failures against the three named known-red tests. |
| F20 | Every task that replaces a content path names and deletes the members it orphans. |
| F21 | Declared test counts recomputed (Task 4: 12, Task 7: 19, Task 8: 12, Task 13: 12, Task 18: 12) and Task 6's self-contradicting "PASS, 4" split into a write-the-golden step. |
| F22 | The no-op "remove `private` from `struct Field`" is dropped; the promotions are **five** members, in Task 20, the only task that needs them. |
| F23 | `TaskStructuredExtraction.notes(from:excluding:)` is the single notes rule and excludes `AXCheckBox`, so a row's checkbox value cannot leak into `TaskItem.notes`. |
| F24 | Task 13 says `conversationName` is new, promotes the two real private members it wraps, and keeps `split(_:byKnownParticipant:)` on the new path. |
| F25 | The three vacuous tests are replaced: a genuinely frameless node asserted against the window origin (Task 4), a flush-vs-offset equality against one shared golden (Task 11), and a sidebar-classification assertion at a nonzero origin (Task 18). |
| F26 | Stale `file:line` references refreshed (`AXReader.swift:23`/`:80-130`, `AppWiring.swift:1382-1391`/`:1449-1481`/`:1483`, `NativeConversationParserTests.swift:6`, `SlackParserTests.swift:6`, Mail's typed path is Phase A **Task 12**). |
| F27 | The Global Constraints state that `GenericV2Content` survives for `GenericAXParser`, Word/Pages and Outlook/Spark. |
| F28 | The final registration list is written out in Task 5, re-asserted by a new `PhaseDCoverageTests` test in Task 21, and appended to by Tasks 22-26 (13 bundle-ID + 4 host = 17). |
| F29 | `testConfigClaimsEveryTerminalBundleID` asserts four bundle IDs. |
| F30 | `BrowserCaptureResult` gains no field; consumers read `result.capture.structured`. |

Two changes follow from the rulings rather than being named by them, and are recorded here so a
reviewer does not read them as drift: Task 10 reuses `SlackParser.channel(fromTitle:)` /
`isGroup(fromTitle:)` instead of adding a third title parser (they are asserted directly by
`StructuredConversationParserTests`), and Task 13 keeps the Phase A conversation walk as the
fallback when no `WAMessageBubbleTableViewCell` anchor is present, because that walk owns both
`ParserRefusal` cases and is what the six existing WhatsApp tests drive.

### 5. Second pass over Tasks 22-27 (§14b)

**Spec coverage.** Every §14b paragraph maps to a task in the table above. The five hosts, the
refusal rule, the sender heuristic, the `contentKind`/`sourceKey` rules, the fixture rules, the
five live rows and the exit criterion are each claimed by a numbered task.

**Placeholder scan.** No `TBD`, `TODO`, `implement later`, `similar to Task N`, "add error
handling" or "write tests for the above" in Tasks 22-27. The `?` marks inside each parser's
ANCHORS header block and the `<YYYY-MM-DD>` in the same block are **not** plan placeholders: they
are fields the executor can only fill from the live dump recorded in that task's Step 1, each with
an explicit instruction on what to write, and Task 27 Step 4 fails the phase if any of them
survives.

**Type consistency across the new tasks.**

- `refusesEmptyCompose(_ snapshot: AXNode, context: ParseContext) -> Bool` — a plain method on each host parser (no protocol), guarding the `throw ParserRefusal(reason: "empty-compose")` inside that parser's `parse`
  — one spelling in all five parsers (22, 23, 24, 25, 26); each parser's `parse` is its only
  caller, and the tests assert the predicate directly.
- `WebHostParsing.message(sender:timeString:texts:isUser:)` — declared in Task 22 with
  `isUser: Bool = false`; Tasks 22, 24, 25, 26 call it without `isUser`, Task 23 passes it.
  `.draft(in:)`, `.text(of:)`, `.editorText(in:)` and `.path(of:)` likewise have one spelling each.
- `ParserConfig(app:bundleIDs:hosts:attributeSet:offscreenPolicy:preferOverNative:)` — Task 5's
  label order, `bundleIDs: []` for all four host-only parsers, `preferOverNative: false` for all
  four (Task 10's `true` on `SlackParser` is unchanged because that parser also claims a bundle ID).
- `BrowserCapturePipeline.parse(window:windowTitle:browser:contentBudget:registry:)` — Task 22
  fixes the signature and keeps `contentBudget` ahead of `registry`, so Task 9's call site and
  `WebAppStructuredTests.swift:117` both compile.
- `PhaseDCoverageTests.coverage` / `.hostCoverage` — Task 22 adds `hostCoverage` and its test;
  Tasks 23, 24, 26 add one row to each; Task 25 extends `SlackParser`'s `coverage` entry to four
  pairs and adds its host row. The ten new `(fixture, golden)` names are character-for-character
  the names used in the `assertGolden` calls and `git add` lines of Tasks 22-26.
- `AXQuery` surface used: `find`, `findAll`, `collectStaticTexts`, `sortedByVisualOrder`, `all`,
  `first` — all as Tasks 3 and 4 declare them, `sortedByVisualOrder(_:relativeTo:)` always fed a
  `CGRect?`. Table rows come from `GenericPageExtractor.block(for:listDepth:)` (ruling F15).

**Three places §14b contradicts the tree or itself. Each is decided in the task, not left open.**

1. **§14b/§12 Q18 put the refusal in `SourceParser.parse(window:app:)`, but a browser tab never
   reaches a `SourceParser`.** The browser path is `ApplicationRegistry.captureStrategy ==
   .browserAX` → `BrowserCapturePipeline.parse`, and `CaptureDispatch.parseDetailed` — the code
   that catches `ParserRefusal` today — is only on the non-browser branch. **Decision (Task 5 +
   Task 22, spec §12 repair amendment superseding Q18):** `StructuredParser.parse` is `throws`, so a
   host parser throws `ParserRefusal` itself, guarded by its own `refusesEmptyCompose` predicate.
   `CaptureDispatch.structuredCapture` does not catch it, `BrowserCapturePipeline.parse` rethrows it,
   and `AppWiring` gains one `catch` clause that records `.skipped(.parserNoContent)` — the same
   outcome `CaptureDispatch.parseDetailed` already produces for a refusing native parser. There is
   **no** separate refusal protocol; one mechanism serves both dispatch paths (ruling F13).
2. **§14b says the DOM attributes are "gated per parser by `ParserConfig.attributeSet`", but
   `ParserRegistry.forcedAttributes(for:)` is keyed by bundle ID** (Task 5), and a host-routed
   parser has no bundle ID. **Decision:** the `attributeSet` is still declared exactly as §14b
   writes it, and each parser's header plus one test per parser records that it is inert here —
   Task 1's `AXWebArea`-ancestor gate is what actually supplies `domClassList`/`domIdentifier` on a
   browser tab, which is always satisfied for these five hosts.
3. **§14b lists `teams.cloud.microsoft` as a Teams host, but neither
   `WebAppCaptureParser.classify` nor `URLKeyNormalizer` knows that domain.** **Decision
   (Task 26):** `classify` gains it, because `classify` is the authority for `contentKind` (§12 Q3)
   and without it that host would produce `.webpage` instead of `.conversation`. `URLKeyNormalizer`
   is deliberately **not** changed — normalizing a host differently changes its `source_key` and
   would fork every existing thread on that domain — so the two Teams domains keep two key schemes
   until someone plans that migration. The divergence is asserted, with its reason, in
   `TeamsWebParserTests.testKeyDerivationIsUnchangedForEveryWebHostInThisPhase`.
