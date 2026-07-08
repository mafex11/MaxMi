# MaxMi — Milestone 4: Native-App Parser Framework

**Date:** 2026-07-08
**Status:** Approved design
**Depends on:** M1 (capture→DB), M2 (MCP search), M3 (encryption+signing) — all merged to main and live-verified.

## 1. What we're building

Extend capture beyond browser tabs to native macOS apps. M4 ships an **app-agnostic parser framework** with a **generic AX fallback** (so *every* app gets baseline capture from day one) plus **one dedicated parser: Slack**. WhatsApp — the other app the user runs daily — rides the generic fallback in M4 because its Catalyst AX tree is too shallow to feed a real parser without a native helper (verified live: 64 nodes / 9 static texts vs Slack's 634 nodes / 179 static texts). A WhatsApp native-helper parser is deferred to a follow-up.

This mirrors Minimi's real architecture (verified from the installed app): a generic `get-native-content`/`get-web-content` fallback plus ~8–10 accreted per-app parsers, several with native helper binaries. M4 builds the framework + fallback + the first dedicated parser; further apps become cheap per-app follow-ups.

**Success test:** with Slack frontmost, browsing channels produces correctly-keyed Slack threads with sender-attributed messages; with an unregistered app frontmost (Notes, WhatsApp), the generic fallback still captures its visible text; all captured native content flows through versioning → encryption → extraction → MCP search (you can ask "what did I discuss in Slack about the deploy").

## 2. Non-goals for Milestone 4

- **No WhatsApp dedicated parser.** Its AX tree can't support one without a native helper (§8 residuals); it uses the generic fallback in M4.
- **No native helper binaries.** M4 stays all-Swift, in-process, matching M1. (Native helpers are how a future WhatsApp/Teams parser would work — deferred.)
- **No document parsers** (Notion/Obsidian/Notes get the generic fallback for now).
- **No new capture modality** — this is AX-tree capture, same as M1, applied to more apps. No audio/meetings (M5).
- **No web-app variants.** Slack-in-a-browser is already captured by M1's browser path; M4's Slack parser targets the *native* Slack app only.
- **No changes below the Store boundary.** Versioning, encryption, extraction pipeline, MCP tools are all untouched — parsers only produce cleaner `CaptureInput`.

## 3. Architecture

A parser layer in `MaxMiCapture`, between the existing `AXReader` (builds the `AXNode` value tree) and `Store.commitCapture`:

```
MaxMiCapture/
  SourceParser.swift     protocol SourceParser + ParsedCapture struct + AppInfo struct
  ParserRegistry.swift   bundle-id -> SourceParser; parser(for:) lookup; registers SlackParser
  SlackParser.swift      AXRow-walking chat parser; slack:<workspace>/<channel> keys
  GenericAXParser.swift   M1's visible-text-in-visual-order behavior, app+title keyed
  AXReader.swift         MODIFY window locator: AXFocusedWindow -> AXMainWindow -> AXWindows.first
  FocusObserver.swift    MODIFY gate: browser OR registered-parser OR known-capturable app
MaxMi/
  AppWiring.swift        MODIFY captureFrontmost: dispatch through registry, per-app pause,
                         source_app from parser (not hardcoded "Web")
  MenuBarController.swift per-app pause menu (submenu of recently-seen apps)
```

**Capture flow (one cycle):**
```
frontmost app changes / focus / recapture tick
  -> is it capturable? (browser bundle-id OR registry has a parser OR known-app allowlist)   no -> ignore
  -> per-app pause set for this bundle id?   yes -> skip
  -> AXReader.snapshot(pid) -> AXNode tree   (locator: focused -> main -> windows.first)
  -> registry.parser(for: bundleID)?
       yes (Slack): parser.parse(window, app) -> ParsedCapture
            -> nil/throw?  LOG + SKIP (never fall back to dumping a registered app's raw tree)
       no:  GenericAXParser.parse -> ParsedCapture  (visible text, app+title key)
  -> denylist check on sourceKey (existing) -> skip if blocked
  -> per-thread pause on sourceKey?   yes -> skip
  -> commitCapture(CaptureInput(sourceApp, sourceKey, sourceTitle, content))
```

Everything after `commitCapture` is unchanged M1/M2/M3.

## 4. The parser contract

```swift
public struct AppInfo: Sendable {
    public let bundleID: String
    public let name: String          // NSRunningApplication.localizedName, e.g. "Slack"
    public let windowTitle: String?
}

public struct ParsedCapture: Sendable, Equatable {
    public let sourceApp: String     // "Slack", "WhatsApp", "Notes" — replaces hardcoded "Web"
    public let sourceKey: String     // stable thread identity (REQUIRED, non-empty)
    public let sourceTitle: String?
    public let content: String       // visual-order text the pipeline will extract facts from
}

public protocol SourceParser: Sendable {
    /// Parse a window's AX tree into a capture, or nil if this parser can't handle it.
    /// Throwing is treated identically to nil by the caller (log + skip), never a crash.
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
}
```

**Invariant:** `sourceKey` must be non-empty and stable across re-captures of the same logical thread — this is what makes M1's per-hour versioning/dedup work. A parser returning an empty key is a bug; the caller treats empty-key results as `nil` (skip).

## 5. Slack parser (the one dedicated parser)

Verified live: window reached via `AXMainWindow`; content is `AXRow`s under the message list, `AXStaticText` for sender + message, sidebar `AXStaticText` for workspace/channel/DM names.

- **Window:** via the new AXReader locator order (Slack leaves `AXWindows` empty, populates `AXMainWindow`).
- **source_key:** derived from the window title, which Slack formats as `<view> - <workspace> - Slack` (observed: `"Threads - Layerpath - Slack"`). Parse to `slack:<workspace>/<view>` (lowercased, spaces→`-`). If the title doesn't match the expected shape, fall back to `slack:<full-window-title>` — still stable per view. (Channel-level precision within a workspace is best-effort in M4; the title is the reliable signal.)
- **source_app:** `"Slack"`.
- **content:** walk `AXRow` descendants of the main content area in visual order (top→bottom by frame y); within a row, join `AXStaticText` values; emit `sender: message` where a sender line is detectable, else the raw line. Cap total content to a sane size (e.g. 8000 chars, newest-anchored) so a huge scrollback doesn't bloat one version. Exclude the sidebar/nav chrome (channel list) from `content` — those are navigation, not conversation — by skipping the known sidebar subtree (identified by role/position); if unsure, include (over-capture of channel names is harmless, matches generic behavior).
- **Denylist:** applies to `source_key` as usual; additionally a Slack workspace/DM can be per-thread paused (§7).

## 6. Generic AX fallback

`GenericAXParser` reproduces M1's proven behavior for any capturable app without a dedicated parser:
- Collect `AXStaticText` values in visual order (frame y then x), newline-joined, same as M1's `BrowserTabExtractor.visualOrderText`.
- **source_key:** `<bundleID>:<windowTitle>` (e.g. `net.whatsapp.WhatsApp:WhatsApp`, `com.apple.Notes:<note title>`). Window title is the only stable signal for arbitrary apps; documented as coarse (a title-less or generic-title window collapses to one thread — acceptable for fallback).
- **source_app:** the app's localized name.
- **empty content** (nothing visible / shallow tree like WhatsApp when idle) → return nil (skip); don't create empty threads.

The fallback is deliberately coarse: it guarantees coverage, and any app that deserves better gets promoted to a dedicated parser later.

## 7. Sensitive-content control

Native chats/docs are more sensitive than web pages (private DMs, personal notes). M4 adds user control beyond M3's at-rest encryption:
- **Per-app pause:** a settings-backed set of paused bundle ids; the capture gate skips a paused app entirely. Menu-bar submenu "Pause capture for ▸" lists recently-seen capturable apps with checkmarks.
- **Per-thread pause:** a settings-backed set of paused `source_key`s (e.g. one Slack DM); the gate skips a paused key. (Exposed minimally in M4 — a menu action "Pause capture for current thread"; full management UI is later.)
- **Existing denylist** still applies to every `source_key`.
- **Defaults:** capture-on for all capturable apps (the user chose these). Stored in the existing `settings` table (keys `paused_apps`, `paused_threads` as JSON arrays), read at capture time.

## 8. Threat model / residual notes

- **WhatsApp under generic fallback captures little** (shallow AX). That's honest, not a regression — WhatsApp was never captured before M4. A real WhatsApp parser needs a native helper (deferred).
- **source_key coarseness for generic apps:** apps with unstable or duplicate window titles may merge or fracture threads. Acceptable for fallback; dedicated parsers fix it per-app.
- All M3 protections hold: content is encrypted at rest; native-app content is as sensitive as any and is covered by the same `enc:v1:` encryption and the new per-app/per-thread pause.
- Gemini still receives plaintext content for extraction (unchanged since M1, by design).

## 9. Error handling

- **Registered parser throws or returns nil:** log to stderr, SKIP this capture. NEVER fall back to `GenericAXParser` for a registered app — a Slack parser bug must not degrade into dumping Slack's raw AX tree (which could include content the parser intentionally excluded). This is an explicit exit criterion.
- **AXReader returns no window** (empty tree, app mid-launch): the M1 Chromium retry-shortly logic applies to any Electron app; otherwise log + skip.
- **Empty parsed content:** skip (no empty threads), both parsers.
- **Unknown/unregistered app that isn't in the capturable allowlist:** ignored silently (not every app should be captured).
- Capture failures never crash; the per-cycle try/catch from M1 covers the new dispatch.

## 10. Testing strategy

- **MaxMiCaptureTests** (fixture-driven, no live apps in CI — recorded `AXNode` JSON trees, same pattern as M1's browser fixtures):
  - `SlackParser`: a recorded Slack window fixture → asserts `source_app == "Slack"`, `source_key` like `slack:layerpath/threads`, sender-attributed message lines in visual order, sidebar chrome handling, content cap.
  - `GenericAXParser`: a recorded generic-app fixture (e.g. Notes) → visual-order text, `bundleID:title` key; empty tree → nil.
  - `ParserRegistry`: returns SlackParser for the Slack bundle id, nil for an unregistered id.
  - No-silent-fallback: a Slack fixture that makes SlackParser return nil → caller does NOT invoke GenericAXParser (assert via a spy/registry seam).
  - `AXReader` window-locator order: a fixture/mock where `AXWindows` is empty but `AXMainWindow` present → window still found. (Pure-logic portion; live AX stays manual.)
  - Per-app / per-thread pause: paused bundle id or key → capture gate returns skip.
- **Live exit test** (manual, §11): Slack + WhatsApp + Notes, real capture, then MCP search.

## 11. Milestone exit criteria

1. Framework dispatches by bundle id: Slack → SlackParser, everything capturable else → GenericAXParser.
2. Slack produces threads keyed `slack:<workspace>/<view>` with sender-attributed messages; visible in the DB (metadata cleartext, content `enc:v1:`).
3. An unregistered app (Notes, WhatsApp) captures via the generic fallback — proving coverage.
4. A registered parser returning nil/throwing does NOT silently dump the raw tree (no-silent-fallback holds).
5. Captured native content flows end-to-end: versioned, encrypted, extracted to facts, and returned by `search_memory` (ask a Slack-content question, get a decrypted answer).
6. Per-app pause (menu) and per-thread pause skip capture for the chosen target; denylist still applies.
7. Full fixture-driven test suite green; no live apps in CI; no new warnings.

## 12. Later milestones (roadmap — deferred per-app parsers are cheap follow-ups on this framework)

- **WhatsApp dedicated parser** (needs a native helper binary like Minimi's `get-whatsapp-content`).
- **Document parsers:** Notion, Obsidian, Notes (document-body shape — one reusable parser with per-app locators).
- **Mail** (message shape: sender/subject/body).
- **More chat:** Telegram, Discord, iMessage.
- **Conversation apps:** ChatGPT, Claude desktop.
- Each is a self-contained task: register bundle id + write AX locators + fixture test. No new milestone spec needed — the framework absorbs them.
- M5 (meetings), M6 (hourly agent + timeline), M7 (team sharing) unchanged.
