# MaxMi — M8: Structured Capture (typed captures, deltas, action-grounded summaries)

**Date:** 2026-09-06
**Status:** Design, decided. All decisions in §3-§7 are architect-final; §12 is the decisions log for every place the code contradicted the design brief (nothing was silently redesigned, nothing left open). Next step is the Codex review pass in §13.
**Milestone:** M8 — the *quality* milestone. M1-M5 built capture, M6 built synthesis + UI, M7 (team sharing) is permanently dropped. M8 fixes the thing that makes the whole stack feel dumb: captures are unstructured AX text dumps, so summaries describe the dump instead of the user, and the hourly agent builds todos on top of those weak summaries.
**North star:** exceed Minimi. Minimi has a typed four-shape parser contract and feeds its hourly review RAW versions with metadata; it does NOT do region detection, table-row joining, focused-element capture, or deltas. M8 adopts the typed contract and the raw-versions review shape, then adds the four things Minimi lacks.

## 1. What we're building

1. **A typed capture contract.** `CapturedContent` — a `Codable` enum of six shapes (document, conversation, tasks, calendar, terminal, generic) replacing "one blob of `String`". Every parser produces one; `versions.content` keeps a deterministic *rendering* of it so search, embeddings, and MCP are untouched.
2. **Generic flattener v2.** `GenericPageExtractor` replaces `DocumentExtraction.bodyText` for the fallback path: real roles, heading levels, list depth, joined table rows, region detection (main / sidebar / dialog / toolbar / nav / banner / footer), focused element, secure-field masking, per-region budgets.
3. **Deltas and events.** Every capture computes what actually changed (`CaptureDelta`) and records it in a new `capture_events` table alongside focus, navigation, dialog, and typing events.
4. **Typing capture without a keylogger.** `TypingObserver` diffs the *focused accessibility field's value* between captures. No `CGEventTap`, no system-wide keystroke tap.
5. **Prompts fed structure, not dumps.** Capture summaries are grounded in the delta + typed text; session summaries are grounded in a deterministic `ActivityTimeline` instead of concatenated evidence; the hourly agent gets raw compact versions + the timeline instead of summaries-of-summaries.
6. **An AX query DSL + anchored parsers.** `AXQuery` path expressions over `AXNode`, a `StructuredParser` v2 protocol with per-parser config, and rewritten anchored parsers for terminals, editors, chat apps, note apps, Finder, and the browser generic path.

**Success test:** after an hour of real work, the timeline reads `09:02–09:14 Warp (terminal ~/code/MaxMi): ran swift test ×3; last output ends "… 2 failures"; typed 3 commands` — not `Warp · you were working in a terminal`. Finder's window lands as sidebar/main/toolbar regions with real table rows, not one alphabet-soup paragraph. The hourly agent's todos cite concrete new content.

## 2. Background — the verified root causes

Every claim below was read out of the tree at `5c627e8`.

**Captures are dumps.** `Sources/MaxMiCapture/DocumentExtraction.swift:10-25` — `bodyText(in:maxCharacters:)` keeps only nodes whose `role` is `AXStaticText` or `AXTextArea`, sorts by `(frame.origin.y, frame.origin.x)`, and joins with `\n`. No roles, no hierarchy, no regions, no table-row joining, no focused element, no selection, no secure-field handling. `contentCap = 8000`. `GenericAXParser.swift:12` is a single call to it. `NotesParser.swift:8`, `NotionParser.swift:8`, `ObsidianParser.swift:8` call it directly; `StructuredNativeParsers.swift:196` (Word/Pages via `StructuredEntityExtraction.document`) and `:221` (Outlook/Spark via `.email`) call it too.

**No structured type exists.** `ParsedCapture` (`Sources/MaxMiCapture/SourceParser.swift:16`) and `CaptureEnvelope` (`Sources/MaxMiCore/CaptureEnvelope.swift:52`) carry `content: String` plus flat metadata (`sourceApp`, `sourceKey`, `sourceTitle`, `contentKind: CaptureContentKind`, `parserID`, `parserVersion`, `accumulationPolicy`, `offscreenPolicy`, `trigger`, `truncated`).

**The registry never falls through.** `ParserRegistry` is `[String: any SourceParser]` keyed on exact bundle ID (`ParserRegistry.swift`). `CaptureDispatch.parseDetailed` returns `.noContent` when a registered parser returns nil and `.failed` when it throws — the comment calls this "the no-silent-fallback rule". Browsers never reach the registry at all: `Sources/MaxMi/AppWiring.swift:1446-1477` branches on `ApplicationRegistry.browser(for:)` into `BrowserCapturePipeline.parse`.

**Deltas are computed then thrown away.** `CaptureAccumulator.merge(previous:incoming:policy:maxCharacters:)` (`CaptureEnvelope.swift`) returns `CaptureAccumulationResult{content, changed, addedItemCount}`; its only caller, `Sources/MaxMiStore/StoreAPI.swift:99`, uses `content` and discards the other two. `recordNovelFingerprints` (`StoreAPI.swift:39-41`) knows exactly which lines are new and returns a bare `Bool`. `CaptureTrigger` is persisted (`latest_contexts.trigger`, `capture_health_events.trigger`) and never reaches a prompt.

**Prompts see raw text and almost no metadata.** `ExtractPrompt.build(newContent:previousContent:sourceApp:sourceKey:)` (`Sources/MaxMiRelay/ExtractPrompt.swift:2`) gets four strings. `AgentPrompts.summarizeForDisplay(appLabel:evidence:maxEvidenceChars:)` (`Sources/MaxMiActivity/AgentPrompts.swift:95`) asks for "one concise second-person sentence… Keep it under 24 words" from raw text plus an app label. `DisplaySummarizer` defaults `maxEvidenceChars: 12_000` (`DisplaySummarizer.swift:9`) and `AgentPrompts.truncateEvidence` joins the raw evidence snapshots with `"\n\n"`. `HourlyAgent` consumes `AgentReviewInput{sessions: [ReviewSession(id, summary)], openItems: [(id, title)]}` — summaries of summaries; the store query is `SELECT id, summary_ciphertext, updated_at FROM activity_sessions WHERE summary_status='summarized'` (`AgentStore.swift:88-89`).

**Storage.** Schema is at `v9` (`Migrations.swift:4`, `currentIdentifier = "v9"`). `versions(id, thread_id, hour_bucket, content, content_hash, word_count, is_frozen, committed_at, extract_status, metadata)`; `latest_contexts` carries `content_kind`, `parser_id`, `trigger`, `display_summary_ciphertext`, `summary_prompt_version`, `summary_source_hash`; `activity_session_evidence.content_ciphertext` stores the raw `parsed.content` verbatim (`AppWiring.swift:1576-1582` → `ActivityStore.swift:52,80`). Encryption is `AESGCMFieldCipher: FieldCipher` with `encrypt(_:) throws -> String` / `decrypt(_:) throws -> String` and prefix `"enc:v1:"` (`Sources/MaxMiCore/FieldCipher.swift:12-18`); all ciphertext columns are `TEXT`.

**Gemini.** `EnvConfig` reads `~/Library/Application Support/MaxMi/.env` for `GEMINI_API_KEY`, `MAXMI_EXTRACT_MODEL` (default `gemini-flash-lite-latest`), `MAXMI_EMBED_MODEL` (`gemini-embedding-001`), `MAXMI_EMBED_DIMS` (1536). One `GeminiThrottle` is shared.

**Fact extraction is already at parity — Phase C is an improvement, not catch-up.** Live Minimi traffic shows `/api/memory/extract` sending `{previous_content: null (always), new_content, metadata: {source_app, source_key}}` and returning `{memories: [String]}` — 1-5 memories per call (median 3), 7-29 words each, third person naming the user by first name, atomic, mixing action facts ("Sudhanshu searched for X") with content facts. MaxMi's `ExtractPrompt` already produces exactly this shape and already passes a real `previousContent` (which Minimi never does). So §6c's delta-grounded extraction is MaxMi going **beyond** Minimi, and must not regress the existing third-person-with-first-name output format.

**Scale.** 506 tests, all XCTest (`func test…`; zero `import Testing`).

## 3. Goals / Non-goals

**Goals**
- Typed structured captures, losslessly renderable back to today's text.
- Summaries that describe user *actions*, grounded in deltas plus a chronological timeline.
- Parser coverage that is cheap to extend, via an AX query DSL instead of bespoke geometry per app.
- Typing captured through the focused-field value diff.

**Non-goals (explicit architect decisions — do not "improve" these)**
- **No system-wide keystroke tap.** No `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`, ever. Typing is only ever inferred from an accessibility field's value.
- **No PII/email redaction inside captured content** beyond the existing app + domain denylist (`Denylist.isSensitiveApp`, `isBlockedWebURL`, `isBlockedByUser`, `isBlocked`). Minimi does not redact either; parity was chosen deliberately.
- **The hourly todo agent's UI** and the future double-tap-Option todo panel are **M9**, out of scope here. M8 changes only what the agent is *fed*.
- **No reminders and no reminder slots.** Reminder scheduling arrives with **M9** (the todo panel), which will add the `agent_action_items` columns and the slot legend together. M8 neither stores nor mentions slots.
- **Team sharing (M7) stays permanently dropped.**
- **No OCR, no screenshots, no new capture modality.**
- No change to the MCP tool surface (`search_memory`, `list_active_threads`, `get_latest_context` keep their shapes).

## 4. Phase A — typed capture contract + generic flattener v2

### 4a. `CapturedContent` (new, `Sources/MaxMiCore/CapturedContent.swift`)

All types `public`, `Codable`, `Sendable`, `Equatable`. No name in this file collides with anything in `Sources/` today (verified).

