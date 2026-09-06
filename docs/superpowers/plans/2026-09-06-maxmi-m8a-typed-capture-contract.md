# MaxMi M8 Phase A — Typed Capture Contract + Generic Flattener v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MaxMi's "one blob of `String`" capture with a typed, losslessly-renderable `CapturedContent` contract, a role/region-aware generic flattener, and a `v10` schema that stores both, so every downstream consumer keeps working byte-for-byte while gaining structure.

**Architecture:** Six `Codable` shapes (`document`, `conversation`, `tasks`, `calendar`, `terminal`, `generic`) live in `MaxMiCore` next to a pure `ContentRenderer` that turns any shape back into the exact text `versions.content` holds today. `MaxMiCapture` gains `GenericPageExtractor`, which walks an `AXNode` window into regions of typed blocks (headings, paragraphs, list items, joined table rows, labels, masked secure fields) and replaces `DocumentExtraction.bodyText` on the fallback path. `MaxMiStore` gains two additive nullable `structured_ciphertext TEXT` columns and a kind-aware accumulator that returns a `CaptureDelta` instead of discarding it. Parsers migrate one group at a time; an unmigrated or failing parser degrades to the generic extractor instead of storing nothing.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+, XCTest, GRDB 7, ApplicationServices/AppKit accessibility APIs, CryptoKit (`AESGCMFieldCipher`).

**Spec:** `docs/superpowers/specs/2026-09-06-maxmi-m8-structured-capture-design.md` — this plan implements §4 (all of Phase A: 4a–4g), plus the Phase A parts of §8 (cross-cutting), §9 (testing), and §11 (exit criteria). Phases B (§5), C (§6), and D (§7) are separate plans and are **out of scope here**; the interfaces Phase B consumes from Phase A (`CaptureDelta`, `StructuredAccumulationResult`, `CommitResult.committed(versionID:contentHash:delta:)`, `AXReader.focusedElementSnapshot(pid:)`, `FocusedElement`, `Block.authoredByUser`) are produced here with the exact names the spec uses.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- **All new types are `public`, `Codable`, `Sendable`, `Equatable`** (§4a). Public structs with `let` properties need explicit `public init`s — the implicit memberwise init is internal and the types cross module boundaries.
- **XCTest only.** Zero `import Testing` anywhere; tests are `final class …: XCTestCase` with `func test…` methods (§2: "506 tests, all XCTest").
- **The 506 existing tests stay green.** Every signature change in this plan lists its exact existing call sites.
- **No `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`, ever** (§3 Non-goals).
- **No PII/email redaction inside captured content** beyond the existing `Denylist` app + domain denylist (§3 Non-goals).
- **No change to the MCP tool surface.** `search_memory`, `list_active_threads`, `get_latest_context` keep their request/response shapes and keep reading `content` (§4g). Exposing `structured` over MCP is out of scope.
- **Ciphertext columns are `TEXT`, never `BLOB`**, written through `FieldCipher.encrypt(_:) throws -> String` which returns `"enc:v1:"`-prefixed base64 (§4c, §12 Q2). Reuse `AESGCMFieldCipher` and the existing Keychain key `dev.mafex.maxmi.dbkey`. No new key, no new format.
- **A `structured_ciphertext` that is NULL, fails to decrypt, fails to JSON-decode, or carries `v > CapturedContentEnvelope.currentSchemaVersion` are all the same case:** fall back to `LegacyContentAdapter`. Never a crash, never a lost capture (§4c, §8).
- **Deterministic encoding.** `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes`, `dateEncodingStrategy = .iso8601`; `JSONDecoder` with `dateDecodingStrategy = .iso8601`. The same `CapturedContent` must always encode to the same bytes (§4a).
- **`CapturedContentEnvelope.currentSchemaVersion = 1`** (§4a).
- **`CaptureContentKind` keeps all ten existing cases** (`webpage, conversation, document, terminal, email, calendar, task, meeting, voiceNote, generic`) — pinned by the `latest_contexts.content_kind` CHECK constraint and by MCP. `structured.kind` is only the **default**; `ParsedCapture.contentKind` stays authoritative and overridable, so Mail/Outlook/Spark keep `.email` and browsers keep `.webpage` (§4a, §12 Q3).
- **`GenericPageExtractor` budgets:** `totalBudget = 8_000` (== `DocumentExtraction.contentCap` today), `mainShare = 0.70`, `dialogShare = 0.15`, `restShare = 0.15` (§4e).
- **`GenericPageExtractor` is pure and total** — it cannot throw and always returns a `GenericPage`, possibly with zero regions, which the caller treats as empty content exactly as today (§8).
- **Performance:** `GenericPageExtractor.extract` completes in **< 150 ms for a 20_000-node tree** (§8). `AXReader`'s own budgets stay `maxNodes: 20_000, maxDepth: 40`.
- **New AX attribute reads are bounded:** `subrole`/`selected`/`hidden` unconditionally, `headingLevel` only when `role == "AXHeading"`, `placeholder`/`selectedText` only for `AXTextArea`/`AXTextField`/`AXSearchField`/`AXComboBox` (§4e, §8).
- **Migrations are additive and nullable**, so rollback is "ignore the new columns". `Migrations.currentIdentifier` becomes `"v10"` (§4c). `Sources/MaxMiStore/DatabaseRecovery.swift:131` compares the last applied identifier against `Migrations.currentIdentifier`, so both must move together.
- **No new network destinations.** Gemini only, one shared `GeminiThrottle` (§8).
- **Fixtures are hand-scrubbed.** Never commit real page text, messages, file contents, URLs, names, or tokens (`Tests/MaxMiCaptureTests/Fixtures/README.md`). Every new fixture gets a row in that README's table.
- **Commit messages are plain imperative** ("Add CapturedContent typed capture enum"). **No `Co-Authored-By` trailers, no AI attribution anywhere** — not in commit messages, code comments, or docs.
- **Live verification ritual** (§9, unchanged): `./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" && sleep 2 && open MaxMi.app`. **No `tccutil reset`** — signed builds keep the Accessibility grant across rebuilds. Verify captures by timestamp strictly after the new process start.

### Two deliberate behaviour changes this phase ships

1. **The registry now falls through.** Today `CaptureDispatch.parseDetailed` returns `.noContent`/`.failed` when a registered parser returns nil or throws, and stores nothing ("the no-silent-fallback rule", `ParserRegistry.swift`). Per §4f rule 3 that reverses: a broken or over-narrow parser degrades to a worse capture, not to no capture. It is made non-silent by the §8 health-ledger marker `"GenericPageExtractor.v2/fallback/<ParserTypeName>"`. `Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift` asserts the old behaviour and is replaced in Task 10.
2. **`.document` and `.generic` accumulate by replace, not by rolling text.** §4d pins `.document`/`.generic` → "replace with incoming". Unmigrated and generic-v2 parsers therefore stop concatenating near-duplicate whole-page snapshots across captures; each capture supersedes the last. This is the architect's decision and must not be "improved" — off-screen scroll accumulation for documents is superseded by whole-page re-capture. `.conversation` and `.terminal` keep accumulating (by message identity and by segment append).

### Two reconciliations of spec text against the code

Both are decided here so no task has to reopen them.

1. **`LegacyContentAdapter` preserves empty lines.** §4c describes "one `.paragraph` block per non-empty line", but §4b/§9 require the strictly stronger invariant `ContentRenderer.render(LegacyContentAdapter.adapt(s, kind:), .full) == s` **byte-for-byte**, and real rendered captures do contain blank lines (a `.document` renders a blank line after its title). The invariant wins: `adapt` splits on `"\n"` with `omittingEmptySubsequences: false` and keeps empty lines as empty `.paragraph` blocks.
2. **Nil-`structured` resolution lives in `CaptureEnvelope.init`, not in `CaptureDispatch`.** §4f says `CaptureDispatch` is the single place that resolves nil → `LegacyContentAdapter`. But `Sources/MaxMi/AppWiring.swift:1446-1477` routes browsers through `BrowserCapturePipeline.parse` and never reaches `CaptureDispatch`, so `CaptureDispatch` cannot be the single point. `CaptureEnvelope.init` is: every path builds an envelope. The initializer takes `structured: CapturedContent? = nil`, stores the non-optional `structured` the spec requires, and resolves nil through `LegacyContentAdapter` in exactly one place. `CaptureDispatch` still attaches structured explicitly for rule 2 so the call site reads honestly.

---

## File Structure

### Created

| File | Responsibility |
|---|---|
| `Sources/MaxMiCore/CapturedContent.swift` | The six typed shapes, `Block`/`Region`/`FocusedElement`/`Message`/…, `CapturedContent.kind`, `CapturedContentEnvelope` + its deterministic encode/decode. Types only — no rendering, no merging. |
| `Sources/MaxMiCore/ContentRenderer.swift` | Pure `CapturedContent` → `String`. The only place that knows the wire text shape. Also exposes the per-item renderers (`renderBlocks`, `renderMessage`, `renderTask`, `renderEvent`, `renderSegment`) that the accumulator and the extractor use to size things without re-rendering the whole page. |
| `Sources/MaxMiCore/LegacyContentAdapter.swift` | The one-way adapter from an already-rendered string to `.generic`, used for every pre-v10 row and every unmigrated parser. |
| `Sources/MaxMiCore/CaptureDelta.swift` | `CaptureDelta` + `CaptureDelta.between(previous:merged:)`. Phase B consumes this file unchanged. |
| `Sources/MaxMiCore/StructuredAccumulator.swift` | `StructuredAccumulationResult` and the kind-aware `CaptureAccumulator.merge(previous:incoming:policy:maxCharacters:)` overload plus structured bounding. Kept out of `CaptureEnvelope.swift`, which is already 300+ lines of string-merge logic. |
| `Sources/MaxMiCapture/GenericPageExtractor.swift` | The AX walk: role model, region detection, focused element, budgets. Replaces `DocumentExtraction.bodyText` on the fallback path. |
| `Sources/MaxMiCapture/GenericV2Content.swift` | The two ways a not-yet-anchored parser gets typed `.generic` content: the v2 extractor, or its own already-filtered lines. |
| `Tests/MaxMiCaptureTests/Fixtures/finder-offset-window.json` | A Finder-shaped window at a **nonzero screen origin** with a source list, a table with rows, and a toolbar status line. |
| `Tests/MaxMiCaptureTests/Fixtures/dialog-over-window.json` | A window with a long main body and an `AXSheet` dialog on top, at a nonzero origin. |
| `Tests/MaxMiCaptureTests/Fixtures/ax-attributes.json` | A tiny tree exercising every new `AXNode` attribute (`subrole`, `headingLevel`, `selected`, `placeholder`, `selectedText`, `hidden`). |
| `Tests/MaxMiCoreTests/CapturedContentTests.swift` | Codable round-trips, deterministic bytes, `kind` defaults, envelope version gate. |
| `Tests/MaxMiCoreTests/ContentRendererTests.swift` | Golden strings for all six shapes plus `.compact`/`.mainOnly`. |
| `Tests/MaxMiCoreTests/LegacyContentAdapterTests.swift` | The byte-for-byte round-trip invariant and the `CaptureEnvelope` plumbing. |
| `Tests/MaxMiCoreTests/StructuredAccumulatorTests.swift` | Per-shape merge semantics, bounding, `changed`, and `CaptureDelta`. |
| `Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift` | New attributes decode; the eleven existing fixtures still decode unchanged. |
| `Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift` | One test per role-model row, recursion-stop, dedup, menu exclusion. |
| `Tests/MaxMiCaptureTests/GenericPageRegionTests.swift` | The six region rules with a nonzero window origin, plus the two new fixtures. |
| `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift` | Focused element, budget allocation, `truncated`. |
| `Tests/MaxMiCaptureTests/GenericPageExtractorPerformanceTests.swift` | The one wall-clock test in the suite: 20k-node synthetic tree. |
| `Tests/MaxMiCaptureTests/ParserFallthroughTests.swift` | Replaces `NoSilentFallbackTests.swift`: registered parser returning nil now yields generic content plus a fallback marker. |
| `Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift` | Slack / Teams / WhatsApp typed output. |
| `Tests/MaxMiCaptureTests/StructuredMailParserTests.swift` | Mail `MailRecord` → `Message` mapping. |
| `Tests/MaxMiCaptureTests/StructuredEntityTypedTests.swift` | Calendar/Fantastical `.calendar` and the five task apps' `.tasks`. |
| `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift` | Prompt-regex segmentation, `isRunning`, failure → one segment with `command: nil`. |
| `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift` | Browser generic + conversation typed output. |
| `Tests/MaxMiCaptureTests/GenericV2ParserTests.swift` | The nine generic-v2 parsers keep their `contentKind` overrides. |
| `Tests/MaxMiStoreTests/MigrationV10Tests.swift` | Both columns exist, are nullable, `currentIdentifier == "v10"`. |
| `Tests/MaxMiStoreTests/StructuredContextReadTests.swift` | Read path: real envelope, NULL, corrupt, future-version — all four outcomes. |
| `Tests/MaxMiStoreTests/StructuredCommitTests.swift` | `commitCapture` writes both columns, accumulates by shape, returns the delta. |
| `Tests/MaxMiMCPTests/MCPStructuredNoChangeTests.swift` | The §4g guard: tool surface and rendered output unchanged by structured capture. |

### Modified

| File | Change |
|---|---|
| `Sources/MaxMiCapture/AXSnapshot.swift` | `AXNode` gains `subrole`, `headingLevel`, `selected`, `placeholder`, `selectedText`, `hidden`; `init` defaults them; `CodingKeys`/`init(from:)`/`encode(to:)` handle them with `decodeIfPresent` so the eleven existing fixtures decode unchanged. |
| `Sources/MaxMiCapture/AXReader.swift` | `convert` fetches the new attributes under the §8 conditions; new `focusedElementSnapshot(pid:)`. |
| `Sources/MaxMiCore/CaptureEnvelope.swift` | `CaptureEnvelope` gains non-optional `structured`; `init` takes `structured: CapturedContent? = nil` and resolves nil through `LegacyContentAdapter`; `legacy(…)` unchanged externally. `CaptureAccumulator.bound` becomes internal so `ContentRenderer` can reuse the head/tail policy. `CommitResult` is in `MaxMiStore`, not here. |
| `Sources/MaxMiCapture/SourceParser.swift` | `ParsedCapture` gains `structured: CapturedContent?` (last init parameter, defaulted nil); `envelope(…)` gains `structured:`; `SourceParser` gains `parseStructured` with a nil default. |
| `Sources/MaxMiCapture/DocumentExtraction.swift` | Doc comment marking `bodyText` legacy. No behaviour change — Notes/Notion/Obsidian/Word/Pages/Outlook/Spark still call it via generic v2's fallback until Phase D. |
| `Sources/MaxMiCapture/GenericAXParser.swift` | `parseStructured` built on `GenericPageExtractor`; `parse` becomes a render wrapper. Key derivation and the `ApplicationRegistry`-driven kind/offscreen mapping are untouched. |
| `Sources/MaxMiCapture/ParserRegistry.swift` | `CaptureDispatch.ParseResult` gains `.parsedByFallback(ParsedCapture, failedParser: String)`; `parseDetailed` implements §4f's four rules. |
| `Sources/MaxMiCapture/SlackParser.swift`, `NativeConversationParser.swift`, `MailParser.swift`, `StructuredNativeParsers.swift`, `TerminalParser.swift`, `WebAppCaptureParser.swift`, `BrowserTabExtractor.swift`, `NotesParser.swift`, `NotionParser.swift`, `ObsidianParser.swift`, `DiscordParser.swift`, `MessagesParser.swift` | Typed output per §4f. |
| `Sources/MaxMiStore/Migrations.swift` | `registerMigration("v10")`; `currentIdentifier = "v10"`. |
| `Sources/MaxMiStore/StoreAPI.swift` | `CommitResult.committed` gains `delta:`; `commitCapture` reads the previous structured value, calls the structured merge, and writes `structured_ciphertext` on both tables. |
| `Sources/MaxMiStore/LatestContextStore.swift` | `LatestContextRecord` gains `structured: CapturedContent`; both construction sites (`:67`, `:155`) route NULL/corrupt through `LegacyContentAdapter`. |
| `Sources/MaxMi/AppWiring.swift` | The two `case .committed(let versionID, _)` sites (`:1574`, `:1592`) take a third binding; the `CaptureDispatch.parseDetailed` switch handles `.parsedByFallback`; `parsed.envelope(…)` passes `structured:`. |
| `Tests/MaxMiCaptureTests/Fixtures/README.md` | Rows for the three new fixtures. |
| 10 existing test files | `case .committed(let x, _)` → `case .committed(let x, _, _)`. Exact list in Task 9. |

### Deleted

| File | Why |
|---|---|
| `Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift` | Asserts the behaviour §4f rule 3 deliberately reverses. Replaced by `ParserFallthroughTests.swift` in Task 10. |

---

### Task 1: `CapturedContent` typed capture shapes

**Files:**
- Create: `Sources/MaxMiCore/CapturedContent.swift`
- Test: `Tests/MaxMiCoreTests/CapturedContentTests.swift`

