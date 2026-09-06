# MaxMi — M8: Structured Capture (typed captures, deltas, action-grounded summaries)

**Date:** 2026-09-06
**Status:** Design, decided. All decisions in §3-§7 are architect-final; §12 is the decisions log for every place the code contradicted the design brief (nothing was silently redesigned, nothing left open). **§14 holds three scope additions approved on 2026-09-07**, after Phase A shipped — raw-content embedding, five host-routed web-app parsers, and the daily check-in — with their contradictions logged as §12 Q16-Q22. Next step is the Codex review pass in §13.
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
- **No reminders and no reminder slots.** Reminder scheduling arrives with **M9** (the todo panel), which will add the `agent_action_items` columns and the slot legend together. M8 neither stores nor mentions slots. **This is unchanged by the 2026-09-07 additions:** §14c's daily check-in schedules nothing and sends no slot vocabulary (§12 Q9 stands).
- **Team sharing (M7) stays permanently dropped.**
- **No OCR, no screenshots, no new capture modality.**
- No change to the MCP tool **request** surface: `search_memory`, `list_active_threads` and `get_latest_context` keep their names, arguments and required fields. **Amended 2026-09-07:** `search_memory`'s *response text* now gains a `### Matching context` section (§14a); its request shape is still byte-identical and `structured` is still never exposed.

**Formerly non-goals, now in scope (architect decisions, 2026-09-07 — see §14)**
- **Raw-content embedding is no longer deferred.** §12 Q15's facts-only decision is reversed: M8 embeds one vector per committed version into a new `context_embeddings` `vec0` table and `search_memory` searches it alongside fact embeddings. Implemented in **Phase C** (§14a).
- **The daily morning check-in moves from M9 into Phase C.** One short second-person briefing per day, stored in a new `checkins` table and surfaced as a Today card at the top of the menu-bar popover (§14c). Only the check-in moves; the rest of the M9 todo panel does not.
- **Five web-app parsers by host** (Gmail, LinkedIn messaging, Outlook web, Slack web, Teams web) are added as **Phase D tasks 22-26** (§14b). This widens Phase D's parser table; it changes no contract.

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
    /// A stable identity — the source's native message ID when one exists (e.g. Mail's messageID), otherwise the `makeID` fingerprint.
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
    public let notes: String?          // the event's detail/notes body
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
- `ParsedCapture.envelope(cleanSourceKey:parserID:trigger:truncated:)` gains a `structured:` argument. Nil resolution on the write path happens in exactly one place, `CaptureEnvelope.init`: both `ParsedCapture.envelope(...)` (via `CaptureDispatch`, §4f) and `CaptureEnvelope.legacy(sourceApp:sourceKey:sourceTitle:content:)` route through it, and it resolves nil → `LegacyContentAdapter.adapt(renderedContent: content, kind: contentKind)`. On the read path, `structured_ciphertext` NULL/undecodable resolves via `LegacyContentAdapter` in the store (§4c); no other site resolves nil.
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
| `.calendar` | One line per event: `"\(dateString) — \(title)"`, then ` @\(location)`, ` / \(organizer)`, ` [conference]` when `hasConference`; then, when `notes` is non-nil and non-empty, a following line `"Details: \(notes)"` with any further notes lines indented two spaces. |
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
    /// One `.main` region of `.paragraph` blocks, one per line, including empty lines, so that `ContentRenderer.render(LegacyContentAdapter.adapt(s, kind:), .full) == s` holds byte-for-byte.
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

For `.conversation` and `.terminal` accumulation, bounding applies `maxCharacters` to the *rendered* form by trimming whole messages/segments from the front (oldest first, keeping the newest) — never mid-block. This front-trimming (keep-newest) policy is specific to accumulation in this section; it is not how `GenericPageExtractor` bounds its output — that budget trimming (§4e) drops blocks from the *end* of each region, keeping the top of the page.

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
| `AXListItem`, `AXTreeItem` | `.listItem(depth:)`, depth = number of enclosing list ancestors minus one; items in the outermost list have depth 0 and render with no indent |
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

**Budgets.** `totalBudget = 8_000` is the default; a parser may pass a larger budget to preserve its current cap (browser path 16_000; Word/Pages/Outlook/Spark 32_000). `main` gets `totalBudget × mainShare`, `dialog` gets `× dialogShare`, all other regions share `× restShare` proportionally to their unbounded rendered size. Unused share rolls into `main`. Trimming removes whole blocks from the **end** of each region's block list — keeping the top of the page, the opposite of the keep-newest front-trimming §4d uses for `.conversation`/`.terminal` accumulation — except `.dialog`, which is never trimmed (a dialog is short and is usually the single most important thing on screen; if a dialog exceeds its share, it takes the space from `main`). `Result.truncated` is true when any block was dropped.

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
| `MailParser` | `.conversation` | `channel` = subject; one `Message` per `MailRecord` (`From`/`Date`/body already parsed). `contentKind` stays `.email` |
| `OutlookParser`, `SparkParser` | `.generic` | no `MailRecord` source exists for Outlook/Spark; they produce `.generic` with `contentKind` `.email` in Phase A. Typed `.conversation` for them is deferred to a later phase |
| `CalendarParser`, `FantasticalParser` | `.calendar` | |
| `RemindersParser`, `MicrosoftToDoParser`, `TodoistParser`, `OmniFocusParser`, `TogglParser` | `.tasks` | |
| `TerminalParser` | `.terminal` | segmentation per §7; failure → one segment, `command: nil` |
| `WebAppCaptureParser` | `.conversation` for conversation hosts; `.generic` otherwise | generic path = `GenericPageExtractor` over the `AXWebArea` subtree with `url` set. `contentKind` stays `.webpage` / `.email` |
| `NotesParser`, `NotionParser`, `ObsidianParser`, `WordParser`, `PagesParser`, `DiscordParser`, `MessagesParser` | `.generic` via v2 | real parsers land in Phase D |

### 4g. MCP — unchanged