```swift
public enum Authorship: Codable, Sendable, Equatable {
    case user
    case other(String)
    case unknown
}

public enum BlockType: Codable, Sendable, Equatable {
    case heading(level: Int)                       // clamped 1...6
    case paragraph
    case listItem(depth: Int)                      // 0-based nesting depth
    case label                                     // button/link/menu-item/tab/checkbox/image label
    case tableRow(cells: [String], selected: Bool)
    case input(placeholder: String?)               // text field / text area / combo box value
}

public struct Block: Codable, Sendable, Equatable {
    public let type: BlockType
    public let text: String
    /// Set by TypingObserver (Phase B) when this block came from the focused field the user typed into.
    public let authoredByUser: Bool                // default false
}

public enum RegionKind: String, Codable, Sendable, CaseIterable {
    case main, sidebar, navigation, toolbar, dialog, banner, footer, unknown
}

public struct Region: Codable, Sendable, Equatable {
    public let kind: RegionKind
    public let blocks: [Block]
}

public struct FocusedElement: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let value: String?          // nil when isSecure
    public let selectedText: String?
    public let isSecure: Bool
}

public struct GenericPage: Codable, Sendable, Equatable {
    public let regions: [Region]
    public let focused: FocusedElement?
    public let url: String?
}

public struct Document: Codable, Sendable, Equatable {
    public let title: String
    public let blocks: [Block]
    public let author: Authorship
    public let url: String?
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

    /// Deterministic and order-independent, so accumulation can union by identity.
    /// `ContentHash.sha256Hex("\(sender)\u{1F}\(timeString ?? "")\u{1F}\(text)").prefix(24)`
    public static func makeID(sender: String, timeString: String?, text: String) -> String
}

public struct Conversation: Codable, Sendable, Equatable {
    public let channel: String
    public let isGroup: Bool
    public let messages: [Message]
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
}

public struct CalendarEvent: Codable, Sendable, Equatable {
    public let title: String
    public let dateString: String
    public let start: Date?
    public let end: Date?
    public let organizer: String?
    public let location: String?
    public let hasConference: Bool
}

public struct TerminalSegment: Codable, Sendable, Equatable {
    public let command: String?       // nil when segmentation failed
    public let output: String
    public let isRunning: Bool
}

public struct TerminalSession: Codable, Sendable, Equatable {
    public let cwd: String?
    public let segments: [TerminalSegment]
}

public enum CapturedContent: Codable, Sendable, Equatable {
    case document(Document)
    case conversation(Conversation)
    case tasks([TaskItem])
    case calendar([CalendarEvent])
    case terminal(TerminalSession)
    case generic(GenericPage)

    /// The DEFAULT `CaptureContentKind` for this shape. Parsers may override
    /// (see §12 Q3): `.email` and `.webpage` are not derivable from the shape.
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
```

**Wire envelope.** Persisted JSON is wrapped so the shape can evolve without a column migration:

```swift
public struct CapturedContentEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let v: Int
    public let content: CapturedContent
}
```

Encoding uses a fixed `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes` and no date strategy override beyond `.iso8601`, so the bytes are deterministic (needed for hashing and golden fixtures). A decode of `v > currentSchemaVersion` is treated exactly like a NULL column: fall back to `LegacyContentAdapter`.

**`ParsedCapture` / `CaptureEnvelope` gain one field.**

- `ParsedCapture` gains `public let structured: CapturedContent?`, defaulting to `nil` in `init`. Optional, so the twenty-odd existing parser construction sites keep compiling unchanged; a migrated parser sets it, an unmigrated one leaves it nil.
- `CaptureEnvelope` gains `public let structured: CapturedContent` — **non-optional**. Everything downstream of dispatch (store, prompts, timeline) can therefore rely on it existing.
- `ParsedCapture.envelope(cleanSourceKey:parserID:trigger:truncated:)` gains a `structured:` argument and `CaptureDispatch` is the single place that resolves nil → `LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)` (§4f). `CaptureEnvelope.legacy(sourceApp:sourceKey:sourceTitle:content:)` does the same.
- When `structured` is non-nil, `content` is `ContentRenderer.render(structured, style: .full)`.

`CaptureContentKind` keeps all ten existing cases (`webpage, conversation, document, terminal, email, calendar, task, meeting, voiceNote, generic`) — it is pinned by the `latest_contexts.content_kind` CHECK constraint and by MCP. `ParsedCapture.contentKind` stays authoritative and defaults to `structured.kind`.

### 4b. `ContentRenderer` (new, `Sources/MaxMiCore/ContentRenderer.swift`)

```swift
public enum RenderStyle: Sendable, Equatable {
    case full
    case compact(maxChars: Int)
    case mainOnly(maxChars: Int)
}

public enum ContentRenderer {
    public static func render(_ content: CapturedContent, style: RenderStyle) -> String
}
```

Pure, total, deterministic — the same `CapturedContent` always renders to the same bytes. `.full` is what goes into `versions.content` and `latest_contexts.content_ciphertext`, so search, embeddings, MCP, and `message_fingerprints` keep working with no changes. `.compact` and `.mainOnly` exist only to feed prompts.

Rules, exhaustively:

| Shape | `.full` rendering |
|---|---|
| `.document` | `"# \(title)"`, blank line, then blocks. |
| `.conversation` | One line per message, matching Minimi's observed wire shape: `"(From: \(sender))(sent \(timeString)): \(text)"`. **`isUser` renders the sender as `"You"`, not `"[user]"`** — `[user]` is the internal `Authorship` marker only and never appears in rendered text. The `(sent …)` clause is omitted when `timeString` is nil; when `timeString` is nil but `timestamp` is set, format it as `"MMM d, HH:mm zzz"` in the local timezone. `isDraft` appends `" (draft)"` to the sender: `"(From: You (draft)): …"`. Multi-line `text` keeps its newlines, indented two spaces after the first line. |
| `.tasks` | One line per item: `"- [x] "` when `.completed`, `"- [ ] "` when `.open`, `"- "` when `.unknown`; then `title`; then ` (due \(dueString))`, ` [\(project)]`, ` #tag` for each tag, and `notes` indented two spaces on following lines. |
| `.calendar` | One line per event: `"\(dateString) — \(title)"`, then ` @\(location)`, ` / \(organizer)`, ` [conference]` when `hasConference`. |
| `.terminal` | Per segment: `"$ \(command)"` when `command != nil`, then the output verbatim, then `"… (running)"` when `isRunning`. Segments separated by a blank line. |
| `.generic` | Regions in a fixed order: `.main`, `.dialog`, then `.sidebar`, `.navigation`, `.toolbar`, `.banner`, `.footer`, `.unknown` — each non-main region preceded by a header line `"## Sidebar"`, `"## Dialog"`, `"## Navigation"`, `"## Toolbar"`, `"## Banner"`, `"## Footer"`, `"## Other"`. `.main` gets no header. `url` renders as a first line `"URL: \(url)"` when present. |

Block rendering (shared): `.heading(level: n)` → `String(repeating: "#", count: n) + " " + text`; `.paragraph` → `text`; `.listItem(depth: d)` → `String(repeating: "  ", count: d) + "- " + text`; `.label` → `text`; `.tableRow(cells:selected:)` → `cells.joined(separator: " | ")`, prefixed `"* "` when `selected`; `.input(placeholder:)` → `text` when non-empty, else `"«\(placeholder ?? "empty field")»"`.

`.compact(maxChars:)` = `.full` then bounded by `CaptureAccumulator`'s existing head/tail policy (keep `maxChars/3` from the head, `…`, the rest from the tail) so identity-bearing openings survive.
`.mainOnly(maxChars:)` = for `.generic`, only the `.main` and `.dialog` regions (no headers); for every other shape, identical to `.compact(maxChars:)`.

`ContentRenderer.render(structured, style: .full)` on a `LegacyContentAdapter`-produced value **must** return the original string byte-for-byte. This is a test (§10) and it is what makes the migration safe.

### 4c. Storage — migration `v10` (additive)

```sql
-- Migrations.swift: m.registerMigration("v10")
ALTER TABLE versions         ADD COLUMN structured_ciphertext TEXT;
ALTER TABLE latest_contexts  ADD COLUMN structured_ciphertext TEXT;
```

`TEXT`, not `BLOB` — `FieldCipher.encrypt` returns the `"enc:v1:"`-prefixed base64 `String`, and every other ciphertext column in the schema is `TEXT` (see §12 Q2). `Migrations.currentIdentifier` becomes `"v10"`. `content` continues to hold the rendered `.full` text; nothing existing changes shape.

**No backfill.** Rows written before v10 have `structured_ciphertext IS NULL`. Every reader routes NULL through:

```swift
public enum LegacyContentAdapter {
    /// One `.main` region of `.paragraph` blocks, one per non-empty line.
    public static func adapt(renderedContent: String, kind: CaptureContentKind) -> CapturedContent
}
```

It always returns `.generic(GenericPage(regions: [Region(kind: .main, blocks: …)], focused: nil, url: nil))` regardless of `kind`; `kind` is accepted so callers can pass it for future refinement and so the call reads honestly at the site. Reading path: `StoreAPI` decrypts `structured_ciphertext` with `decryptOrMarker`-equivalent handling (a decrypt failure, a JSON decode failure, and a NULL are all the same case) and falls back to `LegacyContentAdapter.adapt(renderedContent: <the decrypted content column>, kind: <content_kind column>)`.

Rollback = ignore the two new columns; v9 readers are unaffected because both are nullable.

### 4d. Kind-aware accumulation + delta

`CaptureAccumulator` gains a structured overload. The existing `merge(previous:incoming:policy:maxCharacters:) -> CaptureAccumulationResult` stays for `CaptureInput.legacyEnvelope` and its seven tests.

```swift
public struct StructuredAccumulationResult: Sendable, Equatable {
    public let content: CapturedContent
    public let rendered: String          // ContentRenderer.render(content, style: .full)
    public let changed: Bool
    public let delta: CaptureDelta       // §5a — never discarded
}

extension CaptureAccumulator {
    public static func merge(
        previous: CapturedContent?,
        incoming: CapturedContent,
        policy: CaptureAccumulationPolicy,
        maxCharacters: Int
    ) -> StructuredAccumulationResult
}
```

Merge semantics by shape (the incoming shape wins; a shape change is a replace):