**Interfaces:**
- Consumes: `CaptureContentKind` (`Sources/MaxMiCore/CaptureEnvelope.swift:3`), `ContentHash.sha256Hex(_:)` (`Sources/MaxMiCore/Hashing.swift:5`).
- Produces: `Authorship`, `BlockType`, `Block`, `RegionKind`, `Region`, `FocusedElement`, `GenericPage`, `Document`, `Message` (+ `Message.makeID(sender:timeString:text:)`), `Conversation`, `TaskStatus`, `TaskItem`, `CalendarEvent`, `TerminalSegment`, `TerminalSession`, `CapturedContent` (+ `var kind: CaptureContentKind`), `CapturedContentEnvelope` (+ `currentSchemaVersion`, `encode(_:) throws -> String`, `decode(_:) -> CapturedContent?`). Every type is `public`, `Codable`, `Sendable`, `Equatable` with an explicit `public init`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCoreTests/CapturedContentTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class CapturedContentTests: XCTestCase {
    func roundTrip(_ content: CapturedContent) throws -> CapturedContent {
        let json = try CapturedContentEnvelope.encode(content)
        return try XCTUnwrap(CapturedContentEnvelope.decode(json))
    }

    func testDocumentRoundTrip() throws {
        let content = CapturedContent.document(Document(
            title: "Design notes",
            blocks: [
                Block(type: .heading(level: 1), text: "Design notes"),
                Block(type: .paragraph, text: "First paragraph"),
                Block(type: .listItem(depth: 1), text: "Nested bullet"),
            ],
            author: .other("Ana"),
            url: nil
        ))
        XCTAssertEqual(try roundTrip(content), content)
    }

    func testConversationRoundTripKeepsMessageIdentity() throws {
        let content = CapturedContent.conversation(Conversation(
            channel: "#maxmi-dev",
            isGroup: true,
            messages: [
                Message(id: Message.makeID(sender: "Ana", timeString: "09:20", text: "ping"),
                        sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                        isUser: false, isDraft: false),
                Message(id: "draft:composer", sender: "You", text: "on it",
                        timestamp: nil, timeString: nil, isUser: true, isDraft: true),
            ]
        ))
        XCTAssertEqual(try roundTrip(content), content)
    }

    func testTasksCalendarTerminalGenericRoundTrip() throws {
        let tasks = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: "Fri",
                     project: "MaxMi", tags: ["ship"], notes: "two lines\nsecond"),
            TaskItem(title: "Done thing", status: .completed, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        XCTAssertEqual(try roundTrip(tasks), tasks)

        let calendar = CapturedContent.calendar([
            CalendarEvent(title: "Daily Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: "Ana", location: "Room 2", hasConference: true,
                          notes: "agenda line one\nagenda line two"),
            CalendarEvent(title: "Solo block", dateString: "Mon 11:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(try roundTrip(calendar), calendar)

        let terminal = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
            TerminalSegment(command: nil, output: "raw blob", isRunning: true),
        ]))
        XCTAssertEqual(try roundTrip(terminal), terminal)

        let generic = CapturedContent.generic(GenericPage(
            regions: [
                Region(kind: .main, blocks: [Block(type: .tableRow(cells: ["a", "b"], selected: true), text: "a b")]),
                Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            ],
            focused: FocusedElement(role: "AXTextField", identifier: "search", value: "vec0",
                                    selectedText: "vec", isSecure: false),
            url: "https://example.com/a"
        ))
        XCTAssertEqual(try roundTrip(generic), generic)
    }

    func testAuthorshipAndInputPayloadsRoundTrip() throws {
        for author in [Authorship.user, .other("Ana"), .unknown] {
            let content = CapturedContent.document(Document(
                title: "T",
                blocks: [Block(type: .input(placeholder: "Search"), text: "", authoredByUser: true)],
                author: author, url: nil
            ))
            XCTAssertEqual(try roundTrip(content), content)
        }
    }

    func testEncodingIsDeterministic() throws {
        let content = CapturedContent.generic(GenericPage(
            regions: [Region(kind: .main, blocks: [
                Block(type: .paragraph, text: "slash / and unicode ✓"),
                Block(type: .heading(level: 3), text: "h3"),
            ])],
            focused: nil,
            url: "https://example.com/a/b"
        ))
        let first = try CapturedContentEnvelope.encode(content)
        let second = try CapturedContentEnvelope.encode(content)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("https://example.com/a/b"), "slashes are not escaped")
        XCTAssertTrue(first.hasPrefix("{\"content\""), "keys are sorted, so `content` precedes `v`")
    }

    func testDecodeRejectsFutureSchemaVersionAndGarbage() {
        XCTAssertNil(CapturedContentEnvelope.decode("{\"v\":2,\"content\":{\"generic\":{\"_0\":{\"regions\":[]}}}}"))
        XCTAssertNil(CapturedContentEnvelope.decode("not json"))
        XCTAssertNil(CapturedContentEnvelope.decode(""))
    }

    func testKindDefaultsPerShape() {
        XCTAssertEqual(CapturedContent.document(Document(title: "t", blocks: [], author: .unknown, url: nil)).kind, .document)
        XCTAssertEqual(CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [])).kind, .conversation)
        XCTAssertEqual(CapturedContent.tasks([]).kind, .task)
        XCTAssertEqual(CapturedContent.calendar([]).kind, .calendar)
        XCTAssertEqual(CapturedContent.terminal(TerminalSession(cwd: nil, segments: [])).kind, .terminal)
        XCTAssertEqual(CapturedContent.generic(GenericPage(regions: [], focused: nil, url: nil)).kind, .generic)
    }

    func testMakeIDIsStableAndOrderIndependent() {
        let a = Message.makeID(sender: "Ana", timeString: "09:20", text: "ping")
        let b = Message.makeID(sender: "Ana", timeString: "09:20", text: "ping")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 24)
        XCTAssertNotEqual(a, Message.makeID(sender: "Ana", timeString: nil, text: "ping"))
        XCTAssertNotEqual(a, Message.makeID(sender: "Bo", timeString: "09:20", text: "ping"))
    }

    func testBlockAuthoredByUserDefaultsFalseAndDecodesWhenAbsent() throws {
        XCTAssertFalse(Block(type: .paragraph, text: "x").authoredByUser)
        let decoder = JSONDecoder()
        let block = try decoder.decode(Block.self, from: Data("{\"type\":{\"paragraph\":{}},\"text\":\"x\"}".utf8))
        XCTAssertFalse(block.authoredByUser)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CapturedContentTests`
Expected: FAIL to compile — "cannot find 'CapturedContent' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCore/CapturedContent.swift`:

```swift
import Foundation

public enum Authorship: Codable, Sendable, Equatable {
    case user
    case other(String)
    case unknown
}

public enum BlockType: Codable, Sendable, Equatable {
    /// Clamped to 1...6 by `ContentRenderer`; the extractor clamps on the way in too.
    case heading(level: Int)
    case paragraph
    /// 0-based nesting depth.
    case listItem(depth: Int)
    /// Button/link/menu-item/tab/checkbox/image label.
    case label
    case tableRow(cells: [String], selected: Bool)
    /// Text field / text area / combo box value.
    case input(placeholder: String?)
}

public struct Block: Codable, Sendable, Equatable {
    public let type: BlockType
    public let text: String
    /// Set by `TypingObserver` (Phase B) when this block came from the focused field
    /// the user typed into. Absent in stored JSON written before Phase B.
    public let authoredByUser: Bool

    public init(type: BlockType, text: String, authoredByUser: Bool = false) {
        self.type = type
        self.text = text
        self.authoredByUser = authoredByUser
    }

    private enum CodingKeys: String, CodingKey { case type, text, authoredByUser }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(BlockType.self, forKey: .type)
        text = try c.decode(String.self, forKey: .text)
        authoredByUser = try c.decodeIfPresent(Bool.self, forKey: .authoredByUser) ?? false
    }
}

public enum RegionKind: String, Codable, Sendable, CaseIterable {
    case main, sidebar, navigation, toolbar, dialog, banner, footer, unknown
}

public struct Region: Codable, Sendable, Equatable {
    public let kind: RegionKind
    public let blocks: [Block]

    public init(kind: RegionKind, blocks: [Block]) {
        self.kind = kind
        self.blocks = blocks
    }
}

public struct FocusedElement: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    /// nil when `isSecure` — a secure field's value is never read, not merely not stored.
    public let value: String?
    public let selectedText: String?
    public let isSecure: Bool

    public init(role: String, identifier: String?, value: String?, selectedText: String?, isSecure: Bool) {
        self.role = role
        self.identifier = identifier
        self.value = isSecure ? nil : value
        self.selectedText = selectedText
        self.isSecure = isSecure
    }
}

public struct GenericPage: Codable, Sendable, Equatable {
    public let regions: [Region]
    public let focused: FocusedElement?
    public let url: String?

    public init(regions: [Region], focused: FocusedElement?, url: String?) {
        self.regions = regions
        self.focused = focused
        self.url = url
    }
}

public struct Document: Codable, Sendable, Equatable {
    public let title: String
    public let blocks: [Block]
    public let author: Authorship
    public let url: String?

    public init(title: String, blocks: [Block], author: Authorship, url: String?) {
        self.title = title
        self.blocks = blocks
        self.author = author
        self.url = url
    }
}

public struct Message: Codable, Sendable, Equatable {
    /// Stable fingerprint. See `Message.makeID`.
    public let id: String
    public let sender: String
    public let text: String
    public let timestamp: Date?
    public let timeString: String?
    public let isUser: Bool
    public let isDraft: Bool

    public init(id: String, sender: String, text: String, timestamp: Date?,
                timeString: String?, isUser: Bool, isDraft: Bool) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.timeString = timeString
        self.isUser = isUser
        self.isDraft = isDraft
    }

    /// Deterministic and order-independent, so accumulation can union by identity.
    public static func makeID(sender: String, timeString: String?, text: String) -> String {
        String(ContentHash.sha256Hex("\(sender)\u{1F}\(timeString ?? "")\u{1F}\(text)").prefix(24))
    }
}

public struct Conversation: Codable, Sendable, Equatable {
    public let channel: String
    public let isGroup: Bool
    public let messages: [Message]

    public init(channel: String, isGroup: Bool, messages: [Message]) {
        self.channel = channel
        self.isGroup = isGroup
        self.messages = messages
    }
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case completed, open, unknown
}

public struct TaskItem: Codable, Sendable, Equatable {
    public let title: String
    public let status: TaskStatus
    public let due: Date?
    public let dueString: String?
    public let project: String?
    public let tags: [String]
    public let notes: String?

    public init(title: String, status: TaskStatus, due: Date?, dueString: String?,
                project: String?, tags: [String], notes: String?) {
        self.title = title
        self.status = status
        self.due = due
        self.dueString = dueString
        self.project = project
        self.tags = tags
        self.notes = notes
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable {
    public let title: String
    public let dateString: String
    public let start: Date?
    public let end: Date?
    public let organizer: String?
    public let location: String?
    public let hasConference: Bool
    /// The event's detail/notes body, as the app exposes it.
    public let notes: String?

    public init(title: String, dateString: String, start: Date?, end: Date?,
                organizer: String?, location: String?, hasConference: Bool, notes: String?) {
        self.title = title
        self.dateString = dateString
        self.start = start
        self.end = end
        self.organizer = organizer
        self.location = location
        self.hasConference = hasConference
        self.notes = notes
    }
}

public struct TerminalSegment: Codable, Sendable, Equatable {
    /// nil when segmentation failed — the whole scrollback lands in `output`.
    public let command: String?
    public let output: String
    public let isRunning: Bool

    public init(command: String?, output: String, isRunning: Bool) {
        self.command = command
        self.output = output
        self.isRunning = isRunning
    }
}

public struct TerminalSession: Codable, Sendable, Equatable {
    public let cwd: String?
    public let segments: [TerminalSegment]

    public init(cwd: String?, segments: [TerminalSegment]) {
        self.cwd = cwd
        self.segments = segments
    }
}

public enum CapturedContent: Codable, Sendable, Equatable {
    case document(Document)
    case conversation(Conversation)
    case tasks([TaskItem])
    case calendar([CalendarEvent])
    case terminal(TerminalSession)
    case generic(GenericPage)

    /// The DEFAULT `CaptureContentKind` for this shape. Parsers may override:
    /// `.email` and `.webpage` are not derivable from the shape.
    public var kind: CaptureContentKind {
        switch self {
        case .document:     return .document
        case .conversation: return .conversation
        case .tasks:        return .task
        case .calendar:     return .calendar
        case .terminal:     return .terminal
        case .generic:      return .generic
        }
    }
}

/// Persisted JSON is wrapped so the shape can evolve without a column migration.
public struct CapturedContentEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let v: Int
    public let content: CapturedContent

    public init(v: Int = CapturedContentEnvelope.currentSchemaVersion, content: CapturedContent) {
        self.v = v
        self.content = content
    }

    /// Deterministic bytes: sorted keys, unescaped slashes, ISO-8601 dates. Needed for
    /// hashing and for golden fixtures.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ content: CapturedContent) throws -> String {
        let data = try makeEncoder().encode(CapturedContentEnvelope(content: content))
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for malformed JSON and for `v > currentSchemaVersion`. The caller treats nil
    /// exactly like a NULL column and falls back to `LegacyContentAdapter`.
    public static func decode(_ json: String) -> CapturedContent? {
        guard let envelope = try? makeDecoder().decode(CapturedContentEnvelope.self, from: Data(json.utf8)),
              envelope.v <= currentSchemaVersion else { return nil }
        return envelope.content
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CapturedContentTests`
Expected: PASS, 8 tests.

If `testEncodingIsDeterministic`'s `hasPrefix("{\"content\"")` assertion fails, print `first` and fix the assertion to the actual sorted-key order rather than changing the encoder — `.sortedKeys` is the constraint, the prefix is only evidence of it.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCore/CapturedContent.swift Tests/MaxMiCoreTests/CapturedContentTests.swift
git commit -m "Add CapturedContent typed capture enum"
```

---

### Task 2: `ContentRenderer` — the deterministic wire text

**Files:**
- Create: `Sources/MaxMiCore/ContentRenderer.swift`
- Modify: `Sources/MaxMiCore/CaptureEnvelope.swift` — `private static func bound` becomes internal `static func bound` (last function in `enum CaptureAccumulator`) so `.compact`/`.mainOnly` reuse the existing head/tail policy instead of duplicating it.
- Test: `Tests/MaxMiCoreTests/ContentRendererTests.swift`

**Interfaces:**
- Consumes: everything from Task 1; `CaptureAccumulator.bound(_:to:)`.
- Produces: `RenderStyle` (`.full`, `.compact(maxChars: Int)`, `.mainOnly(maxChars: Int)`), `ContentRenderer.render(_:style:) -> String`, and the per-item renderers later tasks size things with: `ContentRenderer.renderBlock(_ block: Block) -> String`, `renderBlocks(_ blocks: [Block]) -> String`, `renderMessage(_ message: Message) -> String`, `renderTask(_ item: TaskItem) -> String`, `renderEvent(_ event: CalendarEvent) -> String`, `renderSegment(_ segment: TerminalSegment) -> String`, `formatTimestamp(_ date: Date) -> String`, `regionOrder: [RegionKind]`, `regionHeader(_ kind: RegionKind) -> String?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCoreTests/ContentRendererTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class ContentRendererTests: XCTestCase {
    func full(_ content: CapturedContent) -> String { ContentRenderer.render(content, style: .full) }

    func testDocumentGolden() {
        let content = CapturedContent.document(Document(
            title: "Design notes",
            blocks: [
                Block(type: .paragraph, text: "Intro line"),
                Block(type: .heading(level: 2), text: "Regions"),
                Block(type: .listItem(depth: 0), text: "top"),
                Block(type: .listItem(depth: 1), text: "nested"),
            ],
            author: .user, url: nil
        ))
        XCTAssertEqual(full(content), "# Design notes\n\nIntro line\n## Regions\n- top\n  - nested")
    }

    func testDocumentWithNoBlocksIsJustTheTitle() {
        let content = CapturedContent.document(Document(title: "Empty", blocks: [], author: .unknown, url: nil))
        XCTAssertEqual(full(content), "# Empty")
    }

    func testConversationGoldenUsesYouAndSentClause() {
        let content = CapturedContent.conversation(Conversation(channel: "#maxmi-dev", isGroup: true, messages: [
            Message(id: "1", sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                    isUser: false, isDraft: false),
            Message(id: "2", sender: "Sudhanshu", text: "on it", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: false),
            Message(id: "3", sender: "Sudhanshu", text: "typing this", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: true),
        ]))
        XCTAssertEqual(full(content), """
        (From: Ana)(sent 09:20): ping
        (From: You): on it
        (From: You (draft)): typing this
        """)
    }

    func testConversationNeverRendersUserMarker() {
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "[user]", text: "hi", timestamp: nil, timeString: nil,
                    isUser: true, isDraft: false),
        ]))
        XCTAssertFalse(full(content).contains("[user]"), "isUser renders as You, never as the internal marker")
        XCTAssertEqual(full(content), "(From: You): hi")
    }

    func testConversationFormatsTimestampWhenTimeStringMissing() {
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "Ana", text: "hi", timestamp: date, timeString: nil,
                    isUser: false, isDraft: false),
        ]))
        XCTAssertEqual(full(content), "(From: Ana)(sent \(ContentRenderer.formatTimestamp(date))): hi")
        XCTAssertNotNil(ContentRenderer.formatTimestamp(date)
            .range(of: "^[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{2}:[0-9]{2} .+$", options: .regularExpression),
            "MMM d, HH:mm zzz")
    }

    func testConversationIndentsContinuationLines() {
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: false, messages: [
            Message(id: "1", sender: "Ana", text: "line one\nline two", timestamp: nil, timeString: nil,
                    isUser: false, isDraft: false),
        ]))
        XCTAssertEqual(full(content), "(From: Ana): line one\n  line two")
    }

    func testTasksGolden() {
        let content = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: "Fri",
                     project: "MaxMi", tags: ["ship", "m8"], notes: "note a\nnote b"),
            TaskItem(title: "Done thing", status: .completed, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
            TaskItem(title: "Maybe", status: .unknown, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        XCTAssertEqual(full(content), """
        - [ ] Ship M8a (due Fri) [MaxMi] #ship #m8
          note a
          note b
        - [x] Done thing
        - Maybe
        """)
    }

    func testCalendarGolden() {
        let content = CapturedContent.calendar([
            CalendarEvent(title: "Daily Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: "Ana", location: "Room 2", hasConference: true,
                          notes: "Bring the metrics"),
            CalendarEvent(title: "Solo block", dateString: "Mon 11:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(full(content), """
        Mon 09:00 — Daily Sync @Room 2 / Ana [conference]
        Details: Bring the metrics
        Mon 11:00 — Solo block
        """)
    }

    func testCalendarNotesKeepFurtherLinesIndented() {
        let content = CapturedContent.calendar([
            CalendarEvent(title: "Review", dateString: "Tue 14:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false,
                          notes: "line one\nline two"),
        ])
        XCTAssertEqual(full(content), "Tue 14:00 — Review\nDetails: line one\n  line two")
    }

    func testTerminalGolden() {
        let content = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
            TerminalSegment(command: "swift build", output: "compiling", isRunning: true),
        ]))
        XCTAssertEqual(full(content), "$ swift test\n2 failures\n\n$ swift build\ncompiling\n… (running)")
    }

    func testTerminalSegmentWithoutCommandRendersOutputOnly() {
        let content = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: nil, output: "raw blob", isRunning: false),
        ]))
        XCTAssertEqual(full(content), "raw blob")
    }

    func testGenericRegionOrderAndHeaders() {
        let content = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .footer, blocks: [Block(type: .paragraph, text: "foot")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")]),
            Region(kind: .dialog, blocks: [Block(type: .paragraph, text: "Quit?")]),
            Region(kind: .navigation, blocks: [Block(type: .label, text: "Back")]),
            Region(kind: .toolbar, blocks: [Block(type: .paragraph, text: "Uploading 34 items")]),
            Region(kind: .banner, blocks: [Block(type: .paragraph, text: "Offline")]),
            Region(kind: .unknown, blocks: [Block(type: .paragraph, text: "stray")]),
        ], focused: nil, url: "https://example.com/a"))
        XCTAssertEqual(full(content), """
        URL: https://example.com/a
        body
        ## Dialog
        Quit?
        ## Sidebar
        Downloads
        ## Navigation
        Back
        ## Toolbar
        Uploading 34 items
        ## Banner
        Offline
        ## Footer
        foot
        ## Other
        stray
        """)
    }

    func testBlockRenderingRules() {
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 3), text: "h")), "### h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 9), text: "h")), "###### h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .heading(level: 0), text: "h")), "# h")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .label, text: "Send")), "Send")
        XCTAssertEqual(
            ContentRenderer.renderBlock(Block(type: .tableRow(cells: ["a", "b", "c"], selected: false), text: "")),
            "a | b | c")
        XCTAssertEqual(
            ContentRenderer.renderBlock(Block(type: .tableRow(cells: ["a", "b"], selected: true), text: "")),
            "* a | b")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: "Search"), text: "")), "«Search»")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: nil), text: "")), "«empty field»")
        XCTAssertEqual(ContentRenderer.renderBlock(Block(type: .input(placeholder: "Search"), text: "vec0")), "vec0")
    }

    func testCompactBoundsWithHeadAndTail() {
        let messages = (0..<40).map {
            Message(id: "\($0)", sender: "Ana", text: "message number \($0)", timestamp: nil,
                    timeString: nil, isUser: false, isDraft: false)
        }
        let content = CapturedContent.conversation(Conversation(channel: "c", isGroup: true, messages: messages))
        let compact = ContentRenderer.render(content, style: .compact(maxChars: 300))
        XCTAssertEqual(compact.count, 300)
        XCTAssertTrue(compact.contains("\n…\n"))
        XCTAssertTrue(compact.hasPrefix("(From: Ana): message number 0"), "identity-bearing head survives")
        XCTAssertTrue(compact.hasSuffix("message number 39"), "recent tail survives")
    }

    func testMainOnlyKeepsMainAndDialogWithoutHeaders() {
        let content = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Downloads")]),
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")]),
            Region(kind: .dialog, blocks: [Block(type: .paragraph, text: "Quit?")]),
        ], focused: nil, url: "https://example.com/a"))
        XCTAssertEqual(ContentRenderer.render(content, style: .mainOnly(maxChars: 1_000)), "body\nQuit?")
    }

    func testMainOnlyFallsBackToCompactForNonGenericShapes() {
        let content = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        XCTAssertEqual(ContentRenderer.render(content, style: .mainOnly(maxChars: 1_000)),
                       ContentRenderer.render(content, style: .compact(maxChars: 1_000)))
    }

    func testEmptyGenericPageRendersEmptyString() {
        XCTAssertEqual(full(.generic(GenericPage(regions: [], focused: nil, url: nil))), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ContentRendererTests`
Expected: FAIL to compile — "cannot find 'ContentRenderer' in scope".

- [ ] **Step 3: Write minimal implementation**

First make the existing head/tail bound reusable. In `Sources/MaxMiCore/CaptureEnvelope.swift`, change the last function of `enum CaptureAccumulator` from:

```swift
    private static func bound(_ content: String, to limit: Int) -> String {
```

to:

```swift
    /// Retain the identity-bearing beginning and the more recent tail. Internal (not private)
    /// because `ContentRenderer.render(_, .compact:)` is defined as exactly this policy.
    static func bound(_ content: String, to limit: Int) -> String {
```

Then create `Sources/MaxMiCore/ContentRenderer.swift`:

```swift
import Foundation

public enum RenderStyle: Sendable, Equatable {
    case full
    case compact(maxChars: Int)
    case mainOnly(maxChars: Int)
}

/// Pure, total, deterministic `CapturedContent` -> `String`. `.full` is what goes into
/// `versions.content` and `latest_contexts.content_ciphertext`, so search, embeddings, MCP,
/// and `message_fingerprints` keep working unchanged. `.compact` and `.mainOnly` exist only
/// to feed prompts.
public enum ContentRenderer {
    /// Fixed render order. `.main` gets no header; everything else is announced.
    public static let regionOrder: [RegionKind] = [
        .main, .dialog, .sidebar, .navigation, .toolbar, .banner, .footer, .unknown,
    ]

    public static func regionHeader(_ kind: RegionKind) -> String? {
        switch kind {
        case .main:       return nil
        case .dialog:     return "## Dialog"
        case .sidebar:    return "## Sidebar"
        case .navigation: return "## Navigation"
        case .toolbar:    return "## Toolbar"
        case .banner:     return "## Banner"
        case .footer:     return "## Footer"
        case .unknown:    return "## Other"
        }
    }

    public static func render(_ content: CapturedContent, style: RenderStyle) -> String {
        switch style {
        case .full:
            return renderFull(content)
        case .compact(let maxChars):
            return CaptureAccumulator.bound(renderFull(content), to: max(4, maxChars))
        case .mainOnly(let maxChars):
            guard case .generic(let page) = content else {
                return CaptureAccumulator.bound(renderFull(content), to: max(4, maxChars))
            }
            // No region headers and no `URL:` line: the prompt's CONTEXT block (spec 6a)
            // already carries app, window, and url as separate fields.
            let blocks = page.regions
                .filter { $0.kind == .main || $0.kind == .dialog }
                .sorted { orderIndex($0.kind) < orderIndex($1.kind) }
                .flatMap(\.blocks)
            return CaptureAccumulator.bound(renderBlocks(blocks), to: max(4, maxChars))
        }
    }

    // MARK: - Per-item renderers (also used for sizing, so nothing has to re-render a page)

    public static func renderBlock(_ block: Block) -> String {
        switch block.type {
        case .heading(let level):
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + block.text
        case .paragraph:
            return block.text
        case .listItem(let depth):
            return String(repeating: "  ", count: max(0, depth)) + "- " + block.text
        case .label:
            return block.text
        case .tableRow(let cells, let selected):
            return (selected ? "* " : "") + cells.joined(separator: " | ")
        case .input(let placeholder):
            return block.text.isEmpty ? "«\(placeholder ?? "empty field")»" : block.text
        }
    }

    public static func renderBlocks(_ blocks: [Block]) -> String {
        blocks.map(renderBlock).joined(separator: "\n")
    }

    public static func renderMessage(_ message: Message) -> String {
        var sender = message.isUser ? "You" : message.sender
        if message.isDraft { sender += " (draft)" }
        var head = "(From: \(sender))"
        if let stamp = message.timeString ?? message.timestamp.map(formatTimestamp) {
            head += "(sent \(stamp))"
        }
        let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = "\(head): \(lines.first ?? "")"
        for line in lines.dropFirst() { out += "\n  " + line }
        return out
    }

    public static func renderTask(_ item: TaskItem) -> String {
        var line: String
        switch item.status {
        case .completed: line = "- [x] "
        case .open:      line = "- [ ] "
        case .unknown:   line = "- "
        }
        line += item.title
        if let due = item.dueString, !due.isEmpty { line += " (due \(due))" }
        if let project = item.project, !project.isEmpty { line += " [\(project)]" }
        for tag in item.tags { line += " #\(tag)" }
        if let notes = item.notes, !notes.isEmpty {
            for note in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                line += "\n  " + note
            }
        }
        return line
    }

    public static func renderEvent(_ event: CalendarEvent) -> String {
        var line = "\(event.dateString) — \(event.title)"
        if let location = event.location, !location.isEmpty { line += " @\(location)" }
        if let organizer = event.organizer, !organizer.isEmpty { line += " / \(organizer)" }
        if event.hasConference { line += " [conference]" }
        if let notes = event.notes, !notes.isEmpty {
            let lines = notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            line += "\nDetails: \(lines.first ?? "")"
            for extra in lines.dropFirst() { line += "\n  " + extra }
        }
        return line
    }

    public static func renderSegment(_ segment: TerminalSegment) -> String {
        var parts: [String] = []
        if let command = segment.command { parts.append("$ \(command)") }
        if !segment.output.isEmpty { parts.append(segment.output) }
        if segment.isRunning { parts.append("… (running)") }
        return parts.joined(separator: "\n")
    }

    /// `Message.timestamp` fallback format, local timezone.
    public static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    // MARK: - Private

    /// `DateFormatter` is thread-safe for formatting on macOS. Held once rather than rebuilt
    /// per message: a rendered conversation can carry hundreds of messages per capture.
    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, HH:mm zzz"
        return formatter
    }()

    private static func orderIndex(_ kind: RegionKind) -> Int {
        regionOrder.firstIndex(of: kind) ?? regionOrder.count
    }

    private static func renderFull(_ content: CapturedContent) -> String {
        switch content {
        case .document(let doc):
            let body = renderBlocks(doc.blocks)
            return body.isEmpty ? "# \(doc.title)" : "# \(doc.title)\n\n\(body)"
        case .conversation(let conversation):
            return conversation.messages.map(renderMessage).joined(separator: "\n")
        case .tasks(let items):
            return items.map(renderTask).joined(separator: "\n")
        case .calendar(let events):
            return events.map(renderEvent).joined(separator: "\n")
        case .terminal(let session):
            return session.segments.map(renderSegment).joined(separator: "\n\n")
        case .generic(let page):
            var chunks: [String] = []
            if let url = page.url, !url.isEmpty { chunks.append("URL: \(url)") }
            for kind in regionOrder {
                let blocks = page.regions.filter { $0.kind == kind }.flatMap(\.blocks)
                guard !blocks.isEmpty else { continue }
                let body = renderBlocks(blocks)
                if let header = regionHeader(kind) {
                    chunks.append("\(header)\n\(body)")
                } else {
                    chunks.append(body)
                }
            }
            return chunks.joined(separator: "\n")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ContentRendererTests`
Expected: PASS, 18 tests.

Then confirm nothing regressed in the string accumulator whose `bound` you just re-scoped:

Run: `swift test --filter CaptureAccumulatorTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCore/ContentRenderer.swift Sources/MaxMiCore/CaptureEnvelope.swift \
        Tests/MaxMiCoreTests/ContentRendererTests.swift
git commit -m "Add ContentRenderer for deterministic capture text"
```

---

### Task 3: `LegacyContentAdapter` + `CaptureEnvelope.structured`

**Files:**
- Create: `Sources/MaxMiCore/LegacyContentAdapter.swift`
- Modify: `Sources/MaxMiCore/CaptureEnvelope.swift` — `CaptureEnvelope` gains `public let structured: CapturedContent` and its `init` gains `structured: CapturedContent? = nil` as the **last** parameter.
- Test: `Tests/MaxMiCoreTests/LegacyContentAdapterTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `ContentRenderer.render(_:style:)`.
- Produces: `LegacyContentAdapter.adapt(renderedContent: String, kind: CaptureContentKind) -> CapturedContent`; `CaptureEnvelope.structured: CapturedContent` (non-optional) plus the tolerant `init(…, structured: CapturedContent? = nil)`. The invariant every later task relies on: **`envelope.content == ContentRenderer.render(envelope.structured, style: .full)`**.

The six existing `CaptureEnvelope(` construction sites (`Tests/MaxMiStoreTests/LatestContextStoreTests.swift:56`, `Tests/MaxMiStoreTests/CaptureSummaryStoreTests.swift:70`, `Tests/MaxMiStoreTests/LocalMemorySearchTests.swift:44`, `Tests/MaxMiMCPTests/MemoryQueriesTests.swift:137,218,224`) must keep compiling untouched — that is why `structured:` is defaulted and last.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCoreTests/LegacyContentAdapterTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class LegacyContentAdapterTests: XCTestCase {
    /// A corpus of strings shaped like real rendered captures, including the blank lines a
    /// rendered `.document` and a multi-segment `.terminal` produce.
    static let corpus: [String] = [
        "",
        "single line",
        "Alice: one\nBob: two\nCarol: three",
        "# Design notes\n\nIntro line\n## Regions\n- top\n  - nested",
        "$ swift test\n2 failures\n\n$ swift build\ncompiling\n… (running)",
        "URL: https://example.com/a\nbody\n## Sidebar\nDownloads",
        "leading blank\n\n\ntrailing newline\n",
        "\nstarts with a newline",
        "tabs\tand   spaces  ",
    ]

    func testAdaptProducesOneMainRegionOfParagraphs() {
        guard case .generic(let page) = LegacyContentAdapter.adapt(
            renderedContent: "one\ntwo", kind: .conversation
        ) else { return XCTFail("adapt always returns .generic") }
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.regions[0].kind, .main)
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["one", "two"])
        XCTAssertEqual(page.regions[0].blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertNil(page.focused)
        XCTAssertNil(page.url)
    }

    func testAdaptIgnoresKindAndAlwaysReturnsGeneric() {
        for kind in CaptureContentKind.allCases {
            XCTAssertEqual(LegacyContentAdapter.adapt(renderedContent: "x", kind: kind).kind, .generic)
        }
    }

    func testRoundTripIsByteForByte() {
        for original in Self.corpus {
            let adapted = LegacyContentAdapter.adapt(renderedContent: original, kind: .generic)
            XCTAssertEqual(ContentRenderer.render(adapted, style: .full), original,
                           "round-trip must be byte-for-byte for \(original.debugDescription)")
        }
    }

    func testEnvelopeWithoutStructuredKeepsContentAndAdapts() {
        let envelope = CaptureEnvelope(
            sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
            content: "note body\n\nsecond paragraph", contentKind: .document,
            parserID: "NotesParser", parserVersion: 1,
            accumulationPolicy: .rollingText, offscreenPolicy: .visibleOnly(),
            trigger: .appActivated, truncated: false
        )
        XCTAssertEqual(envelope.content, "note body\n\nsecond paragraph")
        XCTAssertEqual(envelope.structured.kind, .generic)
        XCTAssertEqual(ContentRenderer.render(envelope.structured, style: .full), envelope.content)
    }

    func testEnvelopeWithStructuredDerivesContentFromIt() {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true,
            messages: [Message(id: "1", sender: "Ana", text: "ping", timestamp: nil,
                               timeString: "09:20", isUser: false, isDraft: false)]
        ))
        let envelope = CaptureEnvelope(
            sourceApp: "Slack", sourceKey: "slack:acme/dev", sourceTitle: "dev",
            content: "IGNORED", contentKind: .conversation,
            parserID: "SlackParser", parserVersion: 2,
            accumulationPolicy: .appendItems, offscreenPolicy: .visibleOnly(),
            trigger: .conversationChanged, truncated: false,
            structured: structured
        )
        XCTAssertEqual(envelope.content, "(From: Ana)(sent 09:20): ping")
        XCTAssertEqual(envelope.structured, structured)
    }

    func testLegacyFactoryStillWorksAndCarriesGenericStructure() {
        let envelope = CaptureEnvelope.legacy(
            sourceApp: "Web", sourceKey: "https://example.com", sourceTitle: "T", content: "a\nb"
        )
        XCTAssertEqual(envelope.contentKind, .generic)
        XCTAssertEqual(envelope.parserID, "legacy")
        XCTAssertEqual(envelope.content, "a\nb")
        XCTAssertEqual(ContentRenderer.render(envelope.structured, style: .full), "a\nb")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LegacyContentAdapterTests`
Expected: FAIL to compile — "cannot find 'LegacyContentAdapter' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCore/LegacyContentAdapter.swift`:

```swift
import Foundation

/// Adapts an already-rendered capture string into the typed contract, for every row written
/// before schema v10 and every parser that has not been migrated yet.
public enum LegacyContentAdapter {
    /// One `.main` region of `.paragraph` blocks, one per line.
    ///
    /// Empty lines are preserved as empty `.paragraph` blocks: the round-trip invariant
    /// `ContentRenderer.render(adapt(s, kind:), .full) == s` must hold byte-for-byte, and real
    /// rendered captures do contain blank lines (a `.document` renders one after its title).
    ///
    /// `kind` is accepted, and deliberately unused, so the call site reads honestly and so a
    /// future refinement can specialise per kind without changing every caller.
    public static func adapt(renderedContent: String, kind: CaptureContentKind) -> CapturedContent {
        let blocks = renderedContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Block(type: .paragraph, text: String($0)) }
        return .generic(GenericPage(
            regions: [Region(kind: .main, blocks: blocks)],
            focused: nil,
            url: nil
        ))
    }
}
```

Then in `Sources/MaxMiCore/CaptureEnvelope.swift`, add the property to `CaptureEnvelope` right after `truncated`:

```swift
    public let truncated: Bool
    /// The typed shape this capture is stored as. Non-optional: everything downstream of
    /// dispatch (store, prompts, timeline) can rely on it existing.
    public let structured: CapturedContent
```

and change the initializer to accept and resolve it:

```swift
    public init(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String,
        contentKind: CaptureContentKind,
        parserID: String,
        parserVersion: Int,
        accumulationPolicy: CaptureAccumulationPolicy,
        offscreenPolicy: OffscreenCapturePolicy,
        trigger: CaptureTrigger,
        truncated: Bool,
        structured: CapturedContent? = nil
    ) {
        self.sourceApp = sourceApp
        self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle
        self.contentKind = contentKind
        self.parserID = parserID
        self.parserVersion = max(1, parserVersion)
        self.accumulationPolicy = accumulationPolicy
        self.offscreenPolicy = offscreenPolicy
        self.trigger = trigger
        self.truncated = truncated
        // The single place nil is resolved. Every path — CaptureDispatch, the browser
        // pipeline in AppWiring, and CaptureEnvelope.legacy — builds an envelope, so this
        // initializer is the only point that covers all of them.
        if let structured {
            self.structured = structured
            self.content = ContentRenderer.render(structured, style: .full)
        } else {
            self.structured = LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)
            self.content = content
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LegacyContentAdapterTests`
Expected: PASS, 6 tests.

Then confirm the six untouched construction sites still compile and behave:

Run: `swift test --filter LatestContextStoreTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCore/LegacyContentAdapter.swift Sources/MaxMiCore/CaptureEnvelope.swift \
        Tests/MaxMiCoreTests/LegacyContentAdapterTests.swift
git commit -m "Add LegacyContentAdapter and carry structured content on CaptureEnvelope"
```

---

### Task 4: `AXNode` attribute additions + `AXReader` attribute set

**Files:**
- Modify: `Sources/MaxMiCapture/AXSnapshot.swift` (the whole `AXNode` struct)
- Modify: `Sources/MaxMiCapture/AXReader.swift:57-91` (`convert`), plus a new `focusedElementSnapshot(pid:)`
- Create: `Tests/MaxMiCaptureTests/Fixtures/ax-attributes.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `AXNode.subrole: String?`, `AXNode.headingLevel: Int?`, `AXNode.selected: Bool`, `AXNode.placeholder: String?`, `AXNode.selectedText: String?`, `AXNode.hidden: Bool`; `AXNode.init(role:value:title:url:frame:focused:children:identifier:label:subrole:headingLevel:selected:placeholder:selectedText:hidden:)` with every new parameter defaulted (`nil`, `nil`, `false`, `nil`, `nil`, `false`) so the ~120 existing `AXNode(` construction sites in `Sources/` and `Tests/` compile unchanged; `AXReader.focusedElementSnapshot(pid: pid_t) -> AXNode?`.

Phase D adds `domClassList` and `domIdentifier` on top of this — do not add them here.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/Fixtures/ax-attributes.json`:

```json
{
  "role": "AXWindow", "value": null, "title": "Attributes", "url": null,
  "frame": {"x":100,"y":80,"width":800,"height":600}, "focused": false,
  "children": [
    {"role": "AXHeading", "value": "Section one", "title": null, "url": null,
     "frame": {"x":110,"y":100,"width":400,"height":24}, "focused": false,
     "headingLevel": 3, "children": []},
    {"role": "AXTextField", "value": "typed text", "title": null, "url": null,
     "frame": {"x":110,"y":140,"width":400,"height":24}, "focused": true,
     "placeholder": "Search", "selectedText": "typed", "children": []},
    {"role": "AXTextField", "value": null, "title": null, "url": null,
     "frame": {"x":110,"y":180,"width":400,"height":24}, "focused": false,
     "subrole": "AXSecureTextField", "children": []},
    {"role": "AXRow", "value": null, "title": null, "url": null,
     "frame": {"x":110,"y":220,"width":600,"height":20}, "focused": false,
     "selected": true, "children": [
       {"role": "AXStaticText", "value": "Report.pdf", "title": null, "url": null,
        "frame": {"x":120,"y":220,"width":200,"height":16}, "focused": false, "children": []}
     ]},
    {"role": "AXGroup", "value": null, "title": "collapsed", "url": null,
     "frame": {"x":110,"y":260,"width":600,"height":20}, "focused": false,
     "hidden": true, "children": []}
  ]
}
```

Append to the table in `Tests/MaxMiCaptureTests/Fixtures/README.md`:

```markdown
| `ax-attributes.json` | Hand-authored attribute coverage shape | `AXNode` decoding of subrole/headingLevel/selected/placeholder/selectedText/hidden |
```

Create `Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture

final class AXNodeAttributesTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testNewAttributesDecode() throws {
        let window = try fixture("ax-attributes")
        XCTAssertEqual(window.children[0].headingLevel, 3)
        XCTAssertEqual(window.children[1].placeholder, "Search")
        XCTAssertEqual(window.children[1].selectedText, "typed")
        XCTAssertEqual(window.children[2].subrole, "AXSecureTextField")
        XCTAssertTrue(window.children[3].selected)
        XCTAssertTrue(window.children[4].hidden)
    }

    func testAbsentAttributesDefaultAndDoNotBreakOldFixtures() throws {
        for name in ["calendar-event", "chrome-article", "chromium-gmail-thread", "cursor-editor",
                     "gecko-slack-chat", "pages-document", "reminder-task", "safari-domain-only",
                     "slack-window", "whatsapp-conversation", "zen-meet"] {
            let node = try fixture(name)
            XCTAssertNil(node.subrole, "\(name) has no subrole and must decode as nil")
            XCTAssertNil(node.headingLevel, "\(name)")
            XCTAssertNil(node.placeholder, "\(name)")
            XCTAssertNil(node.selectedText, "\(name)")
            XCTAssertFalse(node.selected, "\(name) defaults selected to false")
            XCTAssertFalse(node.hidden, "\(name) defaults hidden to false")
        }
    }

    func testEncodeDecodeRoundTripPreservesNewAttributes() throws {
        let original = try fixture("ax-attributes")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AXNode.self, from: data)
        XCTAssertEqual(decoded.children[0].headingLevel, 3)
        XCTAssertEqual(decoded.children[2].subrole, "AXSecureTextField")
        XCTAssertTrue(decoded.children[3].selected)
        XCTAssertTrue(decoded.children[4].hidden)
        XCTAssertEqual(decoded.children[1].selectedText, "typed")
    }

    func testMemberwiseInitDefaultsKeepOldCallSitesValid() {
        let node = AXNode(role: "AXStaticText", value: "x", title: nil, url: nil,
                          frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                          focused: false, children: [])
        XCTAssertNil(node.subrole)
        XCTAssertFalse(node.selected)
        XCTAssertFalse(node.hidden)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AXNodeAttributesTests`
Expected: FAIL to compile — "value of type 'AXNode' has no member 'subrole'".

- [ ] **Step 3: Write minimal implementation**

Replace the body of `Sources/MaxMiCapture/AXSnapshot.swift` with:

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
    public let identifier: String?
    public let label: String?
    /// kAXSubroleAttribute. Region detection and secure-field masking depend on it.
    public let subrole: String?
    /// "AXHeadingLevel", fetched only when role == "AXHeading".
    public let headingLevel: Int?
    /// kAXSelectedAttribute.
    public let selected: Bool
    /// kAXPlaceholderValueAttribute, fetched only for text-entry roles.
    public let placeholder: String?
    /// kAXSelectedTextAttribute, fetched only for text-entry roles.
    public let selectedText: String?
    /// "AXHidden".
    public let hidden: Bool

    public init(role: String, value: String?, title: String?, url: String?,
                frame: CGRect?, focused: Bool, children: [AXNode],
                identifier: String? = nil, label: String? = nil,
                subrole: String? = nil, headingLevel: Int? = nil, selected: Bool = false,
                placeholder: String? = nil, selectedText: String? = nil, hidden: Bool = false) {
        self.role = role; self.value = value; self.title = title
        self.url = url; self.frame = frame; self.focused = focused; self.children = children
        self.identifier = identifier; self.label = label
        self.subrole = subrole; self.headingLevel = headingLevel; self.selected = selected
        self.placeholder = placeholder; self.selectedText = selectedText; self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case role, value, title, url, frame, focused, children, identifier, label
        case subrole, headingLevel, selected, placeholder, selectedText, hidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        focused = try container.decode(Bool.self, forKey: .focused)
        children = try container.decode([AXNode].self, forKey: .children)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // decodeIfPresent + defaults: the eleven pre-M8 fixtures carry none of these keys.
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        headingLevel = try container.decodeIfPresent(Int.self, forKey: .headingLevel)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false

        if let frameDict = try? container.decode([String: CGFloat].self, forKey: .frame) {
            let x = frameDict["x"] ?? 0
            let y = frameDict["y"] ?? 0
            let width = frameDict["width"] ?? 0
            let height = frameDict["height"] ?? 0
            frame = CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        } else {
            frame = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(focused, forKey: .focused)
        try container.encode(children, forKey: .children)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(headingLevel, forKey: .headingLevel)
        try container.encode(selected, forKey: .selected)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encodeIfPresent(selectedText, forKey: .selectedText)
        try container.encode(hidden, forKey: .hidden)

        if let frame = frame {
            let frameDict: [String: CGFloat] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height
            ]
            try container.encode(frameDict, forKey: .frame)
        } else {
            try container.encodeNil(forKey: .frame)
        }
    }
}
```

In `Sources/MaxMiCapture/AXReader.swift`, add the text-entry role set at the top of `enum AXReader`:

```swift
    /// Roles whose placeholder and selected-text are worth an extra AX round trip.
    static let textEntryRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
```

then extend `convert` — insert these reads immediately after the existing `label` read and pass them to the `AXNode` initializer at the end of the function:

```swift
        // Three unconditional extra reads: region detection needs subrole, table rows need
        // selected, and hidden containers must never be walked for text.
        let subrole = copyAttr(el, kAXSubroleAttribute) as? String
        let selected = (copyAttr(el, kAXSelectedAttribute) as? Bool) ?? false
        let hidden = (copyAttr(el, "AXHidden") as? Bool) ?? false
        // Conditional reads: keep the per-node cost off the roles that cannot carry them.
        let headingLevel = role == "AXHeading"
            ? (copyAttr(el, "AXHeadingLevel") as? NSNumber)?.intValue
            : nil
        let isTextEntry = Self.textEntryRoles.contains(role)
        let placeholder = isTextEntry ? copyAttr(el, kAXPlaceholderValueAttribute) as? String : nil
        let selectedText = isTextEntry ? copyAttr(el, kAXSelectedTextAttribute) as? String : nil
```

```swift
        return AXNode(role: role, value: value, title: title, url: url,
                      frame: frame, focused: focused, children: children,
                      identifier: identifier, label: label,
                      subrole: subrole, headingLevel: headingLevel, selected: selected,
                      placeholder: placeholder, selectedText: selectedText, hidden: hidden)
```

and add the shallow focused-element read as a new `public static` function right after `snapshotFrontmostWindow`:

```swift
    /// Shallow read of the app's focused UI element, for the case where the window snapshot
    /// contains no node with `focused == true` (virtualised trees, web areas). `maxDepth: 1`
    /// keeps this to the element plus its immediate children.
    public static func focusedElementSnapshot(pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        guard let element = copyAttr(app, kAXFocusedUIElementAttribute) as! AXUIElement? else { return nil }
        var budget = 64
        return convert(element, depth: 0, maxDepth: 1, budget: &budget)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AXNodeAttributesTests`
Expected: PASS, 4 tests.

Then confirm every existing fixture consumer still decodes and behaves:

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS, unchanged (the old fixtures decode with the new fields defaulted).

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/AXSnapshot.swift Sources/MaxMiCapture/AXReader.swift \
        Tests/MaxMiCaptureTests/AXNodeAttributesTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/ax-attributes.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Read subrole, heading level, selection, placeholder and hidden from AX"
```

---

### Task 5: `GenericPageExtractor` role model and block emission

**Files:**
- Create: `Sources/MaxMiCapture/GenericPageExtractor.swift`
- Modify: `Sources/MaxMiCapture/DocumentExtraction.swift:5-8` (doc comment marking `bodyText` legacy)
- Test: `Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift`

**Interfaces:**
- Consumes: `AXNode` incl. the Task 4 attributes; `Block`, `BlockType`, `Region`, `RegionKind`, `GenericPage`, `CapturedContent` (Task 1); `ContentRenderer.regionOrder` (Task 2); `OffscreenCapturePolicy`/`OffscreenCaptureMode` (`Sources/MaxMiCore/CaptureEnvelope.swift:18-46`).
- Produces: `GenericPageExtractor.Options` (`totalBudget = 8_000`, `mainShare = 0.70`, `dialogShare = 0.15`, `restShare = 0.15`, `offscreenPolicy = .visibleOnly()`), `GenericPageExtractor.Result` (`page: GenericPage`, `truncated: Bool`), `GenericPageExtractor.extract(window:focusedElement:url:options:) -> Result`. Task 6 adds region classification inside this file; Task 7 wires `focusedElement` and the budgets. In this task every block lands in one `.main` region, `focused` is `nil`, and `truncated` is `false` — the signature is final so Tasks 6 and 7 only add code, never change callers.

This task emits blocks; it does **not** classify regions or apply budgets. `extract` is pure and total: it cannot throw, and a window with no readable content yields `GenericPage(regions: [], focused: nil, url: url)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageExtractorTests: XCTestCase {
    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil, headingLevel: Int? = nil,
              selected: Bool = false, placeholder: String? = nil, hidden: Bool = false,
              frame: CGRect? = nil, focused: Bool = false, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: focused,
               children: children, identifier: identifier, label: label, subrole: subrole,
               headingLevel: headingLevel, selected: selected, placeholder: placeholder,
               selectedText: nil, hidden: hidden)
    }

    func text(_ value: String, y: CGFloat = 0, x: CGFloat = 0) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: x, y: y, width: 100, height: 16))
    }

    func extract(_ children: [AXNode], url: String? = nil) -> GenericPageExtractor.Result {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: nil, children: children),
            focusedElement: nil, url: url
        )
    }

    func mainBlocks(_ children: [AXNode]) -> [Block] {
        let regions = extract(children).page.regions
        return regions.first(where: { $0.kind == .main })?.blocks ?? []
    }

    func testHeadingUsesLevelAttributeAndDefaultsToTwo() {
        XCTAssertEqual(
            mainBlocks([node("AXHeading", value: "Explicit", headingLevel: 4)]).map(\.type),
            [.heading(level: 4)])
        XCTAssertEqual(
            mainBlocks([node("AXHeading", value: "Default")]).map(\.type),
            [.heading(level: 2)], "default heading level is 2")
    }

    func testHeadingLevelIsClampedToOneThroughSix() {
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "hi", headingLevel: 99)]).map(\.type),
                       [.heading(level: 6)])
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "lo", headingLevel: 0)]).map(\.type),
                       [.heading(level: 1)])
        XCTAssertEqual(mainBlocks([node("AXHeading", value: "neg", headingLevel: -3)]).map(\.type),
                       [.heading(level: 1)])
    }

    func testStaticTextAndParagraphBecomeParagraphs() {
        let blocks = mainBlocks([text("static"), node("AXParagraph", value: "para")])
        XCTAssertEqual(blocks.map(\.type), [.paragraph, .paragraph])
        XCTAssertEqual(blocks.map(\.text), ["static", "para"])
    }

    func testTextEntryRolesBecomeInputsCarryingValueAndPlaceholder() {
        let blocks = mainBlocks([
            node("AXTextField", value: "vec0", placeholder: "Search"),
            node("AXTextArea", value: "body text"),
            node("AXSearchField", placeholder: "Filter"),
            node("AXComboBox", value: "Choice"),
        ])
        XCTAssertEqual(blocks.map(\.type), [
            .input(placeholder: "Search"), .input(placeholder: nil),
            .input(placeholder: "Filter"), .input(placeholder: nil),
        ])
        XCTAssertEqual(blocks.map(\.text), ["vec0", "body text", "", "Choice"])
    }

    func testEmptyUnnamedInputIsNotEmitted() {
        XCTAssertTrue(mainBlocks([node("AXTextField")]).isEmpty)
    }

    func testSecureFieldIsMaskedAndValueNeverAppears() {
        let blocks = mainBlocks([
            node("AXTextField", value: "hunter2", subrole: "AXSecureTextField", placeholder: "Password"),
        ])
        XCTAssertEqual(blocks.map(\.text), ["«secure field»"])
        XCTAssertEqual(blocks.map(\.type), [.input(placeholder: nil)])
        XCTAssertFalse(ContentRenderer.renderBlocks(blocks).contains("hunter2"))
    }

    func testListItemsCarryZeroBasedNestingDepth() {
        let tree = [
            node("AXList", children: [
                node("AXListItem", children: [text("top")]),
                node("AXList", children: [
                    node("AXListItem", children: [text("nested")]),
                ]),
            ]),
        ]
        let blocks = mainBlocks(tree)
        XCTAssertEqual(blocks.map(\.type), [.listItem(depth: 0), .listItem(depth: 1)])
        XCTAssertEqual(blocks.map(\.text), ["top", "nested"])
    }

    func testTreeItemInsideOutlineIsAListItem() {
        let blocks = mainBlocks([
            node("AXOutline", children: [node("AXTreeItem", children: [text("Downloads")])]),
        ])
        XCTAssertEqual(blocks.map(\.type), [.listItem(depth: 0)])
    }

    func testRowBecomesOneJoinedTableRow() {
        let row = node("AXRow", selected: true, frame: CGRect(x: 0, y: 40, width: 600, height: 20), children: [
            node("AXCell", frame: CGRect(x: 300, y: 40, width: 100, height: 20),
                 children: [text("12 KB", y: 40, x: 300)]),
            node("AXCell", frame: CGRect(x: 0, y: 40, width: 200, height: 20),
                 children: [text("Report.pdf", y: 40, x: 0)]),
        ])
        let blocks = mainBlocks([node("AXTable", children: [row])])
        XCTAssertEqual(blocks.count, 1, "one row is one block, not one per cell")
        XCTAssertEqual(blocks[0].type, .tableRow(cells: ["Report.pdf", "12 KB"], selected: true),
                       "cells in visual (y, x) order, selected from AXSelected")
        XCTAssertEqual(ContentRenderer.renderBlock(blocks[0]), "* Report.pdf | 12 KB")
    }

    func testTableRowDropsAdjacentDuplicateCellText() {
        let row = node("AXTableRow", frame: CGRect(x: 0, y: 10, width: 300, height: 20), children: [
            text("Report.pdf", y: 10, x: 0),
            text("Report.pdf", y: 10, x: 1),
            text("12 KB", y: 10, x: 100),
        ])
        XCTAssertEqual(mainBlocks([row]).map(\.type), [.tableRow(cells: ["Report.pdf", "12 KB"], selected: false)])
    }

    func testLabelRolesUseTitleThenLabelThenValue() {
        let blocks = mainBlocks([
            node("AXButton", title: "Send"),
            node("AXLink", label: "Open docs"),
            node("AXMenuItem", value: "Duplicate"),
            node("AXCheckBox", title: "Remember me"),
            node("AXRadioButton", subrole: "AXTabButton", title: "Messages"),
            node("AXImage", label: "Avatar"),
        ])
        XCTAssertEqual(blocks.map(\.type), Array(repeating: BlockType.label, count: 6))
        XCTAssertEqual(blocks.map(\.text),
                       ["Send", "Open docs", "Duplicate", "Remember me", "Messages", "Avatar"])
    }

    func testEmittingNodeStopsRecursionIntoItsOwnChildren() {
        let paragraph = node("AXStaticText", value: "whole paragraph",
                             frame: CGRect(x: 0, y: 0, width: 100, height: 16),
                             children: [text("run one"), text("run two")])
        XCTAssertEqual(mainBlocks([paragraph]).map(\.text), ["whole paragraph"],
                       "text runs beneath an emitting node are never emitted")
    }

    func testExactDuplicateTextIsDroppedWithinARegionKeepingFirstOccurrence() {
        let blocks = mainBlocks([text("alpha", y: 0), text("beta", y: 10), text("alpha", y: 20)])
        XCTAssertEqual(blocks.map(\.text), ["alpha", "beta"])
    }

    func testMenuSubtreesAreNeverTraversed() {
        for role in ["AXMenuBar", "AXMenuBarItem", "AXMenu"] {
            let tree = [node(role, children: [text("File"), text("Edit")]), text("real body")]
            XCTAssertEqual(mainBlocks(tree).map(\.text), ["real body"],
                           "\(role) content is structurally excluded")
        }
    }

    func testScrollBarSplitterAndGrowAreaSubtreesAreSkipped() {
        for role in ["AXScrollBar", "AXSplitter", "AXGrowArea"] {
            let tree = [node(role, children: [text("chrome")]), text("real body")]
            XCTAssertEqual(mainBlocks(tree).map(\.text), ["real body"], "\(role)")
        }
    }

    func testHiddenAndZeroSizedNodesAreSkipped() {
        let tree = [
            node("AXGroup", hidden: true, children: [text("hidden text")]),
            node("AXStaticText", value: "zero width", frame: CGRect(x: 0, y: 0, width: 0, height: 16)),
            node("AXStaticText", value: "zero height", frame: CGRect(x: 0, y: 0, width: 100, height: 0)),
            text("visible"),
        ]
        XCTAssertEqual(mainBlocks(tree).map(\.text), ["visible"])
    }

    func testNodeEntirelyOutsideTheWindowIsSkippedUnlessScrollPolicyIsSet() {
        let window = node("AXWindow", frame: CGRect(x: 100, y: 100, width: 800, height: 600), children: [
            text("inside", y: 200, x: 200),
            node("AXStaticText", value: "far below",
                 frame: CGRect(x: 200, y: 5_000, width: 100, height: 16)),
        ])
        let visibleOnly = GenericPageExtractor.extract(window: window, focusedElement: nil, url: nil)
        XCTAssertEqual(visibleOnly.page.regions.first?.blocks.map(\.text), ["inside"])

        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = .accessibilityScroll(maxSteps: 3)
        let withScroll = GenericPageExtractor.extract(window: window, focusedElement: nil,
                                                      url: nil, options: options)
        XCTAssertEqual(withScroll.page.regions.first?.blocks.map(\.text), ["inside", "far below"])
    }

    func testBlocksAreOrderedVisuallyNotInTreeOrder() {
        // Same ordering `DocumentExtraction.bodyText` applied: y, then x. The tree lists the
        // lower line first.
        let blocks = mainBlocks([
            text("Second line", y: 100),
            text("First line", y: 10),
            text("Second line right", y: 100, x: 500),
        ])
        XCTAssertEqual(blocks.map(\.text), ["First line", "Second line", "Second line right"])
    }

    func testBlocksWithoutFramesKeepEmissionOrder() {
        let blocks = mainBlocks([
            node("AXStaticText", value: "one"),
            node("AXStaticText", value: "two"),
            node("AXStaticText", value: "three"),
        ])
        XCTAssertEqual(blocks.map(\.text), ["one", "two", "three"])
    }

    func testUrlIsCarriedAndEmptyWindowYieldsNoRegions() {
        let empty = extract([node("AXButton")], url: "https://example.com/a")
        XCTAssertEqual(empty.page.regions, [])
        XCTAssertEqual(empty.page.url, "https://example.com/a")
        XCTAssertNil(empty.page.focused)
        XCTAssertFalse(empty.truncated)
    }

    func testDefaultOptionsMatchTheSpecBudgets() {
        let options = GenericPageExtractor.Options()
        XCTAssertEqual(options.totalBudget, 8_000)
        XCTAssertEqual(options.mainShare, 0.70)
        XCTAssertEqual(options.dialogShare, 0.15)
        XCTAssertEqual(options.restShare, 0.15)
        XCTAssertEqual(options.offscreenPolicy.mode, .visibleOnly)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenericPageExtractorTests`
Expected: FAIL to compile — "cannot find 'GenericPageExtractor' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MaxMiCapture/GenericPageExtractor.swift`:

```swift
import Foundation
import MaxMiCore

/// Generic flattener v2. Replaces `DocumentExtraction.bodyText` on the fallback path: real
/// roles, heading levels, list depth, joined table rows, secure-field masking.
///
/// Pure and total — it cannot throw and always returns a `GenericPage`, possibly with zero
/// regions, which the caller treats as empty content exactly as before.
public enum GenericPageExtractor {
    public struct Options: Sendable, Equatable {
        public var totalBudget: Int = 8_000          // == DocumentExtraction.contentCap today
        public var mainShare: Double = 0.70
        public var dialogShare: Double = 0.15
        public var restShare: Double = 0.15
        public var offscreenPolicy: OffscreenCapturePolicy = .visibleOnly()
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public let page: GenericPage
        public let truncated: Bool
        public init(page: GenericPage, truncated: Bool) {
            self.page = page
            self.truncated = truncated
        }
    }

    /// Menu content is structurally excluded, not filtered by text.
    static let menuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu"]
    /// Skipped entirely, subtree included.
    static let skipRoles: Set<String> = ["AXScrollBar", "AXSplitter", "AXGrowArea"]
    static let paragraphRoles: Set<String> = ["AXStaticText", "AXParagraph"]
    static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
    static let listItemRoles: Set<String> = ["AXListItem", "AXTreeItem"]
    static let rowRoles: Set<String> = ["AXRow", "AXTableRow"]
    static let labelRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXImage",
    ]
    static let listContainerRoles: Set<String> = ["AXList", "AXOutline"]
    static let secureSubrole = "AXSecureTextField"
    static let secureMask = "«secure field»"

    /// One emitted block plus the visual position of the node it came from. `order` is a
    /// monotonic counter so sorting by (y, x, order) is deterministic even when frames are
    /// missing or identical — `Array.sort` is not stable.
    struct BlockEntry {
        let y: CGFloat
        let x: CGFloat
        let order: Int
        let block: Block
    }

    /// One region's worth of blocks plus the visual position of the node that claimed it, so
    /// same-kind regions concatenate in (y, x) order.
    struct Claim {
        let kind: RegionKind
        let y: CGFloat
        let x: CGFloat
        var entries: [BlockEntry]
    }

    /// `window` is the node `AXReader.snapshotFrontmostWindow` already resolved. The extractor
    /// never re-resolves it.
    public static func extract(
        window: AXNode,
        focusedElement: AXNode?,
        url: String?,
        options: Options = Options()
    ) -> Result {
        var claims = [Claim(kind: .main,
                            y: window.frame?.minY ?? 0,
                            x: window.frame?.minX ?? 0,
                            entries: [])]
        var order = 0
        walk(window, window: window, claimIndex: 0, listDepth: 0,
             options: options, order: &order, claims: &claims)
        return Result(
            page: GenericPage(regions: assemble(claims), focused: nil, url: url),
            truncated: false
        )
    }

    static func walk(
        _ node: AXNode,
        window: AXNode,
        claimIndex: Int,
        listDepth: Int,
        options: Options,
        order: inout Int,
        claims: inout [Claim]
    ) {
        if menuRoles.contains(node.role) { return }
        if node.hidden { return }
        if skipRoles.contains(node.role) { return }
        // A zero-width or zero-height frame means nothing under here is on screen. A nil frame
        // is "unknown", not "zero", and is walked.
        if let frame = node.frame, frame.width == 0 || frame.height == 0 { return }
        if isOffscreen(node, window: window, options: options) { return }

        if let block = block(for: node, listDepth: listDepth) {
            claims[claimIndex].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
            order += 1
            // A node that emits text stops recursion into its own children — this is what
            // prevents a paragraph and its five text runs all appearing.
            return
        }
        let childDepth = listContainerRoles.contains(node.role) ? listDepth + 1 : listDepth
        for child in node.children {
            walk(child, window: window, claimIndex: claimIndex, listDepth: childDepth,
                 options: options, order: &order, claims: &claims)
        }
    }

    static func isOffscreen(_ node: AXNode, window: AXNode, options: Options) -> Bool {
        guard options.offscreenPolicy.mode != .accessibilityScroll,
              let windowFrame = window.frame, let frame = node.frame,
              windowFrame.width > 0, windowFrame.height > 0 else { return false }
        return !windowFrame.intersects(frame)
    }

    static func block(for node: AXNode, listDepth: Int) -> Block? {
        // Checked first and at any role: a secure field's value is never read.
        if node.subrole == secureSubrole {
            return Block(type: .input(placeholder: nil), text: secureMask)
        }
        if node.role == "AXHeading" {
            let text = readableText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .heading(level: min(max(node.headingLevel ?? 2, 1), 6)), text: text)
        }
        if paragraphRoles.contains(node.role) {
            let text = readableText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .paragraph, text: text)
        }
        if inputRoles.contains(node.role) {
            let text = (node.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty field with no placeholder carries no information at all.
            guard !text.isEmpty || node.placeholder != nil else { return nil }
            return Block(type: .input(placeholder: node.placeholder), text: text)
        }
        if listItemRoles.contains(node.role) {
            let text = joinedDescendantText(node)
            guard !text.isEmpty else { return nil }
            return Block(type: .listItem(depth: max(0, listDepth - 1)), text: text)
        }
        if rowRoles.contains(node.role) {
            let cells = rowCells(node)
            guard !cells.isEmpty else { return nil }
            // `text` is the space-joined form so delta and dedup can compare rows as text;
            // `ContentRenderer` renders from `cells`.
            return Block(type: .tableRow(cells: cells, selected: node.selected),
                         text: cells.joined(separator: " "))
        }
        if labelRoles.contains(node.role) {
            let text = (node.title ?? node.label ?? node.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Block(type: .label, text: text)
        }
        return nil
    }

    static func readableText(_ node: AXNode) -> String {
        (node.value ?? node.title ?? node.label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joinedDescendantText(_ node: AXNode) -> String {
        orderedDescendantText(node, roles: ["AXStaticText", "AXHeading"]).joined(separator: " ")
    }

    static func rowCells(_ node: AXNode) -> [String] {
        orderedDescendantText(node, roles: ["AXCell", "AXStaticText"])
    }

    /// Descendant text in visual (y, x) order, adjacent duplicates dropped. A matching node
    /// with usable text is not descended into; a matching node with empty text is.
    static func orderedDescendantText(_ node: AXNode, roles: Set<String>) -> [String] {
        var found: [(y: CGFloat, x: CGFloat, text: String)] = []
        func visit(_ current: AXNode) {
            if menuRoles.contains(current.role) || current.hidden { return }
            if roles.contains(current.role) {
                let text = readableText(current)
                if !text.isEmpty {
                    found.append((current.frame?.minY ?? 0, current.frame?.minX ?? 0, text))
                    return
                }
            }
            for child in current.children { visit(child) }
        }
        for child in node.children { visit(child) }
        let ordered = found.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }.map(\.text)
        return ordered.reduce(into: [String]()) { result, value in
            if result.last != value { result.append(value) }
        }
    }

    /// Group claims by kind in the renderer's canonical order; within a kind, concatenate
    /// claims in (y, x) order; within a claim, order blocks visually (y, then x, then emission
    /// order) — the same visual ordering `DocumentExtraction.bodyText` applied. Then drop
    /// exact-text duplicates, first occurrence winning.
    static func assemble(_ claims: [Claim]) -> [Region] {
        var regions: [Region] = []
        for kind in ContentRenderer.regionOrder {
            let matching = claims
                .filter { $0.kind == kind && !$0.entries.isEmpty }
                .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            guard !matching.isEmpty else { continue }
            var seen = Set<String>()
            var blocks: [Block] = []
            for claim in matching {
                let ordered = claim.entries.sorted {
                    if $0.y != $1.y { return $0.y < $1.y }
                    if $0.x != $1.x { return $0.x < $1.x }
                    return $0.order < $1.order
                }
                for entry in ordered where seen.insert(entry.block.text).inserted {
                    blocks.append(entry.block)
                }
            }
            guard !blocks.isEmpty else { continue }
            regions.append(Region(kind: kind, blocks: blocks))
        }
        return regions
    }
}
```

Then mark the old flattener legacy — in `Sources/MaxMiCapture/DocumentExtraction.swift`, replace the two comment lines above `static func bodyText` with:

```swift
    /// LEGACY (M8 Phase A). Superseded by `GenericPageExtractor` on the fallback path; kept
    /// because the generic-v2 document parsers still use it for their body text until Phase D
    /// replaces them with anchored parsers. Do not use it in new code.
    ///
    /// AXTextArea + AXStaticText values in visual order (y then x), newest-anchored
    /// hard cap. Returns "" if there is no text (caller returns nil → no empty thread).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenericPageExtractorTests`
Expected: PASS, 20 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/GenericPageExtractor.swift Sources/MaxMiCapture/DocumentExtraction.swift \
        Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift
git commit -m "Add GenericPageExtractor role model and block emission"
```

---

### Task 6: Region detection, in window-relative coordinates

**Files:**
- Modify: `Sources/MaxMiCapture/GenericPageExtractor.swift` (add `classifyRegion`, thread `parentIsSplitGroup` through `walk`, create claims)
- Create: `Tests/MaxMiCaptureTests/Fixtures/finder-offset-window.json`
- Create: `Tests/MaxMiCaptureTests/Fixtures/dialog-over-window.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md`
- Test: `Tests/MaxMiCaptureTests/GenericPageRegionTests.swift`

**Interfaces:**
- Consumes: everything from Task 5 (`Claim`, `walk`, `assemble`, `block(for:listDepth:)`).
- Produces: `GenericPageExtractor.classifyRegion(_ node: AXNode, window: AXNode, parentIsSplitGroup: Bool) -> RegionKind?` (nil = "not claimed; inherit the enclosing region"); `walk` gains a `parentIsSplitGroup: Bool` parameter.

**Why this task exists at all:** `AXFrame` is in **global screen coordinates**. Comparing a child's `minX` against `0` instead of against `window.frame.minX` silently misclassifies every window that is not flush against the left edge of the primary display — a bug this codebase has already been bitten by (`SlackParser.swift` carries the same subtraction and the same comment). Both new fixtures therefore have a **nonzero window origin**, and the tests fail if the subtraction is dropped.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/Fixtures/finder-offset-window.json`:

```json
{
  "role": "AXWindow", "value": null, "title": "Projects", "url": null,
  "frame": {"x":340,"y":120,"width":1000,"height":700}, "focused": false,
  "children": [
    {"role": "AXToolbar", "value": null, "title": null, "url": null,
     "frame": {"x":340,"y":120,"width":1000,"height":52}, "focused": false, "children": [
       {"role": "AXStaticText", "value": "Uploading 34 items", "title": null, "url": null,
        "frame": {"x":700,"y":134,"width":200,"height":16}, "focused": false, "children": []}
     ]},
    {"role": "AXSplitGroup", "value": null, "title": null, "url": null,
     "frame": {"x":340,"y":172,"width":1000,"height":648}, "focused": false, "children": [
       {"role": "AXGroup", "value": null, "title": null, "url": null,
        "frame": {"x":340,"y":172,"width":200,"height":648}, "focused": false, "children": [
          {"role": "AXOutline", "value": null, "title": null, "url": null,
           "frame": {"x":340,"y":180,"width":200,"height":600}, "focused": false, "children": [
             {"role": "AXTreeItem", "value": null, "title": null, "url": null,
              "frame": {"x":348,"y":190,"width":180,"height":20}, "focused": false, "children": [
                {"role": "AXStaticText", "value": "Favorites", "title": null, "url": null,
                 "frame": {"x":356,"y":190,"width":160,"height":16}, "focused": false, "children": []}
              ]},
             {"role": "AXTreeItem", "value": null, "title": null, "url": null,
              "frame": {"x":348,"y":214,"width":180,"height":20}, "focused": false, "children": [
                {"role": "AXStaticText", "value": "Projects", "title": null, "url": null,
                 "frame": {"x":356,"y":214,"width":160,"height":16}, "focused": false, "children": []}
              ]}
           ]}
        ]},
       {"role": "AXGroup", "value": null, "title": null, "url": null,
        "frame": {"x":540,"y":172,"width":800,"height":648}, "focused": false, "children": [
          {"role": "AXTable", "value": null, "title": null, "url": null,
           "frame": {"x":540,"y":200,"width":800,"height":560}, "focused": false, "children": [
             {"role": "AXRow", "value": null, "title": null, "url": null,
              "frame": {"x":540,"y":200,"width":800,"height":20}, "focused": false, "children": [
                {"role": "AXStaticText", "value": "Name", "title": null, "url": null,
                 "frame": {"x":548,"y":200,"width":300,"height":16}, "focused": false, "children": []},
                {"role": "AXStaticText", "value": "Size", "title": null, "url": null,
                 "frame": {"x":1100,"y":200,"width":100,"height":16}, "focused": false, "children": []}
              ]},
             {"role": "AXRow", "value": null, "title": null, "url": null,
              "frame": {"x":540,"y":224,"width":800,"height":20}, "focused": false, "selected": true,
              "children": [
                {"role": "AXCell", "value": null, "title": null, "url": null,
                 "frame": {"x":548,"y":224,"width":300,"height":20}, "focused": false, "children": [
                   {"role": "AXStaticText", "value": "Report.pdf", "title": null, "url": null,
                    "frame": {"x":548,"y":224,"width":300,"height":16}, "focused": false, "children": []}
                 ]},
                {"role": "AXCell", "value": null, "title": null, "url": null,
                 "frame": {"x":1100,"y":224,"width":100,"height":20}, "focused": false, "children": [
                   {"role": "AXStaticText", "value": "12 KB", "title": null, "url": null,
                    "frame": {"x":1100,"y":224,"width":100,"height":16}, "focused": false, "children": []}
                 ]}
              ]},
             {"role": "AXRow", "value": null, "title": null, "url": null,
              "frame": {"x":540,"y":248,"width":800,"height":20}, "focused": false, "children": [
                {"role": "AXStaticText", "value": "Notes.txt", "title": null, "url": null,
                 "frame": {"x":548,"y":248,"width":300,"height":16}, "focused": false, "children": []},
                {"role": "AXStaticText", "value": "4 KB", "title": null, "url": null,
                 "frame": {"x":1100,"y":248,"width":100,"height":16}, "focused": false, "children": []}
              ]}
           ]}
        ]}
     ]}
  ]
}
```

Create `Tests/MaxMiCaptureTests/Fixtures/dialog-over-window.json`:

```json
{
  "role": "AXWindow", "value": null, "title": "Cloudflare WARP", "url": null,
  "frame": {"x":200,"y":150,"width":900,"height":650}, "focused": false,
  "children": [
    {"role": "AXGroup", "value": null, "title": null, "url": null,
     "frame": {"x":200,"y":150,"width":900,"height":650}, "focused": false, "children": [
       {"role": "AXStaticText", "value": "Main body line one", "title": null, "url": null,
        "frame": {"x":220,"y":200,"width":400,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Main body line two", "title": null, "url": null,
        "frame": {"x":220,"y":220,"width":400,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Main body line three", "title": null, "url": null,
        "frame": {"x":220,"y":240,"width":400,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Main body line four", "title": null, "url": null,
        "frame": {"x":220,"y":260,"width":400,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Main body line five", "title": null, "url": null,
        "frame": {"x":220,"y":280,"width":400,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Main body line six", "title": null, "url": null,
        "frame": {"x":220,"y":300,"width":400,"height":16}, "focused": false, "children": []}
     ]},
    {"role": "AXSheet", "value": null, "title": null, "url": null,
     "frame": {"x":450,"y":300,"width":400,"height":200}, "focused": false, "children": [
       {"role": "AXStaticText", "value": "Quit Cloudflare WARP?", "title": null, "url": null,
        "frame": {"x":470,"y":330,"width":360,"height":16}, "focused": false, "children": []},
       {"role": "AXStaticText", "value": "Open tunnels will disconnect.", "title": null, "url": null,
        "frame": {"x":470,"y":354,"width":360,"height":16}, "focused": false, "children": []},
       {"role": "AXButton", "value": null, "title": "Quit", "url": null,
        "frame": {"x":470,"y":420,"width":80,"height":24}, "focused": false, "children": []},
       {"role": "AXButton", "value": null, "title": "Cancel", "url": null,
        "frame": {"x":560,"y":420,"width":80,"height":24}, "focused": false, "children": []}
     ]}
  ]
}
```

Append to the table in `Tests/MaxMiCaptureTests/Fixtures/README.md`:

```markdown
| `finder-offset-window.json` | Hand-authored Finder-shaped window at a nonzero screen origin | `GenericPageExtractor` sidebar/main/toolbar regions and joined table rows |
| `dialog-over-window.json` | Hand-authored sheet-over-window shape at a nonzero screen origin | `GenericPageExtractor` `.dialog` region and dialog-never-trimmed budgeting |
```

Create `Tests/MaxMiCaptureTests/GenericPageRegionTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageRegionTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil,
              frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: false,
               children: children, identifier: identifier, label: label, subrole: subrole)
    }

    /// Every synthetic window in this file sits at a nonzero screen origin, because that is
    /// exactly the case a global-coordinate comparison gets wrong.
    static let origin = CGRect(x: 500, y: 300, width: 1000, height: 800)

    func regions(_ children: [AXNode], window: CGRect = GenericPageRegionTests.origin) -> [Region] {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: window, children: children),
            focusedElement: nil, url: nil
        ).page.regions
    }

    func blocks(_ regions: [Region], _ kind: RegionKind) -> [Block] {
        regions.first(where: { $0.kind == kind })?.blocks ?? []
    }

    func body(_ text: String, y: CGFloat) -> AXNode {
        node("AXStaticText", value: text, frame: CGRect(x: 520, y: y, width: 400, height: 16))
    }

    func testRule1SheetDialogAndPopoverBecomeDialog() {
        for role in ["AXSheet", "AXDialog", "AXPopover"] {
            let result = regions([
                body("main text", y: 320),
                node(role, frame: CGRect(x: 700, y: 500, width: 300, height: 200),
                     children: [body("dialog text", y: 520)]),
            ])
            XCTAssertEqual(blocks(result, .dialog).map(\.text), ["dialog text"], role)
            XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"], role)
        }
        for subrole in ["AXDialog", "AXSystemDialog"] {
            let result = regions([
                node("AXGroup", subrole: subrole, frame: CGRect(x: 700, y: 500, width: 300, height: 200),
                     children: [body("dialog text", y: 520)]),
            ])
            XCTAssertEqual(blocks(result, .dialog).map(\.text), ["dialog text"], subrole)
        }
    }

    func testRule2ToolbarBecomesToolbar() {
        let result = regions([
            node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 52),
                 children: [body("Uploading 34 items", y: 310)]),
            body("main text", y: 400),
        ])
        XCTAssertEqual(blocks(result, .toolbar).map(\.text), ["Uploading 34 items"])
        XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"])
    }

    func testRule3LandmarkSubrolesMapToRegions() {
        let expected: [(String, RegionKind)] = [
            ("AXLandmarkMain", .main),
            ("AXLandmarkNavigation", .navigation),
            ("AXLandmarkComplementary", .sidebar),
            ("AXLandmarkBanner", .banner),
            ("AXLandmarkContentInfo", .footer),
        ]
        for (subrole, kind) in expected {
            let result = regions([
                node("AXGroup", subrole: subrole, frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                     children: [body("landmark text", y: 330)]),
            ])
            XCTAssertEqual(blocks(result, kind).map(\.text), ["landmark text"], subrole)
        }
    }

    func testRule4SidebarNamingIsCaseInsensitiveOnIdentifierAndLabel() {
        let byIdentifier = regions([
            node("AXGroup", identifier: "MainSideBar", frame: CGRect(x: 500, y: 320, width: 400, height: 200),
                 children: [body("sidebar text", y: 330)]),
        ])
        XCTAssertEqual(blocks(byIdentifier, .sidebar).map(\.text), ["sidebar text"])

        let byLabel = regions([
            node("AXGroup", label: "Source List", frame: CGRect(x: 500, y: 320, width: 400, height: 200),
                 children: [body("source list text", y: 330)]),
        ])
        XCTAssertEqual(blocks(byLabel, .sidebar).map(\.text), ["source list text"])
    }

    func testRule5SplitGroupHeuristicUsesWindowRelativeCoordinates() {
        // Narrow (200 < 350), flush left in WINDOW coordinates (500 - 500 = 0 <= 50), holds an outline.
        let sidebar = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
            node("AXOutline", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
                node("AXTreeItem", frame: CGRect(x: 510, y: 350, width: 180, height: 20),
                     children: [body("Favorites", y: 350)]),
            ]),
        ])
        let main = node("AXGroup", frame: CGRect(x: 700, y: 340, width: 800, height: 700),
                        children: [body("main text", y: 350)])
        let result = regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                   children: [sidebar, main])])
        XCTAssertEqual(blocks(result, .sidebar).map(\.text), ["Favorites"],
                       "window-relative minX must be used; a global comparison would call this main")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["main text"])
    }

    func testRule5RejectsWidePanesAndPanesAwayFromTheLeftEdge() {
        let wide = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 900, height: 700), children: [
            node("AXList", frame: CGRect(x: 500, y: 340, width: 900, height: 700),
                 children: [body("wide list", y: 350)]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [wide])]), .sidebar).isEmpty)

        let offset = node("AXGroup", frame: CGRect(x: 900, y: 340, width: 200, height: 700), children: [
            node("AXList", frame: CGRect(x: 900, y: 340, width: 200, height: 700),
                 children: [body("right list", y: 350)]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [offset])]), .sidebar).isEmpty)

        let noList = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700),
                          children: [body("just text", y: 350)])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [noList])]), .sidebar).isEmpty)
    }

    func testRule5OnlyAppliesToDirectChildrenOfASplitGroup() {
        let nested = node("AXGroup", frame: CGRect(x: 500, y: 340, width: 900, height: 700), children: [
            node("AXGroup", frame: CGRect(x: 500, y: 340, width: 200, height: 700), children: [
                node("AXList", frame: CGRect(x: 500, y: 340, width: 200, height: 700),
                     children: [body("grandchild list", y: 350)]),
            ]),
        ])
        XCTAssertTrue(blocks(regions([node("AXSplitGroup", frame: CGRect(x: 500, y: 340, width: 1000, height: 700),
                                          children: [nested])]), .sidebar).isEmpty,
                      "the heuristic is scoped to direct children of the split group")
    }

    func testRule6EverythingElseIsMainAndUnknownIsNeverEmitted() {
        let result = regions([
            node("AXGroup", frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                 children: [body("plain body", y: 330)]),
        ])
        XCTAssertEqual(result.map(\.kind), [.main])
        XCTAssertFalse(result.contains { $0.kind == .unknown },
                       "the extractor never emits .unknown")
    }

    func testSameKindRegionsConcatenateInVisualOrder() {
        let lower = node("AXToolbar", frame: CGRect(x: 500, y: 900, width: 1000, height: 40),
                         children: [body("bottom bar", y: 910)])
        let upper = node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 40),
                         children: [body("top bar", y: 310)])
        XCTAssertEqual(blocks(regions([lower, upper]), .toolbar).map(\.text), ["top bar", "bottom bar"])
    }

    func testFinderFixtureAtNonzeroOriginSplitsSidebarMainAndToolbar() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("finder-offset-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .sidebar, .toolbar])
        XCTAssertEqual(blocks(result.page.regions, .sidebar).map(\.text), ["Favorites", "Projects"])
        XCTAssertEqual(blocks(result.page.regions, .sidebar).map(\.type),
                       [.listItem(depth: 0), .listItem(depth: 0)])
        XCTAssertEqual(blocks(result.page.regions, .main).map(\.type), [
            .tableRow(cells: ["Name", "Size"], selected: false),
            .tableRow(cells: ["Report.pdf", "12 KB"], selected: true),
            .tableRow(cells: ["Notes.txt", "4 KB"], selected: false),
        ])
        XCTAssertEqual(blocks(result.page.regions, .toolbar).map(\.text), ["Uploading 34 items"])
    }

    func testFinderFixtureRendersJoinedRows() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("finder-offset-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(ContentRenderer.render(.generic(result.page), style: .full), """
        Name | Size
        * Report.pdf | 12 KB
        Notes.txt | 4 KB
        ## Sidebar
        - Favorites
        - Projects
        ## Toolbar
        Uploading 34 items
        """)
    }

    func testDialogOverWindowFixturePutsSheetContentInDialog() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(result.page.regions.map(\.kind), [.main, .dialog])
        XCTAssertEqual(blocks(result.page.regions, .dialog).map(\.text),
                       ["Quit Cloudflare WARP?", "Open tunnels will disconnect.", "Quit", "Cancel"])
        XCTAssertEqual(blocks(result.page.regions, .main).count, 6)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenericPageRegionTests`
Expected: FAIL — the first assertion reports `[]` for `.dialog` because every block still lands in `.main`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/GenericPageExtractor.swift`, add the landmark map and the classifier next to the other role sets:

```swift
    static let dialogRoles: Set<String> = ["AXSheet", "AXDialog", "AXPopover"]
    static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]
    static let landmarkRegions: [String: RegionKind] = [
        "AXLandmarkMain": .main,
        "AXLandmarkNavigation": .navigation,
        "AXLandmarkComplementary": .sidebar,
        "AXLandmarkBanner": .banner,
        "AXLandmarkContentInfo": .footer,
    ]
    static let sidebarNameHints = ["sidebar", "source list"]
    static let sidebarListRoles: Set<String> = ["AXOutline", "AXList", "AXTable"]
    static let sidebarMaxWidthShare = 0.35
    static let sidebarLeftEdgeShare = 0.05
```

```swift
    /// The first matching rule claims this node's entire subtree as one region. nil means
    /// "not claimed" — the node inherits the enclosing region, defaulting to `.main` (rule 6).
    /// A nested claim inside a claimed subtree wins for its own subtree.
    ///
    /// Frames are compared in WINDOW-RELATIVE coordinates: `AXFrame` is global screen
    /// coordinates, so a window that is not flush against the left edge of the primary display
    /// would otherwise misclassify its sidebar.
    static func classifyRegion(_ node: AXNode, window: AXNode, parentIsSplitGroup: Bool) -> RegionKind? {
        if dialogRoles.contains(node.role) { return .dialog }
        if let subrole = node.subrole, dialogSubroles.contains(subrole) { return .dialog }
        if node.role == "AXToolbar" { return .toolbar }
        if let subrole = node.subrole, let kind = landmarkRegions[subrole] { return kind }
        let name = [node.identifier, node.label].compactMap { $0 }.joined(separator: " ").lowercased()
        if sidebarNameHints.contains(where: name.contains) { return .sidebar }
        if parentIsSplitGroup, isSplitGroupSidebar(node, window: window) { return .sidebar }
        return nil
    }

    static func isSplitGroupSidebar(_ node: AXNode, window: AXNode) -> Bool {
        guard let windowFrame = window.frame, windowFrame.width > 0,
              let frame = node.frame else { return false }
        guard frame.width < sidebarMaxWidthShare * windowFrame.width else { return false }
        let relativeX = frame.minX - windowFrame.minX
        guard relativeX <= sidebarLeftEdgeShare * windowFrame.width else { return false }
        return containsListLike(node)
    }

    /// The node itself or any descendant being an outline/list/table. Finder's source list is
    /// sometimes the pane and sometimes wrapped in a group, so both count.
    static func containsListLike(_ node: AXNode) -> Bool {
        if sidebarListRoles.contains(node.role) { return true }
        return node.children.contains(where: containsListLike)
    }
```

Then change `walk` to create claims. Replace its signature and its recursion with:

```swift
    static func walk(
        _ node: AXNode,
        window: AXNode,
        claimIndex: Int,
        parentIsSplitGroup: Bool,
        listDepth: Int,
        options: Options,
        order: inout Int,
        claims: inout [Claim]
    ) {
        if menuRoles.contains(node.role) { return }
        if node.hidden { return }
        if skipRoles.contains(node.role) { return }
        if let frame = node.frame, frame.width == 0 || frame.height == 0 { return }
        if isOffscreen(node, window: window, options: options) { return }

        var currentClaim = claimIndex
        if let kind = classifyRegion(node, window: window, parentIsSplitGroup: parentIsSplitGroup) {
            claims.append(Claim(kind: kind,
                                y: node.frame?.minY ?? 0,
                                x: node.frame?.minX ?? 0,
                                entries: []))
            currentClaim = claims.count - 1
        }

        if let block = block(for: node, listDepth: listDepth) {
            claims[currentClaim].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
            order += 1
            return
        }
        let childDepth = listContainerRoles.contains(node.role) ? listDepth + 1 : listDepth
        let childInSplitGroup = node.role == "AXSplitGroup"
        for child in node.children {
            walk(child, window: window, claimIndex: currentClaim,
                 parentIsSplitGroup: childInSplitGroup, listDepth: childDepth,
                 options: options, order: &order, claims: &claims)
        }
    }
```

and update the single call in `extract`:

```swift
        var order = 0
        walk(window, window: window, claimIndex: 0, parentIsSplitGroup: false,
             listDepth: 0, options: options, order: &order, claims: &claims)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenericPageRegionTests`
Expected: PASS, 11 tests.

Run: `swift test --filter GenericPageExtractorTests`
Expected: PASS, unchanged — the role model is untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/GenericPageExtractor.swift \
        Tests/MaxMiCaptureTests/GenericPageRegionTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/finder-offset-window.json \
        Tests/MaxMiCaptureTests/Fixtures/dialog-over-window.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Detect page regions in window-relative coordinates"
```

---

### Task 7: Focused element, per-region budgets, `truncated`

**Files:**
- Modify: `Sources/MaxMiCapture/GenericPageExtractor.swift` (add `resolveFocusedElement`, `applyBudgets`, `trim`, `renderedSize`; wire them into `extract`)
- Test: `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift`

**Interfaces:**
- Consumes: Tasks 5 and 6 internals; `ContentRenderer.renderBlock(_:)`, `ContentRenderer.renderBlocks(_:)`; `FocusedElement` (Task 1).
- Produces: `GenericPageExtractor.resolveFocusedElement(in window: AXNode, fallback: AXNode?) -> FocusedElement?`, `GenericPageExtractor.applyBudgets(_ regions: [Region], options: Options) -> (regions: [Region], truncated: Bool)`, `GenericPageExtractor.trim(_ blocks: [Block], to allowance: Int) -> (blocks: [Block], truncated: Bool)`. After this task `extract` returns a fully populated `Result` — `page.focused` and `truncated` are real.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageBudgetTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, subrole: String? = nil, selectedText: String? = nil,
              frame: CGRect? = nil, focused: Bool = false, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: frame, focused: focused,
               children: children, identifier: identifier, label: label, subrole: subrole,
               selectedText: selectedText)
    }

    func text(_ value: String, y: CGFloat = 320) -> AXNode {
        node("AXStaticText", value: value, frame: CGRect(x: 520, y: y, width: 400, height: 16))
    }

    static let windowFrame = CGRect(x: 500, y: 300, width: 1000, height: 800)

    func extract(_ children: [AXNode], focusedElement: AXNode? = nil,
                 options: GenericPageExtractor.Options = GenericPageExtractor.Options())
        -> GenericPageExtractor.Result {
        GenericPageExtractor.extract(
            window: node("AXWindow", frame: Self.windowFrame, children: children),
            focusedElement: focusedElement, url: nil, options: options
        )
    }

    func blocks(_ result: GenericPageExtractor.Result, _ kind: RegionKind) -> [Block] {
        result.page.regions.first(where: { $0.kind == kind })?.blocks ?? []
    }

    func testDeepestFocusedNodeInTheTreeWins() {
        let deep = node("AXGroup", frame: CGRect(x: 520, y: 320, width: 400, height: 200),
                        focused: true, children: [
            node("AXTextField", value: "vec0 knn", identifier: "search",
                 selectedText: "vec0", frame: CGRect(x: 520, y: 340, width: 400, height: 24),
                 focused: true),
        ])
        let focused = extract([deep]).page.focused
        XCTAssertEqual(focused?.role, "AXTextField", "the deepest focused node wins")
        XCTAssertEqual(focused?.identifier, "search")
        XCTAssertEqual(focused?.value, "vec0 knn")
        XCTAssertEqual(focused?.selectedText, "vec0")
        XCTAssertEqual(focused?.isSecure, false)
    }

    func testFallbackSnapshotIsUsedWhenTheTreeHasNoFocusedNode() {
        let fallback = node("AXTextArea", value: "composer draft", identifier: "composer",
                            frame: CGRect(x: 520, y: 700, width: 400, height: 60), focused: true)
        let focused = extract([text("body")], focusedElement: fallback).page.focused
        XCTAssertEqual(focused?.role, "AXTextArea")
        XCTAssertEqual(focused?.value, "composer draft")
    }

    func testNoFocusAnywhereYieldsNilFocusedElement() {
        XCTAssertNil(extract([text("body")]).page.focused)
    }

    func testSecureFocusedFieldNeverCarriesItsValue() {
        let secure = node("AXTextField", value: "hunter2", identifier: "password",
                          subrole: "AXSecureTextField",
                          frame: CGRect(x: 520, y: 340, width: 400, height: 24), focused: true)
        let focused = extract([secure]).page.focused
        XCTAssertEqual(focused?.isSecure, true)
        XCTAssertNil(focused?.value)
    }

    func testNothingIsTrimmedWhenEverythingFits() {
        let result = extract([text("alpha", y: 320), text("bravo", y: 340)])
        XCTAssertEqual(blocks(result, .main).map(\.text), ["alpha", "bravo"])
        XCTAssertFalse(result.truncated)
    }

    func testUnusedDialogAndRestSharesRollIntoMain() {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 40   // mainShare alone would be 28 and would drop the third block
        let result = extract([
            text("aaaaaaaaaa", y: 320), text("bbbbbbbbbb", y: 340), text("cccccccccc", y: 360),
        ], options: options)
        XCTAssertEqual(blocks(result, .main).count, 3, "the unused 15% + 15% roll into main")
        XCTAssertFalse(result.truncated)
    }

    func testRestRegionsShareTheirBudgetProportionallyAndNeverSplitABlock() {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 100   // restAllowance = 15 for a 34-char unbounded rest
        let sidebar = node("AXGroup", identifier: "sidebar",
                           frame: CGRect(x: 500, y: 400, width: 300, height: 300), children: [
            node("AXOutline", frame: CGRect(x: 500, y: 400, width: 300, height: 300), children: [
                node("AXListItem", frame: CGRect(x: 510, y: 410, width: 280, height: 20),
                     children: [text("Alpha", y: 410)]),
                node("AXListItem", frame: CGRect(x: 510, y: 430, width: 280, height: 20),
                     children: [text("Bravo", y: 430)]),
                node("AXListItem", frame: CGRect(x: 510, y: 450, width: 280, height: 20),
                     children: [text("Charlie", y: 450)]),
            ]),
        ])
        let toolbar = node("AXToolbar", frame: CGRect(x: 500, y: 300, width: 1000, height: 40),
                           children: [text("Uploading", y: 310)])
        let result = extract([toolbar, sidebar, text("Main", y: 500)], options: options)

        XCTAssertEqual(blocks(result, .sidebar).map(\.text), ["Alpha"],
                       "sidebar's proportional share fits one item")
        XCTAssertEqual(blocks(result, .toolbar).map(\.text), ["Uploading"],
                       "a single block larger than its share is kept whole, never split")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["Main"])
        XCTAssertTrue(result.truncated)
    }

    func testDialogIsNeverTrimmedAndTakesItsOverflowFromMain() throws {
        var options = GenericPageExtractor.Options()
        options.totalBudget = 100
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil, options: options
        )
        XCTAssertEqual(blocks(result, .dialog).map(\.text),
                       ["Quit Cloudflare WARP?", "Open tunnels will disconnect.", "Quit", "Cancel"],
                       "a dialog is never trimmed")
        XCTAssertEqual(blocks(result, .main).map(\.text), ["Main body line one", "Main body line two"],
                       "main pays for the dialog's overflow")
        XCTAssertTrue(result.truncated)
    }

    func testDefaultBudgetLeavesTheDialogFixtureIntact() throws {
        let result = GenericPageExtractor.extract(
            window: try fixture("dialog-over-window"), focusedElement: nil, url: nil
        )
        XCTAssertEqual(blocks(result, .main).count, 6)
        XCTAssertEqual(blocks(result, .dialog).count, 4)
        XCTAssertFalse(result.truncated)
    }

    func testTrimDropsWholeBlocksFromTheEnd() {
        let input = [
            Block(type: .paragraph, text: "0123456789"),
            Block(type: .paragraph, text: "abcdefghij"),
            Block(type: .paragraph, text: "klmnopqrst"),
        ]
        let trimmed = GenericPageExtractor.trim(input, to: 21)
        XCTAssertEqual(trimmed.blocks.map(\.text), ["0123456789", "abcdefghij"])
        XCTAssertTrue(trimmed.truncated)
        XCTAssertFalse(GenericPageExtractor.trim(input, to: 1_000).truncated)
    }

    func testMenuSubtreeIsNeverConsultedForFocus() {
        let menu = node("AXMenu", frame: CGRect(x: 520, y: 320, width: 200, height: 200), children: [
            node("AXMenuItem", title: "Copy", frame: CGRect(x: 520, y: 340, width: 200, height: 20),
                 focused: true),
        ])
        XCTAssertNil(extract([menu, text("body", y: 500)]).page.focused)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenericPageBudgetTests`
Expected: FAIL — `page.focused` is nil in the first test, and "type 'GenericPageExtractor' has no member 'trim'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/GenericPageExtractor.swift`, replace the body of `extract` with:

```swift
    public static func extract(
        window: AXNode,
        focusedElement: AXNode?,
        url: String?,
        options: Options = Options()
    ) -> Result {
        var claims = [Claim(kind: .main,
                            y: window.frame?.minY ?? 0,
                            x: window.frame?.minX ?? 0,
                            entries: [])]
        var order = 0
        walk(window, window: window, claimIndex: 0, parentIsSplitGroup: false,
             listDepth: 0, options: options, order: &order, claims: &claims)
        let budgeted = applyBudgets(assemble(claims), options: options)
        return Result(
            page: GenericPage(
                regions: budgeted.regions,
                focused: resolveFocusedElement(in: window, fallback: focusedElement),
                url: url
            ),
            truncated: budgeted.truncated
        )
    }
```

and add these functions to the enum:

```swift
    /// Preferred source is the deepest node in the window tree with `focused == true`; when the
    /// tree has none, the caller's `AXReader.focusedElementSnapshot` result is used. Menu
    /// subtrees are excluded here for the same reason they are excluded from the text walk.
    static func resolveFocusedElement(in window: AXNode, fallback: AXNode?) -> FocusedElement? {
        var best: (depth: Int, node: AXNode)?
        func visit(_ node: AXNode, depth: Int) {
            if menuRoles.contains(node.role) { return }
            if node.focused, best == nil || depth > best!.depth {
                best = (depth, node)
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        guard let node = best?.node ?? fallback else { return nil }
        let isSecure = node.subrole == secureSubrole
        return FocusedElement(
            role: node.role,
            identifier: node.identifier,
            value: isSecure ? nil : node.value,
            selectedText: node.selectedText,
            isSecure: isSecure
        )
    }

    static func renderedSize(_ blocks: [Block]) -> Int {
        ContentRenderer.renderBlocks(blocks).count
    }

    /// `main` gets `totalBudget × mainShare`, `dialog` gets `× dialogShare`, all other regions
    /// share `× restShare` proportionally to their unbounded rendered size. Unused share rolls
    /// into `main`. `.dialog` is never trimmed — if it exceeds its share it takes the space
    /// from `main`, because a dialog is short and is usually the most important thing on screen.
    static func applyBudgets(_ regions: [Region], options: Options) -> (regions: [Region], truncated: Bool) {
        let total = max(1, options.totalBudget)
        let dialogAllowance = Int(Double(total) * options.dialogShare)
        let restAllowance = Int(Double(total) * options.restShare)
        var mainAllowance = Int(Double(total) * options.mainShare)
        var truncated = false

        let dialogBlocks = regions.first(where: { $0.kind == .dialog })?.blocks ?? []
        mainAllowance += dialogAllowance - renderedSize(dialogBlocks)

        let rest = regions.filter { $0.kind != .main && $0.kind != .dialog }
        let restSizes = rest.map { renderedSize($0.blocks) }
        let restTotal = restSizes.reduce(0, +)
        var trimmedRest: [Region] = []
        var restUsed = 0
        if restTotal <= restAllowance {
            trimmedRest = rest
            restUsed = restTotal
        } else {
            for (region, unbounded) in zip(rest, restSizes) {
                let share = restTotal > 0
                    ? Int(Double(restAllowance) * Double(unbounded) / Double(restTotal))
                    : 0
                let result = trim(region.blocks, to: share)
                truncated = truncated || result.truncated
                if !result.blocks.isEmpty {
                    trimmedRest.append(Region(kind: region.kind, blocks: result.blocks))
                }
                restUsed += renderedSize(result.blocks)
            }
        }
        mainAllowance = max(0, mainAllowance + restAllowance - restUsed)

        let mainResult = trim(regions.first(where: { $0.kind == .main })?.blocks ?? [], to: mainAllowance)
        truncated = truncated || mainResult.truncated

        var out: [Region] = []
        for kind in ContentRenderer.regionOrder {
            switch kind {
            case .main:
                if !mainResult.blocks.isEmpty { out.append(Region(kind: .main, blocks: mainResult.blocks)) }
            case .dialog:
                if !dialogBlocks.isEmpty { out.append(Region(kind: .dialog, blocks: dialogBlocks)) }
            default:
                if let region = trimmedRest.first(where: { $0.kind == kind }) { out.append(region) }
            }
        }
        return (out, truncated)
    }

    /// Drops whole blocks from the END of the list. Never splits a block, so a single block
    /// larger than the allowance is kept whole.
    static func trim(_ blocks: [Block], to allowance: Int) -> (blocks: [Block], truncated: Bool) {
        var kept: [Block] = []
        var used = 0
        for block in blocks {
            let cost = ContentRenderer.renderBlock(block).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, used + cost > allowance { break }
            kept.append(block)
            used += cost
        }
        return (kept, kept.count != blocks.count)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenericPageBudgetTests`
Expected: PASS, 11 tests.

Run: `swift test --filter GenericPageRegionTests`
Expected: PASS — the default 8_000 budget trims nothing in those fixtures.

Run: `swift test --filter GenericPageExtractorTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/GenericPageExtractor.swift Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift
git commit -m "Add focused element capture and per-region budgets to GenericPageExtractor"
```

---

### Task 8: Migration `v10` and the structured read path

**Files:**
- Modify: `Sources/MaxMiStore/Migrations.swift:4` (`currentIdentifier`) and the end of `migrator` (register `v10` after `v9`)
- Modify: `Sources/MaxMiStore/StoreAPI.swift:32-35` (add `structuredOrLegacy` next to `decryptOrMarker`)
- Modify: `Sources/MaxMiStore/LatestContextStore.swift:5-21, 26-92, 131-142, 149-178`
- Test: `Tests/MaxMiStoreTests/MigrationV10Tests.swift`, `Tests/MaxMiStoreTests/StructuredContextReadTests.swift`

**Interfaces:**
- Consumes: `CapturedContentEnvelope.decode(_:)`, `LegacyContentAdapter.adapt(renderedContent:kind:)`, `FieldCipher.decrypt(_:)`.
- Produces: schema `v10` with `versions.structured_ciphertext TEXT` and `latest_contexts.structured_ciphertext TEXT`, both nullable; `Store.structuredOrLegacy(_ stored: String?, renderedContent: String, kind: CaptureContentKind) -> CapturedContent`; `LatestContextRecord.structured: CapturedContent` (non-optional).

`Sources/MaxMiStore/DatabaseRecovery.swift:131` compares the last applied migration identifier with `Migrations.currentIdentifier`; bumping one without the other makes every launch look like a schema mismatch, so both move in this task.

This task does **not** write the new columns — `commitCapture` starts writing them in Task 9. That is deliberate: after this task every row has `structured_ciphertext IS NULL`, which is exactly the pre-v10 state the read path must handle, and the tests here prove it.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiStoreTests/MigrationV10Tests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationV10Tests: XCTestCase {
    func testStructuredColumnsExistAndAreNullableText() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            for table in ["versions", "latest_contexts"] {
                let columns = try Row.fetchAll(d, sql: "PRAGMA table_info(\(table))")
                let column = try XCTUnwrap(
                    columns.first { ($0["name"] as String) == "structured_ciphertext" },
                    "\(table) is missing structured_ciphertext")
                XCTAssertEqual(column["type"] as String, "TEXT", "\(table)")
                XCTAssertEqual(column["notnull"] as Int, 0, "\(table).structured_ciphertext is nullable")
            }
        }
    }

    func testCurrentIdentifierIsV10() {
        XCTAssertEqual(Migrations.currentIdentifier, "v10")
    }

    func testNullStructuredCiphertextIsAcceptedByBothTables() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Web','https://x.com','X',NULL,1,1)")
            try d.execute(sql: """
                INSERT INTO versions (id,thread_id,hour_bucket,content,content_hash,word_count,
                                      is_frozen,committed_at,extract_status,structured_ciphertext)
                VALUES ('v1','t1',100,'c','h',1,0,1,'pending',NULL)
                """)
            try d.execute(sql: """
                INSERT INTO latest_contexts (
                  thread_id, version_id, content_ciphertext, content_hash, content_kind,
                  parser_id, parser_version, accumulation_policy, offscreen_mode,
                  offscreen_max_steps, offscreen_max_chars, trigger, captured_at,
                  character_count, truncated, structured_ciphertext
                ) VALUES ('t1','v1','c','h','generic','legacy',1,'replace','visibleOnly',0,32000,
                          'unknown',1,1,0,NULL)
                """)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM latest_contexts"), 1)
        }
    }
}
```

Create `Tests/MaxMiStoreTests/StructuredContextReadTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class StructuredContextReadTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let cipher = AESGCMFieldCipher.testCipher
    let t0 = EpochMs(1_757_000_000_000)

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: cipher)
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                         content: "note body\nsecond line"),
            nowMs: t0
        )
    }

    func setStructured(_ value: String?) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE latest_contexts SET structured_ciphertext=?", arguments: [value])
        }
    }

    func read() throws -> LatestContextRecord {
        try XCTUnwrap(try store.latestContexts(limit: 1).first)
    }

    func testNullStructuredFallsBackToLegacyAdapter() throws {
        try setStructured(nil)
        let record = try read()
        XCTAssertEqual(record.structured,
                       LegacyContentAdapter.adapt(renderedContent: record.content, kind: record.contentKind))
        XCTAssertEqual(ContentRenderer.render(record.structured, style: .full), record.content)
    }

    func testRealEnvelopeIsDecodedVerbatim() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true,
            messages: [Message(id: "1", sender: "Ana", text: "ping", timestamp: nil,
                               timeString: "09:20", isUser: false, isDraft: false)]
        ))
        try setStructured(try cipher.encrypt(try CapturedContentEnvelope.encode(structured)))
        XCTAssertEqual(try read().structured, structured)
    }

    func testUndecryptableCiphertextFallsBackInsteadOfThrowing() throws {
        try setStructured("enc:v1:not-base64!!")
        let record = try read()
        XCTAssertEqual(record.structured.kind, .generic)
        XCTAssertEqual(ContentRenderer.render(record.structured, style: .full), record.content)
    }

    func testUndecodableJSONFallsBack() throws {
        try setStructured(try cipher.encrypt("{\"nope\":true}"))
        XCTAssertEqual(try read().structured.kind, .generic)
    }

    func testFutureSchemaVersionIsTreatedExactlyLikeNull() throws {
        let future = "{\"v\":99,\"content\":{\"generic\":{\"_0\":{\"regions\":[]}}}}"
        try setStructured(try cipher.encrypt(future))
        let record = try read()
        XCTAssertEqual(record.structured,
                       LegacyContentAdapter.adapt(renderedContent: record.content, kind: record.contentKind))
    }

    func testFilteredPageReadAlsoResolvesStructured() throws {
        let structured = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        try setStructured(try cipher.encrypt(try CapturedContentEnvelope.encode(structured)))
        let page = try store.latestContexts(
            filter: RetrievalFilter(sourceApps: [], contentKinds: [], startAtMs: nil, endAtMs: t0 + 1_000),
            source: nil, threadID: nil, offset: 0, limit: 5
        )
        XCTAssertEqual(page.records.first?.structured, structured)
    }
}
```

If `RetrievalFilter`'s initializer differs from the call above, read `Sources/MaxMiStore/RetrievalModels.swift` and copy the real one — the assertion, not the constructor shape, is the point of this test. `Tests/MaxMiStoreTests/QueryAPITests.swift` has a working example.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MigrationV10Tests`
Expected: FAIL — "versions is missing structured_ciphertext".

Run: `swift test --filter StructuredContextReadTests`
Expected: FAIL to compile — "value of type 'LatestContextRecord' has no member 'structured'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiStore/Migrations.swift`, change line 4 and append the migration after the `v9` block (before the closing `return m`):

```swift
    static let currentIdentifier = "v10"
```

```swift
        m.registerMigration("v10") { db in
            // Additive and nullable: v9 readers are unaffected, so rollback is "ignore the two
            // new columns". TEXT, not BLOB, because FieldCipher.encrypt returns the "enc:v1:"
            // prefixed base64 String and every other ciphertext column in the schema is TEXT.
            // No backfill: rows written before v10 read through LegacyContentAdapter.
            try db.execute(sql: """
            ALTER TABLE versions        ADD COLUMN structured_ciphertext TEXT;
            ALTER TABLE latest_contexts ADD COLUMN structured_ciphertext TEXT;
            """)
        }
```

In `Sources/MaxMiStore/StoreAPI.swift`, add below `decryptOrMarker`:

```swift
    /// A NULL column, a decrypt failure, a JSON decode failure, and a schema version newer than
    /// this build are all the same case: fall back to the legacy adaptation of the rendered
    /// content. Never a throw, never a lost capture.
    func structuredOrLegacy(
        _ stored: String?,
        renderedContent: String,
        kind: CaptureContentKind
    ) -> CapturedContent {
        guard let stored,
              let plain = try? cipher.decrypt(stored),
              let content = CapturedContentEnvelope.decode(plain) else {
            return LegacyContentAdapter.adapt(renderedContent: renderedContent, kind: kind)
        }
        return content
    }
```

In `Sources/MaxMiStore/LatestContextStore.swift`:

1. Add the property to `LatestContextRecord`, after `content`:

```swift
    public let content: String
    /// The typed shape. Rows written before schema v10, and rows whose payload cannot be read,
    /// resolve to `LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)`.
    public let structured: CapturedContent
```

2. Add `c.structured_ciphertext,` to the select list of all three `SELECT` statements (both in `latestContexts(limit:source:)` and the one in `latestContexts(filter:source:threadID:offset:limit:)`), immediately after `c.content_ciphertext,`.

3. Replace the inline `rows.compactMap { row in … }` closure in `latestContexts(limit:source:)` (it duplicates `record(from:)` exactly) with:

```swift
            return rows.compactMap(record(from:))
```

4. Rewrite `record(from:)` so the decrypted content is computed once and feeds both fields:

```swift
    private func record(from row: Row) -> LatestContextRecord? {
        guard
            let kind = CaptureContentKind(rawValue: row["content_kind"]),
            let accumulation = CaptureAccumulationPolicy(rawValue: row["accumulation_policy"]),
            let offscreenMode = OffscreenCaptureMode(rawValue: row["offscreen_mode"]),
            let trigger = CaptureTrigger(rawValue: row["trigger"])
        else { return nil }
        let content = decryptOrMarker(row["content_ciphertext"])
        return LatestContextRecord(
            id: row["thread_id"],
            sourceApp: row["source_app"],
            sourceKey: row["source_key"],
            sourceTitle: row["source_title"],
            content: content,
            structured: structuredOrLegacy(row["structured_ciphertext"],
                                           renderedContent: content, kind: kind),
            contentKind: kind,
            parserID: row["parser_id"],
            parserVersion: row["parser_version"],
            accumulationPolicy: accumulation,
            offscreenPolicy: OffscreenCapturePolicy(
                mode: offscreenMode,
                maxSteps: row["offscreen_max_steps"],
                maxCharacters: row["offscreen_max_chars"]
            ),
            trigger: trigger,
            capturedAtMs: row["captured_at"],
            characterCount: row["character_count"],
            truncated: (row["truncated"] as Int) != 0,
            displaySummary: (row["display_summary_ciphertext"] as String?).map(decryptOrMarker),
            summaryStatus: row["summary_status"]
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MigrationV10Tests`
Expected: PASS, 3 tests.

Run: `swift test --filter StructuredContextReadTests`
Expected: PASS, 6 tests.

Run: `swift test --filter MaxMiStoreTests`
Expected: PASS, unchanged — `LatestContextRecord` is only constructed inside `LatestContextStore.swift`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiStore/Migrations.swift Sources/MaxMiStore/StoreAPI.swift \
        Sources/MaxMiStore/LatestContextStore.swift \
        Tests/MaxMiStoreTests/MigrationV10Tests.swift \
        Tests/MaxMiStoreTests/StructuredContextReadTests.swift
git commit -m "Add v10 structured ciphertext columns and the structured read path"
```

---

### Task 9: `CaptureDelta` + kind-aware accumulation + `commitCapture` writes structured

**Files:**
- Create: `Sources/MaxMiCore/CaptureDelta.swift`
- Create: `Sources/MaxMiCore/StructuredAccumulator.swift`
- Modify: `Sources/MaxMiStore/StoreAPI.swift:20-23` (`CommitResult`), `:68-186` (`commitCapture(_:nowMs:)`)
- Modify: `Sources/MaxMi/AppWiring.swift:1574, 1592`
- Modify (mechanical, one binding each): `Tests/MaxMiStoreTests/EncryptionAtRestTests.swift:18`, `Tests/MaxMiStoreTests/MarkExtractedTests.swift:18`, `Tests/MaxMiStoreTests/QueryAPITests.swift:22`, `Tests/MaxMiStoreTests/LocalMemorySearchTests.swift:23`, `Tests/MaxMiStoreTests/ActivityStoreTests.swift:44`, `Tests/MaxMiStoreTests/CommitCaptureTests.swift:20, 39, 42`, `Tests/MaxMiMCPTests/MemoryQueriesTests.swift:32`, `Tests/MaxMiMCPTests/LazyToolsTests.swift:19, 108`
- Test: `Tests/MaxMiCoreTests/StructuredAccumulatorTests.swift`, `Tests/MaxMiStoreTests/StructuredCommitTests.swift`

**Interfaces:**
- Consumes: `CapturedContent` and friends, `ContentRenderer` (incl. `renderMessage`, `renderSegment`, `renderTask`, `renderEvent`, `renderBlock`), `CaptureAccumulationPolicy`, `Store.structuredOrLegacy` (Task 8).
- Produces: `CaptureDelta` (`addedBlocks: [Block]`, `addedMessages: [Message]`, `addedSegments: [TerminalSegment]`, `removedCount: Int`, `addedChars: Int`, `removedChars: Int`, `isFirstCapture: Bool`, `var isEmpty: Bool`, `static let empty`, `static func between(previous: CapturedContent?, merged: CapturedContent) -> CaptureDelta`); `StructuredAccumulationResult` (`content: CapturedContent`, `rendered: String`, `changed: Bool`, `delta: CaptureDelta`); `CaptureAccumulator.merge(previous: CapturedContent?, incoming: CapturedContent, policy: CaptureAccumulationPolicy, maxCharacters: Int) -> StructuredAccumulationResult`; `CaptureAccumulator.bound(_ content: CapturedContent, to maxCharacters: Int) -> CapturedContent` (public — the migrated parsers in Tasks 11-16 cap their own output with it); `CommitResult.committed(versionID: String, contentHash: String, delta: CaptureDelta)`.

**Phase B depends on every name in that Produces list.** Do not rename anything here.

The existing `CaptureAccumulator.merge(previous: String?, …) -> CaptureAccumulationResult` **stays** — it is still exercised by `Tests/MaxMiCoreTests/CaptureAccumulatorTests.swift` and is the documented string policy that `.compact` reuses.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCoreTests/StructuredAccumulatorTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class StructuredAccumulatorTests: XCTestCase {
    func message(_ sender: String, _ text: String, time: String? = nil,
                 isUser: Bool = false, isDraft: Bool = false) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: time, text: text),
                sender: sender, text: text, timestamp: nil, timeString: time,
                isUser: isUser, isDraft: isDraft)
    }

    func conversation(_ messages: [Message], channel: String = "#dev") -> CapturedContent {
        .conversation(Conversation(channel: channel, isGroup: true, messages: messages))
    }

    func merge(_ previous: CapturedContent?, _ incoming: CapturedContent,
               policy: CaptureAccumulationPolicy = .appendItems,
               maxCharacters: Int = 10_000) -> StructuredAccumulationResult {
        CaptureAccumulator.merge(previous: previous, incoming: incoming,
                                 policy: policy, maxCharacters: maxCharacters)
    }

    func testFirstCaptureIsTheIncomingValueAndIsMarkedFirst() {
        let incoming = conversation([message("Ana", "one")])
        let result = merge(nil, incoming)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.rendered, ContentRenderer.render(incoming, style: .full))
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.delta.isFirstCapture)
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["one"])
        XCTAssertEqual(result.delta.removedCount, 0)
    }

    func testConversationUnionsByMessageIdPreservingOrder() {
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let incoming = conversation([message("Bo", "two"), message("Cy", "three")])
        let result = merge(previous, incoming)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["three"])
        XCTAssertEqual(result.delta.removedCount, 0)
        XCTAssertFalse(result.delta.isFirstCapture)
        XCTAssertTrue(result.changed)
    }

    func testConversationUnchangedIncomingReportsNoChangeAndEmptyDelta() {
        let previous = conversation([message("Ana", "one")])
        let result = merge(previous, conversation([message("Ana", "one")]))
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.delta.isEmpty)
    }

    func testOnlyTheIncomingDraftSurvivesPerSenderAndAlwaysSitsLast() {
        let previous = conversation([
            message("Ana", "one"),
            message("Sudhanshu", "old draft", isUser: true, isDraft: true),
        ])
        let incoming = conversation([
            message("Ana", "one"),
            message("Sudhanshu", "new draft", isUser: true, isDraft: true),
        ])
        guard case .conversation(let merged) = merge(previous, incoming).content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["one", "new draft"])
        XCTAssertEqual(merged.messages.filter(\.isDraft).count, 1, "a draft is a live edit, not history")
    }

    func testReplacePolicyDropsPreviousMessagesAndCountsThemRemoved() {
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let incoming = conversation([message("Cy", "three")])
        let result = merge(previous, incoming, policy: .replace)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["three"])
        XCTAssertEqual(result.delta.removedCount, 2)
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["three"])
    }

    func testTerminalAppendsWhenCwdMatchesAndPreviousIsAPrefix() {
        let previous = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
        ]))
        let incoming = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: true),
        ]))
        let result = merge(previous, incoming)
        guard case .terminal(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(merged.segments.last?.isRunning, true, "isRunning always comes from incoming")
        XCTAssertEqual(result.delta.addedSegments.map(\.command), ["swift test"])
    }

    func testTerminalReplacesOnCwdChangeOrDivergentHistory() {
        let previous = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
        ]))
        let otherDir = CapturedContent.terminal(TerminalSession(cwd: "yuki", segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        guard case .terminal(let replaced) = merge(previous, otherDir).content else { return XCTFail() }
        XCTAssertEqual(replaced.segments.map(\.command), ["ls"])

        let divergent = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "clear", output: "", isRunning: false),
        ]))
        let result = merge(previous, divergent)
        guard case .terminal(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.segments.map(\.command), ["clear"])
        XCTAssertTrue(result.delta.addedSegments.isEmpty, "a replace appends nothing")
        XCTAssertEqual(result.delta.removedCount, 1)
    }

    func testDocumentAndGenericReplaceAndReportAddedMainBlocks() {
        let previous = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "old line")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Chrome churn A")]),
        ], focused: nil, url: nil))
        let incoming = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "old line"),
                                         Block(type: .paragraph, text: "new line")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Chrome churn B")]),
        ], focused: nil, url: nil))
        let result = merge(previous, incoming, policy: .rollingText)
        XCTAssertEqual(result.content, incoming, ".generic replaces with incoming")
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["new line"],
                       "non-main regions are ignored for delta purposes")
    }

    func testDocumentDeltaUsesItsOwnBlocks() {
        let previous = CapturedContent.document(Document(
            title: "Notes", blocks: [Block(type: .paragraph, text: "a")], author: .user, url: nil))
        let incoming = CapturedContent.document(Document(
            title: "Notes", blocks: [Block(type: .paragraph, text: "a"),
                                     Block(type: .paragraph, text: "b")], author: .user, url: nil))
        let result = merge(previous, incoming, policy: .rollingText)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["b"])
    }

    func testTasksAndCalendarReplaceAndOnlyReportCharCounts() {
        let previous = CapturedContent.tasks([
            TaskItem(title: "one", status: .open, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
        ])
        let incoming = CapturedContent.tasks([
            TaskItem(title: "one", status: .completed, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
            TaskItem(title: "two", status: .open, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
        ])
        let result = merge(previous, incoming, policy: .replace)
        XCTAssertEqual(result.content, incoming)
        XCTAssertTrue(result.delta.addedBlocks.isEmpty)
        XCTAssertTrue(result.delta.addedMessages.isEmpty)
        XCTAssertTrue(result.delta.addedSegments.isEmpty)
        XCTAssertGreaterThan(result.delta.addedChars, 0, "something changed is still visible")

        let calendarPrevious = CapturedContent.calendar([
            CalendarEvent(title: "Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(merge(calendarPrevious, calendarPrevious).content, calendarPrevious)
    }

    func testShapeChangeIsAlwaysAReplace() {
        let previous = conversation([message("Ana", "one")])
        let incoming = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        let result = merge(previous, incoming)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.delta.addedSegments.count, 1)
    }

    func testBoundingTrimsWholeMessagesFromTheFrontAndNeverSplitsOne() {
        let messages = (0..<40).map { message("Ana", "message number \($0)") }
        let result = merge(nil, conversation(messages), maxCharacters: 300)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertLessThanOrEqual(result.rendered.count, 300)
        XCTAssertLessThan(merged.messages.count, 40)
        XCTAssertEqual(merged.messages.last?.text, "message number 39", "oldest go first")
        for rendered in merged.messages.map(ContentRenderer.renderMessage) {
            XCTAssertTrue(result.rendered.contains(rendered), "no message is cut mid-way")
        }
    }

    func testBoundingKeepsAtLeastOneItem() {
        let long = String(repeating: "x", count: 5_000)
        let result = merge(nil, conversation([message("Ana", long)]), maxCharacters: 1_000)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.count, 1, "never trim below one whole item")
    }

    func testCaptureDeltaEmptyAndCharCounts() {
        XCTAssertTrue(CaptureDelta.empty.isEmpty)
        XCTAssertFalse(CaptureDelta.empty.isFirstCapture)
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let delta = CaptureDelta.between(previous: previous, merged: conversation([message("Ana", "one")]))
        XCTAssertEqual(delta.removedCount, 1)
        XCTAssertGreaterThan(delta.removedChars, 0)
        XCTAssertEqual(delta.addedChars, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StructuredAccumulatorTests`
Expected: FAIL to compile — "cannot find 'StructuredAccumulationResult' in scope".

- [ ] **Step 3a: Write `CaptureDelta`**

Create `Sources/MaxMiCore/CaptureDelta.swift`:

```swift
import Foundation

/// What actually changed in one capture. Exactly one of the three `added*` arrays is non-empty
/// for any given delta; the others are empty. A struct rather than an enum so the encrypted JSON
/// payload Phase B writes stays flat and stable.
public struct CaptureDelta: Codable, Sendable, Equatable {
    public let addedBlocks: [Block]
    public let addedMessages: [Message]
    public let addedSegments: [TerminalSegment]
    public let removedCount: Int
    public let addedChars: Int
    public let removedChars: Int
    public let isFirstCapture: Bool

    public init(addedBlocks: [Block] = [], addedMessages: [Message] = [],
                addedSegments: [TerminalSegment] = [], removedCount: Int = 0,
                addedChars: Int = 0, removedChars: Int = 0, isFirstCapture: Bool = false) {
        self.addedBlocks = addedBlocks
        self.addedMessages = addedMessages
        self.addedSegments = addedSegments
        self.removedCount = removedCount
        self.addedChars = addedChars
        self.removedChars = removedChars
        self.isFirstCapture = isFirstCapture
    }

    public var isEmpty: Bool {
        addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty
            && removedCount == 0
    }

    public static let empty = CaptureDelta()

    /// Computed once, inside `CaptureAccumulator.merge`. Never recomputed elsewhere.
    public static func between(previous: CapturedContent?, merged: CapturedContent) -> CaptureDelta {
        let previousRendered = previous.map { ContentRenderer.render($0, style: .full) } ?? ""
        let mergedRendered = ContentRenderer.render(merged, style: .full)
        let addedChars = max(0, mergedRendered.count - previousRendered.count)
        let removedChars = max(0, previousRendered.count - mergedRendered.count)
        let isFirst = previous == nil

        switch merged {
        case .conversation(let current):
            let old = previousMessages(previous)
            let oldIDs = Set(old.map(\.id))
            let currentIDs = Set(current.messages.map(\.id))
            return CaptureDelta(
                addedMessages: current.messages.filter { !oldIDs.contains($0.id) },
                removedCount: old.filter { !currentIDs.contains($0.id) }.count,
                addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
        case .terminal(let current):
            let old = previousSegments(previous)
            let appended = isSegmentPrefix(old, current.segments)
            return CaptureDelta(
                addedSegments: appended ? Array(current.segments.dropFirst(old.count)) : [],
                removedCount: appended ? 0 : old.count,
                addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
        case .document(let current):
            return blockDelta(old: previousDocumentBlocks(previous), new: current.blocks,
                              addedChars: addedChars, removedChars: removedChars, isFirst: isFirst)
        case .generic(let current):
            // Only `.main` counts: chrome churns constantly and would drown the signal. A
            // `.dialog` region appearing is reported as a dialog event in Phase B instead.
            return blockDelta(old: previousMainBlocks(previous), new: mainBlocks(current),
                              addedChars: addedChars, removedChars: removedChars, isFirst: isFirst)
        case .tasks, .calendar:
            return CaptureDelta(addedChars: addedChars, removedChars: removedChars,
                                isFirstCapture: isFirst)
        }
    }

    static func blockDelta(old: [Block], new: [Block], addedChars: Int, removedChars: Int,
                           isFirst: Bool) -> CaptureDelta {
        let oldTexts = Set(old.map(\.text))
        let newTexts = Set(new.map(\.text))
        return CaptureDelta(
            addedBlocks: new.filter { !oldTexts.contains($0.text) },
            removedCount: old.filter { !newTexts.contains($0.text) }.count,
            addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
    }

    static func mainBlocks(_ page: GenericPage) -> [Block] {
        page.regions.filter { $0.kind == .main }.flatMap(\.blocks)
    }

    static func previousMessages(_ previous: CapturedContent?) -> [Message] {
        if case .conversation(let value) = previous { return value.messages }
        return []
    }

    static func previousSegments(_ previous: CapturedContent?) -> [TerminalSegment] {
        if case .terminal(let value) = previous { return value.segments }
        return []
    }

    static func previousDocumentBlocks(_ previous: CapturedContent?) -> [Block] {
        if case .document(let value) = previous { return value.blocks }
        return []
    }

    static func previousMainBlocks(_ previous: CapturedContent?) -> [Block] {
        if case .generic(let value) = previous { return mainBlocks(value) }
        return []
    }

    /// Prefix under `(command, output)` equality — `isRunning` is volatile and never compared.
    static func isSegmentPrefix(_ prefix: [TerminalSegment], _ whole: [TerminalSegment]) -> Bool {
        guard prefix.count <= whole.count else { return false }
        for (index, segment) in prefix.enumerated() {
            if segment.command != whole[index].command || segment.output != whole[index].output {
                return false
            }
        }
        return true
    }
}
```

- [ ] **Step 3b: Write the structured accumulator**

Create `Sources/MaxMiCore/StructuredAccumulator.swift`:

```swift
import Foundation

public struct StructuredAccumulationResult: Sendable, Equatable {
    public let content: CapturedContent
    /// `ContentRenderer.render(content, style: .full)` — what goes into `versions.content`.
    public let rendered: String
    public let changed: Bool
    /// Never discarded. `Store.commitCapture` hands it back through `CommitResult`.
    public let delta: CaptureDelta

    public init(content: CapturedContent, rendered: String, changed: Bool, delta: CaptureDelta) {
        self.content = content
        self.rendered = rendered
        self.changed = changed
        self.delta = delta
    }
}

extension CaptureAccumulator {
    /// Kind-aware accumulation. The incoming shape wins; a shape change is a replace.
    public static func merge(
        previous: CapturedContent?,
        incoming: CapturedContent,
        policy: CaptureAccumulationPolicy,
        maxCharacters: Int
    ) -> StructuredAccumulationResult {
        let cap = max(1_000, maxCharacters)
        let merged: CapturedContent
        if let previous, sameShape(previous, incoming) {
            merged = mergeSameShape(previous: previous, incoming: incoming, policy: policy)
        } else {
            merged = incoming
        }
        let bounded = bound(merged, to: cap)
        return StructuredAccumulationResult(
            content: bounded,
            rendered: ContentRenderer.render(bounded, style: .full),
            changed: previous != bounded,
            delta: CaptureDelta.between(previous: previous, merged: bounded)
        )
    }

    static func sameShape(_ lhs: CapturedContent, _ rhs: CapturedContent) -> Bool {
        switch (lhs, rhs) {
        case (.document, .document), (.conversation, .conversation), (.tasks, .tasks),
             (.calendar, .calendar), (.terminal, .terminal), (.generic, .generic):
            return true
        default:
            return false
        }
    }

    static func mergeSameShape(
        previous: CapturedContent,
        incoming: CapturedContent,
        policy: CaptureAccumulationPolicy
    ) -> CapturedContent {
        switch (previous, incoming) {
        case (.conversation(let old), .conversation(let new)):
            guard policy != .replace else { return incoming }
            var messages = old.messages.filter { !$0.isDraft }
            let existing = Set(messages.map(\.id))
            for message in new.messages where !message.isDraft && !existing.contains(message.id) {
                messages.append(message)
            }
            // At most one draft per (sender, isUser), always the incoming one: a draft is a
            // live edit, not history.
            messages.append(contentsOf: latestDrafts(new.messages.filter(\.isDraft)))
            return .conversation(Conversation(channel: new.channel, isGroup: new.isGroup,
                                             messages: messages))
        case (.terminal(let old), .terminal(let new)):
            guard policy != .replace, old.cwd == new.cwd,
                  CaptureDelta.isSegmentPrefix(old.segments, new.segments),
                  new.segments.count > old.segments.count else { return incoming }
            var segments = old.segments.map {
                TerminalSegment(command: $0.command, output: $0.output, isRunning: false)
            }
            segments.append(contentsOf: new.segments.dropFirst(old.segments.count))
            return .terminal(TerminalSession(cwd: new.cwd, segments: segments))
        default:
            // .document / .generic / .tasks / .calendar all replace with incoming.
            return incoming
        }
    }

    static func latestDrafts(_ drafts: [Message]) -> [Message] {
        var byKey: [String: Message] = [:]
        var order: [String] = []
        for draft in drafts {
            let key = "\(draft.isUser)\u{1F}\(draft.sender)"
            if byKey[key] == nil { order.append(key) }
            byKey[key] = draft
        }
        return order.compactMap { byKey[$0] }
    }

    /// Bounds the RENDERED form, trimming whole blocks/messages/segments from the front
    /// (oldest first) — never mid-item, and never below one item. Public because the migrated
    /// parsers cap their own output the same way instead of each reinventing it.
    public static func bound(_ content: CapturedContent, to maxCharacters: Int) -> CapturedContent {
        let cap = max(1_000, maxCharacters)
        guard ContentRenderer.render(content, style: .full).count > cap else { return content }
        switch content {
        case .conversation(let value):
            let kept = dropOldest(value.messages, cost: { ContentRenderer.renderMessage($0).count }, cap: cap)
            return .conversation(Conversation(channel: value.channel, isGroup: value.isGroup, messages: kept))
        case .terminal(let value):
            // Segments render separated by a blank line, so each costs two joining newlines.
            let kept = dropOldest(value.segments,
                                  cost: { ContentRenderer.renderSegment($0).count + 1 }, cap: cap)
            return .terminal(TerminalSession(cwd: value.cwd, segments: kept))
        case .tasks(let items):
            return .tasks(dropOldest(items, cost: { ContentRenderer.renderTask($0).count }, cap: cap))
        case .calendar(let events):
            return .calendar(dropOldest(events, cost: { ContentRenderer.renderEvent($0).count }, cap: cap))
        case .document(let value):
            // The title line is always kept; it is the document's identity.
            let titleCost = "# \(value.title)".count + 2
            let kept = dropOldest(value.blocks, cost: { ContentRenderer.renderBlock($0).count },
                                  cap: max(0, cap - titleCost))
            return .document(Document(title: value.title, blocks: kept,
                                      author: value.author, url: value.url))
        case .generic(let page):
            var regions = page.regions
            var urlCost = 0
            if let url = page.url, !url.isEmpty { urlCost = "URL: \(url)".count + 1 }
            // Drop from the front of the first region, then drop that region and continue.
            while !regions.isEmpty {
                let candidate = GenericPage(regions: regions, focused: page.focused, url: page.url)
                if ContentRenderer.render(.generic(candidate), style: .full).count <= cap { break }
                let first = regions[0]
                let others = regions.dropFirst().reduce(0) { $0 + ContentRenderer.renderBlocks($1.blocks).count + 1 }
                let allowance = max(0, cap - urlCost - others)
                let kept = dropOldest(first.blocks, cost: { ContentRenderer.renderBlock($0).count },
                                      cap: allowance)
                if kept.count == first.blocks.count { regions.removeFirst(); continue }
                regions[0] = Region(kind: first.kind, blocks: kept)
                if kept.count <= 1 && regions.count > 1 { break }
            }
            return .generic(GenericPage(regions: regions, focused: page.focused, url: page.url))
        }
    }

    /// Drops items from the FRONT until the joined cost fits, always keeping at least one.
    static func dropOldest<Item>(_ items: [Item], cost: (Item) -> Int, cap: Int) -> [Item] {
        guard items.count > 1 else { return items }
        var kept = items
        var total = kept.reduce(0) { $0 + cost($1) + 1 } - 1
        while kept.count > 1, total > cap {
            total -= cost(kept.removeFirst()) + 1
        }
        return kept
    }
}
```

- [ ] **Step 4a: Run the accumulator test**

Run: `swift test --filter StructuredAccumulatorTests`
Expected: PASS, 14 tests.

Run: `swift test --filter CaptureAccumulatorTests`
Expected: PASS, unchanged — the string overload is untouched.

- [ ] **Step 5a: Commit the core half**

```bash
git add Sources/MaxMiCore/CaptureDelta.swift Sources/MaxMiCore/StructuredAccumulator.swift \
        Tests/MaxMiCoreTests/StructuredAccumulatorTests.swift
git commit -m "Add CaptureDelta and kind-aware structured accumulation"
```

- [ ] **Step 1b: Write the failing store test**

Create `Tests/MaxMiStoreTests/StructuredCommitTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class StructuredCommitTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let cipher = AESGCMFieldCipher.testCipher
    let h10 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: cipher)
    }

    func message(_ sender: String, _ text: String) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: nil, text: text),
                sender: sender, text: text, timestamp: nil, timeString: nil,
                isUser: false, isDraft: false)
    }

    func envelope(_ structured: CapturedContent, key: String = "slack:acme/dev") -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: "Slack", sourceKey: key, sourceTitle: "dev", content: "IGNORED",
            contentKind: .conversation, parserID: "SlackParser", parserVersion: 2,
            accumulationPolicy: .appendItems, offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            trigger: .conversationChanged, truncated: false, structured: structured
        )
    }

    func storedStructured(table: String) throws -> CapturedContent? {
        try db.dbQueue.read { d in
            guard let raw = try String.fetchOne(d, sql: "SELECT structured_ciphertext FROM \(table)")
            else { return nil }
            return CapturedContentEnvelope.decode(try cipher.decrypt(raw))
        }
    }

    func testCommitWritesStructuredToBothTablesEncrypted() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "ping")]))
        guard case .committed = try store.commitCapture(envelope(structured), nowMs: h10)
        else { return XCTFail("expected a commit") }

        XCTAssertEqual(try storedStructured(table: "latest_contexts"), structured)
        XCTAssertEqual(try storedStructured(table: "versions"), structured)
        let raw = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT structured_ciphertext FROM versions")
        }
        XCTAssertEqual(raw?.hasPrefix("enc:v1:"), true, "structured payload is encrypted at rest")
    }

    func testCommittedContentIsTheRenderedStructuredValue() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "ping")]))
        _ = try store.commitCapture(envelope(structured), nowMs: h10)
        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "(From: Ana): ping")
        XCTAssertEqual(record.structured, structured)
    }

    func testConversationAccumulatesAcrossCapturesAndReturnsTheDelta() throws {
        _ = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one")]))),
            nowMs: h10)
        let result = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one"), message("Bo", "two")]))),
            nowMs: h10 + 60_000)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertEqual(delta.addedMessages.map(\.text), ["two"])
        XCTAssertFalse(delta.isFirstCapture)

        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "(From: Ana): one\n(From: Bo): two")
    }

    func testFirstCaptureDeltaIsMarkedFirst() throws {
        let result = try store.commitCapture(
            envelope(.conversation(Conversation(channel: "#dev", isGroup: true,
                                                messages: [message("Ana", "one")]))),
            nowMs: h10)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertTrue(delta.isFirstCapture)
        XCTAssertEqual(delta.addedMessages.count, 1)
    }

    func testUnchangedTreeStillDeduplicates() throws {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#dev", isGroup: true, messages: [message("Ana", "one")]))
        _ = try store.commitCapture(envelope(structured), nowMs: h10)
        XCTAssertEqual(try store.commitCapture(envelope(structured), nowMs: h10 + 1_000), .deduplicated)
    }

    func testLegacyCaptureInputStillCommitsAndStoresGenericStructure() throws {
        let result = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                         content: "note body"),
            nowMs: h10)
        guard case .committed(_, _, let delta) = result else { return XCTFail("expected a commit") }
        XCTAssertTrue(delta.isFirstCapture)
        let record = try XCTUnwrap(try store.latestContexts(limit: 1).first)
        XCTAssertEqual(record.content, "note body")
        XCTAssertEqual(record.structured.kind, .generic)
    }
}
```

- [ ] **Step 2b: Run test to verify it fails**

Run: `swift test --filter StructuredCommitTests`
Expected: FAIL to compile — `case .committed(_, _, let delta)` has the wrong arity for `CommitResult`.

- [ ] **Step 3c: Wire the store**

In `Sources/MaxMiStore/StoreAPI.swift`, change `CommitResult`:

```swift
public enum CommitResult: Equatable, Sendable {
    case deduplicated
    case committed(versionID: String, contentHash: String, delta: CaptureDelta)
}
```

Inside `commitCapture(_ envelope: CaptureEnvelope, nowMs:)`, replace the previous-context read and the accumulation block (currently `StoreAPI.swift:89-105`) with:

```swift
            // 2. Accumulate the raw latest context independently from semantic versions.
            let previousContext = try Row.fetchOne(d, sql: """
                SELECT content_ciphertext, content_hash, structured_ciphertext, content_kind
                FROM latest_contexts WHERE thread_id=?
                """, arguments: [threadID])
            let previousStored = previousContext?["content_ciphertext"] as String?
            let previousContextHash = previousContext?["content_hash"] as String?
            let previous = previousStored.flatMap { try? cipher.decrypt($0) }
            let previousStructured: CapturedContent? = previous.map { rendered in
                let kind = (previousContext?["content_kind"] as String?)
                    .flatMap(CaptureContentKind.init(rawValue:)) ?? .generic
                return structuredOrLegacy(previousContext?["structured_ciphertext"],
                                          renderedContent: rendered, kind: kind)
            }
            let accumulated = CaptureAccumulator.merge(
                previous: previousStructured,
                incoming: envelope.structured,
                policy: envelope.accumulationPolicy,
                maxCharacters: envelope.offscreenPolicy.maxCharacters
            )
            let accumulatedHash = ContentHash.sha256Hex(accumulated.rendered)
            let accumulatedStored = try cipher.encrypt(accumulated.rendered)
            let structuredStored = try cipher.encrypt(
                try CapturedContentEnvelope.encode(accumulated.content))
            let contextTruncated = envelope.truncated
                || accumulated.rendered.count >= envelope.offscreenPolicy.maxCharacters
```

Add the new column to the `latest_contexts` upsert: append `structured_ciphertext` to the column list, one more `?` to the `VALUES` list, `structured_ciphertext=excluded.structured_ciphertext,` to the `DO UPDATE SET` clause, and `structuredStored` to the arguments array immediately after `accumulatedStored`'s group — the argument order must match the column order exactly.

Replace the remaining three uses of `accumulated.content` (`character_count` argument, `let versionContent = accumulated.content`, and the truncation check) with `accumulated.rendered`.

Add the column to the `versions` insert and update. In the UPDATE:

```swift
                try d.execute(sql: """
                    UPDATE versions SET content=?, content_hash=?, word_count=?, committed_at=?,
                                        extract_status='pending', is_frozen=0, metadata=?,
                                        structured_ciphertext=? WHERE id=?
                    """, arguments: [storedContent, versionHash, words, nowMs, metadata,
                                     structuredStored, vid])
```

In the INSERT:

```swift
                try d.execute(sql: """
                    INSERT INTO versions (
                      id, thread_id, hour_bucket, content, content_hash, word_count,
                      is_frozen, committed_at, extract_status, metadata, structured_ciphertext
                    ) VALUES (?,?,?,?,?,?,0,?,'pending',?,?)
                    """, arguments: [vid, threadID, bucket, storedContent, versionHash, words,
                                     nowMs, metadata, structuredStored])
```

and return the delta:

```swift
            return .committed(versionID: versionID, contentHash: versionHash, delta: accumulated.delta)
```

- [ ] **Step 3d: Update the thirteen pattern-match sites**

`Sources/MaxMi/AppWiring.swift:1574` → `if case .committed(let versionID, _, _) = result {`
`Sources/MaxMi/AppWiring.swift:1592` → `case .committed(let versionID, _, _):`

In each of these, add one `_` to the binding list: `Tests/MaxMiStoreTests/EncryptionAtRestTests.swift:18`, `Tests/MaxMiStoreTests/MarkExtractedTests.swift:18`, `Tests/MaxMiStoreTests/QueryAPITests.swift:22`, `Tests/MaxMiStoreTests/LocalMemorySearchTests.swift:23`, `Tests/MaxMiStoreTests/ActivityStoreTests.swift:44`, `Tests/MaxMiStoreTests/CommitCaptureTests.swift:20, 39, 42`, `Tests/MaxMiMCPTests/MemoryQueriesTests.swift:32`, `Tests/MaxMiMCPTests/LazyToolsTests.swift:19, 108`. For example `CommitCaptureTests.swift:20`:

```swift
        guard case .committed(let vid, let hash, _) = try store.commitCapture(input("hello world"), nowMs: h10)
```

`Tests/MaxMiStoreTests/MigrationTests.swift:76` and `Tests/MaxMiStoreTests/FingerprintDedupTests.swift:19, 31` use bare `case .committed` and need no change.

Find any site the list missed with:

```bash
swift build 2>&1 | grep -n "tuple pattern\|committed"
```

- [ ] **Step 4b: Run the store tests**

Run: `swift test --filter StructuredCommitTests`
Expected: PASS, 6 tests.

Run: `swift test --filter CommitCaptureTests`
Expected: PASS, unchanged.

Run: `swift test`
Expected: PASS, all targets. `CommitCaptureTests.testWithinHourRewritesInPlaceAndResetsPending` still sees `"first plus more"` because a legacy `CaptureInput` uses `.replace`, whose structured merge is also a replace, and the round-trip invariant keeps the rendered bytes identical.

- [ ] **Step 5b: Commit the store half**

```bash
git add Sources/MaxMiStore/StoreAPI.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiStoreTests Tests/MaxMiMCPTests
git commit -m "Persist structured captures and return the capture delta from commitCapture"
```

---

### Task 10: `parseStructured`, the registry fall-through, and generic v2 on the fallback path

**Files:**
- Modify: `Sources/MaxMiCapture/SourceParser.swift` (`ParsedCapture` gains `structured` + `resolvedStructured`, `envelope(…)` gains `structured:`, `SourceParser` gains `parseStructured`)
- Modify: `Sources/MaxMiCapture/GenericAXParser.swift` (whole file)
- Modify: `Sources/MaxMiCapture/ParserRegistry.swift:76-140` (`ParseResult`, `parse`, `parseDetailed`)
- Modify: `Sources/MaxMi/AppWiring.swift:1478-1500` (the `parseDetailed` switch)
- Delete: `Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift`
- Test: `Tests/MaxMiCaptureTests/ParserFallthroughTests.swift`

**Interfaces:**
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)`, `ContentRenderer.render(_:style:)`, `LegacyContentAdapter.adapt(renderedContent:kind:)`, `CaptureEnvelope.init(…structured:)`.
- Produces:
  - `ParsedCapture.structured: CapturedContent?` — last initializer parameter, defaulted `nil`, so the ~25 existing `ParsedCapture(` construction sites compile unchanged.
  - `ParsedCapture.resolvedStructured: CapturedContent` — `structured ?? LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)`.
  - `ParsedCapture.envelope(cleanSourceKey:parserID:trigger:truncated:structured:)` where `structured: CapturedContent? = nil` means "use my own".
  - `SourceParser.parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent?` with a default implementation returning `nil` (nil = NOT_HANDLED).
  - `CaptureDispatch.ParseResult.parsedByFallback(ParsedCapture, failedParser: String)`.
  - `GenericAXParser.parseStructured` producing `.generic(GenericPage)` from `GenericPageExtractor`, `parserVersion: 2`.

**Composition rule (§4f, resolving §12 Q13 so nothing walks the tree twice).** `CaptureDispatch` calls `parse` **once**. A migrated parser's `parse` is defined as `parseStructured` plus a render, so the single call produces both the keys/policies and the typed value. Therefore:

1. Registered parser, `parse` returns non-nil → `.parsed(capture)`. `capture.structured` is non-nil for a migrated parser, nil for an unmigrated one.
2. `structured` nil → the `LegacyContentAdapter` shape, applied by `resolvedStructured` / `CaptureEnvelope.init`.
3. Registered parser returns nil or throws → **fall through to the generic extractor**, reported as `.parsedByFallback`.
4. No registered parser → the generic extractor, reported as `.parsed`.

`GenericAXParser` passes `focusedElement: nil`: only `AppWiring` knows the pid that `AXReader.focusedElementSnapshot(pid:)` needs, and it is Phase B's `TypingObserver` that wires it. In Phase A the focused element comes from the in-tree `focused == true` node.

- [ ] **Step 1: Write the failing test**

Delete the obsolete test, which asserts the behaviour §4f rule 3 reverses:

```bash
git rm Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift
```

Create `Tests/MaxMiCaptureTests/ParserFallthroughTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class ParserFallthroughTests: XCTestCase {
    func text(_ value: String, y: CGFloat = 0, x: CGFloat = 0) -> AXNode {
        AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: y, width: 100, height: 16), focused: false, children: [])
    }

    func window(_ children: [AXNode], title: String?) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: children)
    }

    /// A Slack window with sidebar text but no AXRow messages: SlackParser returns nil.
    func testRegisteredParserReturningNilNowFallsThroughToGenericContent() {
        let win = window([text("sidebar noise")], title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let result = CaptureDispatch.parseDetailed(window: win, app: app, registry: ParserRegistry())
        guard case .parsedByFallback(let capture, let failedParser) = result else {
            return XCTFail("expected a generic fallback, got \(result)")
        }
        XCTAssertEqual(failedParser, "SlackParser")
        XCTAssertEqual(capture.content, "sidebar noise")
        XCTAssertEqual(capture.resolvedStructured.kind, .generic)
        XCTAssertNotNil(CaptureDispatch.parse(window: win, app: app, registry: ParserRegistry()),
                        "the convenience form returns the fallback capture too")
    }

    func testFallbackHealthMarkerIsComposedFromTheFailedParserName() {
        let win = window([text("sidebar noise")], title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        guard case .parsedByFallback(_, let failedParser) = CaptureDispatch.parseDetailed(
            window: win, app: app, registry: ParserRegistry()
        ) else { return XCTFail() }
        XCTAssertEqual("GenericPageExtractor.v2/fallback/\(failedParser)",
                       "GenericPageExtractor.v2/fallback/SlackParser")
    }

    func testNoContentIsStillReportedWhenEvenTheGenericPathFindsNothing() {
        let win = window([AXNode(role: "AXButton", value: nil, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 focused: false, children: [])],
                         title: "general - Acme - Slack")
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        XCTAssertEqual(CaptureDispatch.parseDetailed(window: win, app: app,
                                                     registry: ParserRegistry()), .noContent)
    }

    func testUnregisteredAppStillUsesTheGenericPathAsParsed() {
        let win = window([text("note body")], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        guard case .parsed(let capture) = CaptureDispatch.parseDetailed(
            window: win, app: app, registry: ParserRegistry()
        ) else { return XCTFail("expected .parsed") }
        XCTAssertEqual(capture.content, "note body")
        XCTAssertEqual(capture.sourceApp, "Unknown")
    }

    func testGenericParserProducesTypedGenericContentAtVersionTwo() throws {
        let win = window([
            AXNode(role: "AXHeading", value: "Title", title: nil, url: nil,
                   frame: CGRect(x: 0, y: 0, width: 100, height: 24), focused: false,
                   children: [], headingLevel: 1),
            text("body line", y: 40),
        ], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        let structured = try XCTUnwrap(try GenericAXParser().parseStructured(window: win, app: app))
        guard case .generic(let page) = structured else { return XCTFail("expected .generic") }
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.type), [.heading(level: 1), .paragraph])

        let capture = try XCTUnwrap(try GenericAXParser().parse(window: win, app: app))
        XCTAssertEqual(capture.structured, structured)
        XCTAssertEqual(capture.content, "# Title\nbody line")
        XCTAssertEqual(capture.content, ContentRenderer.render(structured, style: .full))
        XCTAssertEqual(capture.parserVersion, 2)
    }

    func testGenericParserReturnsNilForAWindowWithNoReadableContent() throws {
        let win = window([AXNode(role: "AXButton", value: nil, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 focused: false, children: [])], title: "Note")
        let app = AppInfo(bundleID: "com.example.unknown", name: "Unknown", windowTitle: "Note")
        XCTAssertNil(try GenericAXParser().parseStructured(window: win, app: app))
        XCTAssertNil(try GenericAXParser().parse(window: win, app: app))
    }

    func testDefaultParseStructuredImplementationReturnsNil() throws {
        struct Unmigrated: SourceParser {
            func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
                ParsedCapture(sourceApp: "X", sourceKey: "x:1", sourceTitle: nil, content: "a\nb")
            }
        }
        let win = window([], title: nil)
        let app = AppInfo(bundleID: "x", name: "X", windowTitle: nil)
        XCTAssertNil(try Unmigrated().parseStructured(window: win, app: app))
        let capture = try XCTUnwrap(try Unmigrated().parse(window: win, app: app))
        XCTAssertNil(capture.structured)
        XCTAssertEqual(capture.resolvedStructured,
                       LegacyContentAdapter.adapt(renderedContent: "a\nb", kind: .generic))
    }

    func testEnvelopeCarriesTheParsersStructuredValueAndAcceptsAnOverride() {
        let structured = CapturedContent.tasks([
            TaskItem(title: "Ship M8a", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let migrated = ParsedCapture(
            sourceApp: "Reminders", sourceKey: "reminder:task:1", sourceTitle: "Ship M8a",
            content: "- [ ] Ship M8a", contentKind: .task, parserVersion: 2,
            accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(), structured: structured
        )
        let envelope = migrated.envelope(cleanSourceKey: "reminder:task:1", parserID: "RemindersParser",
                                         trigger: .appActivated, truncated: false)
        XCTAssertEqual(envelope.structured, structured)
        XCTAssertEqual(envelope.content, "- [ ] Ship M8a")

        let override = CapturedContent.generic(GenericPage(
            regions: [Region(kind: .main, blocks: [Block(type: .paragraph, text: "override")])],
            focused: nil, url: nil))
        let overridden = migrated.envelope(cleanSourceKey: "reminder:task:1", parserID: "X",
                                           trigger: .appActivated, truncated: false,
                                           structured: override)
        XCTAssertEqual(overridden.structured, override)
        XCTAssertEqual(overridden.content, "override")
    }

    func testUnmigratedParsersEnvelopeGetsTheLegacyAdaptation() {
        let unmigrated = ParsedCapture(sourceApp: "Notes", sourceKey: "notes:x", sourceTitle: "x",
                                       content: "line one\nline two", contentKind: .document)
        let envelope = unmigrated.envelope(cleanSourceKey: "notes:x", parserID: "NotesParser",
                                           trigger: .appActivated, truncated: false)
        XCTAssertEqual(envelope.structured.kind, .generic)
        XCTAssertEqual(envelope.content, "line one\nline two")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParserFallthroughTests`
Expected: FAIL to compile — "type 'CaptureDispatch.ParseResult' has no member 'parsedByFallback'".

- [ ] **Step 3a: Extend `ParsedCapture` and `SourceParser`**

In `Sources/MaxMiCapture/SourceParser.swift`, add the property and parameter to `ParsedCapture`:

```swift
    public let offscreenPolicy: OffscreenCapturePolicy
    /// The typed shape, when this parser has been migrated. nil for an unmigrated parser, which
    /// is handed a `LegacyContentAdapter` shape by `resolvedStructured`.
    public let structured: CapturedContent?
```

```swift
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly(),
        structured: CapturedContent? = nil
    ) {
```

```swift
        self.offscreenPolicy = offscreenPolicy
        self.structured = structured
```

Add the resolver and extend `envelope`:

```swift
    /// The typed shape this capture will be stored as (spec 4f rule 2).
    public var resolvedStructured: CapturedContent {
        structured ?? LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)
    }

    public func envelope(
        cleanSourceKey: String,
        parserID: String,
        trigger: CaptureTrigger,
        truncated: Bool,
        structured: CapturedContent? = nil
    ) -> CaptureEnvelope {
        CaptureEnvelope(
            sourceApp: sourceApp,
            sourceKey: cleanSourceKey,
            sourceTitle: sourceTitle,
            content: content,
            contentKind: contentKind,
            parserID: parserID,
            parserVersion: parserVersion,
            accumulationPolicy: accumulationPolicy,
            offscreenPolicy: offscreenPolicy,
            trigger: trigger,
            truncated: truncated,
            structured: structured ?? self.structured
        )
    }
```

Extend the protocol at the bottom of the file:

```swift
/// Turns a window's AX tree into a capture, or nil if it can't handle it.
/// Throwing is treated identically to nil by the caller (log + fall through), never a crash.
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
    /// The structured shape, or nil = NOT_HANDLED. A migrated parser implements this as its
    /// single source of truth and reduces `parse` to a render wrapper, so one capture is one
    /// AX walk. An unmigrated parser implements only `parse`.
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent?
}

public extension SourceParser {
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? { nil }
}
```

- [ ] **Step 3b: Rewrite `GenericAXParser` on top of the v2 extractor**

Replace the body of `Sources/MaxMiCapture/GenericAXParser.swift`:

```swift
import Foundation
import MaxMiCore

/// Fallback for any capturable app without a dedicated parser, and the degradation target when a
/// dedicated parser cannot handle its window. Content is `GenericPageExtractor`'s typed page
/// rendered back to text, keyed by bundle id + window title (coarse but guarantees coverage).
public struct GenericAXParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = Self.profile(for: app).offscreen
        // focusedElement is nil here: only AppWiring knows the pid that
        // AXReader.focusedElementSnapshot needs, and Phase B's TypingObserver wires it.
        let result = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: nil, options: options
        )
        guard !result.page.regions.isEmpty else { return nil }   // no empty threads
        return .generic(result.page)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        let profile = Self.profile(for: app)
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: profile.kind,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: profile.offscreen,
            structured: structured
        )
    }

    /// Unchanged from v1: the kind comes from the application registry's descriptor, and the
    /// offscreen policy from the kind.
    static func profile(for app: AppInfo) -> (kind: CaptureContentKind, offscreen: OffscreenCapturePolicy) {
        let kind: CaptureContentKind = switch ApplicationRegistry.descriptor(for: app.bundleID)?.kind {
        case .document: .document
        case .chat: .conversation
        case .terminal: .terminal
        case .email: .email
        case .calendar: .calendar
        case .task: .task
        default: .generic
        }
        let offscreen: OffscreenCapturePolicy = switch kind {
        case .document, .conversation, .calendar, .task, .meeting, .voiceNote:
            .accessibilityScroll(maxSteps: 3)
        default:
            .visibleOnly(maxCharacters: 32_000)
        }
        return (kind, offscreen)
    }
}
```

- [ ] **Step 3c: Implement the four dispatch rules**

In `Sources/MaxMiCapture/ParserRegistry.swift`, replace `ParseResult`, `parse`, and `parseDetailed`:

```swift
    public enum ParseResult: Sendable, Equatable {
        case parsed(ParsedCapture)
        /// A registered parser returned nil or threw, and the generic extractor stood in.
        /// `failedParser` is the type name, for the capture-health marker.
        case parsedByFallback(ParsedCapture, failedParser: String)
        case noContent
        case failed
    }
```

```swift
    /// Decide what to store for a frontmost app's window. Returns nil = skip.
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture? {
        switch parseDetailed(window: window, app: app, registry: registry) {
        case .parsed(let parsed):                 return parsed
        case .parsedByFallback(let parsed, _):    return parsed
        case .noContent, .failed:                 return nil
        }
    }

    /// Diagnostic form of `parse`: distinguishes empty/not-handled from a generic fallback
    /// without ever carrying captured content into logs or the health ledger.
    ///
    /// A registered parser that returns nil or throws now FALLS THROUGH to
    /// `GenericPageExtractor` (spec 4f rule 3). This deliberately reverses the old
    /// no-silent-fallback rule: a broken or over-narrow parser must degrade to a worse
    /// capture, not to no capture. It stays non-silent because the caller records
    /// "GenericPageExtractor.v2/fallback/<ParserTypeName>" in `capture_health_events.parser`.
    public static func parseDetailed(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParseResult {
        if let parser = registry.parser(for: app.bundleID) {
            let parserName = String(describing: type(of: parser))
            do {
                if let result = try parser.parse(window: window, app: app) {
                    return .parsed(result)
                }
                SafeLogger.shared.log(
                    .info,
                    subsystem: .capture,
                    event: .parserNoContent,
                    fields: SafeLogFields(parserID: SafeLogToken(validating: parserName))
                )
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .capture,
                    event: .parserFailed,
                    error: error,
                    fields: SafeLogFields(parserID: SafeLogToken(validating: parserName))
                )
            }
            guard let fallback = genericCapture(window: window, app: app) else { return .noContent }
            return .parsedByFallback(fallback, failedParser: parserName)
        }
        guard let result = genericCapture(window: window, app: app) else { return .noContent }
        return .parsed(result)
    }

    /// `GenericPageExtractor` is pure and total, so the only nil here is "no readable content".
    private static func genericCapture(window: AXNode, app: AppInfo) -> ParsedCapture? {
        (try? GenericAXParser().parse(window: window, app: app)) ?? nil
    }
```

The `.failed` case is kept because `AppWiring` still switches on it and `CaptureHealthStore` still records it; nothing in `parseDetailed` returns it any more.

- [ ] **Step 3d: Record the fallback in the health ledger**

In `Sources/MaxMi/AppWiring.swift`, extend the `parseDetailed` switch (immediately after `case .parsed(let capture): parsed = capture`):

```swift
                case .parsedByFallback(let capture, let failedParser):
                    parsed = capture
                    // Non-silent degradation: the Capture Health window shows which parsers
                    // are failing (spec 8). capture_health_events has no free-text note column
                    // and `reason` is only populated for skipped/failed, so the fallback is
                    // encoded in `parser`.
                    effectiveParserName = "GenericPageExtractor.v2/fallback/\(failedParser)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ParserFallthroughTests`
Expected: PASS, 9 tests.

Run: `swift test --filter GenericAXParserTests`
Expected: PASS. These assertions were written against `DocumentExtraction`'s output and the v2 rendering is identical for their fixtures (static text and text areas render to the same lines, in the same visual order). If any assertion now differs, update the expected string to the real v2 rendering — print the value and read `Tests/MaxMiCaptureTests/Fixtures/cursor-editor.json` — and never weaken the assertion into a `contains` check.

Run: `swift test`
Expected: PASS, all targets.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/SourceParser.swift Sources/MaxMiCapture/GenericAXParser.swift \
        Sources/MaxMiCapture/ParserRegistry.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiCaptureTests/ParserFallthroughTests.swift \
        Tests/MaxMiCaptureTests/NoSilentFallbackTests.swift
git commit -m "Fall through to the generic extractor when a parser cannot handle its window"
```

---

### Task 11: Slack, Teams and WhatsApp produce `.conversation`

**Files:**
- Modify: `Sources/MaxMiCapture/SlackParser.swift` (whole file)
- Modify: `Sources/MaxMiCapture/NativeConversationParser.swift` (`WhatsAppParser`, `TeamsParser`, and `NativeConversationExtraction.parse` → `extract`)
- Modify: `Tests/MaxMiCaptureTests/SlackParserTests.swift:30, 31, 33, 53, 54, 104`
- Modify: `Tests/MaxMiCaptureTests/NativeConversationParserTests.swift:18, 69`
- Test: `Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift`

**Interfaces:**
- Consumes: `Message`, `Message.makeID(sender:timeString:text:)`, `Conversation`, `CapturedContent.conversation`, `ContentRenderer.render(_:style:)`, `CaptureAccumulator.bound(_:to:)`, `ParsedCapture(… structured:)`.
- Produces: `SlackParser.parseStructured`, `SlackParser.channel(fromTitle:)`, `SlackParser.isGroup(fromTitle:)`, `SlackParser.messages(in:windowX:)`; `WhatsAppParser.parseStructured`, `TeamsParser.parseStructured`; `NativeConversationExtraction.extract(window:app:sourceApp:keyPrefix:requiresConversationIdentity:allowsFallback:) -> Extracted?` where `struct Extracted { let content: CapturedContent; let sourceKey: String; let sourceTitle: String? }`.

**The stored text changes shape for these three apps.** A message line was `"Alice: shipped the build"`; it is now `"(From: Alice): shipped the build"` — §4b's rendering, matching Minimi's observed wire shape. Line-based `message_fingerprints` dedup and search are unaffected (still one line per message). Update the existing assertions to the new strings; do not weaken them.

**`isGroup` has exactly one signal today.** A Slack `"<view> - <workspace> - Slack"` title is a channel view and therefore multi-party; anything else is treated as one-to-one. WhatsApp and Teams headers carry no group marker at all in the current AX walk, so they are `false` until Phase D's anchored parsers read the participant list. Do not invent a heuristic here.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredConversationParserTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func messages(_ content: CapturedContent?) throws -> [Message] {
        guard case .conversation(let conversation) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation")
            return []
        }
        return conversation.messages
    }

    func testSlackFixtureProducesSenderAttributedMessages() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let structured = try SlackParser().parseStructured(window: try fixture("slack-window"), app: app)
        let messages = try messages(structured)
        XCTAssertEqual(messages.map(\.sender), ["Alice", "Bob"])
        XCTAssertEqual(messages.map(\.text), ["shipped the build", "deploy looks green"])
        XCTAssertFalse(messages.contains { $0.isUser || $0.isDraft })
        XCTAssertEqual(messages.map(\.id), messages.map {
            Message.makeID(sender: $0.sender, timeString: nil, text: $0.text)
        })
    }

    func testSlackChannelAndGroupComeFromTheWindowTitle() {
        let parser = SlackParser()
        XCTAssertEqual(parser.channel(fromTitle: "general - Acme - Slack"), "general")
        XCTAssertTrue(parser.isGroup(fromTitle: "general - Acme - Slack"))
        XCTAssertEqual(parser.channel(fromTitle: "Ana Ruiz"), "Ana Ruiz")
        XCTAssertFalse(parser.isGroup(fromTitle: "Ana Ruiz"))
        XCTAssertEqual(parser.channel(fromTitle: nil), "unknown")
        XCTAssertFalse(parser.isGroup(fromTitle: nil))
    }

    func testSlackCaptureContentIsTheRenderedConversation() throws {
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let capture = try XCTUnwrap(try SlackParser().parse(window: try fixture("slack-window"), app: app))
        XCTAssertEqual(capture.content,
                       "(From: Alice): shipped the build\n(From: Bob): deploy looks green")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.sourceKey, "slack:acme/general")
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
    }

    func testSlackStructuredOutputIsCappedByDroppingOldestMessages() throws {
        var rows: [AXNode] = []
        for index in 0..<400 {
            let y = CGFloat(index) * 20
            rows.append(AXNode(
                role: "AXRow", value: nil, title: nil, url: nil,
                frame: CGRect(x: 400, y: y, width: 800, height: 20), focused: false,
                children: [
                    AXNode(role: "AXStaticText", value: "Person\(index)", title: nil, url: nil,
                           frame: CGRect(x: 400, y: y, width: 100, height: 16), focused: false,
                           children: []),
                    AXNode(role: "AXStaticText", value: String(repeating: "x", count: 60),
                           title: nil, url: nil,
                           frame: CGRect(x: 520, y: y, width: 400, height: 16), focused: false,
                           children: []),
                ]))
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: rows)
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let capture = try XCTUnwrap(try SlackParser().parse(window: window, app: app))
        XCTAssertLessThanOrEqual(capture.content.count, SlackParser.contentCap)
        XCTAssertTrue(capture.content.contains("Person399"), "newest survives")
        XCTAssertFalse(capture.content.contains("Person0"), "oldest is dropped")
        let messages = try messages(capture.structured)
        XCTAssertEqual(messages.last?.sender, "Person399")
    }

    func testWhatsAppFixtureProducesTypedMessagesAndKeepsItsKey() throws {
        let app = AppInfo(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp",
                          windowTitle: "WhatsApp")
        let window = try fixture("whatsapp-conversation")
        let structured = try WhatsAppParser().parseStructured(window: window, app: app)
        guard case .conversation(let conversation) = try XCTUnwrap(structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Project Group")
        XCTAssertFalse(conversation.isGroup, "no group marker is exposed by the AX walk yet")
        XCTAssertEqual(conversation.messages.map(\.sender), ["Alex", "You"])
        XCTAssertEqual(conversation.messages.map(\.text), ["Morning update", "I am reviewing it"])

        let capture = try XCTUnwrap(try WhatsAppParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "whatsapp:project-group")
        XCTAssertEqual(capture.sourceTitle, "Project Group")
        XCTAssertEqual(capture.content,
                       "(From: Alex): Morning update\n(From: You): I am reviewing it")
        XCTAssertEqual(capture.contentKind, .conversation)
    }

    func testSingleTextRowBecomesAnUnknownSenderMessage() throws {
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 400, y: 10, width: 800, height: 20), focused: false,
                         children: [
            AXNode(role: "AXStaticText", value: "system joined the channel", title: nil, url: nil,
                   frame: CGRect(x: 400, y: 10, width: 400, height: 16), focused: false, children: []),
        ])
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [row])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        let messages = try messages(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertEqual(messages.map(\.sender), ["unknown"])
        XCTAssertEqual(messages.map(\.text), ["system joined the channel"])
    }

    func testEmptyMessageAreaStillReturnsNilSoDispatchCanFallThrough() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "general - Acme - Slack", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
                            children: [])
        let app = AppInfo(bundleID: ParserRegistry.slackBundleID, name: "Slack",
                          windowTitle: "general - Acme - Slack")
        XCTAssertNil(try SlackParser().parseStructured(window: window, app: app))
        XCTAssertNil(try SlackParser().parse(window: window, app: app))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StructuredConversationParserTests`
Expected: FAIL to compile — "value of type 'SlackParser' has no member 'channel'".

- [ ] **Step 3a: Migrate `SlackParser`**

Replace `Sources/MaxMiCapture/SlackParser.swift`'s `parse` and `messageLines` with:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        let messages = messages(in: window, windowX: window.frame?.origin.x ?? 0)
        guard !messages.isEmpty else { return nil }
        let conversation = Conversation(
            channel: channel(fromTitle: app.windowTitle),
            isGroup: isGroup(fromTitle: app.windowTitle),
            messages: messages
        )
        // Newest-anchored cap on the STRUCTURED value: the rendered text is derived from it, so
        // capping the string afterwards would be undone by CaptureEnvelope.
        return CaptureAccumulator.bound(.conversation(conversation), to: Self.contentCap)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: "Slack",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: structured
        )
    }

    /// "<view> - <workspace> - Slack" -> "<view>"; else the whole title.
    func channel(fromTitle title: String?) -> String {
        guard let title, !title.isEmpty else { return "unknown" }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, parts.last == "Slack" { return parts[0] }
        return title
    }

    /// A "<view> - <workspace> - Slack" title is a channel view and therefore multi-party. That
    /// is the only group signal this AX walk exposes; Phase D's anchored parser reads the
    /// member list instead.
    func isGroup(fromTitle title: String?) -> Bool {
        guard let title else { return false }
        let parts = title.components(separatedBy: " - ")
        return parts.count >= 3 && parts.last == "Slack"
    }

    /// Collect AXRow messages in visual order. Within a row, the first static text is the
    /// sender and the rest is the body.
    func messages(in root: AXNode, windowX: CGFloat) -> [Message] {
        var rows: [(y: CGFloat, texts: [String])] = []
        collectRows(root, into: &rows, windowX: windowX)
        return rows.sorted { $0.y < $1.y }.compactMap { row in
            let texts = row.texts.filter { !$0.isEmpty }
            guard !texts.isEmpty else { return nil }
            let sender = texts.count >= 2 ? texts[0] : "unknown"
            let text = texts.count >= 2 ? texts.dropFirst().joined(separator: " ") : texts[0]
            return Message(
                id: Message.makeID(sender: sender, timeString: nil, text: text),
                sender: sender, text: text, timestamp: nil, timeString: nil,
                isUser: false, isDraft: false
            )
        }
    }
```

`contentCap`, `sidebarMaxX`, `key(fromTitle:)`, `collectRows`, and `collectStaticText` are unchanged. Make `contentCap` non-private if it is not already (`static let contentCap = 8000` is already internal) so the test can reference it.

- [ ] **Step 3b: Migrate `NativeConversationExtraction`**

In `Sources/MaxMiCapture/NativeConversationParser.swift`, add the shared result type and split `parse` into `extract` plus two thin wrappers. Replace the two parser structs and the head of `NativeConversationExtraction`:

```swift
public struct WhatsAppParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        NativeConversationExtraction.extract(
            window: window, app: app, sourceApp: "WhatsApp", keyPrefix: "whatsapp",
            requiresConversationIdentity: true, allowsFallback: false
        )?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        NativeConversationExtraction.capture(
            window: window, app: app, sourceApp: "WhatsApp", keyPrefix: "whatsapp",
            requiresConversationIdentity: true, allowsFallback: false
        )
    }
}

public struct TeamsParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        NativeConversationExtraction.extract(
            window: window, app: app, sourceApp: "Microsoft Teams", keyPrefix: "teams"
        )?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        NativeConversationExtraction.capture(
            window: window, app: app, sourceApp: "Microsoft Teams", keyPrefix: "teams"
        )
    }
}
```

```swift
enum NativeConversationExtraction {
    struct Extracted {
        let content: CapturedContent
        let sourceKey: String
        let sourceTitle: String?
    }
```

Replace the body of `static func parse(…)` with `extract` returning `Extracted?` and a `capture` wrapper. The AX walk (`mainPaneBoundary`, `conversationTitle`, `collectMessageContainers`, chrome filtering) is unchanged — only the last few lines that built a string change:

```swift
    static func extract(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        keyPrefix: String,
        requiresConversationIdentity: Bool = false,
        allowsFallback: Bool = true
    ) -> Extracted? {
        let boundary = mainPaneBoundary(window)
        let conversation = conversationTitle(
            in: window,
            app: app,
            mainBoundary: boundary,
            requiresHeaderSemantics: requiresConversationIdentity
        )
        var messages: [(y: CGFloat, line: String)] = []
        collectMessageContainers(
            window,
            mainBoundary: boundary,
            requiresMessageSemantics: requiresConversationIdentity,
            into: &messages
        )

        var lines = messages.sorted { $0.y < $1.y }.map(\.line)
        if lines.isEmpty, allowsFallback {
            lines = fallbackMainPaneLines(in: window, mainBoundary: boundary)
        }
        lines = uniqueAdjacent(lines).filter { !isChrome($0) }
        guard !lines.isEmpty,
              !requiresConversationIdentity || conversation != nil else { return nil }

        let identity = conversation ?? meaningfulWindowTitle(app.windowTitle, excluding: sourceApp) ?? "unknown"
        let typed = Conversation(
            channel: identity,
            // WhatsApp and Teams headers expose no group marker; Phase D's anchored parsers
            // read the participant list.
            isGroup: false,
            messages: lines.compactMap(message(fromLine:))
        )
        return Extracted(
            content: CaptureAccumulator.bound(.conversation(typed), to: contentCap),
            sourceKey: "\(keyPrefix):\(slug(identity))",
            sourceTitle: conversation ?? app.windowTitle
        )
    }

    static func capture(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        keyPrefix: String,
        requiresConversationIdentity: Bool = false,
        allowsFallback: Bool = true
    ) -> ParsedCapture? {
        guard let extracted = extract(
            window: window, app: app, sourceApp: sourceApp, keyPrefix: keyPrefix,
            requiresConversationIdentity: requiresConversationIdentity,
            allowsFallback: allowsFallback
        ) else { return nil }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: extracted.sourceKey,
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000),
            structured: extracted.content
        )
    }

    /// `atomicMessageLine` produced "sender: body" or a bare joined line. Split the same way.
    static func message(fromLine line: String) -> Message? {
        guard !line.isEmpty else { return nil }
        var sender = "unknown"
        var text = line
        if let separator = line.range(of: ": "), line.distance(from: line.startIndex, to: separator.lowerBound) <= 80 {
            sender = String(line[..<separator.lowerBound])
            text = String(line[separator.upperBound...])
        }
        return Message(
            id: Message.makeID(sender: sender, timeString: nil, text: text),
            sender: sender, text: text, timestamp: nil, timeString: nil,
            isUser: false, isDraft: false
        )
    }
```

Keep `atomicMessageLine` — `collectMessageContainers` still calls it to build one atomic line per container, which is what `message(fromLine:)` then splits.

- [ ] **Step 3c: Update the six existing assertions to the v2 rendering**

`Tests/MaxMiCaptureTests/SlackParserTests.swift`:

```swift
        XCTAssertTrue(cap.content.contains("(From: Alice): shipped the build"))
        XCTAssertTrue(cap.content.contains("(From: Bob): deploy looks green"))
```

(lines 30-31 and again at 53-54; line 33's `range(of: "Alice")` ordering check and line 104's `contains("Zoe: hi team")` become `contains("(From: Zoe): hi team")`.)

`Tests/MaxMiCaptureTests/NativeConversationParserTests.swift:18`:

```swift
        XCTAssertEqual(capture.content, "(From: Alex): Morning update\n(From: You): I am reviewing it")
```

Line 69's multi-line expected string gets the same `(From: <sender>): ` prefix on every line. Print `capture.content` once and paste the real value; do not relax the equality into a `contains`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StructuredConversationParserTests`
Expected: PASS, 7 tests.

Run: `swift test --filter SlackParserTests`
Expected: PASS.

Run: `swift test --filter NativeConversationParserTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/SlackParser.swift Sources/MaxMiCapture/NativeConversationParser.swift \
        Tests/MaxMiCaptureTests/SlackParserTests.swift \
        Tests/MaxMiCaptureTests/NativeConversationParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredConversationParserTests.swift
git commit -m "Emit typed conversations from Slack, Teams and WhatsApp"
```

---

### Task 12: Mail produces `.conversation` from `MailRecord`

**Files:**
- Modify: `Sources/MaxMiCapture/MailParser.swift:22-90` (`parse`, `makeCapture`, `makeSelectedMessageCapture`)
- Modify: `Tests/MaxMiCaptureTests/MailParserTests.swift:17-19, 33-34, 40, 53, 67`
- Test: `Tests/MaxMiCaptureTests/StructuredMailParserTests.swift`

**Interfaces:**
- Consumes: `MailParser.MailRecord` (already parsed from the AppleScript output), `Message`, `Conversation`, `CaptureAccumulator.bound(_:to:)`.
- Produces: `MailParser.selectedMessageContent(fromScriptOutput: String, windowTitle: String?) -> MailParser.Extracted?` and `MailParser.inboxContent(fromScriptOutput: String) -> CapturedContent?`, where `struct Extracted { let content: CapturedContent; let sourceKey: String; let sourceTitle: String? }`. `MailParser.parseStructured` returns the same value `parse` renders.

**Mail keeps its AppleScript source (§12 Q6).** Mail's AX tree is ~80 ms per node and unusable, so nothing here touches `window`. `contentKind` stays `.email` — it is not derivable from the `.conversation` shape (§12 Q3).

**Outlook and Spark are NOT part of this task.** §4f groups them with Mail, but only Mail produces `MailRecord`s: `OutlookParser`/`SparkParser` go through `StructuredEntityExtraction.email`, which is `DocumentExtraction.bodyText` and exposes no sender or date at all. Inventing `Message`s with `sender: "unknown"` there would be worse than the generic page, so they move to generic v2 in Task 16, keeping `.email`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/StructuredMailParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredMailParserTests: XCTestCase {
    /// Two structured records in the MAXMI_MAIL_V2 wire format.
    func scriptOutput() -> String {
        let fs = MailParser.fieldSeparator
        let rs = MailParser.recordSeparator
        let first = ["<id-1>", "Taylor <taylor@example.com>", "Project update",
                     "Monday, 9 September 2026 at 09:20", "First body"].joined(separator: fs)
        let second = ["<id-2>", "Sam <sam@example.com>", "Project update",
                      "Monday, 9 September 2026 at 10:05", "Second body"].joined(separator: fs)
        return MailParser.structuredHeader + "\n" + [first, second].joined(separator: rs)
    }

    func testSelectedMessagesBecomeOneMessagePerRecord() throws {
        let extracted = try XCTUnwrap(MailParser.selectedMessageContent(
            fromScriptOutput: scriptOutput(), windowTitle: "Inbox"))
        guard case .conversation(let conversation) = extracted.content else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Project update", "channel is the subject")
        XCTAssertFalse(conversation.isGroup)
        XCTAssertEqual(conversation.messages.map(\.sender),
                       ["Taylor <taylor@example.com>", "Sam <sam@example.com>"])
        XCTAssertEqual(conversation.messages.map(\.text), ["First body", "Second body"])
        XCTAssertEqual(conversation.messages.map(\.timeString),
                       ["Monday, 9 September 2026 at 09:20", "Monday, 9 September 2026 at 10:05"])
        XCTAssertTrue(extracted.sourceKey.hasPrefix("mail:thread:"))
        XCTAssertEqual(extracted.sourceTitle, "Project update")
    }

    func testSelectedMessageCaptureRendersTheConversationAndKeepsEmailKind() throws {
        let capture = try XCTUnwrap(MailParser.makeCapture(
            fromScriptOutput: scriptOutput(), windowTitle: "Inbox"))
        XCTAssertEqual(capture.contentKind, .email, "contentKind is not derived from the shape")
        XCTAssertEqual(capture.sourceApp, "Mail")
        XCTAssertEqual(capture.content, """
        (From: Taylor <taylor@example.com>)(sent Monday, 9 September 2026 at 09:20): First body
        (From: Sam <sam@example.com>)(sent Monday, 9 September 2026 at 10:05): Second body
        """)
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testMultiLineBodyKeepsItsLinesIndented() throws {
        let fs = MailParser.fieldSeparator
        let record = ["<id-3>", "Ana <ana@example.com>", "Two lines", "Tue 10:00",
                      "line one\nline two"].joined(separator: fs)
        let capture = try XCTUnwrap(MailParser.makeCapture(
            fromScriptOutput: MailParser.structuredHeader + "\n" + record, windowTitle: nil))
        XCTAssertEqual(capture.content,
                       "(From: Ana <ana@example.com>)(sent Tue 10:00): line one\n  line two")
    }

    func testInboxListingBecomesOneMessagePerLine() throws {
        let raw = "iCloud » A <a@x.com> | subj A\nExchange » B <b@y.com> | subj B"
        let capture = try XCTUnwrap(MailParser.makeCapture(fromScriptOutput: raw, windowTitle: nil))
        XCTAssertEqual(capture.sourceKey, "mail:inbox")
        XCTAssertEqual(capture.contentKind, .email)
        guard case .conversation(let conversation) = try XCTUnwrap(capture.structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.channel, "Inbox")
        XCTAssertEqual(conversation.messages.map(\.sender), ["iCloud » A <a@x.com>", "Exchange » B <b@y.com>"])
        XCTAssertEqual(conversation.messages.map(\.text), ["subj A", "subj B"])
        XCTAssertEqual(capture.content, """
        (From: iCloud » A <a@x.com>): subj A
        (From: Exchange » B <b@y.com>): subj B
        """)
    }

    func testEmptyOutputStillReturnsNil() {
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: "", windowTitle: nil))
        XCTAssertNil(MailParser.makeCapture(fromScriptOutput: MailParser.structuredHeader, windowTitle: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StructuredMailParserTests`
Expected: FAIL to compile — "type 'MailParser' has no member 'selectedMessageContent'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/MailParser.swift`, add the result type and replace `parse`, `makeCapture`, and `makeSelectedMessageCapture`:

```swift
    struct Extracted {
        let content: CapturedContent
        let sourceKey: String
        let sourceTitle: String?
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let raw = Self.runAppleScript(Self.script) else { return nil }
        return Self.makeCapture(fromScriptOutput: raw, windowTitle: app.windowTitle)
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let raw = Self.runAppleScript(Self.script) else { return nil }
        return Self.extract(fromScriptOutput: raw, windowTitle: app.windowTitle)?.content
    }

    /// Pure transform from raw osascript output → ParsedCapture (nil if no usable records).
    /// Separated from the Process call so it's unit-testable without a live Mail app.
    static func makeCapture(fromScriptOutput raw: String, windowTitle: String?) -> ParsedCapture? {
        guard let extracted = extract(fromScriptOutput: raw, windowTitle: windowTitle) else { return nil }
        let isThread = extracted.sourceKey != "mail:inbox"
        return ParsedCapture(
            sourceApp: "Mail",
            sourceKey: extracted.sourceKey,
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            // Not derivable from the .conversation shape — Mail stays .email (spec 12 Q3).
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: isThread
                ? .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000)
                : .accessibilityScroll(maxSteps: 3),
            structured: extracted.content
        )
    }

    static func extract(fromScriptOutput raw: String, windowTitle: String?) -> Extracted? {
        if raw.hasPrefix(structuredHeader) {
            return selectedMessageContent(fromScriptOutput: raw, windowTitle: windowTitle)
        }
        guard let content = inboxContent(fromScriptOutput: raw) else { return nil }
        return Extracted(content: content, sourceKey: "mail:inbox", sourceTitle: windowTitle)
    }

    /// The per-account inbox listing: "account » sender | subject" per line.
    static func inboxContent(fromScriptOutput raw: String) -> CapturedContent? {
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let messages = lines.map { line -> Message in
            var sender = "unknown"
            var text = line
            if let separator = line.range(of: " | ") {
                sender = String(line[..<separator.lowerBound])
                text = String(line[separator.upperBound...])
            }
            return Message(
                id: Message.makeID(sender: sender, timeString: nil, text: text),
                sender: sender, text: text, timestamp: nil, timeString: nil,
                isUser: false, isDraft: false
            )
        }
        return CaptureAccumulator.bound(
            .conversation(Conversation(channel: "Inbox", isGroup: false, messages: messages)),
            to: contentCap
        )
    }

    /// One `Message` per `MailRecord`; `channel` is the subject (spec 4f).
    static func selectedMessageContent(fromScriptOutput raw: String, windowTitle: String?) -> Extracted? {
        let records = mailRecords(fromScriptOutput: raw)
        guard !records.isEmpty else { return nil }
        let messages = records.map { record in
            Message(
                id: record.messageID.isEmpty
                    ? Message.makeID(sender: record.sender, timeString: record.date, text: record.body)
                    : record.messageID,
                sender: record.sender.isEmpty ? "unknown" : record.sender,
                text: record.body,
                timestamp: nil,
                timeString: record.date.isEmpty ? nil : record.date,
                isUser: false,
                isDraft: false
            )
        }
        let subject = records.first(where: { !$0.subject.isEmpty })?.subject
        let identities = records.map {
            $0.messageID.isEmpty ? "\($0.sender)|\($0.subject)" : $0.messageID
        }.joined(separator: "|")
        let conversation = Conversation(
            channel: subject ?? windowTitle ?? "message",
            isGroup: false,
            messages: messages
        )
        return Extracted(
            content: CaptureAccumulator.bound(.conversation(conversation), to: contentCap),
            sourceKey: "mail:thread:\(String(ContentHash.sha256Hex(identities).prefix(24)))",
            sourceTitle: subject ?? windowTitle
        )
    }

    /// The record split, unchanged — extracted from the old makeSelectedMessageCapture so both
    /// the typed path and the tests can use it.
    static func mailRecords(fromScriptOutput raw: String) -> [MailRecord] {
        let payload = raw.dropFirst(structuredHeader.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.components(separatedBy: recordSeparator).compactMap { record -> MailRecord? in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 5 else { return nil }
            let body = fields.dropFirst(4).joined(separator: fieldSeparator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let date = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sender.isEmpty || !subject.isEmpty || !body.isEmpty else { return nil }
            return MailRecord(messageID: messageID, sender: sender, subject: subject, date: date, body: body)
        }
    }
```

Delete the now-unused `makeSelectedMessageCapture`. `MailRecord`, `script`, `runAppleScript`, `structuredHeader`, `recordSeparator`, `fieldSeparator`, and `contentCap` are unchanged.

Update the five existing assertions in `Tests/MaxMiCaptureTests/MailParserTests.swift` to the v2 rendering:

- `:17-19` — `contains("Blinkist")` and `contains("Razorpay")` still pass; `contains("layerpath.com » vercel[bot]")` becomes `contains("(From: layerpath.com » vercel[bot]")`.
- `:33-34` — the cap assertions still hold; `contains("number 1000")` / `!contains("number 1 ")` still hold.
- `:40` — `"(From: iCloud » A <a@x.com>): subj A\n(From: Exchange » B <b@y.com>): subj B"`.
- `:53` and `:67` — the `From: `/`Subject: `/`Date: ` block form is gone. Replace with the rendered conversation: print the value once and paste it. `:67`'s `contains("First body\n\n---\n\nFrom: Sam")` becomes `contains("): First body\n(From: Sam")`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StructuredMailParserTests`
Expected: PASS, 5 tests.

Run: `swift test --filter MailParserTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/MailParser.swift Tests/MaxMiCaptureTests/MailParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredMailParserTests.swift
git commit -m "Map Mail records onto typed conversation messages"
```

---

### Task 13: Calendar apps produce `.calendar`, task apps produce `.tasks`

**Files:**
- Modify: `Sources/MaxMiCapture/StructuredNativeParsers.swift` — `CalendarParser`, `FantasticalParser`, `RemindersParser`, `MicrosoftToDoParser`, `TodoistParser`, `OmniFocusParser`, `TogglParser`, and `StructuredEntityExtraction.calendar` / `.task`
- Modify: `Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift:20-23, 45-47, 65`
- Test: `Tests/MaxMiCaptureTests/StructuredEntityTypedTests.swift`

**Interfaces:**
- Consumes: `StructuredEntityExtraction.preferredDetailRoot`, `orderedFields`, `firstValue`, `remainingValues`, `looksLikeDateOrTime`, `shortHash` (all unchanged); `CalendarEvent`, `TaskItem`, `TaskStatus`.
- Produces: `StructuredEntityExtraction.calendarContent(window:app:sourceApp:) -> (content: CapturedContent, sourceKey: String, sourceTitle: String)?` and `taskContent(window:app:sourceApp:) -> (content: CapturedContent, sourceKey: String, sourceTitle: String)?`, plus `parseStructured` on all seven parsers. `sourceKey` and `contentKind` are unchanged from v1, so no thread identity moves.

**Nothing is dropped.** The v1 rendering's `Details:` block of leftover field text maps onto `CalendarEvent.notes`, rendered as a `Details: …` line (§4b); `TaskItem.notes` carries the task equivalent. Title, date, location, organizer, and the conference flag all survive too.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/StructuredEntityTypedTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class StructuredEntityTypedTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testCalendarEventFixtureBecomesATypedEvent() throws {
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: "Calendar")
        let structured = try CalendarParser().parseStructured(window: try fixture("calendar-event"), app: app)
        guard case .calendar(let events) = try XCTUnwrap(structured) else {
            return XCTFail("expected .calendar")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Design review")
        XCTAssertEqual(events[0].dateString, "Tuesday, 3:00 PM")
        XCTAssertEqual(events[0].location, "Studio room")
        XCTAssertEqual(events[0].organizer, "Work", "the calendar/account name lands in organizer")
        XCTAssertEqual(events[0].notes, "Review the interaction flow.",
                       "the leftover detail text becomes CalendarEvent.notes")
        XCTAssertFalse(events[0].hasConference)
        XCTAssertNil(events[0].start)
        XCTAssertNil(events[0].end)
    }

    func testCalendarCaptureKeepsItsKeyKindAndPolicyAndRendersTheEvent() throws {
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: "Calendar")
        let capture = try XCTUnwrap(try CalendarParser().parse(window: try fixture("calendar-event"), app: app))
        XCTAssertEqual(capture.sourceApp, "Calendar")
        XCTAssertEqual(capture.sourceTitle, "Design review")
        XCTAssertTrue(capture.sourceKey.hasPrefix("calendar:event:"))
        XCTAssertEqual(capture.contentKind, .calendar)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertEqual(capture.parserVersion, 2)
        XCTAssertEqual(capture.content, """
        Tuesday, 3:00 PM — Design review @Studio room / Work
        Details: Review the interaction flow.
        """)
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testFantasticalUsesTheSameShapeWithItsOwnKeyPrefix() throws {
        let app = AppInfo(bundleID: "com.flexibits.fantastical2.mac", name: "Fantastical",
                          windowTitle: "Fantastical")
        let capture = try XCTUnwrap(try FantasticalParser().parse(window: try fixture("calendar-event"), app: app))
        XCTAssertEqual(capture.sourceApp, "Fantastical")
        XCTAssertTrue(capture.sourceKey.hasPrefix("fantastical:event:"))
        XCTAssertEqual(capture.contentKind, .calendar)
    }

    func testReminderFixtureBecomesATypedOpenTask() throws {
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let structured = try RemindersParser().parseStructured(window: try fixture("reminder-task"), app: app)
        guard case .tasks(let items) = try XCTUnwrap(structured) else {
            return XCTFail("expected .tasks")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Submit project notes")
        XCTAssertEqual(items[0].status, .open)
        XCTAssertEqual(items[0].project, "Work")
        XCTAssertEqual(items[0].dueString, "Tomorrow, 5:00 PM")
        XCTAssertEqual(items[0].tags, [])
        XCTAssertNil(items[0].due)
    }

    func testReminderCaptureRendersTheTaskLine() throws {
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let capture = try XCTUnwrap(try RemindersParser().parse(window: try fixture("reminder-task"), app: app))
        XCTAssertEqual(capture.contentKind, .task)
        XCTAssertEqual(capture.accumulationPolicy, .replace)
        XCTAssertEqual(capture.sourceTitle, "Submit project notes")
        XCTAssertEqual(capture.content, "- [ ] Submit project notes (due Tomorrow, 5:00 PM) [Work]")
    }

    func testCheckedCheckboxBecomesCompleted() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Reminders", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Send invoice", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
                AXNode(role: "AXCheckBox", value: "1", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 40, width: 24, height: 24), focused: false,
                       children: [], identifier: "completed"),
            ]),
        ])
        let app = AppInfo(bundleID: "com.apple.reminders", name: "Reminders", windowTitle: "Reminders")
        let capture = try XCTUnwrap(try RemindersParser().parse(window: window, app: app))
        XCTAssertTrue(capture.content.hasPrefix("- [x] Send invoice"))
    }

    func testTaskNotesCarryTheLeftoverDetailText() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Todoist", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Draft the brief", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
                AXNode(role: "AXStaticText", value: "Include the pricing table", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 60, width: 400, height: 16), focused: false, children: []),
            ]),
        ])
        let app = AppInfo(bundleID: "com.todoist.mac.Todoist", name: "Todoist", windowTitle: "Todoist")
        let capture = try XCTUnwrap(try TodoistParser().parse(window: window, app: app))
        XCTAssertTrue(capture.content.contains("\n  Include the pricing table"),
                      "leftover detail text becomes TaskItem.notes")
    }

    func testAllFourRemainingTaskAppsUseTheTasksShape() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "Tasks", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXGroup", value: nil, title: "task detail", url: nil,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false, children: [
                AXNode(role: "AXHeading", value: "Do the thing", title: nil, url: nil,
                       frame: CGRect(x: 10, y: 10, width: 400, height: 24), focused: false, children: []),
            ]),
        ])
        let cases: [(any SourceParser, String)] = [
            (MicrosoftToDoParser(), "com.microsoft.to-do-mac"),
            (TodoistParser(), "com.todoist.mac.Todoist"),
            (OmniFocusParser(), "com.omnigroup.OmniFocus4"),
            (TogglParser(), "com.toggl.toggldesktop"),
        ]
        for (parser, bundleID) in cases {
            let app = AppInfo(bundleID: bundleID, name: "Tasks", windowTitle: "Tasks")
            let structured = try XCTUnwrap(try parser.parseStructured(window: window, app: app), bundleID)
            XCTAssertEqual(structured.kind, .task, bundleID)
        }
    }

    func testUnparseableWindowStillReturnsNil() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [])
        let app = AppInfo(bundleID: "com.apple.iCal", name: "Calendar", windowTitle: nil)
        XCTAssertNil(try CalendarParser().parseStructured(window: window, app: app))
        XCTAssertNil(try RemindersParser().parseStructured(window: window, app: app))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StructuredEntityTypedTests`
Expected: FAIL — `parseStructured` returns the protocol default `nil`, so the first `XCTUnwrap` fails.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/StructuredNativeParsers.swift`, give each of the seven parsers a `parseStructured` alongside its existing `parse`, for example:

```swift
public struct CalendarParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.calendar(window: window, app: app, sourceApp: "Calendar", prefix: "calendar")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.calendarContent(window: window, app: app, sourceApp: "Calendar")?.content
    }
}
```

Apply the same two-line pattern to `FantasticalParser` (`sourceApp: "Fantastical"`), and to `RemindersParser` / `MicrosoftToDoParser` / `TodoistParser` / `OmniFocusParser` / `TogglParser` using `taskContent(window:app:sourceApp:)` with their existing `sourceApp` strings.

Then replace `StructuredEntityExtraction.calendar` and `.task` with a typed core plus a render wrapper:

```swift
    struct Extracted {
        let content: CapturedContent
        let sourceKey: String
        let sourceTitle: String
    }

    static func calendarContent(window: AXNode, app: AppInfo, sourceApp: String) -> Extracted? {
        let root = preferredDetailRoot(in: window, hints: ["event", "detail", "popover"])
        let fields = orderedFields(in: root)
        guard !fields.isEmpty else { return nil }

        let title = firstValue(fields, metadataHints: ["title", "summary", "event-name"])
            ?? fields.first(where: { $0.role == "AXHeading" && !isChrome($0.value) })?.value
            ?? meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp, "Calendar"])
        guard let title, !title.isEmpty else { return nil }
        let when = firstValue(fields, metadataHints: ["date", "time", "start", "end"])
            ?? fields.first(where: { looksLikeDateOrTime($0.value) })?.value
        let location = firstValue(fields, metadataHints: ["location", "place"])
        // No organizer is exposed by these detail views, so the account/calendar name — the
        // closest thing to "who owns this event" — lands in `organizer`.
        let organizer = firstValue(fields, metadataHints: ["organizer", "invitee", "calendar-name", "account"])
        let hasConference = fields.contains { field in
            let value = field.value.lowercased()
            return value.contains("zoom.us") || value.contains("meet.google.com")
                || value.contains("teams.microsoft.com") || value.contains("join with")
        }
        // Everything the four named fields did not claim becomes the detail body, exactly as
        // the v1 `Details:` block did.
        let details = remainingValues(
            fields, excluding: [title, when, location, organizer].compactMap { $0 }
        )
        let event = CalendarEvent(
            title: title,
            dateString: when ?? "",
            start: nil, end: nil,
            organizer: organizer,
            location: location,
            hasConference: hasConference,
            notes: details.isEmpty ? nil : details.joined(separator: "\n")
        )
        let identity = [title, when ?? "", organizer ?? ""].joined(separator: "|")
        return Extracted(content: .calendar([event]),
                         sourceKey: "event:\(shortHash(identity))",
                         sourceTitle: title)
    }

    static func calendar(window: AXNode, app: AppInfo, sourceApp: String, prefix: String) -> ParsedCapture? {
        guard let extracted = calendarContent(window: window, app: app, sourceApp: sourceApp) else { return nil }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(extracted.sourceKey)",
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .calendar,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000),
            structured: extracted.content
        )
    }

    static func taskContent(window: AXNode, app: AppInfo, sourceApp: String) -> Extracted? {
        let root = preferredDetailRoot(in: window, hints: ["task", "reminder", "detail"])
        let fields = orderedFields(in: root)
        guard !fields.isEmpty else { return nil }

        let title = firstValue(fields, metadataHints: ["title", "name", "task-title", "reminder-title"])
            ?? fields.first(where: { $0.role == "AXHeading" && !isChrome($0.value) })?.value
            ?? meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp, "Reminders"])
        guard let title, !title.isEmpty else { return nil }
        let due = firstValue(fields, metadataHints: ["due", "date", "time"])
            ?? fields.first(where: { looksLikeDateOrTime($0.value) })?.value
        let project = firstValue(fields, metadataHints: ["list", "project", "section"])
        let statusField = fields.first { $0.role == "AXCheckBox" || $0.metadata.contains("completed") }
        let checked = ["1", "true", "yes", "checked"].contains(statusField?.value.lowercased() ?? "")
        let status: TaskStatus = statusField == nil ? .unknown : (checked ? .completed : .open)
        let details = remainingValues(
            fields, excluding: [title, due, project, statusField?.value].compactMap { $0 }
        )
        let item = TaskItem(
            title: title,
            status: status,
            due: nil,
            dueString: due,
            project: project,
            tags: [],
            notes: details.isEmpty ? nil : details.joined(separator: "\n")
        )
        let identity = [title, project ?? ""].joined(separator: "|")
        return Extracted(content: .tasks([item]),
                         sourceKey: "task:\(shortHash(identity))",
                         sourceTitle: title)
    }

    static func task(window: AXNode, app: AppInfo, sourceApp: String, prefix: String) -> ParsedCapture? {
        guard let extracted = taskContent(window: window, app: app, sourceApp: sourceApp) else { return nil }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(extracted.sourceKey)",
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .task,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000),
            structured: extracted.content
        )
    }
```

`bounded(_:)` is no longer used by these two paths; leave it in place for `document` and `email`.

**Status semantics changed on purpose:** v1 wrote `Status: open` whenever no checkbox was found. `TaskStatus.unknown` exists precisely for that case, so a window with no checkbox now renders `"- "` instead of `"- [ ] "`. `reminder-task.json` has a checkbox, so its expectation stays `.open`.

Update the existing assertions in `Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift`:

- `:20-23` — replace the four `Event:`/`When:`/`Location:`/`Calendar:` checks with an exact
  equality against `"Tuesday, 3:00 PM — Design review @Studio room / Work\nDetails: Review the interaction flow."`.
- `:45-47` — replace the three `Status:`/`List:`/`Due:` checks with
  `XCTAssertEqual(capture.content, "- [ ] Submit project notes (due Tomorrow, 5:00 PM) [Work]")`.
- `:65` — `contains("Status: completed")` becomes `hasPrefix("- [x] ")`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StructuredEntityTypedTests`
Expected: PASS, 9 tests.

Run: `swift test --filter StructuredNativeParserTests`
Expected: PASS — the Pages and Outlook cases in that file are untouched (they migrate in Task 16).

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/StructuredNativeParsers.swift \
        Tests/MaxMiCaptureTests/StructuredNativeParserTests.swift \
        Tests/MaxMiCaptureTests/StructuredEntityTypedTests.swift
git commit -m "Emit typed calendar events and tasks from the native entity parsers"
```

---

### Task 14: Terminal segmentation produces `.terminal`

**Files:**
- Modify: `Sources/MaxMiCapture/TerminalParser.swift:17-31` (`parse`, plus new `parseStructured`, `segments(fromScrollback:)`, `promptPatterns`)
- Test: `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift`

**Interfaces:**
- Consumes: `TerminalParser.largestTextArea(in:)`, `terminalKey(app:content:)`, `workingDirectory(fromTitle:)`, `workingDirectory(fromContent:)` (all unchanged); `TerminalSegment`, `TerminalSession`.
- Produces: `TerminalParser.promptPatterns: [String]`, `TerminalParser.segments(fromScrollback: String) -> [TerminalSegment]`, `TerminalParser.parseStructured`.

**Segmentation rule (§7c, applied in Phase A per §4f).** Learn the prompt shape from the **first** line matching `^\S+@\S+ ` (user@host) or `^[~/].* [%$❯] ` (a path followed by a prompt terminator), in that order. Every later line matching the **same** pattern starts a new segment whose `command` is the text after the match and whose `output` runs to the next match. The last segment gets `isRunning: true` when no trailing bare prompt line follows. A scrollback that matches neither pattern yields **one** segment with `command: nil` and the whole blob as `output`.

`terminalKey(app:content:)` keeps receiving the **raw blob**, not the rendered text — it needs the prompt lines. `TerminalSession.cwd` comes from the window title first, falling back to the scrollback's prompt cwd (§7c); both helpers already exist and return the slugged last path component. The richer absolute path is Phase D's anchored rewrite.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class TerminalSegmentationTests: XCTestCase {
    func window(_ blob: String, title: String? = "~/code/MaxMi") -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: [AXNode(role: "AXTextArea", value: blob, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                                 focused: false, children: [])])
    }

    func app(_ title: String? = "~/code/MaxMi") -> AppInfo {
        AppInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp", windowTitle: title)
    }

    func session(_ content: CapturedContent?) throws -> TerminalSession {
        guard case .terminal(let session) = try XCTUnwrap(content) else {
            XCTFail("expected .terminal")
            return TerminalSession(cwd: nil, segments: [])
        }
        return session
    }

    func testUserAtHostPromptSplitsCommandsAndOutput() throws {
        let blob = """
        sudhanshu@mac ~/code/MaxMi % swift build
        Compiling MaxMi
        Build complete
        sudhanshu@mac ~/code/MaxMi % swift test
        2 failures
        """
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(session.segments.map(\.output), ["Compiling MaxMi\nBuild complete", "2 failures"])
        XCTAssertEqual(session.segments.map(\.isRunning), [false, true],
                       "no trailing prompt means the last command is still running")
        XCTAssertEqual(session.cwd, "maxmi")
    }

    func testTrailingBarePromptMarksTheLastCommandFinished() throws {
        let blob = """
        sudhanshu@mac ~/code/MaxMi % swift test
        2 failures
        sudhanshu@mac ~/code/MaxMi % 
        """
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), ["swift test"])
        XCTAssertEqual(session.segments.map(\.isRunning), [false])
    }

    func testPathPromptPatternIsUsedWhenThereIsNoUserAtHost() throws {
        let blob = """
        ~/code/ShipCast ❯ git push
        Everything up-to-date
        ~/code/ShipCast ❯ git status
        """
        let session = try session(try TerminalParser().parseStructured(
            window: window(blob, title: "~/code/ShipCast"), app: app("~/code/ShipCast")))
        XCTAssertEqual(session.segments.map(\.command), ["git push"])
        XCTAssertEqual(session.segments.map(\.output), ["Everything up-to-date"])
        XCTAssertEqual(session.cwd, "shipcast")
    }

    func testOutputBeforeTheFirstPromptBecomesACommandlessSegment() throws {
        let blob = """
        welcome banner
        sudhanshu@mac ~/code/MaxMi % ls
        a b c
        """
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.map(\.command), [nil, "ls"])
        XCTAssertEqual(session.segments[0].output, "welcome banner")
    }

    func testUnrecognisedPromptFallsBackToOneCommandlessSegment() throws {
        let blob = "TUI frame\nspinner ⠋\nno prompt anywhere"
        let session = try session(try TerminalParser().parseStructured(window: window(blob), app: app()))
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertNil(session.segments[0].command)
        XCTAssertEqual(session.segments[0].output, blob)
        XCTAssertFalse(session.segments[0].isRunning)
    }

    func testCaptureRendersTheSegmentsAndKeepsKeyKindAndPolicy() throws {
        let blob = """
        sudhanshu@mac ~/code/MaxMi % swift test
        2 failures
        """
        let capture = try XCTUnwrap(try TerminalParser().parse(window: window(blob), app: app()))
        XCTAssertEqual(capture.sourceApp, "Warp")
        XCTAssertEqual(capture.sourceKey, "terminal:warp/maxmi",
                       "the key is still derived from the RAW scrollback")
        XCTAssertEqual(capture.contentKind, .terminal)
        XCTAssertEqual(capture.accumulationPolicy, .appendItems)
        XCTAssertEqual(capture.content, "$ swift test\n2 failures\n… (running)")
        XCTAssertEqual(capture.content, ContentRenderer.render(
            try XCTUnwrap(capture.structured), style: .full))
    }

    func testEmptyScrollbackStillReturnsNil() throws {
        let empty = AXNode(role: "AXWindow", value: nil, title: nil, url: nil,
                           frame: CGRect(x: 0, y: 0, width: 100, height: 100), focused: false,
                           children: [])
        XCTAssertNil(try TerminalParser().parseStructured(window: empty, app: app(nil)))
        XCTAssertNil(try TerminalParser().parse(window: empty, app: app(nil)))
    }

    func testOversizeScrollbackDropsOldestSegments() throws {
        var lines: [String] = []
        for index in 0..<400 {
            lines.append("sudhanshu@mac ~/code/MaxMi % echo \(index)")
            lines.append(String(repeating: "y", count: 40))
        }
        let session = try session(try TerminalParser().parseStructured(
            window: window(lines.joined(separator: "\n")), app: app()))
        XCTAssertEqual(session.segments.last?.command, "echo 399")
        XCTAssertLessThan(session.segments.count, 400, "oldest segments are dropped")
        let capture = try XCTUnwrap(try TerminalParser().parse(
            window: window(lines.joined(separator: "\n")), app: app()))
        XCTAssertLessThanOrEqual(capture.content.count, TerminalParser.contentCap)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalSegmentationTests`
Expected: FAIL — `parseStructured` returns the protocol default `nil`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/TerminalParser.swift`, replace `parse` and add the segmentation:

```swift
    /// Prompt shapes, tried in order. The FIRST one that any line matches becomes the splitter
    /// for the whole scrollback.
    static let promptPatterns = [
        "^\\S+@\\S+ ",           // user@host <path> % command
        "^[~/].* [%$❯] ",        // ~/path ❯ command
    ]

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        let session = TerminalSession(
            cwd: workingDirectory(fromTitle: app.windowTitle) ?? workingDirectory(fromContent: blob),
            segments: Self.segments(fromScrollback: blob)
        )
        return CaptureAccumulator.bound(.terminal(session), to: Self.contentCap)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: app.name,                 // "Warp", "Terminal", "iTerm2"
            // The key needs the RAW prompt lines, not the rendered segments.
            sourceKey: terminalKey(app: app, content: blob),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .terminal,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .visibleOnly(maxCharacters: 64_000),
            structured: structured
        )
    }

    /// Split the scrollback on prompt lines. Failure to recognise any prompt yields one segment
    /// with `command: nil` — a full-screen TUI has no command structure to find.
    static func segments(fromScrollback blob: String) -> [TerminalSegment] {
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let pattern = promptPatterns.first(where: { candidate in
            lines.contains { $0.range(of: candidate, options: .regularExpression) != nil }
        }) else {
            return [TerminalSegment(command: nil, output: blob, isRunning: false)]
        }

        var segments: [TerminalSegment] = []
        var pendingCommand: String?
        var pendingOutput: [String] = []
        var sawPrompt = false

        func flush(isRunning: Bool) {
            let output = joinedOutput(pendingOutput)
            guard pendingCommand != nil || !output.isEmpty else { return }
            segments.append(TerminalSegment(command: pendingCommand, output: output, isRunning: isRunning))
        }

        for line in lines {
            if let range = line.range(of: pattern, options: .regularExpression) {
                flush(isRunning: false)
                pendingOutput = []
                let command = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                pendingCommand = command.isEmpty ? nil : command
                sawPrompt = true
            } else if sawPrompt {
                pendingOutput.append(line)
            } else {
                pendingOutput.append(line)
            }
        }
        // A bare trailing prompt with no output means the previous command finished; anything
        // else is still running.
        if pendingCommand != nil || !joinedOutput(pendingOutput).isEmpty {
            flush(isRunning: true)
        }
        return segments.isEmpty
            ? [TerminalSegment(command: nil, output: blob, isRunning: false)]
            : segments
    }

    /// Join output lines and drop trailing blank lines, so a segment's bytes are deterministic.
    static func joinedOutput(_ lines: [String]) -> String {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
```

`largestTextArea` must become non-private (`func largestTextArea(in root: AXNode) -> String?`) because both `parse` and `parseStructured` call it.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalSegmentationTests`
Expected: PASS, 8 tests.

Run: `swift test --filter TerminalParserTests`
Expected: PASS — `testWarpScrollbackAndKey`'s `content.contains("longer scrollback")` still holds (that blob has no prompt, so it becomes one commandless segment rendered verbatim), and every `terminalKey` test calls the helper directly.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/TerminalParser.swift Tests/MaxMiCaptureTests/TerminalSegmentationTests.swift
git commit -m "Segment terminal scrollback into typed command and output pairs"
```

---

### Task 15: Browser captures produce `.conversation` or `.generic`

**Files:**
- Modify: `Sources/MaxMiCapture/BrowserTabExtractor.swift:164-173` (expose `primaryWebArea`)
- Modify: `Sources/MaxMiCapture/WebAppCaptureParser.swift:44-73` (`parse`), plus new `messages(in:)`
- Modify: `Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift:20`
- Test: `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift`

**Interfaces:**
- Consumes: `TabCapture`, `BrowserTabExtractor.extract(window:windowTitle:engine:)`, `WebAppCaptureParser.classify(url:)`, `WebAppCaptureParser.messageLines(in:)`, `NativeConversationExtraction.message(fromLine:)` (Task 11), `GenericPageExtractor.extract(window:focusedElement:url:options:)`.
- Produces: `BrowserTabExtractor.primaryWebArea(in root: AXNode, windowTitle: String?, engine: BrowserEngine?) -> AXNode?`; `WebAppCaptureParser.messages(in root: AXNode) -> [Message]`; `WebAppParseResult.capture.structured` non-nil on every path.

`contentKind` is unchanged: `.conversation` for the four chat hosts and LinkedIn messaging, `.email` for Gmail/Outlook, `.webpage` otherwise (§4f, §12 Q3). `preservedBoundaries` and `parserID` composition are unchanged, so `BrowserCapturePipeline`'s `quality` and health strings do not move.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/WebAppStructuredTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebAppStructuredTests: XCTestCase {
    func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    func testSlackWebProducesTypedConversationMessages() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "app.zen-browser.zen"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("gecko-slack-chat"),
            windowTitle: "Slack", browser: browser
        )
        guard case .conversation(let conversation) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .conversation")
        }
        XCTAssertEqual(conversation.messages.map(\.sender), ["Alex", "Sam"])
        XCTAssertEqual(conversation.messages.map(\.text),
                       ["Morning update", "Reviewing the browser parser"])
        XCTAssertEqual(result.capture.contentKind, .conversation)
        XCTAssertEqual(result.capture.content,
                       "(From: Alex): Morning update\n(From: Sam): Reviewing the browser parser")
        XCTAssertTrue(result.parserID.contains("gecko/slack/webArea/quality-high"))
    }

    func testGenericPageProducesATypedGenericPageCarryingItsURL() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.apple.Safari"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("safari-domain-only"),
            windowTitle: "Example Article", browser: browser
        )
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.url, "https://example.com")
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["Article body text."])
        XCTAssertEqual(result.capture.contentKind, .webpage)
        XCTAssertEqual(result.capture.content, "URL: https://example.com\nArticle body text.")
    }

    func testGmailKeepsEmailKindWithAGenericShape() throws {
        let browser = try XCTUnwrap(ApplicationRegistry.browser(for: "com.google.Chrome"))
        let result = try BrowserCapturePipeline.parse(
            window: try fixture("chromium-gmail-thread"),
            windowTitle: "Project update - Gmail", browser: browser
        )
        XCTAssertEqual(result.webApp, .gmail)
        XCTAssertEqual(result.capture.contentKind, .email,
                       "kind is not derived from the shape")
        XCTAssertEqual(result.capture.accumulationPolicy, .rollingText)
        XCTAssertEqual(try XCTUnwrap(result.capture.structured).kind, .generic)
        XCTAssertEqual(result.capture.content, ContentRenderer.render(
            try XCTUnwrap(result.capture.structured), style: .full))
    }

    func testPrimaryWebAreaIsFoundForTheGenericPath() throws {
        let webArea = BrowserTabExtractor.primaryWebArea(
            in: try fixture("safari-domain-only"), windowTitle: "Example Article", engine: .webkit)
        XCTAssertEqual(webArea?.role, "AXWebArea")
    }

    func testWebAreaAbsentFallsBackToTheWholeWindow() throws {
        let window = AXNode(role: "AXWindow", value: nil, title: "No web area", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
                            children: [
            AXNode(role: "AXStaticText", value: "chrome only", title: nil, url: nil,
                   frame: CGRect(x: 10, y: 10, width: 200, height: 16), focused: false, children: []),
        ])
        let tab = TabCapture(url: "https://example.com/x", title: "x", content: "chrome only",
                             urlSource: .addressBar, quality: .fallback, truncated: false)
        let result = WebAppCaptureParser.parse(tab: tab, window: window)
        guard case .generic(let page) = try XCTUnwrap(result.capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["chrome only"])
        XCTAssertEqual(page.url, "https://example.com/x")
    }

    func testMessageLinesHelperIsUnchanged() {
        func text(_ value: String, y: CGFloat) -> AXNode {
            AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
                   frame: CGRect(x: 0, y: y, width: 100, height: 16), focused: false, children: [])
        }
        let row = AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                         frame: CGRect(x: 0, y: 100, width: 400, height: 30), focused: false,
                         children: [text("Alex", y: 100), text("yes", y: 101)])
        let root = AXNode(role: "AXWindow", value: nil, title: nil, url: nil, frame: nil,
                          focused: false, children: [row])
        XCTAssertEqual(WebAppCaptureParser.messageLines(in: root), ["Alex: yes"])
        XCTAssertEqual(WebAppCaptureParser.messages(in: root).map(\.sender), ["Alex"])
        XCTAssertEqual(WebAppCaptureParser.messages(in: root).map(\.text), ["yes"])
    }
}
```

If `TabCapture`'s initializer labels differ from the call above, copy the real ones from `Sources/MaxMiCapture/BrowserTabExtractor.swift:23-38`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebAppStructuredTests`
Expected: FAIL — `result.capture.structured` is nil.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MaxMiCapture/BrowserTabExtractor.swift`, add a one-line internal wrapper next to `bestWebArea`:

```swift
    /// The web area the generic structured path should walk. Thin wrapper over the same scoring
    /// `extract` uses, so both paths agree on which frame is the page.
    static func primaryWebArea(in root: AXNode, windowTitle: String?, engine: BrowserEngine? = nil) -> AXNode? {
        bestWebArea(from: nodes(in: root) { $0.role == "AXWebArea" },
                    windowTitle: windowTitle, engine: engine)
    }
```

In `Sources/MaxMiCapture/WebAppCaptureParser.swift`, replace `parse` and add `messages`:

```swift
    public static func parse(tab: TabCapture, window: AXNode) -> WebAppParseResult {
        let app = classify(url: tab.url)
        let isLinkedInMessaging = app == .linkedin
            && (URLComponents(string: tab.url)?.path.hasPrefix("/messaging") == true)
        let isConversation = [.slack, .discord, .whatsapp, .teams].contains(app)
            || isLinkedInMessaging
        let isEmail = app == .gmail || app == .outlook

        let typedMessages = isConversation ? messages(in: window) : []
        let structured: CapturedContent
        let preservedBoundaries: Bool
        if !typedMessages.isEmpty {
            structured = CaptureAccumulator.bound(
                .conversation(Conversation(
                    channel: tab.title ?? URLComponents(string: tab.url)?.host ?? tab.url,
                    isGroup: true,
                    messages: typedMessages
                )),
                to: contentCap
            )
            preservedBoundaries = true
        } else {
            // Generic path: the v2 extractor over the web area, with the URL attached.
            var options = GenericPageExtractor.Options()
            options.totalBudget = contentCap
            options.offscreenPolicy = .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000)
            let root = BrowserTabExtractor.primaryWebArea(in: window, windowTitle: tab.title) ?? window
            let page = GenericPageExtractor.extract(
                window: root, focusedElement: nil, url: tab.url, options: options
            ).page
            structured = .generic(page)
            preservedBoundaries = false
        }

        // Kind is NOT derived from the shape: Gmail/Outlook stay .email and every other page
        // stays .webpage (spec 12 Q3).
        let kind: CaptureContentKind = isConversation ? .conversation : (isEmail ? .email : .webpage)
        let accumulation: CaptureAccumulationPolicy = isConversation ? .appendItems : .rollingText
        let capture = ParsedCapture(
            sourceApp: "Web",
            sourceKey: URLKeyNormalizer.normalize(tab.url),
            sourceTitle: tab.title,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: kind,
            parserVersion: 2,
            accumulationPolicy: accumulation,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000),
            structured: structured
        )
        return WebAppParseResult(capture: capture, app: app, preservedBoundaries: preservedBoundaries)
    }

    /// One `Message` per visible message container, split from the same atomic lines
    /// `messageLines` produces.
    static func messages(in root: AXNode) -> [Message] {
        messageLines(in: root).compactMap(NativeConversationExtraction.message(fromLine:))
    }
```

`bounded(_:)` becomes unused in this file — delete it. `messageLines`, `collectMessageContainers`, `messageLine`, and `collectText` are unchanged.

Update `Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift:20`:

```swift
        XCTAssertEqual(result.capture.content,
                       "(From: Alex): Morning update\n(From: Sam): Reviewing the browser parser")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebAppStructuredTests`
Expected: PASS, 6 tests.

Run: `swift test --filter BrowserCapturePipelineTests`
Expected: PASS.

Run: `swift test --filter ExtractorTests`
Expected: PASS — `BrowserTabExtractor.extract` itself is untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/WebAppCaptureParser.swift Sources/MaxMiCapture/BrowserTabExtractor.swift \
        Tests/MaxMiCaptureTests/BrowserCapturePipelineTests.swift \
        Tests/MaxMiCaptureTests/WebAppStructuredTests.swift
git commit -m "Emit typed conversations and pages from browser captures"
```

---

### Task 16: The nine remaining parsers produce `.generic`, keeping their `contentKind`

**Files:**
- Create: `Sources/MaxMiCapture/GenericV2Content.swift`
- Modify: `Sources/MaxMiCapture/NotesParser.swift`, `NotionParser.swift`, `ObsidianParser.swift` (whole `parse`)
- Modify: `Sources/MaxMiCapture/StructuredNativeParsers.swift` (`WordParser`, `PagesParser`, `OutlookParser`, `SparkParser`, `StructuredEntityExtraction.document`, `.email`)
- Modify: `Sources/MaxMiCapture/DiscordParser.swift`, `Sources/MaxMiCapture/MessagesParser.swift` (`parse` + new `parseStructured`)
- Test: `Tests/MaxMiCaptureTests/GenericV2ParserTests.swift`

**Interfaces:**
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)`, `ContentRenderer`, `Block`, `Region`, `GenericPage`.
- Produces: `GenericV2Content.page(window: AXNode, url: String?, budget: Int, offscreenPolicy: OffscreenCapturePolicy) -> CapturedContent?` and `GenericV2Content.lines(_ lines: [String]) -> CapturedContent?`; `parseStructured` on all nine parsers.

**Two different routes, on purpose.**

- **Notes, Notion, Obsidian, Word, Pages, Outlook, Spark** call `DocumentExtraction.bodyText` today — a pure text dump with no app-specific filtering. They move to `GenericV2Content.page`, i.e. the real v2 extractor. Strict improvement: they gain headings, list depth, table rows, and regions.
- **Discord and Messages** keep their own line collection and wrap it with `GenericV2Content.lines`. Running the v2 extractor over them would be a **regression**: `DiscordParser` deliberately filters known UI chrome (`"Add Reaction"`, `"Message"`, `"Edited"`, …) that v2 emits as `.label` blocks, and its header comment records that Discord's `AXFrame` values are unreliable — so v2's frame-based region detection and off-screen filtering are unsafe there. `MessagesParser` orders bubbles by `y` across `AXTextArea` and `AXStaticText` and nothing else. Both get their anchored parsers in Phase D (§7c), which is where the sender attribution and bubble sides land.

`contentKind` is preserved for every one of the nine: `.document` for Notes/Notion/Obsidian/Word/Pages, `.email` for Outlook/Spark, `.conversation` for Discord/Messages. None is derivable from the `.generic` shape (§12 Q3), and the `latest_contexts.content_kind` CHECK constraint plus MCP filtering depend on them.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/GenericV2ParserTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericV2ParserTests: XCTestCase {
    func text(_ value: String, y: CGFloat) -> AXNode {
        AXNode(role: "AXStaticText", value: value, title: nil, url: nil,
               frame: CGRect(x: 300, y: y, width: 400, height: 16), focused: false, children: [])
    }

    func body(_ children: [AXNode], title: String?) -> AXNode {
        AXNode(role: "AXWindow", value: nil, title: title, url: nil,
               frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), focused: false,
               children: children)
    }

    /// Every parser here keeps a contentKind that the `.generic` shape cannot imply.
    func testAllNineParsersProduceGenericStructureWithTheirOwnKind() throws {
        let document = body([
            AXNode(role: "AXHeading", value: "Heading one", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 10, width: 400, height: 24), focused: false,
                   children: [], headingLevel: 1),
            text("body line", y: 40),
        ], title: nil)
        let cases: [(parser: any SourceParser, app: AppInfo, kind: CaptureContentKind, label: String)] = [
            (NotesParser(), AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries"), .document, "Notes"),
            (NotionParser(), AppInfo(bundleID: "notion.id", name: "Notion", windowTitle: "June LP"), .document, "Notion"),
            (ObsidianParser(), AppInfo(bundleID: "md.obsidian", name: "Obsidian", windowTitle: "Welcome - My Vault - Obsidian v1.5"), .document, "Obsidian"),
            (WordParser(), AppInfo(bundleID: "com.microsoft.Word", name: "Word", windowTitle: "Brief - Microsoft Word"), .document, "Word"),
            (PagesParser(), AppInfo(bundleID: "com.apple.iWork.Pages", name: "Pages", windowTitle: "Brief - Pages"), .document, "Pages"),
            (OutlookParser(), AppInfo(bundleID: "com.microsoft.Outlook", name: "Outlook", windowTitle: "Project update"), .email, "Outlook"),
            (SparkParser(), AppInfo(bundleID: "com.readdle.SparkDesktop", name: "Spark", windowTitle: "Project update"), .email, "Spark"),
        ]
        for entry in cases {
            let structured = try XCTUnwrap(
                try entry.parser.parseStructured(window: document, app: entry.app), entry.label)
            XCTAssertEqual(structured.kind, .generic, entry.label)
            let capture = try XCTUnwrap(try entry.parser.parse(window: document, app: entry.app), entry.label)
            XCTAssertEqual(capture.contentKind, entry.kind,
                           "\(entry.label) must keep its contentKind override")
            XCTAssertEqual(capture.structured, structured, entry.label)
            XCTAssertEqual(capture.content, ContentRenderer.render(structured, style: .full), entry.label)
        }
    }

    func testDocumentParsersNowSeeHeadingsAndKeepTheirKeys() throws {
        let window = body([
            AXNode(role: "AXHeading", value: "Groceries", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 10, width: 400, height: 24), focused: false,
                   children: [], headingLevel: 2),
            text("milk", y: 40),
        ], title: "Groceries")
        let app = AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "Groceries")
        let capture = try XCTUnwrap(try NotesParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "notes:groceries")
        XCTAssertEqual(capture.content, "## Groceries\nmilk",
                       "generic v2 sees the heading level DocumentExtraction threw away")
        XCTAssertEqual(capture.accumulationPolicy, .rollingText)
    }

    func testDiscordKeepsItsOwnChromeFilteringWrappedInGenericBlocks() throws {
        let window = body([
            text("Add Reaction", y: 10),
            text("Ana", y: 30),
            text("Great work everyone!", y: 50),
        ], title: "#general | Acme - Discord")
        let app = AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                          windowTitle: "#general | Acme - Discord")
        let capture = try XCTUnwrap(try DiscordParser().parse(window: window, app: app))
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertFalse(capture.content.contains("Add Reaction"),
                       "the app-specific chrome filter is preserved")
        XCTAssertTrue(capture.content.contains("Great work everyone!"))
        guard case .generic(let page) = try XCTUnwrap(capture.structured) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions.map(\.kind), [.main])
        XCTAssertEqual(page.regions[0].blocks.map(\.type),
                       Array(repeating: BlockType.paragraph, count: page.regions[0].blocks.count))
        XCTAssertEqual(capture.content, ContentRenderer.render(capture.structured!, style: .full))
    }

    func testMessagesKeepsBubbleOrderWrappedInGenericBlocks() throws {
        let window = body([
            AXNode(role: "AXTextArea", value: "call me", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 300, width: 400, height: 20), focused: false, children: []),
            AXNode(role: "AXTextArea", value: "hey are you free", title: nil, url: nil,
                   frame: CGRect(x: 300, y: 100, width: 400, height: 20), focused: false, children: []),
        ], title: "Harnish")
        let app = AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages",
                          windowTitle: "Harnish")
        let capture = try XCTUnwrap(try MessagesParser().parse(window: window, app: app))
        XCTAssertEqual(capture.sourceKey, "imessage:harnish")
        XCTAssertEqual(capture.contentKind, .conversation)
        XCTAssertEqual(capture.content, "hey are you free\ncall me")
        XCTAssertEqual(try XCTUnwrap(capture.structured).kind, .generic)
    }

    func testEmptyWindowsStillReturnNilEverywhere() throws {
        let empty = body([], title: "x")
        let apps: [(any SourceParser, AppInfo)] = [
            (NotesParser(), AppInfo(bundleID: "com.apple.Notes", name: "Notes", windowTitle: "x")),
            (PagesParser(), AppInfo(bundleID: "com.apple.iWork.Pages", name: "Pages", windowTitle: "x")),
            (OutlookParser(), AppInfo(bundleID: "com.microsoft.Outlook", name: "Outlook", windowTitle: "x")),
            (DiscordParser(), AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord", windowTitle: "x")),
            (MessagesParser(), AppInfo(bundleID: ParserRegistry.messagesBundleID, name: "Messages", windowTitle: "x")),
        ]
        for (parser, app) in apps {
            XCTAssertNil(try parser.parseStructured(window: empty, app: app), app.name)
            XCTAssertNil(try parser.parse(window: empty, app: app), app.name)
        }
    }

    func testGenericV2LinesHelperMakesOneParagraphPerLine() throws {
        guard case .generic(let page) = try XCTUnwrap(GenericV2Content.lines(["a", "b"])) else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.regions[0].kind, .main)
        XCTAssertEqual(page.regions[0].blocks.map(\.text), ["a", "b"])
        XCTAssertNil(GenericV2Content.lines([]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenericV2ParserTests`
Expected: FAIL to compile — "cannot find 'GenericV2Content' in scope".

- [ ] **Step 3a: Add the shared helper**

Create `Sources/MaxMiCapture/GenericV2Content.swift`:

```swift
import Foundation
import MaxMiCore

/// Typed `.generic` content for parsers that do not yet have an anchored shape (Phase D, spec 7c).
enum GenericV2Content {
    /// The v2 extractor's page. nil when the window has no readable content, so the caller can
    /// return nil and let dispatch decide.
    static func page(
        window: AXNode,
        url: String? = nil,
        budget: Int = 8_000,
        offscreenPolicy: OffscreenCapturePolicy
    ) -> CapturedContent? {
        var options = GenericPageExtractor.Options()
        options.totalBudget = budget
        options.offscreenPolicy = offscreenPolicy
        let result = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: url, options: options
        )
        guard !result.page.regions.isEmpty else { return nil }
        return .generic(result.page)
    }

    /// One `.main` region of `.paragraph` blocks, for parsers whose own line collection is
    /// better than the generic walk (Discord's chrome filter, Messages' bubble ordering).
    static func lines(_ lines: [String]) -> CapturedContent? {
        let blocks = lines.filter { !$0.isEmpty }.map { Block(type: .paragraph, text: $0) }
        guard !blocks.isEmpty else { return nil }
        return .generic(GenericPage(
            regions: [Region(kind: .main, blocks: blocks)], focused: nil, url: nil
        ))
    }
}
```

- [ ] **Step 3b: Migrate the five document parsers and the two email parsers**

`Sources/MaxMiCapture/NotesParser.swift`:

```swift
public struct NotesParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window, offscreenPolicy: .accessibilityScroll(maxSteps: 3))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(structured, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .rollingText,
                             offscreenPolicy: .accessibilityScroll(maxSteps: 3),
                             structured: structured)
    }
}
```

Apply the identical shape to `NotionParser` (`sourceApp: "Notion"`, key `"notion:\(docSlug(title))"`) and `ObsidianParser` (`sourceApp: "Obsidian"`, key `key(fromTitle: app.windowTitle)` — `key(fromTitle:)` is unchanged).

In `Sources/MaxMiCapture/StructuredNativeParsers.swift`, add `parseStructured` to the four parsers and rewrite the two extraction functions:

```swift
public struct WordParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.document(
            window: window, app: app, sourceApp: "Microsoft Word", prefix: "word",
            titleSuffixes: [" - Microsoft Word", " — Microsoft Word"]
        )
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.documentContent(window: window)
    }
}
```

(the same two-line addition on `PagesParser`, and `emailContent(window:)` on `OutlookParser` and `SparkParser`).

```swift
    /// Generic v2 over the whole window. The anchored document parsers land in Phase D.
    static func documentContent(window: AXNode) -> CapturedContent? {
        GenericV2Content.page(window: window, budget: 32_000,
                              offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: 96_000))
    }

    static func document(
        window: AXNode, app: AppInfo, sourceApp: String, prefix: String, titleSuffixes: [String]
    ) -> ParsedCapture? {
        guard let structured = documentContent(window: window) else { return nil }
        var title = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.isEmpty { title = "untitled" }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(docSlug(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .document,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: 96_000),
            structured: structured
        )
    }

    static func emailContent(window: AXNode) -> CapturedContent? {
        GenericV2Content.page(window: window, budget: 32_000,
                              offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000))
    }

    static func email(window: AXNode, app: AppInfo, sourceApp: String, prefix: String) -> ParsedCapture? {
        guard let structured = emailContent(window: window) else { return nil }
        let title = meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp]) ?? "message"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):message:\(shortHash(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            // Outlook and Spark expose no sender or date, so they stay a page — but the kind
            // is still .email (spec 12 Q3).
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000),
            structured: structured
        )
    }
```

`bounded(_:)` is now unused in this file — delete it.

- [ ] **Step 3c: Wrap Discord and Messages**

In `Sources/MaxMiCapture/DiscordParser.swift`, replace `parse` and add `parseStructured` (`messageLines`, `key(fromTitle:)`, and the chrome set stay exactly as they are):

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        let lines = messageLines(in: window)
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            let add = line.count + 1
            if total + add > Self.contentCap && !kept.isEmpty { break }
            kept.insert(line, at: 0)
            total += add
        }
        // Discord's own chrome filter and tree-order collection are kept: the generic v2 walk
        // would re-emit "Add Reaction" and friends as labels, and Discord's AXFrame values are
        // unreliable, so v2's frame-based rules are unsafe here. Phase D replaces this.
        return GenericV2Content.lines(kept)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: "Discord",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: structured
        )
    }
```

Apply the same pattern in `Sources/MaxMiCapture/MessagesParser.swift` using its `conversationLines(in:)` and `key(fromTitle:)`:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        let lines = conversationLines(in: window)
        guard !lines.isEmpty else { return nil }
        // Bubble order comes from the y sort in conversationLines; Phase D adds sender sides.
        return GenericV2Content.lines(lines).map {
            CaptureAccumulator.bound($0, to: Self.contentCap)
        }
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        return ParsedCapture(
            sourceApp: "Messages",
            sourceKey: key(fromTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .conversation,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            structured: structured
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenericV2ParserTests`
Expected: PASS, 6 tests.

Run: `swift test --filter DocumentParsersTests`
Expected: PASS — those assertions are `contains` checks on body text plus exact `sourceKey`s, and neither moves.

Run: `swift test --filter DiscordParserTests`
Expected: PASS, unchanged.

Run: `swift test --filter MessagesParserTests`
Expected: PASS, unchanged.

Run: `swift test --filter StructuredNativeParserTests`
Expected: PASS. If the Pages case's `contains("Implementation notes")` fails, print the rendered content — v2 emits more than `bodyText` did (labels, headings), never less.

Run: `swift test --filter MaxMiCaptureTests`
Expected: PASS, all capture tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture Tests/MaxMiCaptureTests/GenericV2ParserTests.swift
git commit -m "Move the remaining parsers to typed generic pages"
```

---

### Task 17: MCP surface guard

**Files:**
- Test only: `Tests/MaxMiMCPTests/MCPStructuredNoChangeTests.swift`

**Interfaces:**
- Consumes: `MaxMiToolsDefinitions.all` / `MaxMiTools.toolDefinitions`, `MaxMiTools.call(name:arguments:)`, `MemoryQueries`, `Store.commitCapture(_:nowMs:)`, `CaptureEnvelope(… structured:)`.
- Produces: nothing. This task exists to make §4g's "unchanged" a compiled assertion instead of a promise, and it is a **regression guard for Phases B, C and D** as well.

§4g: `search_memory`, `list_active_threads`, and `get_latest_context` keep their request and response shapes and keep reading `content`. Exposing `structured` over MCP is explicitly out of scope.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiMCPTests/MCPStructuredNoChangeTests.swift`:

```swift
import XCTest
@testable import MaxMiMCP
import MaxMiStore
import MaxMiCore

final class MCPStructuredNoChangeTests: XCTestCase {
    func makeTools(seed: (Store) throws -> Void = { _ in }) throws -> MaxMiTools {
        let store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
        try seed(store)
        let queries = MemoryQueries(store: store, relay: MockRelay(.failure(RelayError.notConfigured)))
        return MaxMiTools(queries: queries)
    }

    func conversationEnvelope() -> CaptureEnvelope {
        let structured = CapturedContent.conversation(Conversation(
            channel: "#maxmi-dev", isGroup: true, messages: [
                Message(id: "1", sender: "Ana", text: "ping", timestamp: nil, timeString: "09:20",
                        isUser: false, isDraft: false),
                Message(id: "2", sender: "Sudhanshu", text: "on it", timestamp: nil, timeString: nil,
                        isUser: true, isDraft: false),
            ]))
        return CaptureEnvelope(
            sourceApp: "Slack", sourceKey: "slack:acme/dev", sourceTitle: "dev",
            content: "IGNORED", contentKind: .conversation, parserID: "SlackParser",
            parserVersion: 2, accumulationPolicy: .appendItems,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3),
            trigger: .conversationChanged, truncated: false, structured: structured)
    }

    func testToolNamesAndRequiredArgumentsAreUnchanged() throws {
        let definitions = try makeTools().toolDefinitions
        XCTAssertEqual(definitions.map { $0["name"] as? String },
                       ["search_memory", "list_active_threads", "get_latest_context", "meeting_memory"])
        let getLatest = try XCTUnwrap(definitions[2]["inputSchema"] as? [String: Any])
        XCTAssertEqual(getLatest["required"] as? [String], [])
        let properties = try XCTUnwrap(getLatest["properties"] as? [String: Any])
        XCTAssertNil(properties["structured"], "structured is never exposed over MCP")
        let kinds = try XCTUnwrap(
            (properties["content_kinds"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(kinds["enum"] as? [String],
                       ["webpage", "conversation", "document", "terminal", "email",
                        "calendar", "task", "meeting", "voiceNote", "generic"])
    }

    func testGetLatestContextReturnsRenderedTextAndNeverTheStructuredPayload() async throws {
        let tools = try makeTools { store in
            _ = try store.commitCapture(self.conversationEnvelope(),
                                        nowMs: EpochMs(Date().timeIntervalSince1970 * 1_000))
        }
        let result = await tools.call(name: "get_latest_context", arguments: [:])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("(From: Ana)(sent 09:20): ping"),
                      "the rendered .full text is what MCP serves")
        XCTAssertTrue(result.text.contains("(From: You): on it"))
        XCTAssertFalse(result.text.contains("enc:v1:"), "no ciphertext leaks")
        XCTAssertFalse(result.text.contains("\"regions\""), "no structured JSON leaks")
        XCTAssertFalse(result.text.contains("\"isDraft\""))
        XCTAssertFalse(result.text.contains("[user]"))
    }

    func testListActiveThreadsStillAnswersAfterAStructuredCommit() async throws {
        let tools = try makeTools { store in
            _ = try store.commitCapture(self.conversationEnvelope(),
                                        nowMs: EpochMs(Date().timeIntervalSince1970 * 1_000))
        }
        let result = await tools.call(name: "list_active_threads", arguments: [:])
        XCTAssertFalse(result.isError, result.text)
    }
}
```

If `MaxMiTools.call` is not `async` in this build, drop the `await` — copy the call shape from `Tests/MaxMiMCPTests/ToolsTests.swift:20-30`. `MockRelay` and `RelayError` are already used there.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MCPStructuredNoChangeTests`
Expected: FAIL only if something in Tasks 8-16 leaked. If it passes first try, that is the point of the task — keep the test and note it in the commit.

- [ ] **Step 3: Write minimal implementation**

No production change. If an assertion fails, the fix belongs in whichever task leaked (almost certainly `MemoryQueries.getLatestContext`, which must keep printing `context.content` and nothing else), not in the assertion.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MCPStructuredNoChangeTests`
Expected: PASS, 3 tests.

Run: `swift test --filter MaxMiMCPTests`
Expected: PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add Tests/MaxMiMCPTests/MCPStructuredNoChangeTests.swift
git commit -m "Guard the MCP tool surface against structured capture changes"
```

---

### Task 18: `GenericPageExtractor` performance bound

**Files:**
- Test only: `Tests/MaxMiCaptureTests/GenericPageExtractorPerformanceTests.swift`

**Interfaces:**
- Consumes: `GenericPageExtractor.extract(window:focusedElement:url:options:)`.
- Produces: nothing.

§8: `extract` must complete in **< 150 ms for a 20_000-node tree** on M1, measured over a synthetic `AXNode` tree since the function is pure and in-memory (`AXReader`'s own budget is already `maxNodes: 20_000`). This is the **one** wall-clock test in the suite. A debug build of Swift is roughly an order of magnitude slower than release, so the 150 ms figure is asserted in release and the same test keeps a loose 1.5 s ceiling in debug — that still catches an accidental quadratic.

- [ ] **Step 1: Write the failing test**

Create `Tests/MaxMiCaptureTests/GenericPageExtractorPerformanceTests.swift`:

```swift
import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class GenericPageExtractorPerformanceTests: XCTestCase {
    /// 20_000 nodes: 20 top-level groups, each with 20 rows of 4 cells plus a heading — the
    /// shape a real table-heavy window has, and the budget AXReader already enforces.
    func makeLargeTree() -> (window: AXNode, nodeCount: Int) {
        var count = 1
        var groups: [AXNode] = []
        for group in 0..<20 {
            var rows: [AXNode] = []
            let groupY = CGFloat(group) * 2_000
            for row in 0..<40 {
                let y = groupY + CGFloat(row) * 24
                var cells: [AXNode] = []
                for cell in 0..<5 {
                    let x = CGFloat(cell) * 200
                    cells.append(AXNode(
                        role: "AXCell", value: nil, title: nil, url: nil,
                        frame: CGRect(x: x, y: y, width: 200, height: 24), focused: false,
                        children: [AXNode(role: "AXStaticText", value: "g\(group)r\(row)c\(cell)",
                                          title: nil, url: nil,
                                          frame: CGRect(x: x, y: y, width: 200, height: 16),
                                          focused: false, children: [])]))
                    count += 2
                }
                rows.append(AXNode(role: "AXRow", value: nil, title: nil, url: nil,
                                   frame: CGRect(x: 0, y: y, width: 1_000, height: 24),
                                   focused: false, children: cells))
                count += 1
            }
            rows.append(AXNode(role: "AXHeading", value: "Group \(group)", title: nil, url: nil,
                               frame: CGRect(x: 0, y: groupY, width: 400, height: 24),
                               focused: false, children: [], headingLevel: 2))
            count += 1
            groups.append(AXNode(role: "AXGroup", value: nil, title: nil, url: nil,
                                 frame: CGRect(x: 0, y: groupY, width: 1_000, height: 1_000),
                                 focused: false, children: rows))
            count += 1
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "Big", url: nil,
                            frame: CGRect(x: 300, y: 200, width: 1_000, height: 40_000),
                            focused: false, children: groups)
        return (window, count)
    }

    func testTwentyThousandNodeTreeStaysWithinTheBound() {
        let tree = makeLargeTree()
        XCTAssertGreaterThanOrEqual(tree.nodeCount, 20_000,
                                    "the fixture must actually reach the AXReader node budget")

        let started = DispatchTime.now().uptimeNanoseconds
        let result = GenericPageExtractor.extract(window: tree.window, focusedElement: nil, url: nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertFalse(result.page.regions.isEmpty, "the walk actually produced blocks")

        #if DEBUG
        // Debug builds are roughly 10x slower. The spec's 150 ms bound is asserted in release:
        //   swift test -c release -Xswiftc -enable-testing --filter GenericPageExtractorPerformanceTests
        let bound = 1.500
        #else
        let bound = 0.150
        #endif
        XCTAssertLessThan(elapsed, bound,
                          "GenericPageExtractor took \(elapsed)s for \(tree.nodeCount) nodes")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenericPageExtractorPerformanceTests`
Expected: PASS if the implementation is already linear, FAIL with the elapsed time printed if anything in Tasks 5-7 is quadratic. The likely culprit if it fails is a per-block `ContentRenderer.render` of the whole page inside a loop — `applyBudgets` and `trim` must render each block once, never the page.

- [ ] **Step 3: Write minimal implementation**

If the debug bound fails, fix the extractor, not the bound. Check in this order:

1. `trim(_:to:)` renders one block per iteration and stops early — it must never call `renderedSize` on the whole list inside its loop.
2. `assemble(_:)` sorts each claim once, not once per block.
3. `isSplitGroupSidebar` / `containsListLike` only run on nodes whose parent is an `AXSplitGroup`, so the descendant scan is not repeated for every node in the tree.
4. `orderedDescendantText` is called only from `block(for:)` on rows and list items, and those stop recursion, so no node is visited twice.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GenericPageExtractorPerformanceTests`
Expected: PASS.

Run: `swift test -c release -Xswiftc -enable-testing --filter GenericPageExtractorPerformanceTests`
Expected: PASS with the 150 ms bound. This builds the whole package in release and takes several minutes; it is the authoritative check for §11 exit criterion 9.

- [ ] **Step 5: Commit**

```bash
git add Tests/MaxMiCaptureTests/GenericPageExtractorPerformanceTests.swift
git commit -m "Assert the generic extractor stays under the 20k-node time bound"
```

---

### Task 19: Full suite, rebuild, and live verification

**Files:**
- No source changes unless a step below fails.

**Interfaces:**
- Consumes: everything built in Tasks 1-18.
- Produces: the §11 exit-criteria evidence for Phase A.

- [ ] **Step 1: Run the full suite and confirm zero warnings**

```bash
swift build 2>&1 | tee /tmp/maxmi-m8a-build.log | grep -c "warning:"
swift test 2>&1 | tail -30
```

Expected: `0` warnings, and every test passing — the 506 pre-existing tests plus roughly 150 added here. If the warning count is not zero, fix the warnings; §11 exit criterion 10 says "zero warnings".

- [ ] **Step 2: Run the release performance check**

```bash
swift test -c release -Xswiftc -enable-testing --filter GenericPageExtractorPerformanceTests
```

Expected: PASS with the 150 ms bound (§11 criterion 9).

- [ ] **Step 3: Confirm the exit criteria that are assertable from the tree**

```bash
# 1. Every parser produces a CapturedContent: no SourceParser conformer is left without
#    parseStructured, except the ones this plan documents as intentionally generic.
grep -rn "struct .*Parser: SourceParser" Sources/MaxMiCapture/ | wc -l
grep -rn "func parseStructured" Sources/MaxMiCapture/ | wc -l

# 2. A secure field's value is never read anywhere.
grep -rn "AXSecureTextField" Sources/MaxMiCapture/

# 3. No keystroke tap was introduced (Phase B's rule, asserted early).
grep -rn "CGEventTap\|addGlobalMonitorForEvents" Sources/ || echo "clean"

# 4. Schema identifier moved with the migration.
grep -n "currentIdentifier" Sources/MaxMiStore/Migrations.swift
grep -n "registerMigration(\"v10\")" Sources/MaxMiStore/Migrations.swift
```

Expected: every `…Parser: SourceParser` conformer in `Sources/MaxMiCapture/` has a `parseStructured` (Tasks 11-16 cover all of them plus `GenericAXParser`); `AXSecureTextField` appears only in `GenericPageExtractor.swift`; the `CGEventTap` grep is clean; `currentIdentifier` is `"v10"` and `v10` is registered.

- [ ] **Step 4: Rebuild the app (no `tccutil reset`)**

```bash
./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" && sleep 2 && open MaxMi.app
```

**Do NOT run `tccutil reset`.** Signed builds keep the Accessibility grant across rebuilds; resetting it revokes the grant and capture silently stops. Note the wall-clock time of the `open` — every capture you verify must be timestamped strictly after it.

- [ ] **Step 5: Live-verify a Finder capture through MCP**

1. Bring a **Finder** window to the front, positioned so it is **not** flush against the left edge of the primary display (this is the window-relative-coordinate case). Give it a sidebar, list or column view with several files, and select one row.
2. Wait for a capture (switch away and back to force `appActivated`).
3. In Claude Code, call the MCP tool `get_latest_context` with `source: "Finder"` and `limit: 1`.
4. Confirm, in the returned raw context:
   - the timestamp is **after** the `open MaxMi.app` from Step 4;
   - the body shows **joined table rows** — `Name | Date Modified | Size | Kind`-style lines with ` | ` separators, and the selected row prefixed `* `;
   - a `## Sidebar` header appears with the source-list entries under it, **not** interleaved with the file rows;
   - a `## Toolbar` section appears when Finder is showing a status line;
   - `content_kind` is `generic` and `parser_id` is `GenericAXParser`.
5. Repeat with a **terminal** (Warp) window that has run two or three commands, and confirm the body renders as `$ <command>` lines followed by their output, with `… (running)` only on a command that has not finished.
6. Repeat with a **Slack** window and confirm message lines read `(From: <sender>): <text>` and that `[user]` appears nowhere.
7. Trigger a dialog over a window (for example quit an app that confirms) and confirm the next capture of that app shows a `## Dialog` section.
8. Focus a password field somewhere (a login page or System Settings) and confirm the capture shows `«secure field»` and **never** the typed characters.
9. Open the **Capture Health** window and confirm no row's `parser` reads `GenericPageExtractor.v2/fallback/…` for an app whose dedicated parser should be handling it. A fallback row for an app you have not opened in its normal state is expected; a fallback row for Slack while a normal Slack channel is frontmost is a bug in Task 11.

- [ ] **Step 6: Commit any fixes and record the verification**

If Steps 1-5 required source changes, commit them with a plain imperative message describing the fix. If nothing changed, there is nothing to commit — do not create an empty commit.

---

## Self-Review

Run against the spec with fresh eyes after the plan was complete.

### 1. Spec coverage

| Spec section | Requirement | Task |
|---|---|---|
| §4a | The six shapes + all supporting types, `public`/`Codable`/`Sendable`/`Equatable` | 1 |
| §4a | `Message.makeID` deterministic and order-independent | 1 |
| §4a | `CapturedContent.kind` defaults per shape | 1 |
| §4a | `CapturedContentEnvelope`, `currentSchemaVersion = 1`, deterministic bytes, `v >` current == NULL | 1 |
| §4a | `ParsedCapture.structured` optional; `CaptureEnvelope.structured` non-optional | 3 (envelope), 10 (parsed capture) |
| §4a | `envelope(…)` gains `structured:`; nil resolved in one place | 10 (argument), 3 (resolution) |
| §4a | `content == render(structured, .full)` when structured is set | 3 |
| §4a | `CaptureContentKind` keeps ten cases; `contentKind` stays authoritative | Global Constraints; asserted in 12, 15, 16 |
| §4b | `RenderStyle`, `ContentRenderer.render`, all six `.full` rules, block rules | 2 |
| §4b | `(From: You)(sent …)`, `(draft)`, `[user]` never rendered, multi-line indent | 2 |
| §4b | `.compact` = head/tail policy; `.mainOnly` = main + dialog | 2 |
| §4a/§4b | `CalendarEvent.notes` and its `Details: …` render line | 1, 2, 13 |
| §4b/§10 | `render(LegacyContentAdapter.adapt(s), .full) == s` byte-for-byte | 3 |
| §4c | `v10` adds two nullable `TEXT` columns; `currentIdentifier = "v10"`; no backfill | 8 |
| §4c | `LegacyContentAdapter.adapt(renderedContent:kind:)` | 3 |
| §4c | NULL / decrypt-fail / decode-fail all route through the adapter | 8 |
| §4d | `StructuredAccumulationResult`, the `merge` overload, per-shape semantics | 9 |
| §4d | Draft rules, terminal prefix-append, replace-on-shape-change, rendered bounding | 9 |
| §4d | `commitCapture` writes both columns and returns the delta; `CommitResult.committed` gains `delta:` | 9 |
| §4e | `Options` with the four budget values and the offscreen policy; `Result` | 5 |
| §4e | Traversal root not re-resolved; menus structurally excluded | 5 |
| §4e | Every role-model row, recursion stop, per-region text dedup, hidden/zero-frame/offscreen skips | 5 |
| §4e | Six region rules, window-relative coordinates, same-kind visual concatenation, `.unknown` never emitted | 6 |
| §4e | Focused element: deepest in-tree, caller fallback, secure ⇒ nil value, `selectedText` | 7 |
| §4e | Budgets, dialog never trimmed, unused share rolls into main, `truncated` | 7 |
| §4e | `AXNode` gains six attributes; conditional AX reads; old fixtures decode unchanged | 4 |
| §4e | `AXReader.focusedElementSnapshot(pid:)` | 4 |
| §4e | `DocumentExtraction.bodyText` kept, marked legacy | 5 |
| §4f | `SourceParser.parseStructured` with a nil default | 10 |
| §4f | The four dispatch rules incl. the fall-through behaviour change | 10 |
| §4f | Slack / Teams / WhatsApp → `.conversation` | 11 |
| §4f | Mail → `.conversation` via `MailRecord`, `.email` kept | 12 |
| §4f | Calendar / Fantastical → `.calendar`; five task apps → `.tasks` | 13 |
| §4f | Terminal → `.terminal`, segmentation per §7c, failure ⇒ one `command: nil` segment | 14 |
| §4f | `WebAppCaptureParser` → `.conversation` for chat hosts, `.generic` over the web area otherwise | 15 |
| §4f | Notes/Notion/Obsidian/Word/Pages/Discord/Messages (+ Outlook/Spark) → `.generic` v2 | 16 |
| §4g | MCP unchanged | 17 |
| §8 | Fallback is non-silent: `GenericPageExtractor.v2/fallback/<ParserTypeName>` in `capture_health_events.parser` | 10 |
| §8 | Extractor pure and total; zero regions treated as empty content | 5 |
| §8 | Additive nullable migration; unreadable payload behaves like NULL; same cipher and Keychain key | 8, Global Constraints |
| §8 | < 150 ms for 20_000 nodes; bounded new AX reads | 18, 4 |
| §8 | Privacy: secure field value never fetched, no new gates, no new destinations | 5, 7 (tests), Global Constraints |
| §9 | Every Phase A test listed in the spec's testing section | 1-18 (each spec'd assertion appears in the task that owns it) |
| §9 | Live verification ritual, no `tccutil reset` | 19 |
| §11 | Criteria 1, 2, 3, 6-partial, 9, 10 (the Phase A subset) | 1-19 |

**Gaps: none.** Two spec requirements land outside their nominal section and are called out where they do land:

- §11 criterion 4 (`capture_events`), criterion 5 (typing), criterion 7 (hourly agent), and criterion 8 (`AXQuery`) belong to Phases B, C and D and are correctly absent. Criterion 6's "capture summaries name the user's action" is Phase C; Phase A only supplies the delta it needs, which Task 9 produces under the exact names §5a specifies.
- §5a's `CaptureDelta` is defined and computed **here** rather than in Phase B, because §4d's `StructuredAccumulationResult` and `CommitResult.committed` both carry it and §5a itself says it is "computed inside `CaptureAccumulator.merge` (§4d), never recomputed elsewhere". Phase B consumes `Sources/MaxMiCore/CaptureDelta.swift` unchanged.

Two consequences of following the spec exactly are recorded so they are not mistaken for oversights: the `.document`/`.generic` replace-instead-of-accumulate change (Global Constraints), and Outlook/Spark going generic-v2 rather than `.conversation` because they expose no sender or date (Task 12).

### 2. Placeholder scan

Searched the plan for `TBD`, `TODO`, `implement later`, `fill in`, `appropriate error handling`, `handle edge cases`, `similar to Task`, and "write tests for the above". No hits. Every code step carries runnable code; every run step names the exact `swift test --filter <TestClass>` invocation and the expected result. The three places that say "if this assertion differs, print the value and paste the real one" are for golden strings derived from committed fixtures — the surrounding text pins what the assertion must remain (an exact equality, never weakened to `contains`).

### 3. Type consistency

Checked every name that crosses a task boundary:

- `CapturedContent`, `CapturedContentEnvelope.encode(_:)`/`.decode(_:)` — defined in Task 1, used with the same spelling in 3, 8, 9, 17.
- `ContentRenderer.render(_:style:)` and the per-item renderers `renderBlock`/`renderBlocks`/`renderMessage`/`renderTask`/`renderEvent`/`renderSegment` plus `regionOrder`/`regionHeader`/`formatTimestamp` — defined in Task 2, used in 3, 5, 7, 9, 10-16.
- `LegacyContentAdapter.adapt(renderedContent:kind:)` — one spelling in 3, 8, 10.
- `CaptureAccumulator.bound(_:to:)` — two overloads: `String` (internal, Task 2) and `CapturedContent` (public, Task 9). The parsers in 11-16 all use the `CapturedContent` one.
- `CaptureDelta.between(previous:merged:)`, `CaptureDelta.isSegmentPrefix(_:_:)` — Task 9 only; `isSegmentPrefix` is reused by `mergeSameShape` in the same task.
- `StructuredAccumulationResult.content`/`.rendered`/`.changed`/`.delta` — Task 9; `commitCapture` uses `.rendered` everywhere the old code used `accumulated.content`.
- `CommitResult.committed(versionID:contentHash:delta:)` — Task 9 defines it and lists all thirteen pattern-match sites.
- `Store.structuredOrLegacy(_:renderedContent:kind:)` — Task 8 defines, Task 9 uses.
- `LatestContextRecord.structured` — Task 8 defines, Task 17 reads through MCP.
- `GenericPageExtractor.extract(window:focusedElement:url:options:)` — signature fixed in Task 5 and never changed by 6 or 7; `Claim`/`BlockEntry`/`walk(…order:claims:)`/`assemble`/`trim`/`applyBudgets`/`resolveFocusedElement`/`classifyRegion`/`isSplitGroupSidebar`/`containsListLike`/`renderedSize` are all single-spelling.
- `AXNode` initializer parameter order `(… identifier:label:subrole:headingLevel:selected:placeholder:selectedText:hidden:)` — Task 4; every test helper in 5, 6, 7, 10-16, 18 uses that order.
- `AXReader.focusedElementSnapshot(pid:)` — Task 4; consumed by Phase B, referenced but not called in Phase A.
- `ParsedCapture(… offscreenPolicy:structured:)` and `resolvedStructured` — Task 10; every migrated parser in 11-16 passes `structured:` last.
- `CaptureDispatch.ParseResult.parsedByFallback(_:failedParser:)` — Task 10 defines it, `AppWiring` and the tests use the same labels.
- `NativeConversationExtraction.Extracted`, `MailParser.Extracted`, `StructuredEntityExtraction.Extracted`, `GenericV2Content.page`/`.lines` — each defined once, in Tasks 11, 12, 13, 16 respectively, and used only within their own task plus Task 15's reuse of `NativeConversationExtraction.message(fromLine:)`.
- `TerminalParser.segments(fromScrollback:)`, `promptPatterns`, `joinedOutput` — Task 14 only.
- `BrowserTabExtractor.primaryWebArea(in:windowTitle:engine:)`, `WebAppCaptureParser.messages(in:)` — Task 15 only.

No mismatches found.