`search_memory`, `list_active_threads`, `get_latest_context` keep their request and response shapes and keep reading `content` (`Sources/MaxMiMCP/Tools.swift:23,32,40`). Exposing `structured` over MCP is explicitly out of scope.

**Amended 2026-09-07 (§14a):** still true for every *request* shape, and `structured` is still never exposed. The one exception is `search_memory`'s **response text**, which gains a `### Matching context` section listing raw-content hits. `MaxMiToolsDefinitions.all` is untouched.

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

**Amended 2026-09-07:** five more parsers, registered by **host** rather than bundle ID — Gmail, LinkedIn messaging, Outlook web, Slack web, Teams web — are specified in **§14b** and become Phase D tasks 22-26. They add no new contract; they extend this table over `ParserConfig.hosts`.

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

Nothing below was silently redesigned. Each item states what the brief assumed, what the code actually is, and the decision that was taken. All twenty-two are settled; none is still open. Q1-Q15 are from the 2026-09-06 design pass; Q16-Q22 are the contradictions the 2026-09-07 scope additions (§14) hit.

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

**Amendments (2026-09-06, pre-flight)**

- §4a — `Message.id` doc comment now states it is the source's native message ID when one exists (e.g. Mail's `messageID`), otherwise the `makeID` fingerprint, instead of implying it is always the fingerprint.
- §4c — `LegacyContentAdapter` now emits one `.paragraph` block per line **including empty lines**, so `render(adapt(s, kind:), .full) == s` holds byte-for-byte (was "non-empty line", which broke the round-trip invariant).
- §4d/§4e — clarified that §4d's keep-newest front-trimming applies only to `.conversation`/`.terminal` accumulation, while `GenericPageExtractor`'s per-region budget trimming (§4e) drops blocks from the end of each region, keeping the top of the page — the two trimming policies are independent and were previously easy to conflate.
- §4e — `.listItem` depth is now defined precisely as the number of enclosing list ancestors minus one, with the outermost list at depth 0 and no indent, replacing the ambiguous "count of ancestor list/outline containers".
- §4e — `Options.totalBudget` is now documented as an 8_000 default that individual parsers may override with a larger budget to preserve their existing cap (browser path 16_000; Word/Pages/Outlook/Spark 32_000).
- §4f — Outlook and Spark now produce `.generic` with `contentKind` `.email` in Phase A, since no `MailRecord` source exists for them; typed `.conversation` for both is deferred to a later phase. Also clarified nil-`structured` resolution: the write path resolves in `CaptureEnvelope.init` (the one place both `ParsedCapture.envelope` and `CaptureEnvelope.legacy` route through), the read path resolves a NULL/undecodable `structured_ciphertext` via `LegacyContentAdapter` in the store, and no other site resolves nil.

**Amendments (2026-09-06, final review)**

