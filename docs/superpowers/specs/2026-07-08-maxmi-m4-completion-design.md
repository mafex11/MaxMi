# MaxMi — M4 Completion: Slack Refinement + Document Parsers

**Date:** 2026-07-08
**Status:** Approved design
**Extends:** `2026-07-08-maxmi-native-app-parsers-design.md` (M4). This is a completion addendum, NOT a new milestone — it finishes M4 by refining the one shipped parser and adding the document-shape parsers, so M4 can be declared closed.
**Depends on:** M4 framework (SourceParser, ParserRegistry, GenericAXParser, per-app pause) merged and live-verified.

## 1. What we're building

Two things to close M4:

1. **Slack message isolation (Tier 1).** The shipped `SlackParser` includes sidebar/nav chrome (channel list, workspace switcher) alongside messages, so extracted facts are coarse ("viewing workspace, channels include design-jam…") instead of message content. Refine it to capture only the message area.

2. **Three dedicated document parsers (Tier 2): Notion, Obsidian, Notes.** Each is its own `SourceParser` registered by bundle id — matching Minimi's model of separate per-app parsers over a shared traversal core. They share an internal `DocumentExtraction` helper for the mechanical text walk, but each owns its own key derivation and node-selection locators (verified live to differ per app). This is deliberately NOT one config-driven parser: per-app AX differences are real code, and isolating them means a Notion AX change can't break Obsidian.

**Mail is explicitly deferred** — it's a message-list table (352 AXRow/AXCell, nil window title, heavy custom roles), not a document shape; a dedicated Mail parser is a later follow-up. Mail continues to capture via the generic fallback.

**Success test:** Slack facts become message-content-level; Notion/Obsidian/Notes each produce correctly-keyed threads with document body text, encrypted at rest, searchable via MCP.

## 2. Non-goals

- **No Mail parser** (deferred; rides generic fallback).
- **No WhatsApp parser** (still deferred; needs a native helper, unchanged from M4).
- **No config-driven mega-parser.** Separate structs per app; shared helper only for the mechanical walk.
- **No new milestone machinery** — no new modality, nothing below `commitCapture` changes, no new spec sections beyond parsers.

## 3. Live-probe findings (the evidence this design rests on)

Probed each app's AX tree via `AXFocusedWindow`→`AXMainWindow` (the M4 locator), node-budgeted:

- **Slack:** rich (634 nodes). Message rows are `AXRow`s under the main content area; sidebar is a distinct `AXGroup` subtree of `AXStaticText` (channel names). The fix is to walk only the message-area rows, not the whole window.
- **Obsidian:** tidy (141 nodes). Title `Welcome - Obsidian Vault - Obsidian 1.12.7`; body in `AXTextArea` + `AXStaticText`.
- **Notion:** rich, deep (1651 nodes, 956 AXGroups). Title `June LP` = the page name; body heavy in `AXTextArea` (219) + `AXStaticText` (223). Needs the node budget (already in AXReader).
- **Notes:** running, document-body shape (title = note title, body AXStaticText/AXTextArea) — consistent with the document family.
- **Mail:** 5531 nodes, `AXRow`/`AXCell` table, nil title, `?:3155` custom roles — message-list shape, deferred.

## 4. Slack refinement (Tier 1)

Change `SlackParser` to isolate the message area:
- Locate the message container and collect `AXRow`s only from within it, excluding the sidebar/nav subtree. Heuristic (in priority order, best-effort per spec §5): prefer the largest-area `AXGroup` that contains `AXRow`s and is NOT the leftmost sidebar column (sidebar is a narrow left column, ~220pt wide, at x≈0); if that's ambiguous, exclude `AXRow`s whose x-origin is within the sidebar band (x < 240) and whose siblings are channel-name `AXStaticText`.
- Everything else unchanged: `slack:<workspace>/<view>` key, sender-attributed lines, 8000-char hard cap, empty→nil.
- The existing SlackParser fixture is extended with a sidebar subtree so the test proves sidebar rows are excluded from content while message rows are kept.

