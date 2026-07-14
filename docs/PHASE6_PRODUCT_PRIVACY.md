# Phase 6 product UX and privacy

Date: 2026-07-14

## Outcome

Phase 6 makes MaxMi understandable and controllable from the menu-bar app. The primary surfaces are:

| Surface | Purpose |
|---|---|
| Left-click tray home | Current capture state, recent memory, local search, pause/resume |
| Open MaxMi | Captures, synthesized Activity, Action Items, and Recordings |
| Capture Health | Content-free captured/deduplicated/skipped/failed diagnostics |
| Settings page in the tray popover | Setup, privacy, cloud review, retention, export, deletion, and application preferences |
| Right-click tray menu | Voice note, current-app/thread pause, diagnostics, Settings, quit |

Settings stays inside the status-item popover. The home gear and the right-click
**Settings…** action both navigate to that page, and **Back** returns to the tray home;
MaxMi does not create a separate Settings window.

The app remains useful when Activity Synthesis is disabled: local capture summaries, local search, recording history, privacy controls, and MCP retrieval do not depend on the Activity timeline.

## Tray home and local search

The status card distinguishes capturing, paused, and attention-required states. It shows the latest observed application/source and the number of captures in the current app session. Recent rows use the encrypted display-summary pipeline introduced in Phase 1.

Search is deliberately lexical and local. It decrypts a bounded candidate set of current raw contexts and facts inside the MaxMi process, matches case/diacritic-insensitively, deduplicates by thread, and returns a short local snippet. It never embeds the query, sends it to Gemini, or persists it.

## New-source cloud review

The review gate operates at source-app identity because that is the stable identity shared by raw context, fact extraction, display summaries, meetings, and Activity evidence.

On the first Phase 6 launch, source types already in the database are marked reviewed/allowed so the upgrade does not silently disable the existing product. A source type first observed later is different:

1. its context is captured and encrypted locally;
2. the recent row shows source/title/kind/size and asks for review;
3. display summaries, fact extraction, embeddings, and Activity summaries exclude it;
4. **Allow AI** enables those pipelines for that source type;
5. **Keep Local** persists a local-only policy that remains manageable in Settings.

MCP latest-context retrieval and tray search remain local regardless of cloud policy. A failed review-policy bootstrap stops capture instead of reverting to implicit cloud processing.

## Capture privacy

- Global pause is stored in SQLite and survives restart. It may expire after 15 minutes, one hour, or at the next local midnight, or remain indefinite.
- App blocks remain available from the right-click tray menu and can be resumed from Settings.
- Paused threads are always listed by their stable source key, even if their original thread row no longer exists.
- User-entered domains are normalized to hosts. Exact hosts and subdomains are blocked before browser content reaches storage; malformed policy reads fail closed and appear in Capture Health.
- Hard-coded authentication, password, banking, meeting, adult, internal-URL, and sensitive-native-app protections remain non-editable safety policy.
- Activity Synthesis retains its separate opt-in consent and per-app exclusions.

The Settings disclosure states that encrypted local data is decrypted before Gemini calls for new-version facts, embeddings, display summaries, meeting processing, and opted-in Activity synthesis. Local tray search and latest-context MCP reads do not use Gemini.

## Data controls

Retention can be set to Forever, 30 days, 90 days, or one year. Applying retention is a separate confirmed action. It removes stale threads and unreferenced historical versions, old closed Activity data, archived action items, agent runs, diagnostics, and fingerprints while preserving current latest/meeting versions and open action items.

Export writes the current memory surface and facts as explicitly plaintext JSON, atomically, with mode `0600`. Delete All removes contexts, facts, embeddings, recordings, Activity, action items, retry state, and diagnostics while retaining privacy settings. Retention cleanup and Delete All create a consistent mode-`0600` SQLite backup before their transaction begins.

Neither destructive control was invoked against the live personal database during implementation.

## Setup and remediation

Settings reports:

- Accessibility permission for visible app/browser context;
- microphone permission for meetings and voice notes;
- Screen Recording permission for system audio, with mic-only fallback disclosed;
- AES-256-GCM/Keychain availability;
- Gemini API-key configuration;
- bundled MCP health and whether Claude points at the exact bundled executable.

Permission buttons request or open the corresponding System Settings pane. API-key validation sends only `MaxMi connection check` to the embedding endpoint, then atomically updates `.env` at mode `0600`; restart is required because active workers retain their startup configuration. MCP probes have bounded timeouts and never call a retrieval tool. Setup commands are copied to the clipboard, not executed silently.

## Content-free live baseline

A consistent backup was created before the first Phase 6 launch:

`~/Library/Application Support/MaxMi/maxmi.db.bak-before-phase6-20260714-185906`

| Check | Result |
|---|---:|
| Threads before launch | 646 |
| Versions before launch | 973 |
| Latest contexts before launch | 646 |
| Recordings before launch | 0 |
| Existing distinct source types | 21 |
| Grandfathered reviewed source types | 21 |
| Local-only source types after bootstrap | 0 |
| SQLite integrity | `ok` |
| Claude Code bundled MCP status | Connected |

The backup is mode `0600`. No source name, title, URL, raw context, fact, summary, transcript, API key, or MCP response content was printed for this verification.

## Manual live acceptance

| Test | Expected result | Status |
|---|---|---|
| Left-click tray icon | status, recent memory, local search, and controls are visible | pending visual |
| Search a private known phrase | matching local snippet; no Gemini request | automated; pending visual |
| Pause for 15 minutes and restart | pause survives restart and expires automatically | automated; pending live |
| Block a test domain | its pages skip with `userBlockedDomain`; subdomains also skip | automated; pending live |
| Pause/resume current app and thread | capture stops and both remain manageable | automated; pending live |
| Open a genuinely new source type | encrypted preview appears; no cloud worker processes it before choice | automated; pending live |
| Choose Keep Local, then Allow AI | policy persists and processing resumes only after approval | automated; pending live |
| Export to a controlled location | plaintext warning, mode `0600`, valid JSON | automated only; intentionally not run on personal corpus |
| Apply retention/Delete All | backup first, expected rows removed | in-memory automated only; intentionally not run live |
| Permission remediation buttons | correct prompt/System Settings pane opens | pending live |
| Validate a replacement API key | content-free validation, secure save, restart message | pending live; existing key untouched |
| Open Settings MCP status | exact bundled server reports connected | backend verified; pending visual |