- `.conversation` — union of `messages` by `Message.id`, preserving order: previous messages in their order, then incoming messages whose id is not already present. Drafts are special: at most one draft per `(sender, isUser)` survives and it is always the incoming one (a draft is a live edit, not history). Cap by `policy`: `.appendItems` and `.rollingText` keep the newest messages that fit `maxCharacters` of rendered output; `.replace` drops the previous list entirely.
- `.document` / `.generic` — replace with incoming.
- `.terminal` — append: if `incoming.cwd == previous.cwd` **and** the previous segment list is a prefix of the incoming one under `(command, output)` equality, keep previous and append the new tail segments; otherwise replace. `isRunning` is always taken from incoming.
- `.tasks` / `.calendar` — replace.

Bounding always applies `maxCharacters` to the *rendered* form, trimming whole blocks/messages/segments from the front (oldest first) — never mid-block.

`changed` is `previous != content`. `delta` is computed as specified in §5a. `StoreAPI.commitCapture` (`StoreAPI.swift:68`) calls the structured overload, writes `accumulated.rendered` where it writes `accumulated.content` today, writes the encrypted envelope into `structured_ciphertext` on both the `latest_contexts` upsert and the `versions` insert, and passes `accumulated.delta` back out. `CommitResult.committed` gains the delta:

```swift
public enum CommitResult: Equatable, Sendable {
    case deduplicated
    case committed(versionID: String, contentHash: String, delta: CaptureDelta)
}
```

### 4e. `GenericPageExtractor` (new, `Sources/MaxMiCapture/GenericPageExtractor.swift`)

Replaces `DocumentExtraction.bodyText` on the generic path. `DocumentExtraction.bodyText` itself is **kept** (Notes/Notion/Obsidian/Word/Pages/Outlook/Spark still call it until Phase D) but gains a doc comment marking it legacy.

```swift
public enum GenericPageExtractor {
    public struct Options: Sendable, Equatable {
        public var totalBudget: Int = 8_000          // == DocumentExtraction.contentCap today
        public var mainShare: Double = 0.70
        public var dialogShare: Double = 0.15
        public var restShare: Double = 0.15
        public var offscreenPolicy: OffscreenCapturePolicy = .visibleOnly()
    }
    public struct Result: Sendable, Equatable {
        public let page: GenericPage
        public let truncated: Bool
    }
    public static func extract(
        window: AXNode,
        focusedElement: AXNode?,
        url: String?,
        options: Options = Options()
    ) -> Result
}
```

**Traversal root.** The caller passes the window node that `AXReader.snapshotFrontmostWindow` already resolved via `kAXFocusedWindowAttribute → "AXMainWindow" → kAXWindowsAttribute.first` (`AXReader.swift:13-15, 32-34`). The extractor never re-resolves it and **never traverses an `AXMenuBar`, `AXMenuBarItem`, or `AXMenu` subtree** — menu content is structurally excluded, not filtered by text.

**Role model** (Minimi's `get-ax-text` model plus MaxMi's additions):

| Role / subrole | Emitted |
|---|---|
| `AXHeading` | `.heading(level:)` — level from `AXHeadingLevel`, default `2`, clamped `1...6` |
| `AXStaticText`, `AXParagraph` | `.paragraph` |
| `AXTextArea`, `AXTextField`, `AXSearchField`, `AXComboBox` | `.input(placeholder:)` carrying the node's `value`; placeholder from `AXPlaceholderValue` |
| subrole `AXSecureTextField` | `.input(placeholder: nil)` with text `"«secure field»"` — **the value is never read** |
| `AXListItem`, `AXTreeItem` | `.listItem(depth:)`, depth = count of ancestor list/outline containers |
| `AXRow`, `AXTableRow` | **one** `.tableRow(cells:selected:)`; cells = texts of descendant `AXCell`/`AXStaticText` in visual `(y, x)` order, adjacent duplicates dropped; `selected` from `AXSelected` |
| `AXButton`, `AXLink`, `AXMenuItem`, `AXCheckBox`, `AXRadioButton` (incl. subrole `AXTabButton`), `AXImage` | `.label` from `title ?? label ?? value` |
| `AXScrollBar`, `AXSplitter`, `AXGrowArea` | skipped entirely (subtree included) |