## 5. Document parsers (Tier 2)

New shared helper + three parsers in `MaxMiCapture`:

```
Sources/MaxMiCapture/
  DocumentExtraction.swift   internal helper: visual-order body text from AXTextArea+AXStaticText,
                             content cap 8000 newest-anchored, returns nil if empty
  NotionParser.swift         key notion:<page-title>; body via DocumentExtraction
  ObsidianParser.swift       key obsidian:<vault>/<note> from "<note> - <vault> - Obsidian <ver>"; body via DocumentExtraction
  NotesParser.swift          key notes:<note-title>; body via DocumentExtraction
```

- Each conforms to `SourceParser`; registered in `ParserRegistry` by bundle id (`notion.id`, `md.obsidian`, `com.apple.Notes`).
- **Shared `DocumentExtraction.bodyText(in:)`** — the mechanical part (collect `AXTextArea` + `AXStaticText` values in visual order top→bottom, join, cap 8000 newest-anchored). No per-app logic lives here.
- **Per-app parser owns:** its bundle id, its `sourceApp` name, and its `sourceKey` derivation (the parts that genuinely differ — Notion's bare-title key, Obsidian's `view - vault - version` title parse, Notes' note-title key). Each returns nil if `DocumentExtraction` yields empty.
- Key collisions/coarseness (e.g. two Notion pages with the same title) are best-effort, same standard as Slack keys (spec §5) — Gemini-tolerant, thread-fracture not data-loss.

## 6. Registry & dispatch

`ParserRegistry` gains three entries (Notion/Obsidian/Notes → their parsers). `CaptureDispatch` is unchanged — registered apps get their parser with no-silent-fallback; unregistered still get generic. AppWiring's `KnownApps` allowlist already includes these bundle ids (they were generic-fallback targets in M4), so widening from fallback to dedicated parser is purely a registry addition — no gate change. Mail stays in `KnownApps` → generic fallback.

## 7. Error handling / encryption / pause

All inherited from M4, unchanged: no-silent-fallback (a doc parser returning nil/throwing logs + skips, never falls to generic); content encrypted at rest (M3); per-app and per-thread pause apply to the new apps automatically (they flow through the same gates); empty content → skip.

## 8. Testing

- **SlackParserTests:** extend the fixture with a sidebar subtree; assert sidebar channel names do NOT appear in content, message rows DO, key unchanged.
- **DocumentExtractionTests:** visual-order body from mixed AXTextArea/AXStaticText; cap; empty→nil.
- **NotionParserTests / ObsidianParserTests / NotesParserTests:** each with a recorded/synthetic fixture → correct key derivation + body text + sourceApp; empty→nil.
- **ParserRegistryTests:** extend — Notion/Obsidian/Notes bundle ids return their parsers; an unregistered id still returns nil.
- Fixture-driven, no live apps in CI (M4 policy). Live §9 walkthrough manual.

## 9. Exit criteria (closes M4)

1. Slack facts are message-content-level, not sidebar chrome (live: search returns actual message topics, not "channels include…").
2. Notion, Obsidian, Notes each produce a dedicated thread (`notion:`/`obsidian:`/`notes:` key), NOT the generic `<bundleid>:<title>` fallback key.
3. Each new app's document body is captured, encrypted at rest, extracted to facts, and returned by `search_memory`.
4. Mail still captures via generic fallback (unchanged); no dedicated Mail thread.
5. No-silent-fallback holds for the new parsers.
6. Full fixture suite green; no live apps in CI; zero warnings.
7. With 1-5 verified live, **M4 is declared complete.**

## 10. Remaining deferred (post-M4 roadmap, unchanged)

- Mail dedicated parser (message-list shape).
- WhatsApp dedicated parser (native helper).
- Telegram/Discord/iMessage, ChatGPT/Claude conversation parsers.
- M5 meetings (the next real capability).