- §4e — the note apps (Notes, Notion, Obsidian) use the 32_000 page budget, not the 8_000 default, and their `accessibilityScroll` ceiling matches it, so a long note is bounded exactly like a Pages or Word document. Viewport-anchored trimming for `.document` (keeping what the user is looking at rather than the top of the page) is a Phase B item. `.dialog` is trimmed only as a last resort, after its rollover from `main` and `rest` is exhausted (Task 7 ruling).
- §4a/§4e/§8 — "the value is never read" now covers the SELECTION too: `AXReader.convert` reads `subrole` first and skips `AXValue`, `AXPlaceholderValue` and `AXSelectedText` entirely for an `AXSecureTextField`, and `FocusedElement.init` nils both `value` and `selectedText` when `isSecure`. `orderedDescendantText` skips secure nodes as well, so a table cell is not a way around the rule.
- §4e — `AXColumn` joins the skip/dead-end roles: it republishes the same `AXCell`s its rows already emitted, so walking it printed every web-table cell a second time as a loose paragraph. Row cells are collected from `AXCell`, `AXStaticText`, `AXTextField` and `AXTextArea` (Finder's name column is an editable field) but never `AXImage`.
- §4b — `ContentRenderer.renderEvent` omits the `" — "` separator when `dateString` is empty, and `.mainOnly` iterates `regionOrder` per kind instead of sorting regions, so two regions of the same kind have a defined order.
- §4d — the browser generic path declares `.replace`, not `.rollingText`: a typed page is not legacy-shaped, so the string accumulator never ran for it anyway. It also throws `ExtractionError.emptyContent` when the extracted page has no regions, mirroring `GenericV2Content.page` returning nil, and `Store.commitCapture` refuses a commit whose accumulated render is empty for a thread that already holds content — an empty render must never replace a real capture.
- §4d — clarified (no behaviour change) that conversation union by `Message.id` COLLAPSES an identical message repeated in one window: sender + time + text is the identity, so two indistinguishable bubbles are one message. A browser test asserting the opposite was rewritten to this contract.
- §4f — `ParsedCapture.resolvedStructured` is internal: nothing outside `MaxMiCapture` resolves a nil `structured`.

**Amendments (2026-09-07, scope additions — §14)**

Three additions the architect approved on 2026-09-07. Each bullet below records what changed and where; the seven contradictions they hit are Q16-Q22 underneath.

- §3 Non-goals / §12 Q15 — **raw-content embedding is no longer deferred.** Q15's facts-only decision is reversed. M8 embeds one vector per committed version into a new `context_embeddings` `vec0` table (migration `v11`) and `search_memory` runs KNN over it as well as over `derivative_embeddings`. Specified in §14a; implemented in **Phase C**. Q15's cost analysis still holds — embedding calls roughly double — and the architect accepted that cost on 2026-09-07 in exchange for the recall gap it closes.
- §3 Non-goals / §4g — **the MCP non-goal is narrowed from "shapes" to "request shapes."** `search_memory`'s response text gains a `### Matching context` section (§14a); its name, arguments, required fields and the "`structured` is never exposed" rule are all unchanged. `MCPStructuredNoChangeTests` is updated deliberately for exactly that one section and for nothing else. §4g carries the same cross-reference.
- §3 Non-goals — **the daily morning check-in moves from M9 into Phase C** (§14c): a new `checkins` table (migration `v12`, or folded into `v11` if Phase C ships both migrations together — the plan decides and says which), an `AgentPrompts.dailyCheckin` prompt, and a Today card at the top of the `MaxMiUI` popover. **Reminders and reminder slots stay in M9** — Q9 is unchanged, and §14c stores no `remind_at` and sends no slot legend.
- §4c / §5b / §14a / §14c — **migration identifiers are now allocated in ship order, not per section.** The tree is at `v10` (`Migrations.currentIdentifier = "v10"`, Phase A merged). §5b already declares `v11` for Phase B's `capture_events`; §14a declares `v11` for `context_embeddings` and §14c declares `v12` for `checkins`. These are *relative* labels — Phase B and Phase C are independently shippable (§10) and either can land first, so whichever migration lands first takes `v11` and the rest follow in sequence. Each phase's implementation plan pins its absolute identifier and bumps `Migrations.currentIdentifier` to match. All three migrations are additive and mutually independent, so the ordering is free. `DatabaseRecovery` needs no edit in any ordering: its accept-set is `Set(Migrations.migrator.migrations)` and its head check reads `Migrations.currentIdentifier` (`DatabaseRecovery.swift:106,132`), both derived from the migrator.
- §7c / Phase D plan — **five web-app parsers registered by host** (Gmail, LinkedIn messaging, Outlook web, Slack web, Teams web) are specified in §14b and appended to the Phase D plan as **tasks 22-26**, after its existing Task 21. They introduce no new type, table or migration; they use `ParserConfig.hosts`, which the Phase D plan already adds in Task 5 for exactly this purpose. Every DOM anchor in §14b is flagged as a **candidate** that must be verified against a live `tools/ax-snapshot-record.swift` dump before use, with the verified set recorded in each parser's header comment.

**Amendments (2026-09-07, Phase D plan repair)**

The Phase D plan's pre-flight scan found 30 places where §7 or the plan contradicted the merged Phase A code. The rulings are recorded in `.superpowers/sdd/2026-09-06-maxmi-m8d-ax-query-dsl-and-parsers/progress.md`; these bullets are the ones that amend the spec itself.

- §7b / §12 Q18 — **`StructuredParser.parse(_:context:)` is `throws`.** Q18 decided that a Phase D parser cannot raise `ParserRefusal` directly and moved the refusal out to the `SourceParser.parse(window:app:)` bridge; §14b then needed a refusal on the *browser* path, where there is no `SourceParser` at all. **This amendment supersedes Q18:** `parse` throws, `nil` still means NOT_HANDLED, and a thrown `ParserRefusal` means "store nothing" on **both** dispatch paths — the native path via `CaptureDispatch.parseDetailed`, which already maps a refusal to `.noContent`, and the browser path via `BrowserCapturePipeline.parse`, which rethrows it so `AppWiring` records `.skipped(.parserNoContent)`. There is **no** separate refusal protocol (the plan's earlier `RefusingStructuredParser` hook is removed); `refusesEmptyCompose(_:context:)` survives only as a plain predicate on each web-app parser, guarding its own throw. A refusal is never reported as a `GenericPageExtractor.v2/fallback/...` degradation.
- §7b — **the §8 fallback marker has exactly one spelling.** `CaptureDispatch.fallbackParserID(failedParser:)` already exists in the merged tree (`Sources/MaxMiCapture/ParserRegistry.swift:167-169`) and already returns `"GenericPageExtractor.v2/fallback/<ParserTypeName>"`. Phase D adds no `notHandledBy:` overload; when no parser claimed a window there is no marker at all.
- §7b — **`ParserConfig.attributeSet` is wired at the live snapshot site.** `AppWiring` resolves `registry.forcedAttributes(for: app.bundleID)` before the detached AX read and passes it to `AXReader.snapshotFrontmostWindow(pid:maxNodes:maxDepth:forcedAttributes:)`. Declaring the set without that line would leave Slack/Notion/Obsidian DOM anchors nil in production while the hand-authored fixtures passed.
- §7a — **no table-row formatter is added.** §7a's helper list is implemented minus `formatTable(_:)`: `GenericPageExtractor.block(for:listDepth:)` already emits `.tableRow(cells:selected:)` with `selected` from `AXSelected`, and the two row consumers (Finder, Outlook web) call it. One row implementation, not two with different empty-row semantics.
- §7c Finder — **rows are delegated to `GenericPageExtractor`; `AXQuery` covers the path and source-list anchors.** The outcome §7c specifies (`//AXOutline//AXRow` / `//AXTable//AXRow` → `.tableRow(cells:selected:)`) is exactly what the extractor produces, so the Finder parser adds identity (the folder path) and the sidebar anchor rather than a second row walk.
- §7c Calendar — **Phase A already retyped this anchor.** `StructuredEntityExtraction.calendarContent` returns `.calendar([CalendarEvent])` from the `preferredDetailRoot` anchor, so Phase D registers it as a `StructuredParser`, widens `hasConference` to fire on a field whose metadata names it as the conference link, and adds the goldens. It does **not** add a parallel event extractor.
- §7c Terminal — **`TerminalSegmentationTests.swift` is not deleted.** Two of its tests are the only coverage of the `contentCap` trim and of the key/kind/policy invariant; they move into `TerminalStructuredTests.swift` and the rest of the file stays, with its two `cwd` expectations updated from Phase A's slug to Phase D's absolute path.
- §7c Notes / Notion / Obsidian — **the 32_000 page budget survives the rewrite.** The anchored `.document` paths reuse each parser's existing `offscreen` constant and bound their output with `CaptureAccumulator.bound(_:to: StructuredEntityExtraction.pageBudget)`, so the cap the 2026-09-06 final review installed is not lost. No new ceiling above a render cap is introduced anywhere in Phase D (Cursor/VS Code cap and ceiling are both 32_000).
- §7d — **twelve duplicated `fixture(_:)` helpers exist, not six.** §7d names six (two with off-by-one line numbers); the tree has twelve, and the Phase D plan's own Task 1 briefly adds a thirteenth. All thirteen are consolidated into `Tests/MaxMiCaptureTests/FixtureLoading.swift`.
- §2 / §11 item 10 — **the test gate is "zero NEW failures", not "zero failures", and the 506 figure is stale.** The baseline after the Phase A merge is 689 tests with exactly three known-red (`ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`, `CaptureDisplaySummarizerTests.testConversationSummaryUsesTrailingMessages`, `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`). Those three may stay red; anything else failing blocks the phase. `import Testing` stays at 0.
- §7a — **`AXQuery.trapsOnInvalidPath` is declared in both build configurations** (`true` in debug, `false` in release), so the grammar tests that switch it off compile under `swift test -c release`. The behaviour §7a specifies is unchanged.

**Q16 — a `vec0` virtual table cannot take a `REFERENCES … ON DELETE CASCADE` clause.** The §14a decision declares `context_embeddings(version_id TEXT PRIMARY KEY REFERENCES versions(id) ON DELETE CASCADE, embedding FLOAT[1536])`. `vec0` accepts neither foreign keys nor `ON DELETE`, which is exactly why the existing `derivative_embeddings` declaration (`Migrations.swift:57-62`) has no FK clause either. **Decision:** keep the cascade as *semantics* and drop it from the DDL — the table is declared in `derivative_embeddings`' style, and the deletes are done explicitly in the two places that already do this for `derivative_embeddings`: `MemoryDataControls.pruneMemory(olderThan:)` (which deletes from `derivative_embeddings` by subquery before deleting versions, `MemoryDataControls.swift:109-127`) and `deleteAllMemory()` (`:157`).

**Q17 — `search_memory`'s cursor pagination is fact-shaped and stays fact-shaped.** `MemoryQueries.searchMemory` counts results, decides `hasMore`, and mints the next cursor from the `factHits` page alone. Making context hits paginate too would change the cursor's meaning and therefore the response contract for existing callers. **Decision:** context hits are supplementary — capped at 5, never paginated, excluded from the `_N results in this page_` count and from the cursor footer. The 0.75 floor is applied to them identically, after the same L2→cosine conversion `factHits` performs.

**Q18 — `StructuredParser.parse(_:context:)` cannot throw, so a Phase D parser cannot raise `ParserRefusal` directly.** §14b's refusal rule (refuse only for a compose-only window with an empty draft) assumes a throwing parse. The Phase D protocol is `func parse(_ snapshot: AXNode, context: ParseContext) -> CapturedContent?` (§7b, Phase D Task 5) — non-throwing by design, because `nil` is its NOT_HANDLED channel. `ParserRefusal` is thrown today only from the `SourceParser` path (`NativeConversationParser.swift:113,118`). **Decision:** the refusal stands but moves one layer out — the `StructuredParser` returns nil and the app's `SourceParser.parse(window:app:)` bridge throws `ParserRefusal` for the empty-compose case, which is where refusals already live and where `CaptureDispatch` already catches them (`ParserRegistry.swift:133`).

**Q19 — `CapturePipeline` cannot reach `MaxMiActivity`, so the check-in cannot be triggered from inside it.** §14c specifies "first pipeline tick at or after 08:00". `CapturePipeline` is in `MaxMiCore`; `AgentPrompts` / `CheckinInputBuilder` are in `MaxMiActivity`, which depends on `MaxMiCore` (`Package.swift:51`) — the dependency cannot be inverted. **Decision:** the trigger is the `AppWiring` timer that *calls* `CapturePipeline.tick()`, not `CapturePipeline` itself. This is exactly how the hourly agent is already driven, so it adds no new wiring shape. §14a's embedding, by contrast, genuinely does live inside `CapturePipeline`, because it needs only `MemoryRelay.embed` and `MemoryStore`.

**Q20 — `agent_action_items` has no `created_at` column.** §14c's input list asks for each open item's `created_at`. The column is **`detected_at`** (`Migrations.swift:138-146`); the table's other timestamps are `updated_at` and `resolved_at`. **Decision:** read `detected_at` and compute age from it — the same mapping §6d already makes when it exposes the field as `ReviewOpenItem.createdAt`. Items resolved yesterday are found by `resolved_at` bucketed with `Store.dayBucket(forMs:timeZone:)`.

**Q21 — `activity_app_visits` has no `thread_id`, so "yesterday's top 5 threads by visit time" is not a query the table can answer.** §14c's no-timeline fallback asks for it. The table is `(id, app_bundle, app_label, started_at, ended_at, day_bucket)` (`Migrations.swift:96-98`) — visits are per app, not per thread. **Decision:** the fallback ranks the **top 5 apps** by summed visit time for yesterday's `day_bucket` and joins in the `source_title` of each app's most recent `latest_contexts` row, which is the closest honest reading of the intent. The fallback also disappears entirely once Phase B's `TimelineBuilder` is available, which is the normal case.

**Q22 — `StoreAPI.pendingWork` neither selects `structured_ciphertext` nor re-qualifies a version whose only failure was the context embedding.** §14a needs a `.compact(maxChars: 6_000)` render, but `pendingWork` reads `v.content` only; and its gate is `v.extract_status = 'pending'` with a retry-deferral predicate hardcoded to `r.kind = 'extract'` (`StoreAPI.swift:250-273`), so once `markExtracted` sets `'completed'`, no `embed_version` retry row can bring that version back. **Decision:** two narrow additions rather than a new state machine — `pendingWork` selects `structured_ciphertext` and populates `PipelineVersion.compactContent` / `.sourceTitle` where it already decrypts (`CapturePipeline` never renders); and Phase C adds a separate "versions with no `context_embeddings` row" query, so the retry queue stays what its comment already calls it — a wake-up list — and the missing-embedding fact lives in the index, not in a status column.

## 13. Rollout

Per the established M5/M6 workflow: **spec → Codex review → revise → implementation plan per phase → Codex review of the plan → revise → subagent-driven build → Codex review of the implementation → revise → live verify.** Phase A's plan lands first and must include the `AXNode`/`AXReader` attribute additions, because both B and D build on them. Phase D runs in its own worktree in parallel with B/C.

## 14. Scope additions (2026-09-07)

Three additions the architect approved on 2026-09-07, after §1-§13 was settled. They **expand** the design; nothing in §4-§7 is redesigned. §14a and §14c land in **Phase C**; §14b becomes **Phase D tasks 22-26**, appended to `docs/superpowers/plans/2026-09-06-maxmi-m8d-ax-query-dsl-and-parsers.md` (which ends at Task 21). Every place one of these additions contradicts the tree, or contradicts earlier spec text, is recorded in §12's 2026-09-07 amendments list — the decision stands and the code moves.

### 14a. Raw-content embedding (Phase C)

**Purpose.** §12 Q15 recorded that Minimi embeds both each extracted memory sentence *and* the full raw rendered content of every capture, and decided facts-only for M8. That decision is **reversed**: fact embeddings alone cannot retrieve a phrase the extractor never turned into a fact, which is the single largest recall gap against Minimi. M8 now embeds one vector per committed version alongside the existing per-derivative vectors, and `search_memory` searches both.

**Data model.** A second `vec0` virtual table, declared in the same style as `derivative_embeddings` (`Migrations.swift:57-62`):

```sql
-- Migrations.swift: m.registerMigration("v11")
CREATE VIRTUAL TABLE context_embeddings USING vec0(
  version_id TEXT PRIMARY KEY,
  embedding  FLOAT[1536]
);
```

Additive; `Migrations.currentIdentifier` becomes `"v11"`. `DatabaseRecovery` needs **no** second edit: its accept-set is `Set(Migrations.migrator.migrations)` and its head check compares against `Migrations.currentIdentifier` (`DatabaseRecovery.swift:106,132`), both derived from the migrator. `1536` is `EnvConfig.embedDims`' default and the literal `derivative_embeddings` already uses; the column stays a literal in DDL exactly as it is today.

`ON DELETE CASCADE` is **semantics, not DDL** — a `vec0` virtual table takes no `REFERENCES` clause (which is why `derivative_embeddings` has none either; §12 Q16). Cascade is done in code, in the two places that already do it for `derivative_embeddings`: `MemoryDataControls.pruneMemory(olderThan:)` gains `DELETE FROM context_embeddings WHERE version_id IN (SELECT id FROM maxmi_prune_versions)` **before** the `DELETE FROM versions` statements (`MemoryDataControls.swift:109-127`), plus the thread-pruned equivalent, and `deleteAllMemory()` gains `DELETE FROM context_embeddings` next to its `DELETE FROM derivative_embeddings` (`:157`). A new `VectorIndex` pair mirrors the existing one: `insertContextEmbedding(versionID:vector:)` and the KNN read used by §14a's retrieval.

**Pipeline placement.** In `CapturePipeline.process`, on the **same tick** that extracts facts and **after** the fact/embedding loop, before `markExtracted`. Embed text per committed version:

```
"\(source_app) · \(source_title ?? "")\n" + ContentRenderer.render(structured, .compact(maxChars: 6_000))
```

One embedding per version. Same `relay.embed(text:)`, so the same shared `GeminiThrottle` (`GeminiClient` holds `GeminiThrottle.shared`), the same `MAXMI_EMBED_MODEL` (`gemini-embedding-001`) and the same 1536 dims — no new relay method, no new model, no new destination. `MemoryStore` gains `insertContextEmbedding(versionID:vector:)`; `PipelineVersion` gains `sourceTitle: String?` and `compactContent: String` (the `.compact(maxChars: 6_000)` render), produced by `StoreAPI.pendingWork` — which must start selecting `structured_ciphertext` to do it — so `CapturePipeline` never decrypts or renders (§12 Q22).

**Skip rule.** A version whose `compactContent`, trimmed, is empty or **shorter than 40 characters** is not embedded and not retried — it is chrome, not memory.

**Backoff / retry.** Failure enqueues `store.enqueueRetry(kind: "embed_version", versionID: v.id, derivativeID: nil, ...)` into the existing `retry_queue` (`kind` is a plain `TEXT` column with **no** CHECK constraint, so a new kind needs no migration) and reuses the existing `30_000 · 2^attempts` capped at `3_600_000` backoff in `StoreAPI.enqueueRetry`. A failed context embedding **never** fails the extract: facts already committed stay committed, and `markExtracted` still runs. Because `pendingWork` gates on `extract_status = 'pending'`, a version cannot re-qualify through the extract path once marked complete, so Phase C adds a separate "versions with no `context_embeddings` row" query to drive the retry (§12 Q22).

**Backfill: none.** Only versions committed after v11 get a context embedding. Recorded as a decision, not an oversight — backfilling would re-embed the entire history in one burst and buys nothing the next capture of the same thread does not.

**Retrieval.** `MemoryQueries.searchMemory` embeds the query once (unchanged, including the 32-entry LRU) and runs **two** KNN reads with that one vector: the existing `factHits` over `derivative_embeddings` (unchanged) and a new `contextHits` over `context_embeddings`. Both apply the same `MemoryQueries.similarityDistanceFloor = 0.75`. `vec0` returns **L2** on unit vectors, so `contextHits` converts at the read boundary exactly as `factHits` does — `cosineDistance = (l2 * l2) / 2.0` (`QueryAPI.swift:42-45`) — and the floor is compared against the converted value, never the raw distance.

**Rendering.** The markdown keeps the existing fact list first and unchanged, then appends, only when there is at least one context hit above the floor:

```
### Matching context

- <source_app> · <source_title ?? source_key> · <absolute (relative)> · thread `<thread_id>`
  <= 300 chars of the .compact render
```

At most **5** version hits. The snippet is the **first 300 characters** of that version's `.compact` render — no per-line scoring, no highlighting, no reordering in this phase. The trailing `_N results in this page_` line and the cursor footer keep counting **facts only**; context hits are supplementary and are not paginated (see §12 Q17).

**Request shape UNCHANGED.** `MaxMiToolsDefinitions.all` is not touched: `search_memory` keeps its name, its `query`/`limit` properties, the shared retrieval properties, and `required: ["query"]`. Only the response *text* gains a section. `MCPStructuredNoChangeTests` is therefore updated **deliberately**, not incidentally: its tool-name/argument assertions stay verbatim and it gains one assertion that the new section appears when a context hit exists and is absent when none does.

**Cost and privacy.** Embedding calls roughly double (one per version on top of one per derivative), which is acceptable on `gemini-embedding-001` and is the whole point of the reversal. No new privacy surface: the raw content is already stored encrypted in `versions.content` / `structured_ciphertext`, the vector lands in the same database file under the same Keychain-held key, and the text is sent to the one destination captures already go to.

**Error handling.** A missing `structured_ciphertext` resolves through `LegacyContentAdapter` exactly as everywhere else, so a pre-v10 row still renders and still embeds. A `relay.embed` failure routes to `embed_version` retry and is logged with `SafeLogger`, never with content interpolated. A `context_embeddings` insert failure is treated identically. `contextHits` throwing is caught inside `searchMemory` and degrades to the fact-only response — a broken second index must never take out memory search.

**Tests.**
- Migration `v11`: `context_embeddings` exists, accepts a 1536-float insert, and `Migrations.currentIdentifier == "v11"`; a `pruneMemory` / `deleteAllMemory` round-trip removes its rows.
- Pipeline: exactly **one** context embedding per committed version (assert call count on a mock relay), and **zero** for a version whose render is empty or 39 characters.
- Retry: a failing embed enqueues `kind == "embed_version"` and does **not** mark the version's extract failed.
- Retrieval: a phrase present only in the raw rendered content and in **no** derivative returns a `### Matching context` hit; the L2→cosine conversion is asserted against a hand-computed value so the floor cannot silently invert; the section is absent when there are no context hits.
- Guard test: `MCPStructuredNoChangeTests` asserts the request shape is byte-identical and the new section is the only response-text change.

**Exit criterion.** A phrase visible on a captured page but absent from every extracted fact for that thread is findable via `search_memory` within one pipeline tick.

### 14b. Web-app parsers by host (Phase D, tasks 22-26)

**Purpose.** M8 already routes native Slack, Discord, Messages and WhatsApp through anchored parsers, and Phase D Task 5 already builds the host map. The five surfaces the user actually lives in on the web — Gmail, LinkedIn messaging, Outlook web, Slack web, Teams web — still land as generic v2 pages. These five parsers make a web tab of a chat or mail surface produce the same typed `.conversation` a native window does.

**Data model.** None. No table, no column, no migration. Every parser produces existing Phase A types (`Conversation`, `Message`, `GenericPage`, `Block.tableRow`) and existing `CaptureContentKind` cases.

**Pipeline placement.** Each is a `StructuredParser` (§7b) registered by **host** via `ParserConfig.hosts` — the field Phase D Task 5 adds precisely for this, where a leading-dot entry (`".slack.com"`) is a suffix match. Routing is `ParserRegistry.host(fromURL:)` → `structuredParser(forHost:)`, reached from the browser path, so no native-app claim is involved and `preferOverNative` stays `false` unless a native app shares the bundle. `AXQuery` is the only traversal API; DOM anchors are available because Task 1 reads `AXDOMClassList` / `AXDOMIdentifier` under an `AXWebArea`, gated per parser by `ParserConfig.attributeSet: ["AXDOMClassList", "AXDOMIdentifier"]`.

**The anchors below are CANDIDATES from DOM knowledge, not verified reads.** Before relying on any of them the implementer MUST dump the live surface with `tools/ax-snapshot-record.swift <bundle-id> <out.json>` (Phase D Task 6) and confirm which selectors actually surface through AX; the **verified** anchors, and every candidate that did not survive, go in the parser's header comment. Web AX frequently drops `data-*` attributes entirely, so a candidate that is a `data-tid` is the most likely to need a fallback.

**Task 22 — Gmail (`mail.google.com`).** `contentKind` `.email` on every path.
- Open thread → `.conversation`. `channel` = the subject from the thread's `h2` heading, falling back to the window title. One `Message` per message container `div.adn`; sender name from `.gD`, address from `.go`; `timeString` from `.g3`; body from `.a3s`. **Expanded messages only** — a collapsed row carries no `.a3s` and is skipped rather than emitted with an empty body.
- Inbox / list view → `.generic`, one `.tableRow(cells:selected:)` per row `tr.zA`, cells `[sender, subject + snippet, time]`.
- Compose window → the draft as `Message(isUser: true, isDraft: true)` read from the `div[aria-label="Message Body"]` editor.

**Task 23 — LinkedIn messaging (`linkedin.com/messaging`).** `.conversation`. Message list items `li.msg-s-message-list__event`; sender `.msg-s-message-group__name`; `timeString` `.msg-s-message-group__timestamp`; body `.msg-s-event-listitem__body`. `isUser` is true when the group name equals the signed-in user's name, read from the "Me" nav item or the profile card; when that name cannot be resolved the message is emitted with `isUser: false` and a header-comment note saying so — never guessed from geometry. `channel` from the conversation header `.msg-entity-lockup__entity-title`. Composer `.msg-form__contenteditable` → draft. **Every other LinkedIn page stays generic v2** — the parser returns nil off `/messaging`.

**Task 24 — Outlook web (`outlook.office.com`, `outlook.live.com`).** `contentKind` `.email`.
- Reading pane → `.conversation`, one `Message` per message card `div[aria-label^="Message"]` (or `role=document` when the aria-label shape differs). Sender and time come from the card header, where `AXDescription` commonly carries a `"From: X, Sent: T"` string — parse it, and fall back to the header's static texts in visual order.
- Message list → `.generic` `.tableRow`s.
- Compose → draft `Message(isUser: true, isDraft: true)`.

**Task 25 — Slack web (`app.slack.com`).** `.conversation`, mirroring the native Slack anchors so both surfaces render identically: message items `div.c-virtual_list__item` / `.c-message_kit__background`; sender `.c-message__sender`; timestamp `.c-timestamp` (the time is in its `aria-label`, i.e. folded into `label`); text `.p-rich_text_section`; composer `.ql-editor` → draft. `channel` from the header `.p-view_header__channel_title`; `isGroup` is `true` for a channel (leading `#`), `false` for a DM. Registered with hosts `["app.slack.com", ".slack.com"]` — the same entries Phase D Task 10 already gives `SlackParser`, so Task 25 **extends `SlackParser`'s existing config and DOM path** rather than adding a second parser for the same host.

**Task 26 — Teams web (`teams.microsoft.com`, `teams.cloud.microsoft`).** `.conversation`. Messages `div[data-tid="chat-pane-message"]`; sender `[data-tid="message-author-name"]`; time `[data-tid="message-timestamp"]`; body `[data-tid="chat-pane-message"] .fui-ChatMessage__body`. `data-tid` is the least likely candidate to surface in AX: if it does not, fall back to the `AXDescription` / `role=group` structure and record in the header comment exactly what did work. `channel` from the header; composer `[data-tid="ckeditor"]` → draft.

**Refusal rule (explicit).** When a parser finds no message container on a page that *is* a chat surface it returns **nil (NOT_HANDLED)**, so §4f rule 3 routes the window to `GenericPageExtractor` and the page is still captured as generic v2 with the `"GenericPageExtractor.v2/fallback/<ParserTypeName>"` health marker. It **refuses** only for a compose-only window with an empty draft — there is genuinely nothing to store, and a refusal is how the health ledger records that. Because `StructuredParser.parse(_:context:)` is non-throwing, the refusal is raised from the app's `SourceParser.parse(window:app:)` bridge, which throws, exactly as `NativeConversationParser` does today (`NativeConversationParser.swift:113,118`); see §12 Q18.

**Rendering / UI.** Nothing new. `ContentRenderer` already renders `.conversation` as `"(From: <sender>)(sent <time>): <text>"` with `"You"` for `isUser` and a `" (draft)"` suffix, and `.tableRow`s as `a | b | c`. No UI change; the win shows up in capture summaries, the timeline and `get_latest_context`.

**Error handling.** `AXQuery` never throws and an unmatched path yields nil / `[]`, so a DOM rename degrades to nil → generic v2 → health marker, never to a crash or a lost capture. A parser that finds messages but cannot resolve a sender emits `Authorship`-neutral text rather than inventing a name. Secure fields are never read anywhere on these paths (§4e).

**Tests.** Per parser: **≥2 recorded, hand-scrubbed AX fixtures** with a golden `CapturedContent` JSON, **at least one at a nonzero window origin**, loaded through the shared `fixture(_:)` / `goldenCapturedContent(_:)` helpers from Task 6 and registered in Task 21's `PhaseDCoverageTests.coverage` dictionary so the coverage assertion covers them machine-checked. Plus, per parser: the nil-not-refusal path when no message container matches; the refusal path for an empty compose-only window; the draft message carries `isUser: true, isDraft: true`; Gmail's collapsed-message skip; LinkedIn's off-`/messaging` nil; Slack web and native Slack render byte-identically from equivalent fixtures. Five new rows are added to Task 21's Step 5 live checklist (Gmail thread + compose, LinkedIn conversation, Outlook reading pane, Slack web channel, Teams chat), each read back with `get_latest_context` using `{"source": "Web", "content_kinds": ["conversation"|"email"], "limit": 1}` and each verified against a capture timestamped strictly after the `open MaxMi.app` in that ritual.

**Exit criterion.** Each of the five hosts, opened in a browser tab, produces a typed capture with real senders, times and bodies — visible as `(From: <name>)(sent <time>): <text>` lines through `get_latest_context` — and the anchors that produced them are recorded, verified, in each parser's header comment.

### 14c. Daily check-in (Phase C)

**Purpose.** Minimi's morning check-in, which M8 previously left to M9: one short second-person briefing per day covering what you worked on yesterday, what is still open, and what is on today. **Reminders and time slots stay M9** — this addition schedules nothing, stores no `remind_at`, and sends no slot legend (§12 Q9 is unchanged).

**Data model.**

```sql
-- Migrations.swift: m.registerMigration("v12")
CREATE TABLE checkins (
  day_bucket                INTEGER PRIMARY KEY,
  generated_at_ms           INTEGER NOT NULL,
  summary_ciphertext        TEXT NOT NULL,
  open_item_ids             TEXT NOT NULL,   -- JSON array of agent_action_items.id
  resolved_yesterday_count  INTEGER NOT NULL,
  dismissed_at_ms           INTEGER NULL,
  prompt_version            TEXT NOT NULL
);
```

`day_bucket` is `Store.dayBucket(forMs:timeZone:)` (`ActivityStore.swift:429`), the same local-timezone bucket `activity_app_visits` and `activity_sessions` use — **not** `HourBucket`. `summary_ciphertext` is `TEXT` written through `AESGCMFieldCipher`, like every other ciphertext column (§12 Q2). The `PRIMARY KEY` on `day_bucket` is what makes "at most one row per day" a database fact rather than a code convention, and makes Regenerate an `INSERT … ON CONFLICT(day_bucket) DO UPDATE`.

Migration identifier: **`v12`**, or folded into `v11` if Phase C ships §14a and §14c in one migration. The spec permits **either** — the Phase C plan decides and states which, and `Migrations.currentIdentifier` follows. `DatabaseRecovery` again needs no edit (derived from the migrator). `checkins` is added to `deleteAllMemory()`; `pruneMemory(olderThan:)` deletes rows whose `generated_at_ms < cutoffMs`.

**Trigger.** The first pipeline tick at or after **08:00 local time** on a day for which no `checkins` row exists for today's `day_bucket`. At most **one** automatic generation per day: the `day_bucket` primary key plus an insert-if-absent check enforce it even across a relaunch. Plus a manual **"Check in now"** menu-bar item (the same `NSMenuItem` pattern as `"Start Voice Note"`, `MenuBarController.swift:60`) that regenerates and **overwrites** today's row. Failures retry on the existing backoff shape — `30s · 2^n` capped at 1h, the same curve as `StoreAPI.enqueueRetry` — and **never block capture**: generation is fire-and-forget off the tick, and a thrown error is logged and left for the next tick.

The tick that drives it is the `AppWiring` timer that calls `CapturePipeline.tick()`, not `CapturePipeline` itself: `CapturePipeline` lives in `MaxMiCore` and cannot reach `MaxMiActivity` (§12 Q19). This is the same wiring the hourly agent already uses.

**Input.** A new `CheckinInputBuilder` in `MaxMiActivity`, reading through a `CheckinRepository` protocol with the concrete adapter in `Sources/MaxMi/` — the established pattern (`ActivitySummaryRepository`, `AgentRepository`, and §5d's `TimelineRepository`), because `MaxMiActivity` depends only on `MaxMiCore` and must not touch GRDB. Every field below is untrusted captured content and is **nonce-fenced and sanitised** with the same mechanism as `AgentPrompts.hourlyReview` (`AgentPrompts.swift:10-13,19-41`): fence-marker stripping, control-character collapse, per-field cap.

| Input | Source | Cap |
|---|---|---|
| Open items | `agent_action_items` where `status = 'open'`: title (from `title_ciphertext`), details (`details_ciphertext`), created-at (**the column is `detected_at`, not `created_at`** — §12 Q20), age in whole days | 15 items |
| Resolved yesterday | `agent_action_items` where `status = 'resolved'` and `resolved_at` falls in yesterday's `day_bucket`: a count plus titles | count + 10 titles |
| Yesterday's timeline | `TimelineBuilder.render` (§5d) over yesterday's local day | 2_500 chars |
| — fallback | When Phase B's timeline is not available: yesterday's top 5 **apps** by summed visit time from `activity_app_visits`, each with the `source_title` of that app's most recent `latest_contexts` row (§12 Q21 — `activity_app_visits` carries `app_bundle`/`app_label`, not `thread_id`, so the ranking is per app and titles are joined in) | 5 rows |
| Today's calendar | `latest_contexts` rows with `content_kind = 'calendar'` captured today, decoded to `.calendar` and read as `CalendarEvent.title` + `dateString` | 8 events |
| Local date + weekday | the injected clock | — |

**Prompt.** `AgentPrompts.dailyCheckin(input:)`, model = `EnvConfig.extractModel`, same shared `GeminiThrottle`, same nonce fences. Instruction:

> Write the user's morning check-in as 3-6 short lines in second person. Line 1: what they mainly worked on yesterday (from the timeline). Then open items worth attention today (max 3, most recent first, never invent). Then today's calendar if provided. Plain text, no headers, ≤ 90 words. If there is nothing meaningful, write one line saying so.

`prompt_version` is written as a named constant, `"checkin-v1"`, on every row — the same discipline §12 Q8 imposed on `activity_sessions.prompt_version`. A prompt-version bump does **not** retroactively regenerate past days; the check-in is a dated artefact, not a cache.

**Surface.** A **"Today" card at the top of the menu-bar popover** — `TrayHomeView`, above `sectionRow` and the recent-captures list, inside the existing always-dark `Theme` (`.preferredColorScheme(.dark)`, `Theme.background`). It shows the check-in text, the generated time, a **Dismiss** button (sets `dismissed_at_ms` and hides the card until tomorrow's bucket) and a **Regenerate** button (overwrites today's row). A new `CheckinViewModel` + `CheckinDTO` in `MaxMiUI` follow the `TrayHomeViewModel` / `TrayHomeDTO` pattern and refresh on the same 2-second popover poll. States: **pending** (before 08:00, or generation in flight) → a one-line placeholder; **ready** → the text; **dismissed** → the card is absent; **empty** → the model's "nothing meaningful" line, rendered as-is. **No notifications in this phase.**

**Error handling.** A relay failure leaves no row and logs through `SafeLogger` with no content interpolated; the next tick retries on the backoff curve; the card stays in **pending**. A decrypt failure on `summary_ciphertext` renders the card as **empty** rather than showing a marker string. A malformed `open_item_ids` JSON is treated as an empty array. Nothing here can throw into the capture path.

**Tests.**
- `CheckinInputBuilder`: every cap enforced (15 / 10 / 2_500 / 5 / 8); fence markers and control characters stripped from every interpolated field; yesterday/today bucketing correct **across midnight and across a timezone change**, with an injected clock and an injected `TimeZone`; the no-timeline fallback path produces the app-ranked rows.
- Trigger: no generation before 08:00; exactly one generation on the first tick at or after 08:00; no second generation later the same day; a new day generates again; a relaunch mid-day does not regenerate; "Check in now" overwrites.
- Store: `checkins` round-trip through `AESGCMFieldCipher` including `dismissed_at_ms` NULL → set; `ON CONFLICT(day_bucket)` overwrite; `deleteAllMemory` and `pruneMemory` remove rows.
- Prompt: a golden string for a fixed input, asserting the instruction text, the fences, and that no reminder or slot vocabulary appears anywhere in it.
- View model: pending / ready / dismissed / empty states, and that Dismiss hides the card for today only.

**Exit criterion.** On the first tick after 08:00 a `checkins` row exists for today, its text appears as the Today card at the top of the popover, and Dismiss hides it for the rest of the day and not beyond.