A node that emits text **stops recursion** into its own children (Minimi's rule — it is what prevents a paragraph and its five text runs all appearing). Within one region, exact-text duplicates are dropped by a `Set` (first occurrence wins, order preserved). Nodes with `AXHidden == true`, or a `frame` of zero width or height, are skipped. A node whose frame lies entirely outside the window frame is skipped unless `options.offscreenPolicy.mode == .accessibilityScroll`.

**Region detection.** Evaluated top-down; the first rule that matches a node claims that node's entire subtree as one region. Frames are compared in **window-relative** coordinates — `child.frame.minX - window.frame.minX` — because `AXFrame` is global screen coordinates (a bug we have already been bitten by; see `project_maxmi_ax_capture`).

1. `role ∈ {AXSheet, AXDialog, AXPopover}` or `subrole ∈ {AXDialog, AXSystemDialog}` → `.dialog`
2. `role == AXToolbar` → `.toolbar`
3. `subrole == AXLandmarkMain` → `.main`; `AXLandmarkNavigation` → `.navigation`; `AXLandmarkComplementary` → `.sidebar`; `AXLandmarkBanner` → `.banner`; `AXLandmarkContentInfo` → `.footer`
4. `identifier` or `label` case-insensitively contains `"sidebar"` or `"source list"` → `.sidebar`
5. Split-group heuristic: inside an `AXSplitGroup`, a **direct child** whose window-relative width is `< 0.35 × window.frame.width`, whose window-relative `minX` is within `0.05 × window.frame.width` of the left edge, and which contains an `AXOutline`, `AXList`, or `AXTable` descendant → `.sidebar`
6. Everything else → `.main`

Regions of the same kind are concatenated in visual `(y, x)` order of their claiming node. `.unknown` is produced only by `LegacyContentAdapter` consumers and by a decode of a future schema version; the extractor never emits it.

**Focused element.** Preferred source is the deepest node in the window tree with `focused == true`. When the tree has none, the caller supplies `focusedElement` from a new shallow read:

```swift
// AXReader.swift
public static func focusedElementSnapshot(pid: pid_t) -> AXNode?   // AXFocusedUIElement, maxDepth: 1
```

`FocusedElement.isSecure` is `subrole == "AXSecureTextField"`; when true, `value` is `nil`. `selectedText` comes from `AXSelectedText`.

**Budgets.** `main` gets `totalBudget × mainShare`, `dialog` gets `× dialogShare`, all other regions share `× restShare` proportionally to their unbounded rendered size. Unused share rolls into `main`. Trimming removes whole blocks from the **end** of each region's block list — except `.dialog`, which is never trimmed (a dialog is short and is usually the single most important thing on screen; if a dialog exceeds its share, it takes the space from `main`). `Result.truncated` is true when any block was dropped.

**AX attribute additions (Phase A, `AXReader.swift`).** Region detection and the role model need attributes `AXReader` does not read today. `AXNode` gains:

```swift
public let subrole: String?           // kAXSubroleAttribute
public let headingLevel: Int?         // "AXHeadingLevel"
public let selected: Bool             // kAXSelectedAttribute, default false
public let placeholder: String?       // kAXPlaceholderValueAttribute
public let selectedText: String?      // kAXSelectedTextAttribute
public let hidden: Bool               // "AXHidden", default false
```

All are decoded with `decodeIfPresent` and default so the eleven existing JSON fixtures still decode unchanged. `subrole`, `selected`, and `hidden` are fetched for every node (three extra `AXUIElementCopyAttributeValue` calls). `headingLevel` is fetched only when `role == "AXHeading"`; `placeholder` and `selectedText` only when `role ∈ {AXTextArea, AXTextField, AXSearchField, AXComboBox}`. `AXDescription` is already read and folded into `label` (`AXReader.swift:75`) — M8 does not separate it (see §12 Q1). Phase D adds `domClassList` and `domIdentifier`.

### 4f. Parser migration in Phase A

`SourceParser` gains a second requirement with a default:

```swift
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
    /// The structured shape, or nil = NOT_HANDLED.
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent?
}

public extension SourceParser {
    func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? { nil }
}
```

**Migrated parsers** implement `parseStructured` as the single source of truth and reduce `parse` to a thin wrapper that renders it — so there is exactly one AX walk. **Unmigrated parsers** implement only `parse` and are handed a `LegacyContentAdapter` shape. `CaptureDispatch.parseDetailed` composes:

1. Registered parser exists → call `parseStructured`. Non-nil → call `parse` for keys/policies and attach the structured value, re-deriving `content` as `ContentRenderer.render(structured, .full)`.
2. `parseStructured` nil but `parse` non-nil → attach `LegacyContentAdapter.adapt(renderedContent:kind:)`.
3. Both nil, or `parse` threw → **fall through to `GenericPageExtractor`.** This reverses the current "no-silent-fallback" rule, which returns `.noContent` / `.failed` and stores nothing. It is a deliberate behaviour change: a broken or over-narrow parser must degrade to a worse capture, not to no capture. It is made non-silent by the health-ledger rule in §8.
4. No registered parser → `GenericPageExtractor` (was `GenericAXParser`).

Phase A migration table:

| Parser | Phase A target | Notes |
|---|---|---|
| `SlackParser`, `TeamsParser`, `WhatsAppParser` (`NativeConversationExtraction`) | `.conversation` | sender/body already separated; `channel` from the existing key derivation, `isGroup` from the existing header semantics |
| `MailParser`, `OutlookParser`, `SparkParser` | `.conversation` | `channel` = subject; one `Message` per `MailRecord` (`From`/`Date`/body already parsed). `contentKind` stays `.email` |
| `CalendarParser`, `FantasticalParser` | `.calendar` | |
| `RemindersParser`, `MicrosoftToDoParser`, `TodoistParser`, `OmniFocusParser`, `TogglParser` | `.tasks` | |
| `TerminalParser` | `.terminal` | segmentation per §7; failure → one segment, `command: nil` |
| `WebAppCaptureParser` | `.conversation` for conversation hosts; `.generic` otherwise | generic path = `GenericPageExtractor` over the `AXWebArea` subtree with `url` set. `contentKind` stays `.webpage` / `.email` |
| `NotesParser`, `NotionParser`, `ObsidianParser`, `WordParser`, `PagesParser`, `DiscordParser`, `MessagesParser` | `.generic` via v2 | real parsers land in Phase D |

### 4g. MCP — unchanged

`search_memory`, `list_active_threads`, `get_latest_context` keep their request and response shapes and keep reading `content` (`Sources/MaxMiMCP/Tools.swift:23,32,40`). Exposing `structured` over MCP is explicitly out of scope.

## 5. Phase B — deltas, events, focused-field typing diff

### 5a. `CaptureDelta` (new, `Sources/MaxMiCore/CaptureDelta.swift`)

```swift
public struct CaptureDelta: Codable, Sendable, Equatable {
    public let addedBlocks: [Block]
    public let addedMessages: [Message]
    public let addedSegments: [TerminalSegment]
    public let removedCount: Int
    public let addedChars: Int
    public let removedChars: Int
    public let isFirstCapture: Bool

    public var isEmpty: Bool {
        addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty
            && removedCount == 0
    }
    public static let empty: CaptureDelta
}
```

Exactly one of the three `added*` arrays is non-empty for any given delta; the others are empty (the shape is a struct rather than an enum so the encrypted JSON payload stays flat and stable). Computed inside `CaptureAccumulator.merge` (§4d), never recomputed elsewhere:

- `.conversation` → `addedMessages` = incoming messages whose `id` is absent from `previous`, in incoming order. `removedCount` = previous messages absent from the merged result (only possible under `.replace`).
- `.document` / `.generic` → `addedBlocks` = blocks of the incoming `.main` region whose `text` is absent from the previous `.main` region's text set, in incoming order. Non-main regions are ignored for delta purposes (chrome churns constantly and would drown the signal); a `.dialog` region appearing is reported as a `dialog` event instead.
- `.terminal` → `addedSegments` = the appended tail (empty on a replace).
- `.tasks` / `.calendar` → `addedBlocks` empty; `addedChars`/`removedChars` reflect the rendered size change so "something changed" is still visible.

`addedChars` / `removedChars` are rendered-character counts. `isFirstCapture` is `previous == nil`.

### 5b. `capture_events` — migration `v11`

```sql
-- Migrations.swift: m.registerMigration("v11")
CREATE TABLE capture_events (
  id                 TEXT PRIMARY KEY,
  thread_id          TEXT REFERENCES threads(id) ON DELETE CASCADE,
  version_id         TEXT REFERENCES versions(id) ON DELETE SET NULL,
  at_ms              INTEGER NOT NULL,
  kind               TEXT NOT NULL CHECK(kind IN ('focus','navigation','content_delta','typing','dialog')),
  trigger            TEXT NOT NULL,
  payload_ciphertext TEXT,
  hour_bucket        INTEGER NOT NULL
);
CREATE INDEX idx_capture_events_at     ON capture_events(at_ms DESC, id DESC);
CREATE INDEX idx_capture_events_thread ON capture_events(thread_id, at_ms DESC);
```

`thread_id` is **nullable** because a `focus` event precedes any thread for that window (§12 Q4). `id` is `Ident.uuidv7(nowMs:)`. `trigger` is `CaptureTrigger.rawValue`, or `"unknown"` for events not born of a capture attempt. `hour_bucket` is `HourBucket.bucket(forMs: at_ms)`. `PRAGMA foreign_keys = ON` is already enabled (M6a).

New store type `Sources/MaxMiStore/CaptureEventStore.swift`:

```swift
public enum CaptureEventKind: String, Sendable, Codable, CaseIterable {
    case focus = "focus"
    case navigation = "navigation"
    case contentDelta = "content_delta"
    case typing = "typing"
    case dialog = "dialog"
}

extension Store {
    public func recordCaptureEvent(
        kind: CaptureEventKind,
        threadID: String?,
        versionID: String?,
        trigger: CaptureTrigger,
        payload: some Encodable & Sendable,
        nowMs: EpochMs
    ) throws
}
```

Payload shapes, JSON-encoded then passed through `cipher.encrypt` into the single `payload_ciphertext` column:

| kind | payload |
|---|---|
| `content_delta` | the `CaptureDelta` |
| `focus` | `{ "bundleID": String, "appLabel": String, "windowTitle": String? }` — encrypted because a window title is content |
| `navigation` | `{ "fromURL": String?, "toURL": String }` |
| `typing` | `{ "insertedText": String, "fieldRole": String, "fieldIdentifier": String?, "totalLength": Int, "replaced": Bool }` |
| `dialog` | `{ "blocks": [Block] }` — the new `.dialog` region's blocks, rendered form capped at 1_000 chars |

Write sites, all inside `finishCapture` (`AppWiring.swift:1403`) except `focus`:

- `content_delta` — one per capture whose `CommitResult` is `.committed` **and** whose `delta.isEmpty == false`. A `.deduplicated` commit writes nothing.
- `focus` — from the existing `FocusObserver.onFocusChanged` closure (`onFocusChanged: (@MainActor (AppInfo, _ isCapturable: Bool, pid_t) -> Void)?`, `FocusObserver.swift:103`), `threadID: nil`, `trigger: .unknown`.
- `navigation` — when `trigger == .browserNavigation`, carrying the previous `latest_contexts` URL for that thread as `fromURL`.
- `dialog` — when the merged `.generic` content has a `.dialog` region and the previous one did not.
- `typing` — from `TypingObserver` (§5c), off the capture path.

**Retention.** There is no age-based sweeper anywhere in MaxMi today (§12 Q5), so M8 adds one narrowly, mirroring `CaptureHealthStore`'s trim-on-write:

```swift
public enum CaptureEventRetention {
    public static let days = 30
}
```

`recordCaptureEvent` deletes `WHERE at_ms < nowMs - days * 86_400_000` at most once per hour, gated on a `settings` key `capture_events_last_trim_at` so a delete does not run on every capture. `capture_events` is additionally deleted by `MemoryDataControls.pruneMemory(olderThan:)` (`at_ms < ?`) and by `deleteAllMemory()`, and its row count is reported in `MemoryDeletionResult`.

30 days, not 14: events are derived signals rather than memories, and the Activity window may reasonably look back a month. Memory retention itself is untouched (still Forever by default). Because this is the only thing MaxMi deletes without being asked, `CapturePrivacyView` gains one sentence of copy next to the retention picker: **"Activity events are kept for 30 days."**

### 5c. `TypingObserver` (new, `Sources/MaxMiCapture/TypingObserver.swift`)

**No `CGEventTap`. No global event monitor.** The only input is the accessibility value of the focused field.

```swift
public struct FocusedFieldKey: Hashable, Sendable {
    public let bundleID: String
    public let windowID: UInt32?          // AppInfo.windowID; falls back to windowTitle when nil
    public let windowTitle: String?
    public let role: String
    public let identifier: String?
}

public struct TypingEvent: Sendable, Equatable, Codable {
    public let insertedText: String
    public let fieldRole: String
    public let fieldIdentifier: String?
    public let totalLength: Int
    public let replaced: Bool
}

public actor TypingObserver {
    public static let debounceMs = 800
    public static let maxTrackedFields = 32     // LRU, in memory only, never persisted
    public static let maxReplacedTailChars = 500

    public init(isEligible: @escaping @Sendable (String) -> Bool)

    /// Returns an event when the focused field's value changed meaningfully, else nil.
    public func observe(_ focused: FocusedElement, key: FocusedFieldKey, nowMs: EpochMs) -> TypingEvent?
}
```

Triggered on every capture and, additionally, on `kAXValueChangedNotification` for the focused element — which `FocusObserver` **already registers** (`FocusObserver.swift:92`) and classifies as `.webContentChanged` for browsers or `.accessibilityChanged` otherwise (`:37-44`). No new notification plumbing is needed; the observer only needs the classified callback plus a fresh `focusedElementSnapshot`. Debounce is 800 ms **per key**.

Diff algorithm (pure, testable, no library):

```
p = length of the common prefix of old and new
s = length of the common suffix of old and new, capped so that p + s <= min(old.count, new.count)
inserted = new[p ..< new.count - s]
removed  = old[p ..< old.count - s]

if removed.isEmpty && !inserted.isEmpty  -> TypingEvent(insertedText: inserted, replaced: false)
if !removed.isEmpty                      -> TypingEvent(insertedText: String(new.suffix(500)), replaced: true)
otherwise                                -> nil
```

This covers the two cases the architect specified — new value extends old (pure append is `s == 0`), and a single contiguous insertion mid-string — and treats paste, replace, select-all-retype, and clear uniformly as `replaced: true` carrying the new tail.

**Never** emits when `focused.isSecure`, when `Denylist.isSensitiveApp(bundleID)`, when the app is user-excluded, or unless the storage consent gate is satisfied: `ActivityStore.activityConsent() == .granted` **and** `activityEnabled() == true` (`ActivityStore.swift:25-27, 253, 273`). Nothing is persisted between launches; the LRU is in-actor memory.

**Typed text also flows into the structured content**, so the next capture's summary can see it:

- `.conversation` — the composer field's value becomes `Message(id: "draft:\(fieldIdentifier ?? role)", sender: "You", text: value, timestamp: nil, timeString: nil, isUser: true, isDraft: true)`, appended last. Per-parser configs (§7) name the composer anchor; on the generic path the composer is the focused `AXTextArea`/`AXTextField` that is not a descendant of the message-list node.
- `.document` / `.generic` — the block derived from the focused element's value is emitted with `authoredByUser: true`.

### 5d. `TimelineBuilder` (new, `Sources/MaxMiActivity/TimelineBuilder.swift`)

`MaxMiActivity` depends only on `MaxMiCore` (`Package.swift`), so it must not touch GRDB. It follows the existing repository-protocol pattern (`ActivitySummaryRepository`, `AgentRepository`), with the concrete adapter in `Sources/MaxMi/StoreTimelineRepository.swift`.

```swift
public struct TimelineEntry: Codable, Sendable, Equatable {
    public let startMs: EpochMs
    public let endMs: EpochMs
    public let appLabel: String
    public let threadID: String?
    public let sourceTitle: String?
    public let url: String?
    public let kind: CaptureContentKind
    public let cwd: String?               // terminal only
    public let deltaSummary: String?      // <= 200 chars of the added content, rendered
    public let newItemCount: Int          // addedMessages / addedBlocks / addedSegments count
    public let typedCount: Int            // number of typing events in this entry
    public let typedSample: String?       // <= 120 chars from the last typing event
}

public struct ActivityTimeline: Codable, Sendable, Equatable {
    public let fromMs: EpochMs
    public let toMs: EpochMs
    public let entries: [TimelineEntry]
}

public protocol TimelineRepository: Sendable {
    func appVisits(fromMs: EpochMs, toMs: EpochMs) throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)]
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent]
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta]
}

/// One decrypted `capture_events` row, shape-agnostic.
public struct TimelineRawEvent: Sendable, Equatable {
    public let kind: CaptureEventKind
    public let atMs: EpochMs
    public let threadID: String?
    public let trigger: CaptureTrigger
    public let delta: CaptureDelta?          // kind == .contentDelta
    public let typing: TypingEvent?          // kind == .typing
    public let toURL: String?                // kind == .navigation
}

/// Per-thread metadata from `threads` + `latest_contexts`.
public struct TimelineThreadMeta: Sendable, Equatable {
    public let sourceApp: String
    public let sourceTitle: String?
    public let kind: CaptureContentKind
    public let url: String?
    public let cwd: String?
}

public struct TimelineBuilder: Sendable {
    public init(repo: any TimelineRepository)
    public func build(fromMs: EpochMs, toMs: EpochMs) throws -> ActivityTimeline
    public static func render(_ timeline: ActivityTimeline, budgetChars: Int) -> String
}
```

`build` is deterministic: read `activity_app_visits` in the window, attach every `capture_events` row whose `at_ms` falls inside a visit, resolve thread metadata from `latest_contexts` + `threads` (`source_title`, `content_kind`, URL from the rendered `.generic` `url`), sort chronologically by `startMs`, and coalesce adjacent entries with the same `threadID` (or the same `bundleID` when `threadID` is nil) into one. It **never** embeds a full dump — only per-visit metadata plus the first 200 characters of that visit's added content.

`render` emits one line per entry, times formatted `HH:mm` in the local timezone:

```
09:02–09:14 Warp (terminal ~/code/MaxMi): ran `swift test` ×3; last output ends "… 2 failures"; typed 3 commands
09:14–09:20 Chrome "sqlite-vec KNN docs" (https://…): read; new since last: 4 paragraphs
09:20–09:23 Slack #maxmi-dev (group): 2 new msgs from Ana; you drafted "…"
```

Template, in order, omitting any absent part: `"\(HH:mm)–\(HH:mm) \(appLabel)"`, then ` (\(kind) \(cwd))` for terminals or ` "\(sourceTitle)"` otherwise, then ` (\(url))` truncated to 60 chars, then `": "`, then the semicolon-joined facts: the delta summary, `"new since last: \(newItemCount) \(unit)"` where unit is `paragraphs`/`msgs`/`segments`/`rows` by shape, and `"typed \(typedCount) …"` with `typedSample` in quotes when present. When `budgetChars` is exceeded, whole entries are dropped **oldest first** and a leading `"(earlier activity omitted)"` line is added.

## 6. Phase C — prompts and the hourly agent fed with structure

### 6a. `CaptureDisplaySummarizer` — per-capture summary

`CaptureSummaryCandidate` (`CaptureDisplaySummarizer.swift:4`) gains `url: String?`, `capturedAt: EpochMs`, `trigger: CaptureTrigger`, `structured: CapturedContent`, `delta: CaptureDelta`, `typedText: String?`. `CaptureDisplaySummaryRepository.captureContextsNeedingSummary` and `CaptureSummaryStore.PendingCaptureSummary` gain the same fields, sourced from `latest_contexts` (`structured_ciphertext`, `trigger`, `captured_at`) and from the newest `content_delta` / `typing` rows in `capture_events` for that thread.

`CaptureDisplaySummarizer.summaryInput(for:)` (`:124`) is replaced by a fixed four-part assembly:

```
CONTEXT
app: <appLabel>
window: <sourceTitle ?? "">
url: <url ?? "">
kind: <contentKind.rawValue>
capturedAt: <ISO8601 local>
trigger: <trigger.rawValue>

<beginFence>
ON SCREEN (main):
<ContentRenderer.render(structured, .mainOnly(maxChars: 3_000))>

NEW SINCE LAST CAPTURE:
<rendered delta, <= 1_500 chars>

USER TYPED:
<typedText, <= 500 chars>
<endFence>
```

The `NEW SINCE LAST CAPTURE:` and `USER TYPED:` sections are omitted entirely when empty (never emitted as a header with nothing under it). Nonce fencing is unchanged — the same `let nonce = UUID().uuidString` / `beginFence` / `endFence` mechanism as `AgentPrompts.swift:10-13`, with the same marker-stripping sanitiser applied to every interpolated value.

The prompt builder is a **new** function, `AgentPrompts.summarizeCaptureForDisplay(...)`. It does not reuse `summarizeForDisplay`, which §6b repurposes for sessions, and it **replaces** `summarizeRecentConversationForDisplay` (`AgentPrompts.swift:157-161`), which is deleted. It has two instruction variants selected on `structured`:

**Non-conversation** (document / generic / terminal / tasks / calendar):

> Write one second-person sentence, at most 24 words, naming the user's ACTION — what they are reading, writing, replying to, running, or reviewing. Ground it ONLY in NEW SINCE LAST CAPTURE and USER TYPED when either is present; use ON SCREEN only when both are absent. Never mention interface elements, buttons, tabs, sidebars, or the app's chrome. Return only the sentence.

**Conversation** — matching the style observed from Minimi's `/api/activity/detect-conversation`, which returns e.g. *"Saran informed you that they cannot listen right now and will do so once home."* The input for this variant is **only the new messages** from `CaptureDelta.addedMessages` (rendered per §4b), plus `channel`, `isGroup`, and the app label. The `ON SCREEN (main)` section is omitted entirely — the whole transcript is never sent for a conversation summary.

> Write one or two sentences, at most 45 words total, about the newest messages only. Refer to other people in the third person by name and to the user as "you". State the concrete request, reply, decision, or follow-up. Do not say the user is "working on" or "reading" anything. Do not mention interface elements. Do not infer anything absent from the messages. Return only the sentences.

When the model returns empty, a refusal, or only chrome, the summarizer does **not** ask again — it writes the locally produced fixed string:

```swift
// Sources/MaxMiCore/CaptureDisplaySummaryFormat.swift
public static func fallback(app: String, title: String?) -> String   // "Viewing <app>: <title>", or "Viewing <app>" when title is nil/empty
```

This string is generated locally and never requested from the model (no such string exists in `Sources/` today; §12 Q7).

**Prompt versioning.** `CaptureDisplaySummaryFormat.standard` becomes `"capture-display-v3-structured"` and `.recentConversation` becomes `"capture-display-v4-recent-conversation"`. `promptVersion(sourceApp:contentKind:)` (`CaptureDisplaySummaryFormat.swift:10-17`) currently returns `recentConversation` only for `sourceApp == "WhatsApp" && contentKind == .conversation`; it now returns it for **every** `contentKind == .conversation` regardless of app, since the conversation variant is no longer WhatsApp-specific. `CaptureSummaryStore.captureContextsNeedingSummary`'s invalidation predicate (`CaptureSummaryStore.swift:36`, today `AND coalesce(c.summary_prompt_version, '') <> ?` gated on `t.source_app='WhatsApp'`) is generalised to compare against `CaptureDisplaySummaryFormat.promptVersion(sourceApp:contentKind:)` for **every** row, so all cached summaries regenerate lazily.

### 6b. `DisplaySummarizer` — per-session summary

`PendingSession.evidence: [String]` (`ActivityGenerationRelay.swift:4`) is replaced by `timelineText: String`, built by `TimelineBuilder.render` over `[session.startedAt, session.endedAt ?? lastActivityAt]` with `budgetChars: 6_000`. `ActivityGenerationRelay.summarizeSession(appLabel:evidence:)` becomes `summarizeSession(appLabel:timelineText:)`; `AgentPrompts.summarizeForDisplay(appLabel:evidence:maxEvidenceChars:)` becomes `summarizeForDisplay(appLabel:timelineText:maxChars:)` and `AgentPrompts.truncateEvidence` is deleted. `DisplaySummarizer.init`'s `maxEvidenceChars: Int = 12_000` becomes `maxTimelineChars: Int = 6_000` (and the two `12_000` call sites at `AppWiring.swift:213,216`).

Instruction:

> Write one or two second-person sentences describing what the user worked on during this period and any outcome they reached. Follow the timeline's chronological order. Name concrete topics, files, commands, or people. Never mention interface elements. Return only the sentences.

`activity_session_evidence` keeps being written (`AppWiring.swift:1576-1582`) — it is the crash-safe provenance record and the M6a "why am I seeing this?" disclosure depends on it — but it is **no longer sent to any model**. Mark it for removal in a later cleanup once provenance moves to `capture_events`. Bump the `promptVersion: "v1"` literal at `Sources/MaxMi/StoreActivitySummaryRepository.swift:35` to `"v2-timeline"` so `activity_sessions.prompt_version` records the change (§12 Q8).

### 6c. `ExtractPrompt` — facts from the delta

`ExtractPrompt.build` gains a metadata parameter:

```swift
public struct ExtractMetadata: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let title: String?
    public let url: String?
    public let kind: CaptureContentKind
    public let capturedAt: EpochMs
}

static func build(newContent: String, previousContent: String?, metadata: ExtractMetadata) -> String
```

`newContent` becomes the **rendered delta** (the primary text); `previousContent` becomes `ContentRenderer.render(previousStructured, .compact(maxChars: 2_000))` as context only. The instruction adds one line: *"Extract facts ONLY from the CURRENT snapshot, which contains only what is new since the previous one."* Facts stay third-person, storage semantics unchanged.

There is **no** `rewriteForDisplay` step. Minimi has one and it truncates; MaxMi's display summaries are already second-person, so the step is explicitly out of scope.

Ripple, all of which must change together: `MemoryRelay.extract(newContent:previousContent:sourceApp:sourceKey:)` (`Sources/MaxMiCore/Protocols.swift:4`) → `extract(newContent:previousContent:metadata:)`; `PipelineVersion` (`Protocols.swift:28`) gains the metadata fields plus the rendered delta; `StoreAPI.pendingWork` populates them; `CapturePipeline.process` (`Sources/MaxMiCore/CapturePipeline.swift`) passes them; `GeminiClient.swift:50` and `HostedRelayClient.swift:83` are the two `ExtractPrompt.build` call sites.

### 6d. `HourlyAgent` — raw versions, Minimi's review shape

`AgentReviewInput` (`HourlyAgent.swift:14`) is replaced. Summaries-of-summaries are gone.

```swift
public struct ReviewVersion: Sendable, Codable, Equatable {
    public let threadID: String
    public let sourceApp: String
    public let sourceTitle: String?
    public let sourceKey: String
    public let kind: CaptureContentKind
    public let wordCount: Int
    public let committedAt: EpochMs
    public let compactContent: String     // ContentRenderer.render(structured, .compact(maxChars: 2_000))
    public let deltaSummary: String?      // rendered delta, <= 400 chars
    public let deltaChars: Int            // trimming priority
}

public struct ReviewOpenItem: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let details: String?
    public let sourceApp: String?
    public let createdAt: EpochMs
}

public struct AgentReviewInput: Sendable {
    public let runID: String
    public let versions: [ReviewVersion]
    public let timelineText: String        // TimelineBuilder.render over the run window
    public let openItems: [ReviewOpenItem]
    public let localTimeISO: String
    public let timeRange: (fromMs: EpochMs, toMs: EpochMs)
}
```

Store side: `AgentStore.claimNextAgentRun(maxSessions:leaseMs:nowMs:)` becomes `claimNextAgentRun(maxVersions:leaseMs:nowMs:)` and `AgentPage{runID, summaries, sourceIDs, openItems}` becomes `AgentPage{runID, versions: [ReviewVersion], openItems: [ReviewOpenItem], fromMs, toMs}`, selecting from `versions` joined to `threads` and `latest_contexts` over the cursor window (`agent_runs.input_from`/`input_to`) rather than from `activity_sessions`. The durable cursor, the single-`running`-run unique index, and the lease all stay exactly as M6b built them.

**Budget:** total untrusted input 40_000 chars — the existing `AgentPrompts.maxTotalUntrustedChars = 40_000`. When over budget, drop versions **smallest `deltaChars` first** (prefer the versions where the most changed), never truncate the timeline below 4_000 chars, and never drop an open item.

Output ops are unchanged: `[AgentOpDTO]` with `op ∈ {"create","update","resolve"}` (`HourlyAgent.swift:36`), validated by `StoreAgentRepository.validateAndMap` into `AgentOp.create/update/resolve` (`AgentStore.swift:49-53`). The nonce fences and all four never-resolve rules (`AgentPrompts.swift:53-56`) plus the DB-level `status == 'open'` guard (`AgentStore.swift:240-246`) stay verbatim. No reminder slot legend is sent: `agent_action_items` has no reminder columns and M8 adds none (§3 Non-goals, §12 Q9).

`agent_runs.prompt_version` is currently declared but never written (§12 Q10); M8 starts writing `"agent-review-v2-versions"` into it on run completion.

## 7. Phase D — AX query DSL + anchored parsers

### 7a. `AXQuery` (new, `Sources/MaxMiCapture/AXQuery.swift`)

`AXNode` gains two web-only attributes, read by `AXReader` only when an ancestor `AXWebArea` was seen: `domClassList: [String]?` (`AXDOMClassList`) and `domIdentifier: String?` (`AXDOMIdentifier`).

Grammar over a path string:

| Token | Meaning |
|---|---|
| `/Role` | direct child with that role |
| `//Role` | any descendant with that role |
| `*` | any role |
| `[attr="v"]` | exact match |
| `[attr^="p"]` | prefix match |
| `[attr*="s"]` | substring match |
| `[n]` | zero-based index among the matches produced so far by that step |

Attributes: `role`, `subrole`, `title`, `description` (an alias of `label`, since `AXDescription` is folded into `label` — §12 Q1), `label`, `value`, `identifier`, `domId`, `domClass` (matches if **any** entry of `domClassList` satisfies the operator). Predicates on one step are ANDed. Matching is case-sensitive except `domClass`, which is case-insensitive.

```swift
public enum AXQuery {
    public static func find(_ path: String, in node: AXNode) -> AXNode?
    public static func findAll(_ path: String, in node: AXNode) -> [AXNode]

    public enum Matchers {
        public static func hasRole(_ r: String) -> (AXNode) -> Bool
        public static func hasIdentifierPrefix(_ p: String) -> (AXNode) -> Bool
        public static func hasClass(_ c: String) -> (AXNode) -> Bool
        public static func hasTitleContaining(_ s: String) -> (AXNode) -> Bool
        public static func and(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool
        public static func or(_ ms: ((AXNode) -> Bool)...) -> (AXNode) -> Bool
        public static func not(_ m: @escaping (AXNode) -> Bool) -> (AXNode) -> Bool
    }

    /// Translation-invariant: sorts by (frame.minY, frame.minX) relative to `origin`.
    public static func sortedByVisualOrder(_ nodes: [AXNode], relativeTo origin: CGRect?) -> [AXNode]
    public static func collectStaticTexts(in node: AXNode) -> [String]
    public static func formatTable(_ row: AXNode) -> Block   // .tableRow(cells:selected:)
}
```

Paths are parsed once into `[Step]` and cached in a lock-guarded LRU (capacity 128) keyed on the path string. The API is **total**: an invalid path is a programmer error, so parsing calls `preconditionFailure` in debug and returns nil / `[]` in release. `AXQuery` never throws.

### 7b. `StructuredParser` — parser protocol v2

```swift
public struct ParserConfig: Sendable, Equatable {
    public let app: String
    public let bundleIDs: [String]
    public let attributeSet: [String]        // extra AX attributes AXReader must fetch for this app
    public let offscreenPolicy: OffscreenCapturePolicy
    public let preferOverNative: Bool        // for browser hosts: beat the generic web path
    public let minAppVersion: String?
}

public struct ParseContext: Sendable {
    public let app: AppInfo
    public let windowTitle: String?
    public let url: String?
    public let previousStructured: CapturedContent?
    public let now: EpochMs
}

public protocol StructuredParser: Sendable {
    static var config: ParserConfig { get }
    func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?   // nil = NOT_HANDLED
}
```

`nil` means NOT_HANDLED and routes to `GenericPageExtractor` (§4f rule 3). `ParserRegistry` gains a second map keyed by bundle ID for `StructuredParser`s, and a third keyed by **host** so browsers route web-app hosts through the same mechanism — replacing the `WebAppKind` switch in `WebAppCaptureParser.classify`. `preferOverNative` decides the order when both a native and a host parser could claim a window. `ParserConfig.attributeSet` is what keeps the extra AX reads off apps that do not need them.

### 7c. Parsers to (re)write, with anchor strategies

| Parser | Shape | Anchor |
|---|---|---|
| Warp, Terminal.app, iTerm2 | `.terminal` | Largest `AXTextArea` (as `TerminalParser.largestTextArea` does today). Learn the prompt regex from the **first** line matching `^\S+@\S+ ` or `^[~/].* [%$❯] `, then split the scrollback on subsequent matches of the same shape: each match starts a segment whose `command` is the text after the prompt and whose `output` runs to the next match. Last segment gets `isRunning: true` when no trailing prompt line follows. `cwd` from the window title, falling back to the existing `promptCwd(in:)`. Segmentation failure → one segment, `command: nil`. |
| Cursor, VS Code | `.document` | `title` = active tab from the window title (strip the trailing ` — <workspace>`). Blocks = visible editor lines from the `AXTextArea`/`AXGroup` whose `identifier` contains `"editor"` (`//AXGroup[identifier*="editor"]//AXTextArea`), each line a `.paragraph`. The integrated terminal panel (an `AXTextArea` sibling whose ancestor identifier contains `"panel"` or `"terminal"`) becomes a second region on the `.generic` fallback, or is dropped when the editor anchor resolves. |
| Chrome, Safari, Zen, Arc (generic web) | `.generic` | `GenericPageExtractor` over the `AXWebArea` subtree, using landmark subroles for regions. `url` from the web area's `AXNode.url`, which `BrowserTabExtractor.bestWebURL` already scores and normalises. |
| Slack | `.conversation` | Message list `//*[domClass*="c-message_list"]`; each message `//*[domClass*="c-virtual_list__item"]`; sender `//*[domClass*="c-message__sender"]`; timestamp `//*[domClass*="c-timestamp"]`; composer `//*[domClass*="ql-editor"]` → `isDraft: true`. Falls back to today's x-band row heuristic when no DOM classes are exposed. |
| Discord | `.conversation` | The `AXList` whose `identifier` or `label` contains `"Messages in"`; within each message group the sender is the group's `AXHeading` — this **fixes the missing sender attribution** the current parser documents as unfixable. Discord's `AXFrame` values are unreliable (`DiscordParser.swift` header comment), so this parser must not use any geometric split. |
| Messages | `.conversation` | Bubbles are the `AXTextArea`/`AXStaticText` nodes inside the transcript; `isUser` from bubble side: `frame.midX > window.frame.midX`. |
| WhatsApp | `.conversation` | Cells with `identifier == "WAMessageBubbleTableViewCell"`. |
| Notes | `.document` | Body from `identifier == "Note Body Text View"`; `title` = its first line; `author` = `.user` unless a header line ends with `"— Shared"`. |
| Notion | `.document` | `AXWebArea` → node with `domClass` `notion-frame` or `notion-peek-renderer`; skip subtrees whose `domClass` contains `layout-margin-right` and skip property groups; `title` from `notion-topbar`. |
| Obsidian | `.document` | `domClass` `cm-editor` (edit) or `markdown-preview-view` (preview); `title` = window title minus the vault suffix (reuse `ObsidianParser.key(fromTitle:)`'s existing split). |
| Mail | `.conversation` | **Keeps the AppleScript source, not the AX tree** — Mail's AX is ~80 ms/node and unusable (§12 Q6). The already-parsed `MailRecord{sender, subject, date, body}` list maps one-to-one onto `Message`s; `channel` = subject. AX is used only for the compose window's `Mail.subjectField` → draft, and only when a compose window is frontmost. |
| Finder | `.generic` | Rows via `//AXOutline//AXRow` and `//AXTable//AXRow` → `.tableRow(cells:selected:)` with `selected` from `AXSelected`; path from the window title or `AXDocument`; the source list becomes a `.sidebar` region via the §4e sidebar rules; the status/progress text ("Uploading 34 items") lands in `.toolbar`. |
| Calendar | `.calendar` | Existing `StructuredEntityExtraction.preferredDetailRoot` anchor, retyped. |
| Reminders | `.tasks` | Existing `StructuredEntityExtraction.task` anchor, retyped; `status` from the row's `AXCheckBox` value. |

### 7d. Fixture tooling

There is no tool today that records an AX snapshot as JSON — `tools/ax-structure-inventory.swift` prints role-count TSV and deliberately emits no attribute values (§12 Q11). Phase D adds `tools/ax-snapshot-record.swift <bundle-id> <out.json>`, which walks the focused window with the same budgets as `AXReader.snapshotFrontmostWindow` (`maxNodes: 20_000`, `maxDepth: 40`) and writes the `Codable` `AXNode` directly. Per `Tests/MaxMiCaptureTests/Fixtures/README.md`, recorded fixtures must be **hand-scrubbed** before commit — no real page text, messages, file contents, URLs, names, or tokens.

The six duplicated `func fixture(_ name: String) throws -> AXNode` helpers (`ExtractorTests.swift:5`, `BrowserCapturePipelineTests.swift:6`, `NativeConversationParserTests.swift:5`, `GenericAXParserTests.swift:5`, `SlackParserTests.swift:5`, `StructuredNativeParserTests.swift:5`) are consolidated into one `Tests/MaxMiCaptureTests/FixtureLoading.swift`.

## 8. Cross-cutting

**Error handling.** A parser that returns nil or throws is caught per-app and falls to `GenericPageExtractor` (§4f). The fallback is **not silent**: `capture_health_events` records the capture with `parser` set to `"GenericPageExtractor.v2/fallback/<ParserTypeName>"`, so the Capture Health window shows which parsers are degrading. `capture_health_events` has no free-text note column and `reason` is only populated for `skipped`/`failed` outcomes, so the fallback is encoded in `parser` rather than by adding a column. `GenericPageExtractor` itself is pure and total — it cannot throw and always returns a `GenericPage` (possibly with zero regions, which the caller treats as `emptyContent` exactly as today).

Migration v10/v11 are additive and nullable, so rollback is "ignore the new columns". A `structured_ciphertext` that fails to decrypt or decode is handled identically to NULL (`LegacyContentAdapter`) — never a crash, never a lost capture. Encryption for the new columns reuses `AESGCMFieldCipher` and the same Keychain key (`dev.mafex.maxmi.dbkey`); no new key, no new format.

**Performance.** `GenericPageExtractor.extract` must complete in **< 150 ms for a 20_000-node tree** on M1 — measured in a test over a synthetic `AXNode` tree, since the function is pure and in-memory. (`AXReader`'s own budget is already `maxNodes: 20_000`.) That test asserts a wall-clock bound and is marked as the one perf test in the suite. The separate live cost of the new AX attributes is bounded by fetching `subrole`/`selected`/`hidden` unconditionally, `headingLevel` only on `AXHeading`, `placeholder`/`selectedText` only on text-entry roles, and `domClassList`/`domIdentifier` only under an `AXWebArea` — plus `ParserConfig.attributeSet` for per-app extras. `AXQuery` path parsing is cached.

**Privacy.** Everything M8 adds inherits the existing gates and adds no new ones and no new network destinations (Gemini only, one shared `GeminiThrottle`). Specifically: `Denylist.isSensitiveApp` and the URL/domain denylist apply before any event or typing row is written; per-app exclusion and `ActivityConsent == .granted` + `activityEnabled()` gate `capture_events` and `TypingObserver` exactly as they gate `activity_session_evidence`; secure fields are never read (the value is not fetched, not just not stored); `capture_events.payload_ciphertext` is encrypted, including `focus` payloads because a window title is content; the `TypingObserver` LRU is in-memory only and is dropped on quit. Per §3, no PII/email redaction is added inside captured content.

## 9. Testing

**Phase A.** `CapturedContent` Codable round-trip for all six shapes incl. `Authorship.other` and nested `BlockType` payloads; deterministic-encoding test (same value → same bytes). `ContentRenderer` golden strings per shape, incl. the `(From: You)(sent …)` conversation line, `(draft)` suffix, and an assertion that `[user]` never appears in rendered output, `a | b | c` table rows, `#`×level headings, region order and `## Sidebar` headers. **Round-trip invariant:** `render(LegacyContentAdapter.adapt(s, kind:), .full) == s` for a corpus of real rendered strings. `.compact`/`.mainOnly` bound tests. `CaptureAccumulator` structured merge per shape: conversation union by `Message.id` with order preserved and one-draft-per-sender; terminal append when cwd matches and prefix matches, replace otherwise; tasks/calendar replace; shape change → replace; rendered bound never splits a block. Migration v10 test asserting both columns exist, are nullable, and that a v9 row reads back through `LegacyContentAdapter`. `GenericPageExtractor`: one test per role-model row; heading level default 2 and clamping; secure field yields `«secure field»` and never the value; text node stops recursion; Set-dedup within a region; menu bar never traversed; region detection for each of the six rules **with a nonzero window origin** (the window-relative-coordinate regression); budget allocation and `truncated`; the 20k-node perf bound. `CaptureDispatch` fall-through: registered parser returning nil now produces a generic capture plus the `capture_health_events` marker.

**Phase B.** `CaptureDelta` per shape incl. `isFirstCapture`, `removedCount`, char counts. Migration v11: table + CHECK + both indexes + `ON DELETE CASCADE` on thread delete + `SET NULL` on version prune. `CaptureEventStore`: encrypted payload round-trip per kind; one `content_delta` per committed non-empty capture and **none** for a `.deduplicated` commit; retention trim at 30 days incl. the once-per-hour gate; `pruneMemory` and `deleteAllMemory` remove events. `TypingObserver`: pure append; single mid-string insertion; paste → `replaced: true` with the ≤500-char tail; clear → `replaced: true`; identical value → nil; debounce suppresses a second call inside 800 ms; secure field → nil; sensitive/excluded app → nil; consent `.unset`/`.declined` → nil; LRU evicts past 32 keys. `TimelineBuilder`: deterministic ordering, coalescing of adjacent same-thread visits, budget dropping oldest-first with the omission line, and an assertion that no rendered entry exceeds 200 chars of delta content.

**Phase C.** Prompt-builder tests (there is no `AgentPromptsTests.swift` today — Phase C creates it): the four-part capture input assembly omits empty sections; the conversation variant sends only `addedMessages` and never the `ON SCREEN` section, and is selected for every `.conversation` shape (not just WhatsApp); rendered conversations use `You` and carry a timestamp when known, and `[user]` never appears in rendered output; nonce fences present and markers stripped from every interpolated field; the fixed-fallback path never calls the relay; `DisplaySummarizer` sends timeline text and never evidence (mock relay asserts the argument); `ExtractPrompt` carries metadata and the delta as `newContent`; `HourlyAgent` budget trimming drops smallest-`deltaChars` first, never drops an open item, and never trims the timeline below 4_000 chars; never-resolve-on-absence and the `status == 'open'` guard still hold with the new input shape; prompt-version bump causes exactly one lazy regeneration per affected row.

**Phase D.** `AXQuery`: each grammar token; predicate ANDing; index selection; `domClass` case-insensitivity; cache hit does not change results; invalid path returns nil in release configuration. Per parser, **≥2 recorded, hand-scrubbed AX fixtures with a golden expected `CapturedContent` JSON**, at least one of them with a nonzero window origin. Two specific generic-v2 fixtures are required: a **Finder** window where sidebar folders land in `.sidebar`, column headers and rows in `.main` as `.tableRow`s, and the "Uploading 34 items" status in `.toolbar`; and a **dialog-over-window** case (the Cloudflare WARP quit dialog) where the dialog's blocks land in `.dialog` and survive budget trimming while `main` is trimmed.

**Live verification ritual** (per repo docs, unchanged): `./packaging/make-app.sh`, then `pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"`, then `open MaxMi.app`. **No `tccutil reset`** — signed builds keep the Accessibility grant across rebuilds. Verify captures by timestamp strictly after the new process start.

## 10. Sequencing

`A → B → C` in order; **D depends only on A** and may run in parallel with B and C on a separate branch/worktree. Each phase is independently shippable:

- **A alone** ships better captures with today's prompts (summaries improve because the rendered text is structured).
- **B alone** ships the event log and timeline with today's prompts (visible in the Capture Health window).
- **C alone** ships the prompt rewiring; without B it degrades gracefully because `CaptureDelta` and the timeline are both empty-safe.
- **D alone** ships parser coverage on top of A.

Conflict surface between B/C and D is small and known: both touch `ParserRegistry` and `AXNode`. A lands the `AXNode` field additions first so D only adds `domClassList`/`domIdentifier` on top.

## 11. Exit criteria

1. Every parser produces a `CapturedContent`; `versions.content` is `ContentRenderer.render(_, .full)` and the round-trip invariant test is green.
2. A Finder window, a dialog-over-window, and a browser page each produce correct regions; a secure field never appears in any stored content.
3. A registered parser returning nil produces a generic capture with a visible `capture_health_events` fallback marker instead of nothing.
4. `capture_events` records content deltas, focus, navigation, dialogs, and typing; 30-day retention works; nothing is written for a denylisted, excluded, or non-consented app.
5. Typing is captured for a Slack composer and a Notes body with no `CGEventTap` anywhere in the binary (grep-asserted in a test).
6. Capture summaries name the user's action from the delta; the fixed fallback string appears instead of a chrome description when there is nothing to say.
7. The hourly agent receives compact raw versions plus the timeline, within 40k chars, and its ops still validate; no summaries-of-summaries remain in its input path.
8. `AXQuery` powers the rewritten parsers; every rewritten parser has ≥2 golden fixtures, one with a nonzero window origin.
9. `GenericPageExtractor` meets the 150 ms / 20k-node bound.
10. Full suite green (506 existing tests plus the new ones), zero warnings, live verification passed per §9.

## 12. Decisions log — where the code contradicted the brief

Nothing below was silently redesigned. Each item states what the brief assumed, what the code actually is, and the decision that was taken. All fifteen are settled; none is still open.

**Q1 — `AXNode` has no `subrole` and no separate `description`.** The brief said to verify `AXSnapshot.swift` fields "role, subrole, title, description, value, identifier, url, frame, focused, children, label" and to add only the DOM attributes in Phase D. In fact `AXNode` (`AXSnapshot.swift:3-12`) has exactly `role, value, title, url, frame, focused, children, identifier, label`, and `AXReader.swift:75-76` folds `kAXDescriptionAttribute ?? kAXHelpAttribute` into `label` — so `description` is not separable today. **Decision:** since Phase A's region detection depends on `AXSubrole` (`AXLandmarkMain`, `AXDialog`, `AXSecureTextField`), the attribute additions `subrole`, `headingLevel`, `selected`, `placeholder`, `selectedText`, and `hidden` moved into **Phase A** (§4e); only `domClassList`/`domIdentifier` stay in Phase D; and the DSL's `description` is an explicit alias of `label`.

**Q2 — new columns must be `TEXT`, not `BLOB`.** The brief specified `structured_ciphertext BLOB NULL` and `payload_ciphertext BLOB`. But `FieldCipher.encrypt(_:) throws -> String` returns an `"enc:v1:"`-prefixed base64 string and every existing ciphertext column (`versions.content`, `latest_contexts.content_ciphertext`, `activity_session_evidence.content_ciphertext`, `agent_action_items.title_ciphertext`) is `TEXT`. **Decision:** `TEXT` columns written through `FieldCipher`. `BLOB` would have required a second cipher API for no benefit.

**Q3 — `ContentKind` cannot be purely derived from `structured`.** The brief said `ContentKind` "is derived from `structured` (add a computed `kind`)". Two of the ten cases are not derivable: `.email` (Mail/Outlook/Spark produce a `.conversation` shape) and `.webpage` (browsers produce a `.generic` shape). Both are load-bearing — `latest_contexts.content_kind` has a CHECK constraint over the exact ten, MCP filters on it, and `CaptureDisplaySummaryFormat.promptVersion(sourceApp:contentKind:)` switches on it. **Decision:** `structured.kind` is the **default**; `ParsedCapture.contentKind` stays authoritative and overridable — Mail/Outlook/Spark keep `.email`, browsers keep `.webpage`.

**Q4 — `capture_events.thread_id` must be nullable.** The brief's DDL lists `thread_id` without NULL, but a `focus` event fires before any thread exists for that window (`FocusObserver.onFocusChanged` runs before parsing). **Decision:** `thread_id` nullable with `ON DELETE CASCADE`; `version_id` nullable with `ON DELETE SET NULL`, so version pruning does not delete events.

**Q5 — there is no sweeper to align with.** The brief said "sweeper deletes events older than 14 days (align with any existing retention policy)". MaxMi has **no automatic age-based deletion**: `MemoryDataControls.pruneMemory(olderThan:)` is user-triggered only, reached from `AppWiring.swift:595-613`, and the default retention is **Forever** (options 30/90/365 days, `CapturePrivacyView.swift:116-119`). The only automatic trim is `CaptureHealthStore`'s **row-count** cap of 500. **Decision:** a new **30-day** automatic trim (not the brief's 14) modelled on `CaptureHealthStore` — trim on write, gated once per hour — plus `capture_events` wired into `pruneMemory` and `deleteAllMemory`. Thirty days because events are derived signals rather than memories and the Activity window may look back a month. Memory retention itself is unchanged (Forever by default). Since this is the only thing MaxMi deletes unasked, the Privacy settings copy states it: "Activity events are kept for 30 days" (§5b).

**Q6 — Mail does not read the AX tree at all.** The brief's Phase D anchors for Mail (`message_view`, `message_header`, `message.from.0`, `message.timestamp`, `_MAIL_MESSAGE_BODY`, `Mail.subjectField`) assume AX traversal. `MailParser` deliberately does not traverse AX: its header comment records that Mail's tree is "pathologically slow (~80 ms per node — reaching the message list would take minutes)" and it sources everything from AppleScript, returning `MailRecord{messageID, sender, subject, date, body}`. **Decision:** Mail stays AppleScript-sourced; `MailRecord`s map straight onto `Message`s; AX is used only for the compose window's `Mail.subjectField`.

**Q7 — there is no `"Viewing <app>"` fallback today.** Grep for `Viewing` across `Sources/` returns zero hits, and `CaptureDisplaySummaryFormat` is purely a prompt-version registry (`standard`, `recentConversation`, `promptVersion(sourceApp:contentKind:)`). **Decision:** add `CaptureDisplaySummaryFormat.fallback(app:title:)` producing `"Viewing <app>: <title>"`, generated locally and never requested from the model.

**Q8 — the activity prompt version is a bare `"v1"` literal.** `Sources/MaxMi/StoreActivitySummaryRepository.swift:35` passes `promptVersion: "v1"` with no named constant, and `CaptureSummaryStore`'s invalidation predicate is gated on `t.source_app='WhatsApp'` (`CaptureSummaryStore.swift:36`) so a version bump currently invalidates **only WhatsApp** rows. **Decision:** generalise the predicate to all apps and replace the literal with a named constant. Without both changes the "cached summaries regenerate lazily" requirement silently fails for every non-WhatsApp app.

**Q9 — no reminder columns exist, so the slot legend was dropped.** Minimi's review request carries `remind_at`, `remind_date`, `remind_slot`, `reminder_shown` per prior item; `agent_action_items` has none of these, and the brief puts the todo UI in M9. **Decision:** the reminder-slot legend is **dropped from the hourly-agent prompt in M8** entirely — sending vocabulary with nowhere to store the result is dead weight. Reminders and slots arrive with M9 (the todo panel), which adds the columns and the legend together; recorded in §3 Non-goals.

**Q10 — `agent_runs.prompt_version` is declared but never written.** The column exists (`Migrations.swift:131`); no code writes it (only `activity_sessions.prompt_version` and `latest_contexts.summary_prompt_version` are written). **Decision:** start writing it, `"agent-review-v2-versions"` on run completion (§6d).

**Q11 — there is no snapshot-recording tool to reuse.** `tools/ax-structure-inventory.swift` prints role-count TSV and intentionally emits no attribute values, so it cannot produce a loadable fixture. Eleven hand-authored fixtures exist (`calendar-event`, `chrome-article`, `chromium-gmail-thread`, `cursor-editor`, `gecko-slack-chat`, `pages-document`, `reminder-task`, `safari-domain-only`, `slack-window`, `whatsapp-conversation`, `zen-meet`). **Decision:** add `tools/ax-snapshot-record.swift` and keep the hand-scrub requirement from `Fixtures/README.md`.

**Q12 — `MemoryStore` does not declare `commitCapture`.** The brief said to write events "in the `commitCapture` path (verify function)". `commitCapture` has two `public` overloads on `Store` (`StoreAPI.swift:64,68`) and is **not** part of the `MemoryStore` protocol (`Protocols.swift:52-63`), whose conformer is `StoreAdapter` (`AppWiring.swift:83`). The sole production call site is `AppWiring.swift:1567`. **Decision:** the delta is computed inside `Store.commitCapture` and returned via `CommitResult`; the event writes live in `finishCapture` (`AppWiring.swift:1403`), the only place that knows the app, trigger, and previous URL.

**Q13 — `parseStructured` returning `CapturedContent?` needs a composition rule.** The brief specified both `ParsedCapture.structured: CapturedContent` (non-optional) and `SourceParser.parseStructured(...) -> CapturedContent?`. Taken literally those need two AX walks per capture. **Decision:** resolved as written in §4f — migrated parsers make `parseStructured` the single source of truth and reduce `parse` to a render wrapper; unmigrated parsers implement only `parse` and get `LegacyContentAdapter`. Neither group walks twice.

**Q14 — `CloudProcessingState`'s gate is inert.** `CapturePrivacyStore.cloudReviewInitialized()` hardcodes `false` (`CapturePrivacyStore.swift:79`), which disables the `pendingReview`/`allowed`/`localOnly` gate that `AppWiring.swift:1570-1574` consults before writing activity evidence. **Decision:** informational only — M8 does not change it. The consent gate in §5c and §8 relies on `ActivityConsent` + `activityEnabled()` rather than `CloudProcessingState` for exactly this reason. Recorded so the inert gate is not mistaken for M8 breakage.

**Q15 — Minimi embeds raw content too; MaxMi still does not.** Live traffic shows Minimi embedding **both** each extracted memory sentence **and** the full raw rendered content of every capture, 1:1, plus a single profile query phrase. MaxMi embeds facts only (`CapturePipeline.process` → `relay.embed(text: d.content)` per derivative). M8 keeps facts-only: adding a second embedding per capture roughly doubles embedding spend and needs a new `vec0` table alongside `derivative_embeddings`, and the retrieval win is unproven for us. **Decision:** facts-only embedding in M8; raw-content embedding is an optional later enhancement, explicitly out of scope here.

## 13. Rollout

Per the established M5/M6 workflow: **spec → Codex review → revise → implementation plan per phase → Codex review of the plan → revise → subagent-driven build → Codex review of the implementation → revise → live verify.** Phase A's plan lands first and must include the `AXNode`/`AXReader` attribute additions, because both B and D build on them. Phase D runs in its own worktree in parallel with B/C.
