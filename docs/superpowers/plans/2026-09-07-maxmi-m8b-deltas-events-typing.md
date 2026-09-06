# MaxMi M8 Phase B — Deltas, Capture Events, Focused-Field Typing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Phase A's typed captures into an *event log of what the user did* — content deltas, focus changes, navigations, dialogs, and focused-field typing — plus a deterministic activity timeline built from it, with 30-day retention.

**Architecture:** Phase A already computes a `CaptureDelta` inside `CaptureAccumulator.merge` and hands it back through `Store.commitCapture`'s `CommitResult`. Phase B gives that delta two explicit signals (`hasRecordableChange`, `dialogBlocks`), adds a `capture_events` table (migration `v11`, with a plaintext `app_bundle` column so a row is attributable to an app without decrypting it) written through `Store.recordCaptureEvent` with encrypted JSON payloads, and writes the events from `AppWiring.finishCapture` — the only site that knows the app, the trigger, and the previous URL. Typing is read from the accessibility value of the *focused field only* (no `CGEventTap`, no global monitor): a pure prefix/suffix diff in `TypingDiff`, an LRU-keyed actor `TypingObserver`, and the typed text also flows back into structured content as a draft `Message` or an `authoredByUser` `Block`. `MaxMiActivity` gains `TimelineBuilder`, which reads app visits + events + thread metadata through a repository protocol and renders a compact, budgeted, chronological text timeline for Phase C's prompts.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+, XCTest, GRDB 7, ApplicationServices/AppKit accessibility APIs, CryptoKit (`AESGCMFieldCipher`).

**Spec:** `docs/superpowers/specs/2026-09-06-maxmi-m8-structured-capture-design.md` — this plan implements §5 (all of Phase B: 5a–5d), the Phase-B parts of §8 (cross-cutting), §9 (testing), §11 exit criteria 4 and 5, and the §12 rulings Q4, Q5, and Q12. Phase A (§4) is **merged** as of `c0a687c`. Phase C (§6) and Phase D (§7) are separate plans and out of scope here.

**Phase A ledger (rulings this plan inherits):** `.superpowers/sdd/2026-09-06-maxmi-m8a-typed-capture-contract/progress.md` — the two items explicitly deferred to Phase B as *blockers* are Task 1 of this plan.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec unless a ruling below says otherwise.

- **Migration numbering.** Phase A ended at `v10`. Phase B's `capture_events` migration is **`v11`**, and `Migrations.currentIdentifier` becomes `"v11"`. A concurrent spec amendment assigns a `context_embeddings` `vec0` table and a `checkins` table to Phase C; **Phase C takes `v12` and `v13`**, not `v11`. Record this in the spec's §12 when Phase C is planned. `Sources/MaxMiStore/DatabaseRecovery.swift` derives its accepted schema-id set from `Migrations.migrator.migrations` (Phase A Task 8 fix), so no hardcoded list needs bumping — but any test asserting `"v10"` does.
- **Retention is 30 days, not 14** (§5b, §12 Q5). `capture_events` is trimmed on write, gated to at most once per hour through the `settings` key `capture_events_last_trim_at`. `CaptureHealthStore.recordCaptureHealth` (`Sources/MaxMiStore/CaptureHealthStore.swift:8-40`) is the precedent for **trimming inside the write transaction and nothing more**: it caps by ROW COUNT (`retainLatest: 500`), with no `settings` key and no time gate. The hourly time gate is new in Phase B and has no shape to copy — do not go looking for one. It is additionally deleted by `MemoryDataControls.pruneMemory(olderThan:)` and `deleteAllMemory()`, and its row count is reported in `MemoryDeletionResult`. Memory retention itself is untouched (still Forever by default).
- **Privacy copy.** `CapturePrivacyView`'s retention card gains exactly this sentence: **"Activity events are kept for 30 days."** This is the only thing MaxMi deletes without being asked, so it is stated in the UI.
- **`capture_events` foreign keys:** `thread_id` **nullable** `REFERENCES threads(id) ON DELETE CASCADE` (a `focus` event precedes any thread for that window, §12 Q4); `version_id` **nullable** `REFERENCES versions(id) ON DELETE SET NULL` (version pruning must not delete events). `PRAGMA foreign_keys = ON` is already set in `Sources/MaxMiStore/Database.swift:12`.
- **`capture_events.app_bundle` is nullable plaintext** (spec §5b as amended 2026-09-07 by this repair pass). A bundle id is an identifier, not content, so it is stored in the clear exactly as `activity_app_visits.app_bundle` already is (`Sources/MaxMiStore/Migrations.swift:96-100`). It exists so §11 criterion 4 is checkable with `SELECT count(*) FROM capture_events WHERE app_bundle=? AND at_ms>?` — without it the only app identifier in a row is inside the encrypted `focus` payload and the criterion cannot be verified at all. Every write site passes it; `Store.recordCaptureEvent`'s `appBundle:` parameter is **required and has no default**, so a new event kind cannot forget it.
- **Ciphertext columns are `TEXT`, never `BLOB`** (§12 Q2), written through `FieldCipher.encrypt(_:) throws -> String` which returns `"enc:v1:"`-prefixed base64. Reuse `AESGCMFieldCipher` and the existing Keychain key `dev.mafex.maxmi.dbkey`. No new key, no new format, no new network destination.
- **Payload JSON is deterministic.** Encode every event payload with `CapturedContentEnvelope.makeEncoder()` (`.sortedKeys`, `.withoutEscapingSlashes`, ISO-8601 dates) and decode with `CapturedContentEnvelope.makeDecoder()`. Same payload value → same bytes.
- **No `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`, ever** (§3 Non-goals, §11 exit criterion 5). The only typing input is the accessibility value of the focused element.
- **A secure field is never read, including its selection** (§4a/§4e/§8 as amended). `AXReader.convert` already skips `AXValue`/`AXPlaceholderValue`/`AXSelectedText` for an `AXSecureTextField`, and `FocusedElement.init` nils both `value` and `selectedText` when `isSecure`. `TypingObserver` additionally returns nil for `focused.isSecure` — belt and braces, and directly testable.
- **Privacy gates are the existing ones; Phase B adds none** (§8). Before any `capture_events` row or typing event is written: `Denylist.isSensitiveApp(bundleID) == false`, the app is not in `activityExcludedApps()`, `ActivityStore.activityConsent() == .granted`, and `activityEnabled() == true`. `AppWiring.isActivityEligible(bundleID:)` (`Sources/MaxMi/AppWiring.swift:1094-1110`) already checks all four and is the single gate every write site calls. It is evaluated **once** per committed capture — `finishCapture` already binds it to `let eligible` at `:1585` — and passed down, never re-derived (each call is three `Store` reads).
- **`CloudProcessingState` is NOT the gate** (§12 Q14). `CapturePrivacyStore.cloudReviewInitialized()` hardcodes `false`, so that gate is inert. Phase B relies on `ActivityConsent` + `activityEnabled()`, deliberately.
- **XCTest only.** Zero `import Testing`. Tests are `final class …: XCTestCase` with `func test…` methods.
- **Baseline: 689 tests, exactly 3 known-red** (pre-existing user WIP, do NOT fix them):
  - `ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`
  - `CaptureDisplaySummarizerTests.testConversationSummaryUsesTrailingMessages`
  - `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`
  Any *other* red test is a regression this plan caused.
- **Test-count bookkeeping.** This plan adds **117** tests and removes **1** (`MigrationV10Tests.testCurrentIdentifierIsV10`, whose assertion moves to `MigrationV11Tests`), so the suite finishes at roughly **805** executed. That number is *informational only* — a plan-wide "expected total" tripwire is too fragile to trust. The gate that actually catches a test file which failed to compile into a target is Task 10 Step 1's per-class presence check: every new test class must appear in the run. `Tests/MaxMiTests/` is **not** a target in `Package.swift`; nothing may be placed there.
- **Zero new warnings.** `swift build 2>&1 | grep warning:` must not grow.
- **`MaxMiActivity` depends only on `MaxMiCore`** (`Package.swift`). It must not import GRDB, `MaxMiStore`, or `MaxMiCapture`. `TimelineBuilder` therefore reaches the database only through a `TimelineRepository` protocol whose concrete adapter lives in `Sources/MaxMi/StoreTimelineRepository.swift`, following `ActivitySummaryRepository`/`AgentRepository`.
- **Fixtures are hand-scrubbed.** Never commit real page text, messages, file contents, URLs, names, emails, paths, or tokens (`Tests/MaxMiCaptureTests/Fixtures/README.md`). Every new fixture gets a row in that README's table.
- **Commit messages are plain imperative** ("Add capture_events migration v11"). **No `Co-Authored-By` trailers, no AI attribution anywhere** — not in commit messages, code comments, or docs.
- **Live verification ritual** (§9, unchanged): `./packaging/make-app.sh`, then `pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"`, then `open MaxMi.app`. **No `tccutil reset`** — signed builds keep the Accessibility grant across rebuilds. Verify captures by timestamp strictly after the new process start.

### Rulings that resolve spec text against the merged code

All six are decided here. No task may reopen them.

1. **`CaptureDelta.isEmpty` must NOT gate `content_delta` writes.** §5b says "one per capture whose `CommitResult` is `.committed` **and** whose `delta.isEmpty == false`". But `isEmpty` is `addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty && removedCount == 0`, and §5a specifies that `.tasks`/`.calendar` deltas carry **no** arrays and **no** `removedCount` — only `addedChars`/`removedChars`. So `isEmpty` is *always* `true` for a Reminders or Calendar capture and gating on it would silently drop every task/calendar event (Phase A ledger, Task 9 deferred item). Task 1 adds an explicit `hasRecordableChange` (`!isEmpty || addedChars > 0 || removedChars > 0`), and Task 4's `CaptureEventDecision.kinds(for:trigger:hasBrowserURL:)` — the one tested place the rule lives — gates on **that**. `isEmpty` stays as-is; it has other callers' semantics and Phase C may use it.

2. **`CaptureEventKind` and the payload structs live in `MaxMiCore`, not `MaxMiStore`/`MaxMiCapture`.** §5b puts `CaptureEventKind` in `Sources/MaxMiStore/CaptureEventStore.swift` and §5c puts `TypingEvent` in `Sources/MaxMiCapture/TypingObserver.swift`. But §5d's `TimelineRawEvent` — in `MaxMiActivity`, which depends only on `MaxMiCore` — has fields of type `CaptureEventKind` and `TypingEvent`. Those two placements are mutually exclusive. **Decision:** `CaptureEventKind`, `FocusEventPayload`, `NavigationEventPayload`, `TypingEvent`, `DialogEventPayload`, and `CaptureEventRetention` all live in new `Sources/MaxMiCore/CaptureEvent.swift`. `MaxMiStore` and `MaxMiActivity` both see them; `TypingObserver` in `MaxMiCapture` produces the `MaxMiCore` `TypingEvent`. Nothing else about §5b/§5c changes. Note this for the spec's §12.

3. **"A dialog appeared" is computed in `CaptureDelta.between`, and travels on the delta.** §5b says the `dialog` event fires "when the merged `.generic` content has a `.dialog` region and the previous one did not". `AppWiring.finishCapture` does not have the previous content — it only has the `CommitResult`. `CaptureDelta.between(previous:merged:)` is the one function that sees both. **Decision:** `CaptureDelta` gains `dialogBlocks: [Block]`, populated by `between` with the merged `.generic` page's `.dialog` blocks *only when* the previous content had no `.dialog` region, and empty otherwise. `CaptureEventDecision` names a `dialog` event when `delta.dialogBlocks` is non-empty, and `AppWiring` supplies its payload. This costs no extra decrypt and no extra query, and keeps `CommitResult`'s arity — the 21 existing `case .committed` pattern matches across `Sources/` and `Tests/` stay compiling.

4. **`thread_id` and the previous URL are read through two small `Store` lookups, not through `CommitResult`.** Events need the thread id, and `navigation` needs the thread's URL *before* the commit overwrites it. Adding both to `CommitResult.committed` would touch all 21 pattern-match sites for no gain. **Decision:** Task 4 adds `Store.threadID(sourceApp:sourceKey:)` (one indexed read on the existing `UNIQUE(source_app, source_key)`, called once after a committed capture) and `Store.previousContextURL(sourceApp:sourceKey:)` (called *before* `commitCapture`, and only when `trigger == .browserNavigation`, so no other capture pays for it).

5. **The consent/exclusion gate stays on the main actor; `TypingObserver.isEligible` is the pure denylist guard.** §5c has `TypingObserver.init(isEligible:)` as `@Sendable (String) -> Bool`, but consent and per-app exclusion are `throws` reads on `Store`, which is not `Sendable`. **Decision:** `AppWiring` calls `isActivityEligible(bundleID:)` on the main actor *before* handing anything to the observer, and constructs the observer with `isEligible: { !Denylist.isSensitiveApp($0) }`. Unit tests drive the consent/exclusion cases by injecting a closure that returns `false`, which is exactly the production composition.

6. **The delta is computed on the merged content BEFORE bounding.** `CaptureAccumulator.merge` currently calls `CaptureDelta.between(previous: previous, merged: bounded)` (`Sources/MaxMiCore/StructuredAccumulator.swift:41`), i.e. against the value *after* `bound` has shed regions to fit `maxCharacters`. Combined with Ruling 3 that is a silent hole: bounding sheds `.dialog` last but it does shed it (`boundGeneric`, `StructuredAccumulator.swift:222`), so an over-cap page that just put a sheet on screen would produce **no** `dialog` event — the one event whose whole point is "something is asking the user for a decision". The same argument applies to `addedBlocks` on any over-cap page: the delta is supposed to describe *what changed*, not *what fit*. **Decision:** Task 1 changes that one line to `merged: merged`. `content`, `rendered` and `changed` keep using `bounded` — only the delta moves. Two existing bounding tests (`StructuredAccumulatorTests.testBoundingTrimsWholeMessagesFromTheFrontAndNeverSplitsOne`, `…KeepsAtLeastOneItem`) assert on `result.content` and `result.rendered` only, so nothing pre-existing depends on the old behaviour.


### Where §9's Phase B test list is covered

| §9 requirement | Task |
|---|---|
| `CaptureDelta` per shape incl. `isFirstCapture`, `removedCount`, char counts | **Already green from Phase A** — `Tests/MaxMiCoreTests/StructuredAccumulatorTests.swift` asserts `addedMessages`/`addedSegments`/`addedBlocks`, `removedCount`, `isFirstCapture` and `addedChars` per shape, and `Tests/MaxMiStoreTests/StructuredCommitTests.swift` asserts the delta arriving through `CommitResult`. Task 1 adds only the two new signals. |
| Migration `v11`: table, CHECK, both indexes, `ON DELETE CASCADE` on thread delete, `SET NULL` on version prune | Tasks 2 (`MigrationV11Tests`) and 2/4 (`CaptureEventStoreTests`) |
| `CaptureEventStore`: encrypted payload round-trip per kind | Task 2 |
| one `content_delta` per committed non-empty capture, **none** for a `.deduplicated` commit | Task 4, via the pure `CaptureEventDecision.kinds(for:trigger:hasBrowserURL:)` — the write site itself is in `AppWiring`, which has no test target, so the *rule* is extracted and tested |
| retention trim at 30 days incl. the once-per-hour gate | Task 2 |
| `pruneMemory` and `deleteAllMemory` remove events | Task 3 |
| `TypingObserver`: append, mid-string insertion, paste, clear, identical, debounce, secure, sensitive/excluded, consent, LRU | Task 5, together with `TypingPollGate`'s pre-read gate (spec §5c's 800 ms, applied to the AX read as well as to the emitted event) |
| `TimelineBuilder`: ordering, coalescing, budget dropping oldest-first with the omission line, no entry exceeding 200 chars of delta content | Task 8 |
| §11 criterion 4 (events recorded; nothing for denylisted/excluded/non-consented) | Task 2 (`CaptureEventStoreTests.testEventsAreAttributableToTheirAppWithoutDecrypting` — the plaintext `app_bundle` column that makes the criterion a query at all) plus Task 10 Steps 5 and 9 (the live check, now attributable to a bundle id). The gate itself still has no unit test: it lives in `AppWiring`, which has no test target. |
| §11 criterion 5 (typing captured, no `CGEventTap` in the binary) | Task 5 (source grep), Task 10 Steps 6 and 10 (binary check) |

---

## File Structure

### Created

| File | Responsibility |
|---|---|
| `Sources/MaxMiCore/CaptureEvent.swift` | `CaptureEventKind`, the four payload structs (`FocusEventPayload`, `NavigationEventPayload`, `TypingEvent`, `DialogEventPayload`), and `CaptureEventRetention`'s constants. Types and one payload-capping helper only — no SQL, no AX. Placed in `MaxMiCore` so `MaxMiStore` (writer), `MaxMiCapture` (typing producer) and `MaxMiActivity` (timeline reader) can all see them (Ruling 2). |
| `Sources/MaxMiStore/CaptureEventStore.swift` | `capture_events` writes and reads: `recordCaptureEvent`, the 30-day trim-on-write with its hourly gate, `recentCaptureEvents`, `captureEvents(fromMs:toMs:)`, plus the two event-context lookups `threadID(sourceApp:sourceKey:)` and `previousContextURL(sourceApp:sourceKey:)`. `CaptureHealthStore.swift` is the precedent for trimming inside the write transaction, and for nothing else: its cap is by row count with no `settings` key and no time gate. |
| `Sources/MaxMiCapture/TypingObserver.swift` | `FocusedFieldKey`, the pure `TypingDiff`, `TypingPollGate` (the pre-read 800 ms per-key time gate that keeps `kAXValueChangedNotification` from firing an AX round trip per notification), the `TypingObserver` actor with its 800 ms per-key emit debounce and 32-entry in-memory LRU, and the `FocusedElement(node:)` bridge from `AXNode`. |
| `Sources/MaxMiCapture/ComposerDraft.swift` | The one pure function that turns a focused chat composer into a draft `Message`, shared by the three native chat parsers and the browser conversation path. |
| `Sources/MaxMiActivity/TimelineBuilder.swift` | `TimelineEntry`, `ActivityTimeline`, `TimelineRepository`, `TimelineRawEvent`, `TimelineThreadMeta`, `TimelineBuilder.build`, and the deterministic `TimelineBuilder.render`. Pure and GRDB-free. |
| `Sources/MaxMi/StoreTimelineRepository.swift` | The concrete `TimelineRepository`: `Store` reads plus payload JSON decoding. The only place that knows both `MaxMiStore` and `MaxMiActivity`. |
| `Tests/MaxMiCoreTests/CaptureDeltaSignalsTests.swift` | `hasRecordableChange` per shape (including the `.tasks`/`.calendar` case `isEmpty` gets wrong) and `dialogBlocks` appearance/absence. |
| `Tests/MaxMiStoreTests/CaptureEventStoreTests.swift` | Encrypted payload round-trip per kind, the CHECK constraint, both indexes, `ON DELETE CASCADE`/`SET NULL`, the 30-day trim and its once-per-hour gate. |
| `Tests/MaxMiStoreTests/MigrationV11Tests.swift` | Table shape, nullability, `currentIdentifier`, and that a `v10` database migrates forward without data loss. |
| `Tests/MaxMiCaptureTests/TypingObserverTests.swift` | The nine `TypingDiff`/observer behaviours §9 lists, plus the LRU bound and the grep-assert that no `CGEventTap` exists in `Sources/`. |
| `Tests/MaxMiCaptureTests/ComposerDraftTests.swift` | Composer found, secure composer refused, message-list text field refused, draft appended by each conversation parser. |
| `Tests/MaxMiCaptureTests/Fixtures/slack-composer-draft.json` | Hand-authored Slack-shaped window with a focused composer `AXTextArea` holding invented draft text and a message list above it. |
| `Tests/MaxMiActivityTests/TimelineBuilderTests.swift` | Deterministic ordering, coalescing, the 200-char delta bound, budget dropping oldest-first with the omission line, and the rendered line format. |

### Modified

| File | Change |
|---|---|
| `Sources/MaxMiCore/CaptureDelta.swift` | Add `dialogBlocks: [Block]` and `hasRecordableChange`; populate `dialogBlocks` in `between`; add a tolerant `init(from:)`. |
| `Sources/MaxMiCore/StructuredAccumulator.swift` | One line: `CaptureAccumulator.merge` computes the delta from the **pre-bound** `merged` value instead of `bounded`, so bounding cannot swallow a `.dialog` region or an added block (Ruling 6). |
| `Sources/MaxMiCore/SafeLogger.swift` | Add `SafeLogEvent.captureEventWriteFailed = "capture_event_write_failed"`. |
| `Sources/MaxMiCapture/SourceParser.swift` | `ParsedCapture` gains `truncated: Bool = false` as the **last** initializer parameter. |
| `Sources/MaxMiCapture/GenericV2Content.swift` | `page(...)` returns `GenericV2Content.Page?` (content + truncated) instead of `CapturedContent?`. |
| `Sources/MaxMiCapture/GenericAXParser.swift`, `NotesParser.swift`, `NotionParser.swift`, `ObsidianParser.swift`, `StructuredNativeParsers.swift` | Carry `truncated` from `GenericV2Content.Page` into `ParsedCapture`. |
| `Sources/MaxMiCapture/WebAppCaptureParser.swift` | Set `ParsedCapture.truncated`; append the composer draft on the conversation path. |
| `Sources/MaxMiCapture/SlackParser.swift`, `NativeConversationParser.swift` | Append the composer draft. |
| `Sources/MaxMiCapture/GenericPageExtractor.swift` | Mark the focused input's block `authoredByUser: true`; resolve the focused element before budgeting and pass its value as the trim anchor. |
| `Sources/MaxMiCapture/GenericPageExtractor+Budgets.swift` | Viewport-anchored `.main` trimming: `applyBudgets(_:anchorText:options:)`, `anchorIndex(in:text:)`, `trimAnchored(_:to:anchorIndex:)`. |
| `Sources/MaxMiCapture/AXReader.swift` | Add `focusedWindowTitle(pid:)` for the `focus` payload. |
| `Sources/MaxMiCapture/FocusObserver.swift` | Add `onAXNotification` so `AppWiring` sees the `kAXValueChangedNotification` that already fires. `FocusObserver`'s own capture debounce is untouched; the typing path gets its own gate (`TypingPollGate`) because `onAXNotification` fires *ahead* of that debounce. |
| `Sources/MaxMiStore/Migrations.swift` | Register `v11`; `currentIdentifier` becomes `"v11"`. |
| `Sources/MaxMiStore/MemoryDataControls.swift` | `MemoryDeletionResult.events`; delete `capture_events` in `pruneMemory` and `deleteAllMemory`. |
| `Sources/MaxMiStore/ActivityStore.swift` | Add `ActivityVisitRecord` and `appVisits(fromMs:toMs:)`. |
| `Sources/MaxMiStore/LatestContextStore.swift` | Add `latestContextRecords(threadIDs:)`. |
| `Sources/MaxMiUI/CapturePrivacyView.swift` | The 30-day events sentence on the retention card. |
| `Sources/MaxMi/AppWiring.swift` | Retire the `content.count >= 8_000` truncation heuristic; write `focus`, `navigation`, `content_delta`, `dialog` and `typing` events; own the `TypingObserver` and its `TypingPollGate`. |
| `Tests/MaxMiStoreTests/MemoryDataControlsTests.swift` (3 literals), `Tests/MaxMiStoreTests/Phase7BaselineScriptTests.swift`, `Tests/MaxMiStoreTests/RuntimeDiagnosticsTests.swift` | The five `"v10"` schema-identifier literals that become `"v11"`. This is the complete list: `grep -rn '"v10"' Tests/` returns exactly these three files plus `MigrationV10Tests.swift:22`, and `MigrationTests.swift` / `SafeDiagnosticsTests.swift` contain **no** `"v10"` at all. |
| `Tests/MaxMiStoreTests/MigrationV10Tests.swift` | Delete `testCurrentIdentifierIsV10` (one method). Everything else in the file is a v10-structural assertion and stays byte-identical; the current-identifier assertion belongs to `MigrationV11Tests` from now on. |
| `Tests/MaxMiCaptureTests/Fixtures/README.md` | A row for `slack-composer-draft.json`. |

---

## Task 1: Delta signals and `truncated` plumbing (Phase A blockers 1 and 2)

Two items the Phase A final review deferred as *explicit Phase B blockers*. Both are prerequisites for Task 4, so they land first, together, in one reviewable change: neither ships behaviour on its own, and both are edits to the same capture write path.

**Files:**
- Modify: `Sources/MaxMiCore/CaptureDelta.swift` (add `dialogBlocks`, `hasRecordableChange`, tolerant `init(from:)`, populate in `between`)
- Modify: `Sources/MaxMiCore/StructuredAccumulator.swift:41` (compute the delta from the pre-bound `merged`, Ruling 6)
- Modify: `Sources/MaxMiCapture/GenericV2Content.swift:8-22` (`page` returns `Page?`)
- Modify: `Sources/MaxMiCapture/SourceParser.swift:16-46` (`ParsedCapture.truncated`)
- Modify: `Sources/MaxMiCapture/GenericAXParser.swift:10-33`
- Modify: `Sources/MaxMiCapture/NotesParser.swift:12-29`
- Modify: `Sources/MaxMiCapture/NotionParser.swift:12-28`
- Modify: `Sources/MaxMiCapture/ObsidianParser.swift:12-27`
- Modify: `Sources/MaxMiCapture/StructuredNativeParsers.swift:82-118, 256-315`
- Modify: `Sources/MaxMiCapture/WebAppCaptureParser.swift:108-127`
- Modify: `Sources/MaxMi/AppWiring.swift:1573-1575`
- Test: `Tests/MaxMiCoreTests/CaptureDeltaSignalsTests.swift` (create)
- Test: `Tests/MaxMiCaptureTests/GenericV2ParserTests.swift` (extend)

**Interfaces:**
- Consumes (all exist on `main` at `c0a687c`): `CaptureDelta.init(addedBlocks:addedMessages:addedSegments:removedCount:addedChars:removedChars:isFirstCapture:)`, `CaptureDelta.between(previous: CapturedContent?, merged: CapturedContent) -> CaptureDelta`, `GenericPage.regions: [Region]`, `Region.kind: RegionKind`, `RegionKind.dialog`, `Block`, `GenericPageExtractor.Result { page: GenericPage, truncated: Bool }`, `GenericPageExtractor.extract(window:focusedElement:url:options:) -> Result`.
- Produces:
  - `CaptureDelta.dialogBlocks: [Block]` — the merged `.generic` page's `.dialog` blocks when the previous content had no `.dialog` region; `[]` otherwise and for every non-`.generic` shape.
  - `CaptureDelta.hasRecordableChange: Bool` — `!isEmpty || addedChars > 0 || removedChars > 0`.
  - `CaptureAccumulator.merge`'s `StructuredAccumulationResult.delta` is now `CaptureDelta.between(previous: previous, merged: merged)` — the **pre-bound** merged value. `.content`, `.rendered` and `.changed` still describe `bounded`. Signature and return type are unchanged, so no caller is touched.
  - `CaptureDelta.init(addedBlocks:addedMessages:addedSegments:removedCount:addedChars:removedChars:isFirstCapture:dialogBlocks:)` — `dialogBlocks` is the **last** parameter and defaults to `[]`, so every existing call site compiles unchanged.
  - `GenericV2Content.Page { let content: CapturedContent; let truncated: Bool }` and `GenericV2Content.page(window:url:budget:offscreenPolicy:) -> Page?`.
  - `ParsedCapture.truncated: Bool` — `truncated` is the **last** initializer parameter and defaults to `false`.
  - `StructuredEntityExtraction.documentContent(window:) -> GenericV2Content.Page?` and `emailContent(window:) -> GenericV2Content.Page?`.

- [ ] **Step 1: Write the failing delta-signal tests**

Create `Tests/MaxMiCoreTests/CaptureDeltaSignalsTests.swift`:

```swift
import XCTest
@testable import MaxMiCore

final class CaptureDeltaSignalsTests: XCTestCase {
    private func page(_ regions: [Region], url: String? = nil) -> CapturedContent {
        .generic(GenericPage(regions: regions, focused: nil, url: url))
    }

    private func main(_ texts: [String]) -> Region {
        Region(kind: .main, blocks: texts.map { Block(type: .paragraph, text: $0) })
    }

    /// The whole reason `hasRecordableChange` exists: a Reminders capture carries no arrays and
    /// no `removedCount`, so `isEmpty` is true even though the list visibly changed.
    func testTaskDeltaIsEmptyButHasRecordableChange() {
        let before = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let after = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
            TaskItem(title: "Write the timeline builder", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let delta = CaptureDelta.between(previous: before, merged: after)
        XCTAssertTrue(delta.isEmpty, "tasks deltas carry no arrays; this is the trap")
        XCTAssertGreaterThan(delta.addedChars, 0)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testCalendarDeltaHasRecordableChangeOnShrink() {
        let event = CalendarEvent(title: "Design review", dateString: "Mon 10:00",
                                 start: nil, end: nil, organizer: nil, location: nil,
                                 hasConference: false, notes: nil)
        let delta = CaptureDelta.between(previous: .calendar([event, event]), merged: .calendar([event]))
        XCTAssertGreaterThan(delta.removedChars, 0)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testIdenticalContentHasNoRecordableChange() {
        let content = page([main(["one", "two"])])
        let delta = CaptureDelta.between(previous: content, merged: content)
        XCTAssertFalse(delta.hasRecordableChange)
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    func testAddedBlocksHaveRecordableChange() {
        let delta = CaptureDelta.between(previous: page([main(["one"])]),
                                         merged: page([main(["one", "two"])]))
        XCTAssertEqual(delta.addedBlocks.map(\.text), ["two"])
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testNewDialogRegionIsReportedInDialogBlocks() {
        let dialog = Region(kind: .dialog, blocks: [
            Block(type: .heading(level: 2), text: "Quit without saving?"),
            Block(type: .label, text: "Cancel"),
        ])
        let delta = CaptureDelta.between(previous: page([main(["one"])]),
                                         merged: page([main(["one"]), dialog]))
        XCTAssertEqual(delta.dialogBlocks.map(\.text), ["Quit without saving?", "Cancel"])
    }

    func testDialogAlreadyPresentIsNotReportedAgain() {
        let dialog = Region(kind: .dialog, blocks: [Block(type: .label, text: "OK")])
        let delta = CaptureDelta.between(previous: page([main(["one"]), dialog]),
                                         merged: page([main(["one", "two"]), dialog]))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    func testFirstCaptureWithADialogReportsIt() {
        let dialog = Region(kind: .dialog, blocks: [Block(type: .label, text: "Allow")])
        let delta = CaptureDelta.between(previous: nil, merged: page([main(["body"]), dialog]))
        XCTAssertTrue(delta.isFirstCapture)
        XCTAssertEqual(delta.dialogBlocks.map(\.text), ["Allow"])
    }

    func testNonGenericShapesNeverCarryDialogBlocks() {
        let message = Message(id: "m1", sender: "Ana", text: "hi", timestamp: nil,
                              timeString: "10:01", isUser: false, isDraft: false)
        let delta = CaptureDelta.between(
            previous: nil,
            merged: .conversation(Conversation(channel: "#maxmi", isGroup: true, messages: [message])))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    /// A payload written by a build that did not know about `dialogBlocks` must still decode.
    func testDecodesPayloadWithoutDialogBlocks() throws {
        let json = """
        {"addedBlocks":[],"addedChars":12,"addedMessages":[],"addedSegments":[],\
        "isFirstCapture":false,"removedChars":0,"removedCount":0}
        """
        let delta = try CapturedContentEnvelope.makeDecoder()
            .decode(CaptureDelta.self, from: Data(json.utf8))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    /// Ruling 6: bounding sheds `.dialog` last, but it does shed it. The delta describes what
    /// CHANGED, not what fit, so a sheet that appeared on an over-cap page must still produce a
    /// `dialog` event even though the stored content no longer contains the dialog region.
    func testDialogSurvivesIntoTheDeltaEvenWhenBoundingDropsIt() {
        let body = (0..<40).map { Block(type: .paragraph, text: "paragraph \($0) " + String(repeating: "b", count: 120)) }
        let previous = page([Region(kind: .main, blocks: body)])
        let incoming = page([
            Region(kind: .main, blocks: body),
            Region(kind: .dialog, blocks: [Block(type: .label, text: "Discard changes?")]),
        ])
        // A cap far below the page's rendered size, so `bound` sheds the dialog region entirely.
        let result = CaptureAccumulator.merge(previous: previous, incoming: incoming,
                                              policy: .replace, maxCharacters: 300)
        guard case .generic(let stored) = result.content else { return XCTFail("expected generic") }
        XCTAssertFalse(stored.regions.contains { $0.kind == .dialog },
                       "bounding dropped the dialog region from the STORED content")
        XCTAssertEqual(result.delta.dialogBlocks.map(\.text), ["Discard changes?"],
                       "but the delta still reports it")
    }

    func testRoundTripsThroughDeterministicEncoder() throws {
        let delta = CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "x")],
                                addedChars: 1, isFirstCapture: true,
                                dialogBlocks: [Block(type: .label, text: "OK")])
        let encoder = CapturedContentEnvelope.makeEncoder()
        let first = try encoder.encode(delta)
        let decoded = try CapturedContentEnvelope.makeDecoder().decode(CaptureDelta.self, from: first)
        XCTAssertEqual(decoded, delta)
        XCTAssertEqual(try encoder.encode(decoded), first)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CaptureDeltaSignalsTests`
Expected: compile FAIL — `CaptureDelta` has no member `dialogBlocks` and no member `hasRecordableChange`. (Once it compiles, `testDialogSurvivesIntoTheDeltaEvenWhenBoundingDropsIt` will still fail until Step 4, because `merge` computes the delta from the bounded value.)

- [ ] **Step 3: Add the two delta signals**

In `Sources/MaxMiCore/CaptureDelta.swift`, extend the stored properties and the initializer, add the two computed members, and add the tolerant decoder. Replace the property block, `init`, and `isEmpty` with:

```swift
    public let addedBlocks: [Block]
    public let addedMessages: [Message]
    public let addedSegments: [TerminalSegment]
    public let removedCount: Int
    public let addedChars: Int
    public let removedChars: Int
    public let isFirstCapture: Bool
    /// The blocks of a `.dialog` region that appeared in this capture and was NOT in the
    /// previous one. Empty for every other case, including a dialog that was already on screen
    /// and every non-`.generic` shape.
    ///
    /// It rides on the delta because `between` is the only function that sees both the previous
    /// and the merged content — `AppWiring.finishCapture`, which writes the `dialog` event, has
    /// only the `CommitResult` (spec 12 Q12).
    public let dialogBlocks: [Block]

    public init(addedBlocks: [Block] = [], addedMessages: [Message] = [],
                addedSegments: [TerminalSegment] = [], removedCount: Int = 0,
                addedChars: Int = 0, removedChars: Int = 0, isFirstCapture: Bool = false,
                dialogBlocks: [Block] = []) {
        self.addedBlocks = addedBlocks
        self.addedMessages = addedMessages
        self.addedSegments = addedSegments
        self.removedCount = removedCount
        self.addedChars = addedChars
        self.removedChars = removedChars
        self.isFirstCapture = isFirstCapture
        self.dialogBlocks = dialogBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case addedBlocks, addedMessages, addedSegments, removedCount
        case addedChars, removedChars, isFirstCapture, dialogBlocks
    }

    /// `dialogBlocks` is decoded leniently so a payload written before it existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addedBlocks = try c.decode([Block].self, forKey: .addedBlocks)
        addedMessages = try c.decode([Message].self, forKey: .addedMessages)
        addedSegments = try c.decode([TerminalSegment].self, forKey: .addedSegments)
        removedCount = try c.decode(Int.self, forKey: .removedCount)
        addedChars = try c.decode(Int.self, forKey: .addedChars)
        removedChars = try c.decode(Int.self, forKey: .removedChars)
        isFirstCapture = try c.decode(Bool.self, forKey: .isFirstCapture)
        dialogBlocks = try c.decodeIfPresent([Block].self, forKey: .dialogBlocks) ?? []
    }

    public var isEmpty: Bool {
        addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty
            && removedCount == 0
    }

    /// Whether this delta is worth a `content_delta` event.
    ///
    /// NOT `!isEmpty`: `.tasks` and `.calendar` deltas carry no arrays and no `removedCount` by
    /// design (spec 5a), so `isEmpty` is always true for them and gating on it would drop every
    /// Reminders and Calendar event. The rendered character counts are the only change signal
    /// those two shapes have.
    public var hasRecordableChange: Bool {
        !isEmpty || addedChars > 0 || removedChars > 0
    }
```

Then populate `dialogBlocks` in `between`. Add the helper and thread it through the two `.generic`-capable branches:

```swift
    /// A `.dialog` region present in `merged` but absent from `previous`. `previous == nil` counts
    /// as absent, so the first capture of a window that already has a sheet on it reports it.
    static func appearingDialogBlocks(previous: CapturedContent?, merged: CapturedContent) -> [Block] {
        guard case .generic(let current) = merged,
              let dialog = current.regions.first(where: { $0.kind == .dialog }),
              !dialog.blocks.isEmpty else { return [] }
        if case .generic(let old) = previous, old.regions.contains(where: { $0.kind == .dialog }) {
            return []
        }
        return dialog.blocks
    }
```

and in `between`'s `.generic` case only (every other shape has no regions, so its `dialogBlocks` stays `[]`):

```swift
        case .generic(let current):
            // Only `.main` counts: chrome churns constantly and would drown the signal. A
            // `.dialog` region appearing is reported separately, in `dialogBlocks`.
            var delta = blockDelta(old: previousMainBlocks(previous), new: mainBlocks(current),
                                   addedChars: addedChars, removedChars: removedChars,
                                   isFirst: isFirst)
            let dialog = appearingDialogBlocks(previous: previous, merged: merged)
            if !dialog.isEmpty {
                delta = CaptureDelta(
                    addedBlocks: delta.addedBlocks, addedMessages: delta.addedMessages,
                    addedSegments: delta.addedSegments, removedCount: delta.removedCount,
                    addedChars: delta.addedChars, removedChars: delta.removedChars,
                    isFirstCapture: delta.isFirstCapture, dialogBlocks: dialog)
            }
            return delta
```

- [ ] **Step 4: Compute the delta from the pre-bound merged content**

In `Sources/MaxMiCore/StructuredAccumulator.swift`, `CaptureAccumulator.merge` currently derives every
field of its result from `bounded`. Change the delta — and only the delta — to use `merged`:

```swift
        let bounded = bound(merged, to: cap)
        return StructuredAccumulationResult(
            content: bounded,
            rendered: ContentRenderer.render(bounded, style: .full),
            changed: previous != bounded,
            // The delta describes what CHANGED, not what FIT. `bound` sheds `.dialog` last but it
            // does shed it (`boundGeneric`), and a delta computed from the bounded value would
            // silently lose the `dialog` event for exactly the over-cap pages most likely to have
            // one (Ruling 6). `content`/`rendered`/`changed` keep describing what was stored.
            delta: CaptureDelta.between(previous: previous, merged: merged)
        )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CaptureDeltaSignalsTests`
Expected: PASS, 11 tests.

Run: `swift test --filter MaxMiCoreTests`
Expected: PASS — Phase A's `StructuredAccumulatorTests` and `CaptureAccumulatorTests` still green. `dialogBlocks` defaults to `[]`, so their `CaptureDelta` equality assertions are unaffected, and the two tests that exercise bounding (`testBoundingTrimsWholeMessagesFromTheFrontAndNeverSplitsOne`, `testBoundingKeepsAtLeastOneItem`) assert on `result.content` and `result.rendered`, never on `result.delta`, so Step 4 does not move them. If some other test does start failing on a delta field, it is asserting that the delta describes the *bounded* value — read it, decide whether the assertion or Ruling 6 is wrong, and do not change both.

- [ ] **Step 6: Commit the delta signals**

```bash
git add Sources/MaxMiCore/CaptureDelta.swift Sources/MaxMiCore/StructuredAccumulator.swift \
        Tests/MaxMiCoreTests/CaptureDeltaSignalsTests.swift
git commit -m "Add hasRecordableChange and dialogBlocks to CaptureDelta"
```

- [ ] **Step 7: Write the failing truncated-plumbing test**

Append to `Tests/MaxMiCaptureTests/GenericV2ParserTests.swift` (inside the existing `final class GenericV2ParserTests: XCTestCase`). The fixture-free tree below is deliberate: it needs one region whose rendered size exceeds a small budget, nothing more.

```swift
    /// `AppWiring` used to infer truncation from `parsed.content.count >= 8_000`, which
    /// false-positives on an 8k-32k document that was never trimmed and false-negatives on a
    /// 32k-budget page that WAS trimmed. The extractor already knows; the parser now carries it.
    ///
    /// Thirty paragraphs, not forty, and the count is load-bearing: `GenericAXParser` uses the
    /// `DocumentExtraction.contentCap` default of 8_000, and with no other region present every
    /// share rolls into `.main`, so `mainAllowance` is 8_000 exactly. Thirty paragraphs render as
    /// 10x201 + 20x202 + 29 separators = 6_079 characters, comfortably under it. Forty render as
    /// 8_109 and the last assertion would be false.
    func testGenericPageParserCarriesTruncatedFromTheExtractor() throws {
        let paragraphs = (0..<30).map { index in
            AXNode(role: "AXStaticText", value: String(repeating: "x", count: 200) + "\(index)",
                   title: nil, url: nil,
                   frame: CGRect(x: 0, y: CGFloat(index) * 20, width: 600, height: 18),
                   focused: false, children: [])
        }
        let window = AXNode(role: "AXWindow", value: nil, title: "Long note", url: nil,
                            frame: CGRect(x: 0, y: 0, width: 900, height: 900),
                            focused: false, children: paragraphs)
        let app = AppInfo(bundleID: "com.example.notes", name: "Notes", windowTitle: "Long note")

        let full = try XCTUnwrap(GenericV2Content.page(
            window: window, budget: 100_000, offscreenPolicy: .visibleOnly()))
        XCTAssertFalse(full.truncated)

        let clipped = try XCTUnwrap(GenericV2Content.page(
            window: window, budget: 500, offscreenPolicy: .visibleOnly()))
        XCTAssertTrue(clipped.truncated)

        let parsed = try XCTUnwrap(GenericAXParser().parse(window: window, app: app))
        XCTAssertFalse(parsed.truncated,
                       "6_079 rendered chars is under the 8_000 default, so nothing was trimmed")
    }
```

- [ ] **Step 8: Run it to verify it fails**

Run: `swift test --filter GenericV2ParserTests/testGenericPageParserCarriesTruncatedFromTheExtractor`
Expected: compile FAIL — `GenericV2Content.page` returns `CapturedContent?`, which has no `truncated`, and `ParsedCapture` has no `truncated`.

- [ ] **Step 9: Make `GenericV2Content.page` return content plus truncation**

Replace `Sources/MaxMiCapture/GenericV2Content.swift`'s `page` with:

```swift
    /// A typed page plus whether budgeting dropped anything. `truncated` is not derivable from
    /// the rendered length — a page can sit under its budget and still have been trimmed, and a
    /// page can sit exactly on a large budget without having been.
    struct Page {
        let content: CapturedContent
        let truncated: Bool
    }

    /// The v2 extractor's page. nil when the window has no readable content, so the caller can
    /// return nil and let dispatch decide.
    static func page(
        window: AXNode,
        url: String? = nil,
        budget: Int = DocumentExtraction.contentCap,
        offscreenPolicy: OffscreenCapturePolicy
    ) -> Page? {
        var options = GenericPageExtractor.Options()
        options.totalBudget = budget
        options.offscreenPolicy = offscreenPolicy
        let result = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: url, options: options
        )
        guard !result.page.regions.isEmpty else { return nil }
        return Page(content: .generic(result.page), truncated: result.truncated)
    }
```

- [ ] **Step 10: Add `ParsedCapture.truncated`**

In `Sources/MaxMiCapture/SourceParser.swift`, add the property after `structured` and the parameter **last** in `init`:

```swift
    /// The typed shape, when this parser has been migrated. nil for an unmigrated parser, which
    /// is handed a `LegacyContentAdapter` shape by `resolvedStructured`.
    public let structured: CapturedContent?
    /// Whether this parser dropped content to stay inside its budget. The parser is the only
    /// thing that knows: `AppWiring` cannot infer it from the rendered length (Phase A ledger,
    /// Task 16 deferred item).
    public let truncated: Bool

    public init(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String,
        contentKind: CaptureContentKind = .generic,
        parserVersion: Int = 1,
        accumulationPolicy: CaptureAccumulationPolicy = .rollingText,
        offscreenPolicy: OffscreenCapturePolicy = .visibleOnly(),
        structured: CapturedContent? = nil,
        truncated: Bool = false
    ) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
        self.contentKind = contentKind
        self.parserVersion = max(1, parserVersion)
        self.accumulationPolicy = accumulationPolicy
        self.offscreenPolicy = offscreenPolicy
        self.structured = structured
        self.truncated = truncated
    }
```

`ParsedCapture.envelope(cleanSourceKey:parserID:trigger:truncated:structured:)` keeps its explicit `truncated:` parameter — `AppWiring` passes the OR of the parser's flag and the browser pipeline's, and Step 13 shows the exact expression.

- [ ] **Step 11: Carry `truncated` through the five generic-v2 parsers**

`Sources/MaxMiCapture/GenericAXParser.swift` — `parseStructured` drops the flag, `parse` uses it:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        // No url, default budget, and no focused element: only AppWiring knows the pid that
        // AXReader.focusedElementSnapshot needs. nil = no readable content, so no empty threads.
        GenericV2Content.page(window: window, offscreenPolicy: Self.profile(for: app).offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        let profile = Self.profile(for: app)
        // Called directly rather than through `parseStructured` so one AX walk yields BOTH the
        // content and the truncation flag.
        guard let page = GenericV2Content.page(window: window, offscreenPolicy: profile.offscreen)
        else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(page.content, style: .full),
            contentKind: profile.kind,
            parserVersion: 2,
            // Whole-page semantics (spec 4d): each extraction is the current state of the
            // window, so it supersedes the previous one rather than merging into it.
            accumulationPolicy: .replace,
            offscreenPolicy: profile.offscreen,
            structured: page.content,
            truncated: page.truncated
        )
    }
```

`Sources/MaxMiCapture/NotesParser.swift`:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window,
                              budget: StructuredEntityExtraction.pageBudget,
                              offscreenPolicy: Self.offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let page = GenericV2Content.page(window: window,
                                              budget: StructuredEntityExtraction.pageBudget,
                                              offscreenPolicy: Self.offscreen) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notes", sourceKey: "notes:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(page.content, style: .full),
                             contentKind: .document, parserVersion: 2,
                             // Whole-page semantics (spec 4d): one extraction is the window's
                             // current state, so it supersedes the previous one.
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: page.content,
                             truncated: page.truncated)
    }
```

`Sources/MaxMiCapture/NotionParser.swift` — identical to `NotesParser` with `sourceApp: "Notion"` and `sourceKey: "notion:\(docSlug(title))"`:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window,
                              budget: StructuredEntityExtraction.pageBudget,
                              offscreenPolicy: Self.offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let page = GenericV2Content.page(window: window,
                                              budget: StructuredEntityExtraction.pageBudget,
                                              offscreenPolicy: Self.offscreen) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "untitled"
        return ParsedCapture(sourceApp: "Notion", sourceKey: "notion:\(docSlug(title))",
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(page.content, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: page.content,
                             truncated: page.truncated)
    }
```

`Sources/MaxMiCapture/ObsidianParser.swift` — same shape, keyed by `key(fromTitle:)` which is unchanged:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        GenericV2Content.page(window: window,
                              budget: StructuredEntityExtraction.pageBudget,
                              offscreenPolicy: Self.offscreen)?.content
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let page = GenericV2Content.page(window: window,
                                              budget: StructuredEntityExtraction.pageBudget,
                                              offscreenPolicy: Self.offscreen) else { return nil }
        return ParsedCapture(sourceApp: "Obsidian", sourceKey: key(fromTitle: app.windowTitle),
                             sourceTitle: app.windowTitle,
                             content: ContentRenderer.render(page.content, style: .full),
                             contentKind: .document, parserVersion: 2,
                             accumulationPolicy: .replace,
                             offscreenPolicy: Self.offscreen,
                             structured: page.content,
                             truncated: page.truncated)
    }
```

`Sources/MaxMiCapture/StructuredNativeParsers.swift` — the two shared content helpers return the page, and the two builders read both fields. The four thin `parseStructured` wrappers (`WordParser:82`, `PagesParser:95`, `OutlookParser:105`, `SparkParser:115`) each gain `?.content`:

```swift
    /// Generic v2 over the whole window. The anchored document parsers land in Phase D.
    static func documentContent(window: AXNode) -> GenericV2Content.Page? {
        GenericV2Content.page(window: window, budget: pageBudget,
                              offscreenPolicy: documentOffscreen)
    }

    static func document(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String,
        titleSuffixes: [String]
    ) -> ParsedCapture? {
        guard let page = documentContent(window: window) else { return nil }
        var title = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.isEmpty { title = "untitled" }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(docSlug(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(page.content, style: .full),
            contentKind: .document,
            parserVersion: 2,
            // Whole-page semantics (spec 4d): each extraction is the window's current state.
            accumulationPolicy: .replace,
            offscreenPolicy: documentOffscreen,
            structured: page.content,
            truncated: page.truncated
        )
    }

    static func emailContent(window: AXNode) -> GenericV2Content.Page? {
        GenericV2Content.page(window: window, budget: pageBudget,
                              offscreenPolicy: emailOffscreen)
    }

    static func email(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        guard let page = emailContent(window: window) else { return nil }
        let title = meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp]) ?? "message"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):message:\(shortHash(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(page.content, style: .full),
            // Outlook and Spark expose no sender or date, so they stay a page — but the kind
            // is still .email (spec 12 Q3).
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: emailOffscreen,
            structured: page.content,
            truncated: page.truncated
        )
    }
```

- [ ] **Step 12: Carry `truncated` on the browser path**

In `Sources/MaxMiCapture/WebAppCaptureParser.swift`, the local `truncated` already holds "bounding dropped content" for both branches. Add it to the `ParsedCapture` so the non-browser and browser paths use the same field:

```swift
        let capture = ParsedCapture(
            sourceApp: "Web",
            sourceKey: URLKeyNormalizer.normalize(tab.url),
            sourceTitle: tab.title,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: kind,
            parserVersion: 2,
            accumulationPolicy: accumulation,
            offscreenPolicy: .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000),
            structured: structured,
            truncated: truncated
        )
```

`BrowserCapturePipeline.parse` keeps its own `BrowserCaptureResult.truncated` unchanged: it additionally ORs `tab.truncated` (the tab TEXT hitting `BrowserTabExtractor`'s cap), which the parser cannot see.

- [ ] **Step 13: Retire the `8_000` heuristic in `AppWiring`**

Replace `Sources/MaxMi/AppWiring.swift:1573-1576`:

```swift
            let nowMs = epochNowMs()
            let wasTruncated = browserTruncated
                || (parsed.content.count >= 8_000 && Browser(rawValue: app.bundleID) == nil)
```

with:

```swift
            let nowMs = epochNowMs()
            // The parser reports its own budgeting; `browserTruncated` adds the one fact the
            // parser cannot see (the tab text hitting BrowserTabExtractor's cap). The old
            // `content.count >= 8_000` guess false-positived on every 8k-32k document.
            let wasTruncated = browserTruncated || parsed.truncated
```

- [ ] **Step 14: Run the full suite**

Run: `swift test 2>&1 | tail -30`
Expected: 701 executed (689 baseline + 11 `CaptureDeltaSignalsTests` + 1 `GenericV2ParserTests`), exactly the 3 known-red failures listed in Global Constraints. `Browser` may now be unused in `finishCapture`; if the compiler warns, leave the `import` alone and check the symbol is still used by the pipeline lookup above — do not delete anything to silence a warning without checking.

Run: `swift build 2>&1 | grep warning: | wc -l`
Expected: `0`.

- [ ] **Step 15: Commit the truncated plumbing**

```bash
git add Sources/MaxMiCapture/GenericV2Content.swift Sources/MaxMiCapture/SourceParser.swift \
        Sources/MaxMiCapture/GenericAXParser.swift Sources/MaxMiCapture/NotesParser.swift \
        Sources/MaxMiCapture/NotionParser.swift Sources/MaxMiCapture/ObsidianParser.swift \
        Sources/MaxMiCapture/StructuredNativeParsers.swift \
        Sources/MaxMiCapture/WebAppCaptureParser.swift Sources/MaxMi/AppWiring.swift \
        Tests/MaxMiCaptureTests/GenericV2ParserTests.swift
git commit -m "Carry extractor truncation through ParsedCapture instead of guessing from length"
```

---

## Task 2: `capture_events` — migration `v11`, the event types, and the store

The table, the payload types, the write path, the reads, and the 30-day trim. Nothing writes an event yet — Task 4 does that — so this task is judged purely on the schema and the store API.

**Files:**
- Create: `Sources/MaxMiCore/CaptureEvent.swift`
- Create: `Sources/MaxMiStore/CaptureEventStore.swift`
- Modify: `Sources/MaxMiStore/Migrations.swift:4` (`currentIdentifier`) and the end of `migrator` (register `v11`)
- Modify: `Sources/MaxMiCore/SafeLogger.swift:57` (add one `SafeLogEvent` case after `capturePolicyReadFailed`)
- Test: `Tests/MaxMiStoreTests/MigrationV11Tests.swift` (create)
- Test: `Tests/MaxMiStoreTests/CaptureEventStoreTests.swift` (create)
- Modify (`"v10"` → `"v11"` literals, five of them): `Tests/MaxMiStoreTests/MemoryDataControlsTests.swift:97,172,179`, `Tests/MaxMiStoreTests/Phase7BaselineScriptTests.swift:69`, `Tests/MaxMiStoreTests/RuntimeDiagnosticsTests.swift:40`
- Modify (one deletion): `Tests/MaxMiStoreTests/MigrationV10Tests.swift:21-23` — delete `testCurrentIdentifierIsV10`, change nothing else in that file

**Interfaces:**
- Consumes: `EpochMs`, `epochNowMs()`, `HourBucket.bucket(forMs:) -> Int64`, `Ident.uuidv7(nowMs:) -> String`, `CaptureTrigger` (`appActivated, accessibilityChanged, conversationChanged, browserNavigation, webContentChanged, periodic, retry, unknown`), `Block`, `ContentRenderer.renderBlocks(_:) -> String`, `CapturedContentEnvelope.makeEncoder()/makeDecoder()`, `CaptureDelta`, `Store.db: MaxMiDatabase`, `Store.cipher: any FieldCipher`, `Store.decryptOrMarker(_:)`, `Store.placeholders(_:)`, `Store.structuredOrLegacy(_:renderedContent:kind:)`.
- Produces:
  - `CaptureEventKind: String, Sendable, Codable, CaseIterable` — `focus`, `navigation`, `contentDelta` (`"content_delta"`), `typing`, `dialog`.
  - `FocusEventPayload(bundleID: String, appLabel: String, windowTitle: String?)`
  - `NavigationEventPayload(fromURL: String?, toURL: String)`
  - `TypingEvent(insertedText: String, fieldRole: String, fieldIdentifier: String?, totalLength: Int, replaced: Bool)`
  - `DialogEventPayload(blocks: [Block])` + `DialogEventPayload.capped(_ blocks: [Block]) -> [Block]`
  - `CaptureEventRetention.days = 30`, `.trimIntervalMs: EpochMs = 3_600_000`, `.lastTrimSettingsKey = "capture_events_last_trim_at"`, `.dialogPayloadCap = 1_000`
  - `CaptureEventRecord(id: String, appBundle: String?, threadID: String?, versionID: String?, atMs: EpochMs, kind: CaptureEventKind, trigger: CaptureTrigger, payloadJSON: String?)`
  - `Store.recordCaptureEvent(kind:appBundle:threadID:versionID:trigger:payload:nowMs:) throws` — `appBundle: String?` is **required, no default**, and is written to the plaintext `app_bundle` column
  - `Store.recentCaptureEvents(limit: Int = 100) throws -> [CaptureEventRecord]`
  - `Store.captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [CaptureEventRecord]`
  - `SafeLogEvent.captureEventWriteFailed = "capture_event_write_failed"`

- [ ] **Step 1: Write the failing migration test**

Create `Tests/MaxMiStoreTests/MigrationV11Tests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MigrationV11Tests: XCTestCase {
    func testCurrentIdentifierIsV11() {
        XCTAssertEqual(Migrations.currentIdentifier, "v11")
    }

    func testCaptureEventsTableShape() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("capture_events"))
            let columns = try Row.fetchAll(d, sql: "PRAGMA table_info(capture_events)")
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"] as String, $0) })
            XCTAssertEqual(Set(byName.keys), [
                "id", "app_bundle", "thread_id", "version_id", "at_ms", "kind", "trigger",
                "payload_ciphertext", "hour_bucket",
            ])
            // Plaintext and nullable: a bundle id is an identifier, not content, and it is what
            // makes spec 11 criterion 4 checkable without a decrypt (spec 5b as amended).
            XCTAssertEqual(byName["app_bundle"]?["type"] as String?, "TEXT")
            XCTAssertEqual(byName["app_bundle"]?["notnull"] as Int?, 0)
            // Nullable on purpose: a focus event precedes any thread for that window (12 Q4),
            // and version pruning must not delete events.
            XCTAssertEqual(byName["thread_id"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["version_id"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["payload_ciphertext"]?["type"] as String?, "TEXT")
            XCTAssertEqual(byName["payload_ciphertext"]?["notnull"] as Int?, 0)
            XCTAssertEqual(byName["at_ms"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["kind"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["trigger"]?["notnull"] as Int?, 1)
            XCTAssertEqual(byName["hour_bucket"]?["notnull"] as Int?, 1)
        }
    }

    func testBothIndexesExist() throws {
        let db = try MaxMiDatabase.inMemory()
        let names = try db.dbQueue.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='capture_events'")
        }
        XCTAssertTrue(names.contains("idx_capture_events_at"), "\(names)")
        XCTAssertTrue(names.contains("idx_capture_events_thread"), "\(names)")
    }

    func testKindCheckConstraintRejectsAnUnknownKind() throws {
        let db = try MaxMiDatabase.inMemory()
        XCTAssertThrowsError(try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                            trigger, payload_ciphertext, hour_bucket)
                VALUES ('e1',NULL,NULL,NULL,1,'scrolling','periodic',NULL,0)
                """)
        })
    }

    func testEveryCaptureEventKindPassesTheCheckConstraint() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.write { d in
            for (index, kind) in CaptureEventKind.allCases.enumerated() {
                try d.execute(sql: """
                    INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                                trigger, payload_ciphertext, hour_bucket)
                    VALUES (?,NULL,NULL,NULL,?,?,'periodic',NULL,0)
                    """, arguments: ["e\(index)", index, kind.rawValue])
            }
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM capture_events"),
                           CaptureEventKind.allCases.count)
        }
    }

    /// A v10 database must migrate forward and keep its rows.
    func testV10DatabaseMigratesForwardWithoutDataLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }

        let old = try MaxMiDatabase(path: url.path, migrate: false)
        try Migrations.migrator.migrate(old.dbQueue, upTo: "v10")
        try old.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO threads VALUES ('t1','Notes','note:one','Idea',NULL,1,1)")
        }
        try old.dbQueue.close()

        let migrated = try MaxMiDatabase(path: url.path)
        defer { try? migrated.dbQueue.close() }
        try migrated.dbQueue.read { d in
            XCTAssertTrue(try d.tableExists("capture_events"))
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM threads"), 1)
            XCTAssertEqual(
                try String.fetchOne(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                "v11")
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter MigrationV11Tests`
Expected: FAIL — `capture_events` does not exist, `currentIdentifier` is `"v10"`, and `CaptureEventKind` is not defined.

- [ ] **Step 3: Add the `MaxMiCore` event types**

Create `Sources/MaxMiCore/CaptureEvent.swift`:

```swift
import Foundation

/// What kind of thing happened. The raw values are the `capture_events.kind` CHECK constraint's
/// vocabulary, so they must match the migration exactly.
public enum CaptureEventKind: String, Sendable, Codable, CaseIterable {
    case focus = "focus"
    case navigation = "navigation"
    case contentDelta = "content_delta"
    case typing = "typing"
    case dialog = "dialog"
}

/// Encrypted like every other payload: a window title is content.
public struct FocusEventPayload: Codable, Sendable, Equatable {
    public let bundleID: String
    public let appLabel: String
    public let windowTitle: String?

    public init(bundleID: String, appLabel: String, windowTitle: String?) {
        self.bundleID = bundleID
        self.appLabel = appLabel
        self.windowTitle = windowTitle
    }
}

public struct NavigationEventPayload: Codable, Sendable, Equatable {
    /// nil for the first capture of a thread — there is no previous URL to report.
    public let fromURL: String?
    public let toURL: String

    public init(fromURL: String?, toURL: String) {
        self.fromURL = fromURL
        self.toURL = toURL
    }
}

/// One meaningful change to the focused field's value. Produced by `TypingObserver`
/// (`MaxMiCapture`), stored as a `typing` event, and read back by `TimelineBuilder`
/// (`MaxMiActivity`) — which is why it lives here rather than next to the observer.
public struct TypingEvent: Codable, Sendable, Equatable {
    /// The inserted run when `replaced == false`; the new value's trailing
    /// `TypingObserver.maxReplacedTailChars` characters when `replaced == true`.
    public let insertedText: String
    public let fieldRole: String
    public let fieldIdentifier: String?
    /// Character count of the field's whole value after the change.
    public let totalLength: Int
    /// True when the change was not a pure insertion — paste, replace, select-all-retype, clear.
    public let replaced: Bool

    public init(insertedText: String, fieldRole: String, fieldIdentifier: String?,
                totalLength: Int, replaced: Bool) {
        self.insertedText = insertedText
        self.fieldRole = fieldRole
        self.fieldIdentifier = fieldIdentifier
        self.totalLength = totalLength
        self.replaced = replaced
    }
}

public struct DialogEventPayload: Codable, Sendable, Equatable {
    public let blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Whole blocks from the front, until the rendered form would exceed
    /// `CaptureEventRetention.dialogPayloadCap`. The first block is always kept: a dialog whose
    /// single block is longer than the cap must still say what it was.
    public static func capped(_ blocks: [Block]) -> [Block] {
        var kept: [Block] = []
        var used = 0
        for block in blocks {
            let cost = ContentRenderer.renderBlock(block).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, used + cost > CaptureEventRetention.dialogPayloadCap { break }
            kept.append(block)
            used += cost
        }
        return kept
    }
}

/// MaxMi's only automatic age-based deletion (spec 12 Q5). Thirty days because events are
/// derived signals rather than memories, and the Activity window may look back a month. Memory
/// retention itself is unchanged — still Forever by default.
public enum CaptureEventRetention {
    public static let days = 30
    /// The trim runs at most this often, so a capture does not pay for a DELETE.
    public static let trimIntervalMs: EpochMs = 3_600_000
    public static let lastTrimSettingsKey = "capture_events_last_trim_at"
    /// Rendered-character cap on a `dialog` payload.
    public static let dialogPayloadCap = 1_000

    public static func cutoffMs(nowMs: EpochMs) -> EpochMs {
        nowMs - EpochMs(days) * 86_400_000
    }
}
```

- [ ] **Step 4: Register migration `v11`**

In `Sources/MaxMiStore/Migrations.swift`, change line 4 to `static let currentIdentifier = "v11"` and append this registration immediately after the `v10` block, before `return m`:

```swift
        m.registerMigration("v11") { db in
            // `app_bundle` is nullable PLAINTEXT, exactly like `activity_app_visits.app_bundle`
            // above: a bundle id is an identifier, not content, and it is the only way to check
            // spec 11 criterion 4 ("nothing is written for a denylisted, excluded, or
            // non-consented app") without decrypting a payload. Not indexed — the only query is
            // the criterion check and `idx_capture_events_at` already covers its time bound.
            // `thread_id` is nullable because a focus event fires before any thread exists for
            // that window (spec 12 Q4). `version_id` is SET NULL so version pruning keeps the
            // event. `payload_ciphertext` is TEXT because FieldCipher.encrypt returns the
            // "enc:v1:" prefixed base64 String (spec 12 Q2).
            try db.execute(sql: """
            CREATE TABLE capture_events (
              id                 TEXT PRIMARY KEY,
              app_bundle         TEXT,
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
            """)
        }
```

- [ ] **Step 5: Retarget the five `"v10"` literals and delete the one duplicate assertion**

`grep -rn '"v10"' Tests/` returns exactly six hits. Five are schema-identifier assertions whose
literal simply becomes `"v11"`. The sixth, `MigrationV10Tests.testCurrentIdentifierIsV10`, is
**deleted**: `MigrationV11Tests.testCurrentIdentifierIsV11` (Step 1) owns that assertion from now
on, and `MigrationV10Tests` keeps only its v10-*structural* tests, which stay true forever.

That is the single disposition for that method. Do not rename it, do not repurpose it, and do not
add a replacement method to that file — a second `Migrations.migrator.migrations.contains("v10")`
assertion would be new dead weight, and `MigrationV11Tests.testV10DatabaseMigratesForwardWithoutDataLoss`
already proves `v10` is still registered by migrating a real `v10` database forward.

Leave the surrounding comments' historical `v10` references alone: they describe when a column
arrived, which is still true.

The script below runs from the **worktree**. `pwd` must be
`/Users/mafex/code/personal/MaxMi/.worktrees/m8b-deltas-events-typing`, NOT
`/Users/mafex/code/personal/MaxMi`, which is a different checkout sitting on branch `main`. The
branch check and the per-target asserts make a wrong directory fail loudly instead of quietly
editing `main`.

```bash
cd /Users/mafex/code/personal/MaxMi/.worktrees/m8b-deltas-events-typing
git rev-parse --abbrev-ref HEAD   # must print m8b-deltas-events-typing
python3 - <<'PATCH'
import pathlib
edits = {
    "Tests/MaxMiStoreTests/MemoryDataControlsTests.swift": [
        ('XCTAssertEqual(result.migrationIdentifier, "v10")',
         'XCTAssertEqual(result.migrationIdentifier, "v11")'),
        ('                "v10"\n', '                "v11"\n'),
    ],
    "Tests/MaxMiStoreTests/Phase7BaselineScriptTests.swift": [
        ('latest_migration=v10', 'latest_migration=v11'),
    ],
    "Tests/MaxMiStoreTests/RuntimeDiagnosticsTests.swift": [
        ('XCTAssertEqual(snapshot.latestMigration.value, "v10")',
         'XCTAssertEqual(snapshot.latestMigration.value, "v11")'),
    ],
}
for path, pairs in edits.items():
    p = pathlib.Path(path)
    text = p.read_text()
    for old, new in pairs:
        assert old in text, (path, old)
        text = text.replace(old, new)
    p.write_text(text)

# Delete the duplicate assertion; MigrationV11Tests owns it now.
p = pathlib.Path("Tests/MaxMiStoreTests/MigrationV10Tests.swift")
text = p.read_text()
method = """    func testCurrentIdentifierIsV10() {
        XCTAssertEqual(Migrations.currentIdentifier, "v10")
    }

"""
assert method in text, "MigrationV10Tests no longer matches; read it before editing"
p.write_text(text.replace(method, ""))
print("done")
PATCH
grep -rn '"v10"' Tests/ || echo "no v10 literals left"
```

Expected: `done`, then `no v10 literals left`. `MigrationV10Tests` now has two test methods, both
about v10's columns; the suite total drops by one, which Task 10 Step 1 accounts for.

- [ ] **Step 6: Run the migration tests to verify they pass**

Run: `swift test --filter "MigrationV11Tests|MigrationV10Tests|MigrationTests"`
Expected: PASS. `MigrationV11Tests` contributes 6 tests; `MigrationV10Tests` contributes 2 (down from 3).

- [ ] **Step 7: Commit the migration**

```bash
git add Sources/MaxMiCore/CaptureEvent.swift Sources/MaxMiStore/Migrations.swift \
        Tests/MaxMiStoreTests/MigrationV11Tests.swift Tests/MaxMiStoreTests/MigrationV10Tests.swift \
        Tests/MaxMiStoreTests/MemoryDataControlsTests.swift \
        Tests/MaxMiStoreTests/Phase7BaselineScriptTests.swift \
        Tests/MaxMiStoreTests/RuntimeDiagnosticsTests.swift
git commit -m "Add capture_events migration v11 and the event payload types"
```

- [ ] **Step 8: Write the failing store tests**

Create `Tests/MaxMiStoreTests/CaptureEventStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class CaptureEventStoreTests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(1_800_000_000_000)

    override func setUpWithError() throws {
        db = try .inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    private func seedThreadAndVersion() throws -> (threadID: String, versionID: String) {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "Idea",
                         content: "first line"),
            nowMs: t0
        ) else {
            throw XCTSkip("commitCapture must commit a first capture")
        }
        let threadID = try store.threadID(forKey: "note:one")
        return (threadID, versionID)
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: CaptureEventRecord) throws -> T {
        let json = try XCTUnwrap(record.payloadJSON)
        return try CapturedContentEnvelope.makeDecoder().decode(type, from: Data(json.utf8))
    }

    /// The `focus` write, which most of these tests only need as "a row exists at this time".
    private func recordFocus(nowMs: EpochMs, appBundle: String = "com.example.editor",
                             windowTitle: String? = nil,
                             trigger: CaptureTrigger = .periodic) throws {
        try store.recordCaptureEvent(
            kind: .focus, appBundle: appBundle, threadID: nil, versionID: nil, trigger: trigger,
            payload: FocusEventPayload(bundleID: appBundle, appLabel: "Editor",
                                       windowTitle: windowTitle),
            nowMs: nowMs)
    }

    func testFocusPayloadRoundTripsAndIsEncryptedAtRest() throws {
        try store.recordCaptureEvent(
            kind: .focus, appBundle: "com.example.editor", threadID: nil, versionID: nil,
            trigger: .unknown,
            payload: FocusEventPayload(bundleID: "com.example.editor", appLabel: "Editor",
                                       windowTitle: "quarterly-plan"),
            nowMs: t0)

        let record = try XCTUnwrap(store.recentCaptureEvents().first)
        XCTAssertEqual(record.kind, .focus)
        XCTAssertEqual(record.appBundle, "com.example.editor",
                       "plaintext, so a row is attributable without a decrypt")
        XCTAssertNil(record.threadID)
        XCTAssertNil(record.versionID)
        XCTAssertEqual(record.trigger, .unknown)
        XCTAssertEqual(record.atMs, t0)
        let payload = try decode(FocusEventPayload.self, from: record)
        XCTAssertEqual(payload.windowTitle, "quarterly-plan")

        let stored = try XCTUnwrap(db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT payload_ciphertext FROM capture_events")
        })
        XCTAssertTrue(stored.hasPrefix("enc:v1:"))
        XCTAssertFalse(stored.contains("quarterly-plan"))
    }

    func testNavigationTypingDialogAndDeltaPayloadsRoundTrip() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .navigation, appBundle: "com.example.browser", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .browserNavigation,
            payload: NavigationEventPayload(fromURL: "https://example.com/a",
                                            toURL: "https://example.com/b"),
            nowMs: t0 + 1)
        try store.recordCaptureEvent(
            kind: .typing, appBundle: "com.example.chat", threadID: seeded.threadID,
            versionID: nil, trigger: .accessibilityChanged,
            payload: TypingEvent(insertedText: " world", fieldRole: "AXTextArea",
                                 fieldIdentifier: "composer", totalLength: 11, replaced: false),
            nowMs: t0 + 2)
        try store.recordCaptureEvent(
            kind: .dialog, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .accessibilityChanged,
            payload: DialogEventPayload(blocks: [Block(type: .label, text: "Discard")]),
            nowMs: t0 + 3)
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "second line")],
                                  addedChars: 12),
            nowMs: t0 + 4)

        let records = try store.recentCaptureEvents()
        XCTAssertEqual(records.map(\.kind), [.contentDelta, .dialog, .typing, .navigation])

        let delta = try decode(CaptureDelta.self, from: records[0])
        XCTAssertEqual(delta.addedBlocks.map(\.text), ["second line"])
        XCTAssertEqual(try decode(DialogEventPayload.self, from: records[1]).blocks.map(\.text),
                       ["Discard"])
        XCTAssertEqual(try decode(TypingEvent.self, from: records[2]).insertedText, " world")
        XCTAssertEqual(try decode(NavigationEventPayload.self, from: records[3]).fromURL,
                       "https://example.com/a")
    }

    func testHourBucketAndIdentifierAreDerivedFromTheTimestamp() throws {
        try recordFocus(nowMs: t0, trigger: .appActivated)
        let bucket = try db.dbQueue.read { d in
            try Int64.fetchOne(d, sql: "SELECT hour_bucket FROM capture_events")
        }
        XCTAssertEqual(bucket, HourBucket.bucket(forMs: t0))
        let id = try XCTUnwrap(store.recentCaptureEvents().first?.id)
        XCTAssertEqual(id.count, 36, "Ident.uuidv7 produces a hyphenated uuid string")
    }

    /// The whole point of the plaintext `app_bundle` column: a row is attributable to an app
    /// without decrypting anything, which is what makes spec 11 criterion 4 ("nothing is written
    /// for a denylisted, excluded, or non-consented app") a query anyone can run. Before this
    /// column the only app identifier in a row lived inside the encrypted `focus` payload.
    func testEventsAreAttributableToTheirAppWithoutDecrypting() throws {
        try recordFocus(nowMs: t0, appBundle: "com.example.editor")
        try recordFocus(nowMs: t0 + 1, appBundle: "com.example.excluded")
        try recordFocus(nowMs: t0 + 2, appBundle: "com.example.excluded")

        let excludedRows = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT count(*) FROM capture_events WHERE app_bundle=? AND at_ms > ?
                """, arguments: ["com.example.excluded", t0])
        }
        XCTAssertEqual(excludedRows, 2, "the exit-criterion query runs on plaintext alone")
        let records = try store.recentCaptureEvents()
        XCTAssertEqual(records.first?.appBundle, "com.example.excluded")
        XCTAssertEqual(records.filter { $0.appBundle == "com.example.editor" }.count, 1)
    }

    func testDeletingTheThreadCascadesItsEvents() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedChars: 1), nowMs: t0 + 1)
        try db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM latest_contexts WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM message_fingerprints WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM versions WHERE thread_id=?", arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM threads WHERE id=?", arguments: [seeded.threadID])
        }
        XCTAssertTrue(try store.recentCaptureEvents().isEmpty)
    }

    func testDeletingTheVersionNullsVersionIDButKeepsTheEvent() throws {
        let seeded = try seedThreadAndVersion()
        try store.recordCaptureEvent(
            kind: .contentDelta, appBundle: "com.example.notes", threadID: seeded.threadID,
            versionID: seeded.versionID, trigger: .periodic,
            payload: CaptureDelta(addedChars: 1), nowMs: t0 + 1)
        try db.dbQueue.write { d in
            try d.execute(sql: "UPDATE latest_contexts SET version_id=NULL WHERE thread_id=?",
                          arguments: [seeded.threadID])
            try d.execute(sql: "DELETE FROM versions WHERE id=?", arguments: [seeded.versionID])
        }
        let record = try XCTUnwrap(store.recentCaptureEvents().first)
        XCTAssertEqual(record.threadID, seeded.threadID)
        XCTAssertNil(record.versionID)
    }

    /// `app_bundle` is nullable, so a hand-written row may omit it. The reader must not drop it.
    private func insertAncientRow(atMs: EpochMs) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (id, app_bundle, thread_id, version_id, at_ms, kind,
                                            trigger, payload_ciphertext, hour_bucket)
                VALUES ('ancient',NULL,NULL,NULL,?,'focus','periodic',NULL,0)
                """, arguments: [atMs])
        }
    }

    func testTrimDeletesEventsOlderThanThirtyDays() throws {
        try insertAncientRow(atMs: t0 - EpochMs(CaptureEventRetention.days) * 86_400_000 - 1)
        try recordFocus(nowMs: t0)
        XCTAssertEqual(try store.recentCaptureEvents().map(\.id).contains("ancient"), false)
    }

    func testTrimRunsAtMostOncePerHour() throws {
        // First write trims (last-trim is unset) and records t0 as the trim time.
        try recordFocus(nowMs: t0)
        try insertAncientRow(atMs: t0 - EpochMs(CaptureEventRetention.days) * 86_400_000 - 1)
        // Inside the gate: the stale row survives, so no capture pays for a DELETE.
        try recordFocus(nowMs: t0 + 1_000)
        XCTAssertTrue(try store.recentCaptureEvents().map(\.id).contains("ancient"))

        // An hour later the gate opens.
        try recordFocus(nowMs: t0 + CaptureEventRetention.trimIntervalMs)
        XCTAssertFalse(try store.recentCaptureEvents().map(\.id).contains("ancient"))
    }

    func testCaptureEventsWindowIsInclusiveAndChronological() throws {
        for offset in [0, 10, 20, 30] {
            try recordFocus(nowMs: t0 + EpochMs(offset), windowTitle: "w\(offset)")
        }
        let window = try store.captureEvents(fromMs: t0 + 10, toMs: t0 + 20)
        XCTAssertEqual(window.map(\.atMs), [t0 + 10, t0 + 20])
    }

    func testRecentCaptureEventsLimitIsBounded() throws {
        for offset in 0..<5 {
            try recordFocus(nowMs: t0 + EpochMs(offset))
        }
        XCTAssertEqual(try store.recentCaptureEvents(limit: 0).count, 1)
        XCTAssertEqual(try store.recentCaptureEvents(limit: 10_000).count, 5)
    }

    func testDialogPayloadIsCappedAtOneThousandRenderedChars() {
        let blocks = (0..<20).map { Block(type: .paragraph, text: String(repeating: "d", count: 100) + "\($0)") }
        let capped = DialogEventPayload.capped(blocks)
        XCTAssertLessThanOrEqual(ContentRenderer.renderBlocks(capped).count,
                                 CaptureEventRetention.dialogPayloadCap)
        XCTAssertLessThan(capped.count, blocks.count)
        XCTAssertEqual(capped.first?.text, blocks.first?.text, "the first block is always kept")
    }

    func testDialogPayloadKeepsASingleOversizeBlock() {
        let one = [Block(type: .paragraph, text: String(repeating: "d", count: 5_000))]
        XCTAssertEqual(DialogEventPayload.capped(one).count, 1)
    }
}
```

- [ ] **Step 9: Run them to verify they fail**

Run: `swift test --filter CaptureEventStoreTests`
Expected: compile FAIL — `recordCaptureEvent`, `recentCaptureEvents`, `captureEvents(fromMs:toMs:)` and `CaptureEventRecord` do not exist.

- [ ] **Step 10: Implement the store**

Create `Sources/MaxMiStore/CaptureEventStore.swift`:

```swift
import Foundation
import GRDB
import MaxMiCore

/// One decrypted `capture_events` row. The payload stays JSON: the reader knows which shape a
/// kind carries, and keeping it opaque here means a new kind needs no change to this type.
public struct CaptureEventRecord: Sendable, Equatable {
    public let id: String
    /// The bundle id of the app this event belongs to, from the plaintext `app_bundle` column.
    /// Optional because the column is nullable, not because any current writer omits it.
    public let appBundle: String?
    public let threadID: String?
    public let versionID: String?
    public let atMs: EpochMs
    public let kind: CaptureEventKind
    public let trigger: CaptureTrigger
    /// nil when the column was NULL. A decrypt or read failure yields the same marker
    /// `decryptOrMarker` uses everywhere else, never a throw.
    public let payloadJSON: String?

    public init(id: String, appBundle: String?, threadID: String?, versionID: String?,
                atMs: EpochMs, kind: CaptureEventKind, trigger: CaptureTrigger,
                payloadJSON: String?) {
        self.id = id
        self.appBundle = appBundle
        self.threadID = threadID
        self.versionID = versionID
        self.atMs = atMs
        self.kind = kind
        self.trigger = trigger
        self.payloadJSON = payloadJSON
    }
}

extension Store {
    /// Records one capture event with an encrypted JSON payload, and bounds the ledger by AGE
    /// (30 days) rather than by row count — an activity window may reasonably look back a month.
    /// The trim is gated to at most once an hour so a capture does not pay for a DELETE.
    ///
    /// Callers are responsible for the privacy gate: `AppWiring.isActivityEligible(bundleID:)`
    /// must be satisfied before this is called (spec 8).
    public func recordCaptureEvent(
        kind: CaptureEventKind,
        // Plaintext, so a row is attributable to an app without decrypting its payload — the only
        // thing that makes spec 11 criterion 4 checkable. Required, with no default, so a new
        // event kind cannot silently write an unattributable row.
        appBundle: String?,
        threadID: String?,
        versionID: String?,
        trigger: CaptureTrigger,
        payload: some Encodable & Sendable,
        nowMs: EpochMs
    ) throws {
        let json = String(
            decoding: try CapturedContentEnvelope.makeEncoder().encode(payload), as: UTF8.self)
        let ciphertext = try cipher.encrypt(json)
        try db.dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO capture_events (
                    id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                    payload_ciphertext, hour_bucket
                ) VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [
                    Ident.uuidv7(nowMs: nowMs), appBundle, threadID, versionID, nowMs,
                    kind.rawValue, trigger.rawValue, ciphertext, HourBucket.bucket(forMs: nowMs),
                ])
            try Self.trimCaptureEventsIfDue(d, nowMs: nowMs)
        }
    }

    /// The once-per-hour gate lives in `settings` next to every other scalar MaxMi keeps.
    static func trimCaptureEventsIfDue(_ d: Database, nowMs: EpochMs) throws {
        let lastTrim = try String.fetchOne(
            d, sql: "SELECT value FROM settings WHERE key=?",
            arguments: [CaptureEventRetention.lastTrimSettingsKey]
        ).flatMap { EpochMs($0) } ?? 0
        guard nowMs - lastTrim >= CaptureEventRetention.trimIntervalMs else { return }
        try d.execute(sql: "DELETE FROM capture_events WHERE at_ms < ?",
                      arguments: [CaptureEventRetention.cutoffMs(nowMs: nowMs)])
        try d.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?,?,?)",
                      arguments: [CaptureEventRetention.lastTrimSettingsKey, String(nowMs), nowMs])
    }

    /// Newest first, for the Capture Health window.
    public func recentCaptureEvents(limit: Int = 100) throws -> [CaptureEventRecord] {
        let boundedLimit = min(max(limit, 1), 500)
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                       payload_ciphertext
                FROM capture_events
                ORDER BY at_ms DESC, id DESC
                LIMIT ?
                """, arguments: [boundedLimit]).compactMap { self.eventRecord(from: $0) }
        }
    }

    /// Chronological, both bounds inclusive. This is the timeline's window read.
    public func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [CaptureEventRecord] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, thread_id, version_id, at_ms, kind, trigger,
                       payload_ciphertext
                FROM capture_events
                WHERE at_ms >= ? AND at_ms <= ?
                ORDER BY at_ms ASC, id ASC
                """, arguments: [fromMs, toMs]).compactMap { self.eventRecord(from: $0) }
        }
    }

    /// An unrecognised `kind` or `trigger` drops the row rather than crashing: a database written
    /// by a newer build must not take the reader down. A payload that will not decrypt becomes
    /// the same `[unreadable memory]` marker every other read uses. An instance method, not
    /// `static`, because decryption needs `self.cipher`.
    private func eventRecord(from row: Row) -> CaptureEventRecord? {
        guard let kind = CaptureEventKind(rawValue: row["kind"]),
              let trigger = CaptureTrigger(rawValue: row["trigger"]) else { return nil }
        return CaptureEventRecord(
            id: row["id"],
            appBundle: row["app_bundle"],
            threadID: row["thread_id"],
            versionID: row["version_id"],
            atMs: row["at_ms"],
            kind: kind,
            trigger: trigger,
            payloadJSON: (row["payload_ciphertext"] as String?).map(decryptOrMarker)
        )
    }
}
```

- [ ] **Step 11: Add the log event**

In `Sources/MaxMiCore/SafeLogger.swift`, after `case capturePolicyReadFailed = "capture_policy_read_failed"`:

```swift
    /// A capture_events write failed. Never fatal — an event is a derived signal, not a memory.
    case captureEventWriteFailed = "capture_event_write_failed"
```

- [ ] **Step 12: Run the store tests to verify they pass**

Run: `swift test --filter CaptureEventStoreTests`
Expected: PASS, 12 tests.

Run: `swift test --filter MaxMiStoreTests 2>&1 | tail -20`
Expected: only the two known-red store failures (`ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`, `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`).

- [ ] **Step 13: Commit the store**

```bash
git add Sources/MaxMiStore/CaptureEventStore.swift Sources/MaxMiCore/SafeLogger.swift \
        Tests/MaxMiStoreTests/CaptureEventStoreTests.swift
git commit -m "Add CaptureEventStore with encrypted payloads and 30-day trim on write"
```

---

## Task 3: Wire `capture_events` into the data controls and state the retention in the UI

The trim in Task 2 covers the automatic case. The user-triggered controls must also reach the new table, and because this is the only thing MaxMi deletes unasked, the Privacy screen says so.

**Files:**
- Modify: `Sources/MaxMiStore/MemoryDataControls.swift:5-13` (`MemoryDeletionResult`), `:91-148` (`pruneMemory`), `:150-175` (`deleteAllMemory`)
- Modify: `Sources/MaxMiUI/CapturePrivacyView.swift:104-121` (`retentionCard`)
- Test: `Tests/MaxMiStoreTests/MemoryDataControlsTests.swift` (extend)
- Test: `Tests/MaxMiUITests/CapturePrivacyCopyTests.swift` (create)

**Interfaces:**
- Consumes: `Store.recordCaptureEvent(kind:appBundle:threadID:versionID:trigger:payload:nowMs:)`, `Store.recentCaptureEvents(limit:)`, `CaptureEventRetention.days`, `FocusEventPayload`, `CaptureDelta` (all from Task 2); `Store.pruneMemory(olderThan:) throws -> MemoryDeletionResult`; `Store.deleteAllMemory() throws -> MemoryDeletionResult`.
- Produces:
  - `MemoryDeletionResult(threads: Int, versions: Int, facts: Int, events: Int)` — `events` is a **required** fourth parameter. The only two construction sites are inside `MemoryDataControls.swift`, so no default is needed and none is added.
  - `CapturePrivacyCopy.eventRetentionNote = "Activity events are kept for 30 days."` in `Sources/MaxMiUI/CapturePrivacyView.swift`, so the copy is assertable without rendering SwiftUI.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MaxMiStoreTests/MemoryDataControlsTests.swift` (inside the existing class):

```swift
    private func seedCaptureEvent(atMs: EpochMs, threadKey: String) throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: threadKey, sourceTitle: "T",
                         content: "content \(threadKey)"),
            nowMs: atMs
        )
        try store.recordCaptureEvent(
            kind: .contentDelta,
            appBundle: "com.example.web",
            threadID: try store.threadID(forKey: threadKey),
            versionID: nil,
            trigger: .periodic,
            payload: CaptureDelta(addedChars: 4),
            nowMs: atMs
        )
    }

    func testPruneDeletesCaptureEventsOlderThanTheCutoffAndCountsThem() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "old")
        try seedCaptureEvent(atMs: t0 + 100_000, threadKey: "new")

        let result = try store.pruneMemory(olderThan: t0 + 50_000)
        XCTAssertEqual(result.events, 1)
        let remaining = try store.recentCaptureEvents()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.atMs, t0 + 100_000)
    }

    func testDeleteAllMemoryRemovesCaptureEventsAndCountsThem() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "one")
        let result = try store.deleteAllMemory()
        XCTAssertEqual(result.events, 1)
        XCTAssertTrue(try store.recentCaptureEvents().isEmpty)
    }

    /// The trim gate must not survive a delete-all: a fresh database should trim on its first
    /// write, not wait an hour.
    func testDeleteAllMemoryClearsTheTrimGate() throws {
        try seedCaptureEvent(atMs: t0, threadKey: "one")
        _ = try store.deleteAllMemory()
        let gate = try store.db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key=?",
                                arguments: [CaptureEventRetention.lastTrimSettingsKey])
        }
        XCTAssertNil(gate)
    }
```

Create `Tests/MaxMiUITests/CapturePrivacyCopyTests.swift`:

```swift
import XCTest
@testable import MaxMiUI

final class CapturePrivacyCopyTests: XCTestCase {
    /// MaxMi's only unasked deletion is stated in the UI, verbatim (spec 5b, 12 Q5).
    func testEventRetentionNoteIsExactAndNamesTheWindow() {
        XCTAssertEqual(CapturePrivacyCopy.eventRetentionNote,
                       "Activity events are kept for 30 days.")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "MemoryDataControlsTests|CapturePrivacyCopyTests"`
Expected: FAIL — `MemoryDeletionResult` has no `events`, and `CapturePrivacyCopy` does not exist.

- [ ] **Step 3: Add `events` to the deletion result**

In `Sources/MaxMiStore/MemoryDataControls.swift`:

```swift
public struct MemoryDeletionResult: Sendable, Equatable {
    public let threads: Int
    public let versions: Int
    public let facts: Int
    /// `capture_events` rows removed. Reported separately from memories because events are
    /// derived signals with their own 30-day retention (spec 5b).
    public let events: Int

    public init(threads: Int, versions: Int, facts: Int, events: Int) {
        self.threads = threads; self.versions = versions; self.facts = facts
        self.events = events
    }
}
```

- [ ] **Step 4: Delete events in `pruneMemory`**

In `pruneMemory(olderThan:)`, add the count next to the three existing counts:

```swift
            let factCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM derivatives WHERE committed_at < ?", arguments: [cutoffMs]) ?? 0
            let eventCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM capture_events WHERE at_ms < ?", arguments: [cutoffMs]) ?? 0
```

add the delete next to the `capture_health_events` delete (the same age-based group), and return the new field:

```swift
            try database.execute(sql: "DELETE FROM capture_health_events WHERE at_ms < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM capture_events WHERE at_ms < ?", arguments: [cutoffMs])
            try database.execute(sql: "DELETE FROM message_fingerprints WHERE seen_at < ?", arguments: [cutoffMs])

            try database.execute(sql: "DROP TABLE maxmi_prune_versions")
            try database.execute(sql: "DROP TABLE maxmi_prune_threads")
            return MemoryDeletionResult(threads: threadCount, versions: versionCount,
                                        facts: factCount, events: eventCount)
```

The thread deletes above this point already cascade their events (`ON DELETE CASCADE`), so `eventCount` can exceed the number of rows this statement itself removes. That is correct: it is the number of events that were older than the cutoff, which is what the user asked about.

- [ ] **Step 5: Delete events in `deleteAllMemory`**

```swift
    public func deleteAllMemory() throws -> MemoryDeletionResult {
        try db.dbQueue.write { database in
            let result = MemoryDeletionResult(
                threads: try Int.fetchOne(database, sql: "SELECT count(*) FROM threads") ?? 0,
                versions: try Int.fetchOne(database, sql: "SELECT count(*) FROM versions") ?? 0,
                facts: try Int.fetchOne(database, sql: "SELECT count(*) FROM derivatives") ?? 0,
                events: try Int.fetchOne(database, sql: "SELECT count(*) FROM capture_events") ?? 0
            )
```

and, next to the existing `paused_threads` settings delete at the end. `MemoryDataControls.swift`
already has `import MaxMiCore` at the top, so the key is the constant — never a repeated literal:

```swift
            try database.execute(sql: "DELETE FROM capture_health_events")
            try database.execute(sql: "DELETE FROM capture_events")
            try database.execute(sql: "DELETE FROM settings WHERE key='paused_threads'")
            // The trim gate must not outlive the rows it was gating, or a fresh database waits an
            // hour before its first trim.
            try database.execute(sql: "DELETE FROM settings WHERE key=?",
                                 arguments: [CaptureEventRetention.lastTrimSettingsKey])
            return result
```

- [ ] **Step 6: Add the Privacy copy**

In `Sources/MaxMiUI/CapturePrivacyView.swift`, add the namespace above the view (top level of the file, after the imports):

```swift
/// User-facing capture-privacy strings that tests assert verbatim. MaxMi's only automatic,
/// unasked deletion is the 30-day `capture_events` window, so it is stated on the retention card.
public enum CapturePrivacyCopy {
    public static let eventRetentionNote = "Activity events are kept for 30 days."
}
```

and extend `retentionCard`'s subtitle stack:

```swift
    private var retentionCard: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("How long to keep memories").font(.subheadline).foregroundColor(Theme.text)
                Text("Older memories are removed when you run cleanup in Data Controls.").font(.caption).foregroundColor(Theme.secondaryText)
                Text(CapturePrivacyCopy.eventRetentionNote)
                    .font(.caption).foregroundColor(Theme.tertiaryText)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { viewModel.snapshot.retentionDays ?? 0 },
                set: { value in Task { await viewModel.setRetention(value == 0 ? nil : value) } }
            )) {
                Text("Forever").tag(0)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }.frame(width: 130)
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter "MemoryDataControlsTests|CapturePrivacyCopyTests"`
Expected: PASS.

Run: `swift build 2>&1 | grep -c warning:`
Expected: `0`. If the compiler reports a missing argument for `MemoryDeletionResult`, a third construction site exists that this task did not list — find it with `grep -rn "MemoryDeletionResult(" Sources/ Tests/` and give it a real count, never `0`.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiStore/MemoryDataControls.swift Sources/MaxMiUI/CapturePrivacyView.swift \
        Tests/MaxMiStoreTests/MemoryDataControlsTests.swift \
        Tests/MaxMiUITests/CapturePrivacyCopyTests.swift
git commit -m "Delete capture_events in the data controls and state the 30-day window"
```

---

## Task 4: Write `content_delta`, `dialog`, `navigation` and `focus` events from `AppWiring`

`finishCapture` is the only place that knows the app, the trigger, and the previous URL (spec §12 Q12), and `handleFocusChange` is the only place that sees a frontmost change before any thread exists (§12 Q4). Typing is Task 6.

**Files:**
- Modify: `Sources/MaxMiStore/CaptureEventStore.swift` (add the two event-context lookups)
- Modify: `Sources/MaxMiCapture/AXReader.swift` (add `focusedWindowTitle(pid:)`)
- Modify: `Sources/MaxMi/AppWiring.swift:1054-1092` (`handleFocusChange` — `:1112-1132` is `isActivitySynthesisEnabled`, do not edit that), `:1443-1476` (browser branch — capture the URL), `:1573-1605` (commit + event writes), and add `recordCaptureEvents` next to `recordCaptureHealth` (`:1781+`)
- Test: `Tests/MaxMiStoreTests/CaptureEventStoreTests.swift` (extend with the two lookups)

**Interfaces:**
- Consumes: `Store.recordCaptureEvent(kind:appBundle:threadID:versionID:trigger:payload:nowMs:)`, `CaptureEventKind`, `FocusEventPayload`, `NavigationEventPayload`, `DialogEventPayload.capped(_:)`, `CaptureDelta.hasRecordableChange`, `CaptureDelta.dialogBlocks`, `SafeLogEvent.captureEventWriteFailed` (Tasks 1–2); `Store.structuredOrLegacy(_:renderedContent:kind:)`, `Store.decryptOrMarker(_:)`; `AppWiring.isActivityEligible(bundleID:) -> Bool`, `AppWiring.recordCaptureHealth(app:trigger:parser:outcome:startedAtMs:)`, `CommitResult.committed(versionID:contentHash:delta:)`, `BrowserCaptureResult.url`.
- Produces:
  - `Store.threadID(sourceApp: String, sourceKey: String) throws -> String?` — nil when the thread does not exist yet. Distinct from the existing `threadID(forKey:) throws -> String`, which ignores the app and throws.
  - `Store.previousContextURL(sourceApp: String, sourceKey: String) throws -> String?` — the URL currently stored for that thread, read from `latest_contexts.structured_ciphertext`.
  - `AXReader.focusedWindowTitle(pid: pid_t) -> String?`
  - `CaptureEventDecision.kinds(for result: CommitResult, trigger: CaptureTrigger, hasBrowserURL: Bool) -> [CaptureEventKind]` — the pure rule for which events one commit warrants, so §9's "one `content_delta` per committed non-empty capture and **none** for a `.deduplicated` commit" is a unit test rather than a live observation.
  - `AppWiring.recordCaptureEvents(app:eligible:threadID:versionID:result:delta:trigger:browserURL:previousURL:nowMs:)` — private. `eligible` is the already-computed `isActivityEligible(bundleID:)` answer that `finishCapture` binds at `:1585`; the method never re-derives it, because each derivation is three `Store` reads.

- [ ] **Step 1: Write the failing lookup tests**

Append to `Tests/MaxMiStoreTests/CaptureEventStoreTests.swift`:

```swift
    func testThreadIDIsScopedToTheSourceApp() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "shared", sourceTitle: "N", content: "n"),
            nowMs: t0)
        let notes = try XCTUnwrap(store.threadID(sourceApp: "Notes", sourceKey: "shared"))
        XCTAssertEqual(notes, try store.threadID(forKey: "shared"))
        XCTAssertNil(try store.threadID(sourceApp: "Web", sourceKey: "shared"))
        XCTAssertNil(try store.threadID(sourceApp: "Notes", sourceKey: "absent"))
    }

    func testPreviousContextURLReadsTheStoredGenericPageURL() throws {
        let page = GenericPage(
            regions: [Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")])],
            focused: nil, url: "https://example.com/a")
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Web", sourceKey: "example.com/a", sourceTitle: "A", content: "",
                contentKind: .webpage, parserID: "test", parserVersion: 2,
                accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .browserNavigation, truncated: false, structured: .generic(page)),
            nowMs: t0)
        XCTAssertEqual(try store.previousContextURL(sourceApp: "Web", sourceKey: "example.com/a"),
                       "https://example.com/a")
        XCTAssertNil(try store.previousContextURL(sourceApp: "Web", sourceKey: "absent"))
    }

    func testPreviousContextURLIsNilForAShapeWithoutOne() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "N", content: "n"),
            nowMs: t0)
        XCTAssertNil(try store.previousContextURL(sourceApp: "Notes", sourceKey: "note:one"))
    }

    // MARK: - Which events a commit warrants

    func testDeduplicatedCommitWarrantsNoEvents() {
        XCTAssertTrue(CaptureEventDecision.kinds(
            for: .deduplicated, trigger: .browserNavigation, hasBrowserURL: true).isEmpty)
    }

    func testCommittedChangingCaptureWarrantsExactlyOneContentDelta() {
        let result = CommitResult.committed(
            versionID: "v1", contentHash: "h",
            delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "x")], addedChars: 1))
        let kinds = CaptureEventDecision.kinds(for: result, trigger: .periodic,
                                              hasBrowserURL: false)
        XCTAssertEqual(kinds, [.contentDelta])
        XCTAssertEqual(kinds.filter { $0 == .contentDelta }.count, 1)
    }

    /// The .tasks/.calendar trap: `isEmpty` is true, so gating on it would write nothing.
    func testCharCountOnlyDeltaStillWarrantsAContentDelta() {
        let result = CommitResult.committed(versionID: "v1", contentHash: "h",
                                           delta: CaptureDelta(addedChars: 12))
        XCTAssertEqual(CaptureEventDecision.kinds(for: result, trigger: .periodic,
                                                  hasBrowserURL: false), [.contentDelta])
    }

    func testUnchangedCommitWarrantsNoContentDelta() {
        let result = CommitResult.committed(versionID: "v1", contentHash: "h", delta: .empty)
        XCTAssertTrue(CaptureEventDecision.kinds(for: result, trigger: .periodic,
                                                 hasBrowserURL: false).isEmpty)
    }

    func testAppearingDialogAndBrowserNavigationAddTheirOwnKinds() {
        let result = CommitResult.committed(
            versionID: "v1", contentHash: "h",
            delta: CaptureDelta(addedChars: 3, dialogBlocks: [Block(type: .label, text: "OK")]))
        XCTAssertEqual(
            CaptureEventDecision.kinds(for: result, trigger: .browserNavigation,
                                       hasBrowserURL: true),
            [.contentDelta, .dialog, .navigation])
    }

    func testNavigationTriggerWithoutAURLWarrantsNoNavigationEvent() {
        let result = CommitResult.committed(versionID: "v1", contentHash: "h",
                                           delta: CaptureDelta(addedChars: 3))
        XCTAssertEqual(
            CaptureEventDecision.kinds(for: result, trigger: .browserNavigation,
                                       hasBrowserURL: false),
            [.contentDelta])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CaptureEventStoreTests/testThreadIDIsScopedToTheSourceApp|CaptureEventStoreTests/testPreviousContextURL"`
Expected: compile FAIL — neither lookup exists.

- [ ] **Step 3: Implement the two lookups**

Append to `Sources/MaxMiStore/CaptureEventStore.swift`, inside the same `extension Store`:

```swift
    // MARK: - Event context lookups

    /// The thread id for an app + clean source key, or nil when the thread does not exist yet.
    /// One indexed read on the existing `UNIQUE(source_app, source_key)`.
    ///
    /// Separate from `threadID(forKey:)`, which ignores the app and throws: an event write must
    /// not fail a capture, and two apps can legitimately share a source key.
    public func threadID(sourceApp: String, sourceKey: String) throws -> String? {
        try db.dbQueue.read { d in
            try String.fetchOne(
                d, sql: "SELECT id FROM threads WHERE source_app=? AND source_key=?",
                arguments: [sourceApp, sourceKey])
        }
    }

    /// The URL currently stored for a thread, for a `navigation` event's `fromURL`. Must be read
    /// BEFORE `commitCapture`, which overwrites the row.
    ///
    /// nil for a thread that does not exist, for a shape that has no URL, and for an unreadable
    /// payload — all of which mean "no previous URL to report", never an error.
    public func previousContextURL(sourceApp: String, sourceKey: String) throws -> String? {
        let row = try db.dbQueue.read { d in
            try Row.fetchOne(d, sql: """
                SELECT c.content_ciphertext, c.structured_ciphertext, c.content_kind
                FROM latest_contexts c JOIN threads t ON t.id = c.thread_id
                WHERE t.source_app=? AND t.source_key=?
                """, arguments: [sourceApp, sourceKey])
        }
        guard let row else { return nil }
        let kind = (row["content_kind"] as String?)
            .flatMap(CaptureContentKind.init(rawValue:)) ?? .generic
        let structured = structuredOrLegacy(
            row["structured_ciphertext"] as String?,
            renderedContent: decryptOrMarker(row["content_ciphertext"]),
            kind: kind)
        switch structured {
        case .generic(let page):    return page.url
        case .document(let value):  return value.url
        default:                    return nil
        }
    }
```

and add this to the top level of the same file, outside the extension:

```swift
/// Which events one commit warrants, in write order.
///
/// The rule lives here, not in `AppWiring`, so it is a unit test: `AppWiring` owns the app, the
/// trigger and the previous URL (spec 12 Q12), but "one `content_delta` per committed changing
/// capture and none for a `.deduplicated` commit" is a rule, and the `MaxMi` executable target has
/// no test target.
public enum CaptureEventDecision {
    public static func kinds(for result: CommitResult, trigger: CaptureTrigger,
                            hasBrowserURL: Bool) -> [CaptureEventKind] {
        // A deduplicated commit changed nothing, so there is nothing to record.
        guard case .committed(_, _, let delta) = result else { return [] }
        var kinds: [CaptureEventKind] = []
        // NOT `!delta.isEmpty`: a .tasks or .calendar delta carries no arrays, so `isEmpty` is
        // always true for those two shapes (spec 5a) and gating on it would drop every Reminders
        // and Calendar event.
        if delta.hasRecordableChange { kinds.append(.contentDelta) }
        if !delta.dialogBlocks.isEmpty { kinds.append(.dialog) }
        if trigger == .browserNavigation, hasBrowserURL { kinds.append(.navigation) }
        return kinds
    }
}
```

- [ ] **Step 4: Run the lookup tests to verify they pass**

Run: `swift test --filter CaptureEventStoreTests`
Expected: PASS, 21 tests (12 from Task 2 plus the 9 added here).

- [ ] **Step 5: Add `AXReader.focusedWindowTitle(pid:)`**

In `Sources/MaxMiCapture/AXReader.swift`, next to `focusedWindowID(pid:)`:

```swift
    /// The title of the app's currently focused window, or nil. Two AX round trips, which is why
    /// it is a separate call rather than part of `focusedWindowID`: only the focus-event path
    /// needs it, and it must not slow the capture path down.
    public static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyAttr(app, kAXFocusedWindowAttribute) as! AXUIElement?
                ?? copyAttr(app, "AXMainWindow") as! AXUIElement?
                ?? (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        let title = copyAttr(window, kAXTitleAttribute) as? String
        return title?.isEmpty == true ? nil : title
    }
```

- [ ] **Step 6: Write the `focus` event in `handleFocusChange`**

In `Sources/MaxMi/AppWiring.swift`, replace the tail of `handleFocusChange` (the `do` block that opens the visit):

```swift
        do {
            let visitID = try store.openVisit(appBundle: app.bundleID, appLabel: app.name, nowMs: nowMs)
            currentVisitID = visitID
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
            )
        }
```

with:

```swift
        do {
            let visitID = try store.openVisit(appBundle: app.bundleID, appLabel: app.name, nowMs: nowMs)
            currentVisitID = visitID
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .activity, event: .activityStateWriteFailed, error: error
            )
        }

        // A focus event has no thread and no capture attempt behind it: it fires before parsing,
        // which is exactly why capture_events.thread_id is nullable (spec 12 Q4). Recorded after
        // the visit so a failed event write never costs the visit. The window title is content,
        // so the payload is encrypted like every other one.
        do {
            try store.recordCaptureEvent(
                kind: .focus,
                appBundle: app.bundleID,
                threadID: nil,
                versionID: nil,
                trigger: .unknown,
                payload: FocusEventPayload(
                    bundleID: app.bundleID,
                    appLabel: app.name,
                    windowTitle: AXReader.focusedWindowTitle(pid: pid)
                ),
                nowMs: nowMs
            )
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .captureEventWriteFailed, error: error
            )
        }
```

Both writes sit after `guard isActivityEligible(bundleID: app.bundleID) else { return }`, which is the whole privacy gate (consent, enabled, denylist, per-app exclusion).

- [ ] **Step 7: Capture the browser URL and the previous URL in `finishCapture`**

In the browser branch, keep the resolved URL: change

```swift
            let parsed: ParsedCapture?
            var browserTruncated = false
```

to

```swift
            let parsed: ParsedCapture?
            var browserTruncated = false
            /// The URL this capture navigated TO, for a `navigation` event. Non-nil only on the
            /// browser path — a native window has no URL to report.
            var browserURL: String?
```

and inside `if let browser = ApplicationRegistry.browser(for: app.bundleID) {`, immediately after `browserTruncated = result.truncated`:

```swift
                browserTruncated = result.truncated
                browserURL = result.url
```

Then in the commit region, read the previous URL **before** committing:

```swift
            let nowMs = epochNowMs()
            // The parser reports its own budgeting; `browserTruncated` adds the one fact the
            // parser cannot see (the tab text hitting BrowserTabExtractor's cap).
            let wasTruncated = browserTruncated || parsed.truncated
            // Read BEFORE the commit overwrites latest_contexts. Only a browser navigation needs
            // it, so no other capture pays for the read.
            let previousURL: String? = trigger == .browserNavigation
                ? ((try? store.previousContextURL(sourceApp: parsed.sourceApp,
                                                  sourceKey: cleanKey)) ?? nil)
                : nil
            let envelope = parsed.envelope(
                cleanSourceKey: cleanKey,
                parserID: effectiveParserName,
                trigger: trigger,
                truncated: wasTruncated
            )
            let result = try store.commitCapture(envelope, nowMs: nowMs)
```

- [ ] **Step 8: Write the three committed-capture events**

Immediately after the existing activity-evidence block and **before** `switch result {`, add:

```swift
            // Events are derived signals, so a failed write is logged and dropped — never
            // allowed to fail the capture that produced it.
            // `eligible` is the `isActivityEligible(bundleID:)` answer already bound above at
            // `:1585` — three `Store` reads. It is passed in, never recomputed.
            if case .committed(let versionID, _, let delta) = result {
                let eventThreadID = (try? store.threadID(sourceApp: parsed.sourceApp,
                                                         sourceKey: cleanKey)) ?? nil
                recordCaptureEvents(
                    app: appInfo, eligible: eligible, threadID: eventThreadID,
                    versionID: versionID, result: result, delta: delta, trigger: trigger,
                    browserURL: browserURL, previousURL: previousURL, nowMs: nowMs
                )
            }
```

This block goes **after** `let eligible = isActivityEligible(bundleID: appInfo.bundleID)` (`:1585`)
and before `switch result {` (`:1606`), which is where the activity-evidence block already sits.

and add the method next to `recordCaptureHealth`:

```swift
    /// The `content_delta`, `dialog` and `navigation` events for one committed capture.
    /// `finishCapture` is the only site that knows the app, the trigger and the previous URL
    /// (spec 12 Q12), so this is deliberately not in the store.
    ///
    /// A `.deduplicated` commit writes nothing: nothing changed, so there is nothing to record.
    private func recordCaptureEvents(
        app: AppInfo,
        // `isActivityEligible(bundleID:)`, evaluated once by the caller. Three `Store` reads per
        // evaluation, and `finishCapture` already has the answer — so it is a parameter, not a
        // second call.
        eligible: Bool,
        threadID: String?,
        versionID: String,
        result: CommitResult,
        delta: CaptureDelta,
        trigger: CaptureTrigger,
        browserURL: String?,
        previousURL: String?,
        nowMs: EpochMs
    ) {
        guard eligible else { return }
        // The rule for WHICH events a commit warrants is tested in MaxMiStore; this method only
        // supplies the payloads for the kinds it names.
        let kinds = CaptureEventDecision.kinds(
            for: result, trigger: trigger, hasBrowserURL: browserURL != nil)
        guard !kinds.isEmpty else { return }
        do {
            for kind in kinds {
                switch kind {
                case .contentDelta:
                    try store.recordCaptureEvent(
                        kind: .contentDelta, appBundle: app.bundleID, threadID: threadID,
                        versionID: versionID, trigger: trigger, payload: delta, nowMs: nowMs
                    )
                case .dialog:
                    // Non-empty only when a `.dialog` region appeared that the previous capture
                    // did not have — the comparison happens in `CaptureDelta.between`, the one
                    // place that sees both sides.
                    try store.recordCaptureEvent(
                        kind: .dialog, appBundle: app.bundleID, threadID: threadID,
                        versionID: versionID, trigger: trigger,
                        payload: DialogEventPayload(
                            blocks: DialogEventPayload.capped(delta.dialogBlocks)),
                        nowMs: nowMs
                    )
                case .navigation:
                    // `kinds` only contains `.navigation` when `browserURL != nil`, so the
                    // force-unwrap-free fallback below is unreachable; it is written as a `guard`
                    // rather than a `!` so a future change to the rule cannot crash a capture.
                    guard let toURL = browserURL else { continue }
                    try store.recordCaptureEvent(
                        kind: .navigation, appBundle: app.bundleID, threadID: threadID,
                        versionID: versionID, trigger: trigger,
                        payload: NavigationEventPayload(fromURL: previousURL, toURL: toURL),
                        nowMs: nowMs
                    )
                case .focus, .typing:
                    // Written by `handleFocusChange` and `recordTypingEvent`, not by a commit.
                    continue
                }
            }
        } catch {
            SafeLogger.shared.log(
                .error, subsystem: .capture, event: .captureEventWriteFailed, error: error
            )
        }
    }
```

- [ ] **Step 9: Build and run the suite**

Run: `swift build 2>&1 | grep -E "error:|warning:"`
Expected: no output.

Run: `swift test 2>&1 | tail -20`
Expected: exactly the 3 known-red failures. No `MaxMi` executable target tests exist in `Package.swift`, so `AppWiring` has no unit coverage — Task 9's live verification is what proves these four writers, and Task 8's timeline tests exercise the read side.

- [ ] **Step 10: Commit**

```bash
git add Sources/MaxMiStore/CaptureEventStore.swift Sources/MaxMiCapture/AXReader.swift \
        Sources/MaxMi/AppWiring.swift Tests/MaxMiStoreTests/CaptureEventStoreTests.swift
git commit -m "Record focus, navigation, content delta and dialog capture events"
```

---

## Task 5: `TypingDiff` and the `TypingObserver` actor

The pure part of typing capture: the diff, the two per-key time gates (one before the AX read, one before the emitted event), the LRU, and the privacy guards. Nothing is wired to AX yet — Task 6 does that — so this task is judged entirely on unit tests.

**Files:**
- Create: `Sources/MaxMiCapture/TypingObserver.swift` (`FocusedFieldKey`, `TypingPollGate`, `TypingDiff`, `TypingObserver`, `FocusedElement(node:)`)
- Test: `Tests/MaxMiCaptureTests/TypingObserverTests.swift` (create)

**Interfaces:**
- Consumes: `TypingEvent(insertedText:fieldRole:fieldIdentifier:totalLength:replaced:)` (Task 2), `FocusedElement(role:identifier:value:selectedText:isSecure:)` and `AXNode` (both merged in Phase A), `Denylist.isSensitiveApp(_:) -> Bool`, `AppInfo(bundleID:name:windowTitle:windowID:)`, `GenericPageExtractor.secureSubrole` (internal `static let`, same module), `EpochMs`.
- Produces:
  - `FocusedFieldKey: Hashable, Sendable` with `bundleID: String`, `window: String?`, `role: String`, `identifier: String?`; `init(bundleID:windowID:windowTitle:role:identifier:)`, which **collapses the two window inputs into one discriminator** — `"id:<CGWindowID>"` when a window id is known, else `"title:<window title>"`, else nil; and `init(app: AppInfo, focused: FocusedElement)`.
  - `TypingPollGate` (`init()`, `static let intervalMs: EpochMs`, `static let staleAfterMs: EpochMs`, `enum Decision { case read, schedule(afterMs: EpochMs), alreadyScheduled }`, `mutating func admit(key: String, nowMs: EpochMs) -> Decision`, `mutating func completeScheduled(key: String, nowMs: EpochMs)`, `var trackedKeyCount: Int`).
  - `TypingDiff.Change(insertedText: String, replaced: Bool)` and `TypingDiff.diff(old: String, new: String, maxReplacedTailChars: Int) -> Change?`.
  - `TypingObserver` actor: `static let debounceMs: EpochMs = 800`, `static let maxTrackedFields = 32`, `static let maxReplacedTailChars = 500`; `init(isEligible: @escaping @Sendable (String) -> Bool)`; `func observe(_ focused: FocusedElement, key: FocusedFieldKey, nowMs: EpochMs) -> TypingEvent?`; `var trackedFieldCount: Int`.
  - `extension FocusedElement { init(node: AXNode) }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MaxMiCaptureTests/TypingObserverTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture
import MaxMiCore

final class TypingObserverTests: XCTestCase {
    private let t0 = EpochMs(1_800_000_000_000)

    private func key(_ bundleID: String = "com.example.chat",
                     windowID: UInt32? = 42,
                     identifier: String? = "composer") -> FocusedFieldKey {
        FocusedFieldKey(bundleID: bundleID, windowID: windowID, windowTitle: nil,
                        role: "AXTextArea", identifier: identifier)
    }

    private func field(_ value: String?, isSecure: Bool = false) -> FocusedElement {
        FocusedElement(role: "AXTextArea", identifier: "composer", value: value,
                       selectedText: nil, isSecure: isSecure)
    }

    private func observer(eligible: Bool = true) -> TypingObserver {
        TypingObserver(isEligible: { _ in eligible })
    }

    // MARK: - TypingDiff

    func testPureAppendIsAnInsertion() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "hello", new: "hello world",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, " world")
        XCTAssertFalse(change.replaced)
    }

    func testSingleMidStringInsertionIsAnInsertion() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "ship it", new: "ship all of it",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, "all of ")
        XCTAssertFalse(change.replaced)
    }

    func testPasteOverASelectionIsAReplacementCarryingTheTail() throws {
        let old = "draft text"
        let new = String(repeating: "p", count: 900)
        let change = try XCTUnwrap(TypingDiff.diff(old: old, new: new, maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText.count, 500)
        XCTAssertEqual(change.insertedText, String(new.suffix(500)))
    }

    func testClearingTheFieldIsAReplacementWithAnEmptyTail() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "abc", new: "", maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText, "")
    }

    func testBackspaceIsAReplacement() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "hello", new: "hell",
                                                   maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText, "hell")
    }

    func testIdenticalValuesProduceNoChange() {
        XCTAssertNil(TypingDiff.diff(old: "same", new: "same", maxReplacedTailChars: 500))
        XCTAssertNil(TypingDiff.diff(old: "", new: "", maxReplacedTailChars: 500))
    }

    func testRepeatedCharactersDoNotOverlapPrefixAndSuffix() throws {
        // Naive prefix+suffix counting would claim 3+3 of a 4-character string.
        let change = try XCTUnwrap(TypingDiff.diff(old: "aaa", new: "aaaa",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, "a")
        XCTAssertFalse(change.replaced)
    }

    // MARK: - TypingObserver

    func testFirstSightingEstablishesTheBaselineAndEmitsNothing() async {
        let observer = observer()
        XCTAssertNil(await observer.observe(field("hello"), key: key(), nowMs: t0))
    }

    func testSecondSightingEmitsTheInsertion() async throws {
        let observer = observer()
        _ = await observer.observe(field("hello"), key: key(), nowMs: t0)
        let event = try XCTUnwrap(
            await observer.observe(field("hello world"), key: key(), nowMs: t0 + 1_000))
        XCTAssertEqual(event.insertedText, " world")
        XCTAssertEqual(event.fieldRole, "AXTextArea")
        XCTAssertEqual(event.fieldIdentifier, "composer")
        XCTAssertEqual(event.totalLength, 11)
        XCTAssertFalse(event.replaced)
    }

    func testIdenticalValueEmitsNothing() async {
        let observer = observer()
        _ = await observer.observe(field("hello"), key: key(), nowMs: t0)
        XCTAssertNil(await observer.observe(field("hello"), key: key(), nowMs: t0 + 1_000))
    }

    func testDebounceSuppressesASecondEventInsideTheWindow() async {
        let observer = observer()
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        XCTAssertNotNil(await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000))
        XCTAssertNil(await observer.observe(field("abc"), key: key(), nowMs: t0 + 1_100))
    }

    /// The suppressed characters are not lost: the baseline is not advanced inside the window, so
    /// the next accepted call reports the whole burst.
    func testSuppressedCharactersAppearInTheNextAcceptedEvent() async throws {
        let observer = observer()
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        _ = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        _ = await observer.observe(field("abc"), key: key(), nowMs: t0 + 1_100)
        let event = try XCTUnwrap(
            await observer.observe(field("abcd"), key: key(), nowMs: t0 + 2_000))
        XCTAssertEqual(event.insertedText, "cd")
    }

    func testDebounceIsPerKey() async {
        let observer = observer()
        let other = key(windowID: 43)
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        _ = await observer.observe(field("a"), key: other, nowMs: t0)
        XCTAssertNotNil(await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000))
        XCTAssertNotNil(await observer.observe(field("ab"), key: other, nowMs: t0 + 1_010))
    }

    func testSecureFieldNeverEmits() async {
        let observer = observer()
        _ = await observer.observe(field("hunter", isSecure: true), key: key(), nowMs: t0)
        XCTAssertNil(await observer.observe(field("hunter2", isSecure: true), key: key(),
                                           nowMs: t0 + 1_000))
    }

    func testSensitiveAppNeverEmits() async {
        let observer = observer()
        let sensitive = key("com.apple.systempreferences")
        _ = await observer.observe(field("a"), key: sensitive, nowMs: t0)
        XCTAssertNil(await observer.observe(field("ab"), key: sensitive, nowMs: t0 + 1_000))
    }

    /// Consent and per-app exclusion reach the observer as the injected predicate: `AppWiring`
    /// composes them in `isActivityEligible`.
    func testIneligibleAppNeverEmits() async {
        let observer = observer(eligible: false)
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        XCTAssertNil(await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000))
    }

    func testLRUEvictsBeyondThirtyTwoFields() async {
        let observer = observer()
        for index in 0..<(TypingObserver.maxTrackedFields + 8) {
            _ = await observer.observe(field("v\(index)"), key: key(windowID: UInt32(index)),
                                      nowMs: t0 + EpochMs(index))
        }
        XCTAssertEqual(await observer.trackedFieldCount, TypingObserver.maxTrackedFields)
        // The oldest key was evicted, so it is a first sighting again.
        XCTAssertNil(await observer.observe(field("v0 changed"), key: key(windowID: 0),
                                           nowMs: t0 + 10_000))
    }

    // MARK: - Key identity

    /// One window discriminator, not two fields: the id when the app exposes one, otherwise the
    /// title. An id and a title for the same window therefore collapse to the same key.
    func testWindowIDWinsOverTheTitle() {
        let withTitle = FocusedFieldKey(bundleID: "b", windowID: 7, windowTitle: "Draft",
                                        role: "AXTextArea", identifier: nil)
        let withoutTitle = FocusedFieldKey(bundleID: "b", windowID: 7, windowTitle: nil,
                                           role: "AXTextArea", identifier: nil)
        XCTAssertEqual(withTitle, withoutTitle)
        XCTAssertEqual(withTitle.window, "id:7")
    }

    func testWindowTitleDistinguishesKeysWhenNoWindowIDIsKnown() {
        let a = FocusedFieldKey(bundleID: "b", windowID: nil, windowTitle: "One",
                                role: "AXTextArea", identifier: nil)
        let b = FocusedFieldKey(bundleID: "b", windowID: nil, windowTitle: "Two",
                                role: "AXTextArea", identifier: nil)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.window, "title:One")
    }

    /// The bug this shape exists to prevent. `AXReader.focusedWindowID(pid:)` returns nil for any
    /// app whose focused window exposes no `CGWindowID`. The capture path passes a real window
    /// title; if the AX-notification path passed nil, the two paths would mint DIFFERENT keys for
    /// the same field, every notification would be a first sighting, and no typing event would
    /// ever be emitted for that app. Both paths pass the same `(windowID, windowTitle)` pair, so
    /// the keys agree — and the last assertion shows the failure mode is loud, not silent.
    func testBothWritePathsMintTheSameKeyWhenNoWindowIDIsAvailable() {
        let captureSide = FocusedFieldKey(
            app: AppInfo(bundleID: "com.example.chat", name: "Chat", windowTitle: "General",
                         windowID: nil),
            focused: field("x"))
        let pollSide = FocusedFieldKey(bundleID: "com.example.chat", windowID: nil,
                                       windowTitle: "General", role: "AXTextArea",
                                       identifier: "composer")
        XCTAssertEqual(captureSide, pollSide)
        XCTAssertEqual(captureSide.window, "title:General")
        XCTAssertNotEqual(
            captureSide,
            FocusedFieldKey(bundleID: "com.example.chat", windowID: nil, windowTitle: nil,
                            role: "AXTextArea", identifier: "composer"),
            "a poll path that forgot the title must not silently agree")
    }

    // MARK: - TypingPollGate

    func testPollGateAdmitsTheFirstNotificationForAKey() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0), .read)
    }

    /// Progress bars, clocks and live regions all fire `kAXValueChangedNotification`, so a burst
    /// is the normal case. It must cost ONE AX read, taken at the end.
    func testPollGateCoalescesABurstIntoOneTrailingRead() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 100),
                       .schedule(afterMs: TypingPollGate.intervalMs - 100))
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 200), .alreadyScheduled)
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 700), .alreadyScheduled)

        gate.completeScheduled(key: "com.example.chat", nowMs: t0 + TypingPollGate.intervalMs)
        XCTAssertEqual(
            gate.admit(key: "com.example.chat", nowMs: t0 + TypingPollGate.intervalMs + 1),
            .schedule(afterMs: TypingPollGate.intervalMs - 1),
            "the trailing read reset the window, so the next burst schedules again")
    }

    func testPollGateIsPerKeyAndReopensAfterTheInterval() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "b", nowMs: t0), .read, "a different app is not gated")
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0 + TypingPollGate.intervalMs), .read)
    }

    func testPollGateForgetsKeysItHasNotSeenRecently() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "b", nowMs: t0 + TypingPollGate.staleAfterMs + 1), .read)
        XCTAssertEqual(gate.trackedKeyCount, 1, "the stale key is forgotten, so the map is bounded")
    }

    func testKeyFromAppInfoAndFocusedElement() {
        let app = AppInfo(bundleID: "com.example.chat", name: "Chat", windowTitle: "General",
                          windowID: 9)
        let built = FocusedFieldKey(app: app, focused: field("x"))
        XCTAssertEqual(built, FocusedFieldKey(bundleID: "com.example.chat", windowID: 9,
                                              windowTitle: nil, role: "AXTextArea",
                                              identifier: "composer"))
    }

    func testFocusedElementFromAXNodeMasksASecureField() {
        let secure = AXNode(role: "AXTextField", value: nil, title: nil, url: nil, frame: nil,
                            focused: true, children: [], identifier: "password",
                            subrole: "AXSecureTextField")
        let element = FocusedElement(node: secure)
        XCTAssertTrue(element.isSecure)
        XCTAssertNil(element.value)
        XCTAssertNil(element.selectedText)

        let plain = AXNode(role: "AXTextArea", value: "hello", title: nil, url: nil, frame: nil,
                           focused: true, children: [], identifier: "composer",
                           selectedText: "he")
        let plainElement = FocusedElement(node: plain)
        XCTAssertFalse(plainElement.isSecure)
        XCTAssertEqual(plainElement.value, "hello")
        XCTAssertEqual(plainElement.selectedText, "he")
    }

    // MARK: - Exit criterion 5

    /// Spec 11 criterion 5, grep-asserted: typing must never come from an event tap.
    func testNoEventTapAnywhereInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let banned = ["CGEvent.tapCreate", "CGEventTapCreate", "addGlobalMonitorForEvents",
                      "IOHIDManager"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(root.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned {
                XCTAssertFalse(text.contains(token), "\(token) found in \(file.lastPathComponent)")
            }
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter TypingObserverTests`
Expected: compile FAIL — `FocusedFieldKey`, `TypingDiff`, `TypingPollGate` and `TypingObserver` do not exist.

- [ ] **Step 3: Implement the file**

Create `Sources/MaxMiCapture/TypingObserver.swift`:

```swift
import Foundation
import MaxMiCore

/// Identity of one text field across captures: bundle id + one window discriminator + role +
/// identifier.
///
/// The window is ONE stored field, not a `windowID`/`windowTitle` pair, because there are two
/// write paths (the capture path and the AX-notification path) and both must arrive at the same
/// key or nothing is ever emitted. `AXReader.focusedWindowID(pid:)` returns nil for any focused
/// window that exposes no `CGWindowID`, so the id alone is not enough and the title alone is not
/// stable — the rule is "the id when there is one, otherwise the title". Both paths therefore pass
/// the SAME `(windowID, windowTitle)` pair and let this initializer decide; neither path is allowed
/// to pass `windowTitle: nil` as a shortcut.
public struct FocusedFieldKey: Hashable, Sendable {
    public let bundleID: String
    /// `"id:<CGWindowID>"`, else `"title:<window title>"`, else nil. Prefixed so an app that names
    /// a window `"7"` cannot collide with window id 7.
    public let window: String?
    public let role: String
    public let identifier: String?

    public init(bundleID: String, windowID: UInt32?, windowTitle: String?,
                role: String, identifier: String?) {
        self.bundleID = bundleID
        if let windowID {
            self.window = "id:\(windowID)"
        } else if let windowTitle, !windowTitle.isEmpty {
            self.window = "title:\(windowTitle)"
        } else {
            self.window = nil
        }
        self.role = role
        self.identifier = identifier
    }

    /// `AppInfo` carries both inputs — `AppWiring` builds it with the AXReader window title and
    /// `AXReader.focusedWindowID(pid:)` — so the capture path has nothing to resolve itself.
    public init(app: AppInfo, focused: FocusedElement) {
        self.init(bundleID: app.bundleID, windowID: app.windowID, windowTitle: app.windowTitle,
                  role: focused.role, identifier: focused.identifier)
    }
}

/// Pre-read time gate for `kAXValueChangedNotification`, keyed per app.
///
/// `FocusObserver.onAXNotification` fires for EVERY notification the app-level `AXObserver`
/// delivers, and it fires *ahead of* `FocusObserver`'s own capture debounce. Progress bars, clocks
/// and live regions all emit value changes. Without this gate each one would run a full
/// `AXReader.focusedElementSnapshot(pid:)` on the main actor — an `AXManualAccessibility` write, a
/// `kAXFocusedUIElementAttribute` read and up to 64 node conversions, several AX round trips each.
/// `TypingObserver.debounceMs` cannot help: it suppresses the emitted EVENT, and the read has
/// already happened by then.
///
/// A value type driven entirely by an injected `nowMs`, so every branch is a unit test with no
/// clock and no sleeping. `AppWiring` owns one on the main actor.
public struct TypingPollGate: Sendable {
    /// The same 800 ms as the emit debounce: a read that could not produce an event is wasted work.
    public static let intervalMs: EpochMs = TypingObserver.debounceMs
    /// A key unseen for this long is forgotten, so the map is bounded by *recently* active apps
    /// rather than by every app ever focused.
    public static let staleAfterMs: EpochMs = 60_000

    public enum Decision: Equatable, Sendable {
        /// Read now.
        case read
        /// Too soon. Read once after this delay — the burst is coalesced into a single TRAILING
        /// read, so the last value of the burst is still seen rather than dropped.
        case schedule(afterMs: EpochMs)
        /// Too soon, and a trailing read for this key is already pending. Do nothing.
        case alreadyScheduled
    }

    private var lastReadAtMs: [String: EpochMs] = [:]
    private var pending: Set<String> = []

    public init() {}

    public var trackedKeyCount: Int { lastReadAtMs.count }

    public mutating func admit(key: String, nowMs: EpochMs) -> Decision {
        lastReadAtMs = lastReadAtMs.filter { nowMs - $0.value < Self.staleAfterMs }
        guard let last = lastReadAtMs[key] else {
            lastReadAtMs[key] = nowMs
            return .read
        }
        let elapsed = nowMs - last
        guard elapsed < Self.intervalMs else {
            lastReadAtMs[key] = nowMs
            pending.remove(key)
            return .read
        }
        guard !pending.contains(key) else { return .alreadyScheduled }
        pending.insert(key)
        return .schedule(afterMs: Self.intervalMs - elapsed)
    }

    /// Called when a scheduled trailing read actually runs, so the window restarts from the read
    /// rather than from the notification that asked for it.
    public mutating func completeScheduled(key: String, nowMs: EpochMs) {
        pending.remove(key)
        lastReadAtMs[key] = nowMs
    }
}

/// The pure diff. No library, no dependency on the actor, so every branch is a unit test.
public enum TypingDiff {
    public struct Change: Sendable, Equatable {
        public let insertedText: String
        public let replaced: Bool

        public init(insertedText: String, replaced: Bool) {
            self.insertedText = insertedText
            self.replaced = replaced
        }
    }

    /// Common-prefix / common-suffix diff, with the suffix capped so prefix + suffix can never
    /// exceed the shorter string (otherwise "aaa" -> "aaaa" would claim six of four characters).
    ///
    /// - a pure insertion (including a plain append, where the common suffix is empty) reports
    ///   the inserted run with `replaced == false`
    /// - anything that also removed characters — paste over a selection, backspace, select-all
    ///   and retype, clear — reports `replaced == true` carrying the new value's trailing
    ///   `maxReplacedTailChars` characters, because there is no single "inserted run" to name
    /// - equal values report nil
    public static func diff(old: String, new: String, maxReplacedTailChars: Int) -> Change? {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(oldChars.count, newChars.count) - prefix
        while suffix < maxSuffix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let inserted = String(newChars[prefix..<(newChars.count - suffix)])
        let removed = String(oldChars[prefix..<(oldChars.count - suffix)])
        if removed.isEmpty {
            return inserted.isEmpty ? nil : Change(insertedText: inserted, replaced: false)
        }
        return Change(insertedText: String(newChars.suffix(max(0, maxReplacedTailChars))),
                      replaced: true)
    }
}

/// Tracks the value of focused text fields and reports meaningful changes.
///
/// **No `CGEventTap`. No global event monitor.** The only input is the accessibility value of the
/// focused element, which the caller reads from the capture it already took or from
/// `AXReader.focusedElementSnapshot(pid:)`.
///
/// Nothing is persisted: the LRU is in-actor memory and is gone on quit.
public actor TypingObserver {
    public static let debounceMs: EpochMs = 800
    public static let maxTrackedFields = 32
    public static let maxReplacedTailChars = 500

    struct Tracked {
        var value: String
        var lastEmittedAtMs: EpochMs?
    }

    /// Consent and per-app exclusion, injected because they are `throws` reads on a non-`Sendable`
    /// `Store`: `AppWiring` composes them in `isActivityEligible` and passes the denylist check
    /// here (spec 5c gates, plan Ruling 5).
    private let isEligible: @Sendable (String) -> Bool
    private var tracked: [FocusedFieldKey: Tracked] = [:]
    /// Least-recently-touched first.
    private var order: [FocusedFieldKey] = []

    public init(isEligible: @escaping @Sendable (String) -> Bool) {
        self.isEligible = isEligible
    }

    public var trackedFieldCount: Int { order.count }

    /// An event when the focused field's value changed meaningfully, else nil.
    ///
    /// The FIRST sighting of a field never emits: its current value is a baseline, not something
    /// the user just typed in front of us.
    public func observe(_ focused: FocusedElement, key: FocusedFieldKey,
                        nowMs: EpochMs) -> TypingEvent? {
        // A secure field has no value to diff — Phase A never read it. Checked first so the
        // field is not even tracked.
        guard !focused.isSecure,
              !Denylist.isSensitiveApp(key.bundleID),
              isEligible(key.bundleID) else { return nil }
        let value = focused.value ?? ""
        guard let existing = touch(key, value: value) else { return nil }
        guard existing.value != value else { return nil }
        if let last = existing.lastEmittedAtMs, nowMs - last < Self.debounceMs {
            // Suppressed — and the baseline is deliberately NOT advanced, so the characters typed
            // inside the window are reported by the next accepted call rather than lost.
            return nil
        }
        guard let change = TypingDiff.diff(old: existing.value, new: value,
                                           maxReplacedTailChars: Self.maxReplacedTailChars) else {
            tracked[key]?.value = value
            return nil
        }
        tracked[key] = Tracked(value: value, lastEmittedAtMs: nowMs)
        return TypingEvent(
            insertedText: change.insertedText,
            fieldRole: focused.role,
            fieldIdentifier: focused.identifier,
            totalLength: value.count,
            replaced: change.replaced
        )
    }

    /// Marks `key` most-recently-used and returns its previous state, or nil when this is the
    /// first sighting (whose value becomes the baseline).
    private func touch(_ key: FocusedFieldKey, value: String) -> Tracked? {
        order.removeAll { $0 == key }
        order.append(key)
        if let existing = tracked[key] { return existing }
        tracked[key] = Tracked(value: value, lastEmittedAtMs: nil)
        evictIfNeeded()
        return nil
    }

    private func evictIfNeeded() {
        while order.count > Self.maxTrackedFields {
            let evicted = order.removeFirst()
            tracked[evicted] = nil
        }
    }
}

extension FocusedElement {
    /// The focused `AXNode` as the typed shape. A secure field's `value` and `selectedText` are
    /// already nil in `AXNode` — `AXReader.convert` never reads them — and `FocusedElement.init`
    /// nils them again, so there is no path by which a secret reaches this type.
    public init(node: AXNode) {
        self.init(
            role: node.role,
            identifier: node.identifier,
            value: node.value,
            selectedText: node.selectedText,
            isSecure: node.subrole == GenericPageExtractor.secureSubrole
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TypingObserverTests`
Expected: PASS, 27 tests.

If `testNoEventTapAnywhereInSources` fails, something in `Sources/` already uses one of the banned APIs — do **not** relax the test. Report it: it is a spec violation that predates this plan.

- [ ] **Step 5: Commit**

```bash
git add Sources/MaxMiCapture/TypingObserver.swift Tests/MaxMiCaptureTests/TypingObserverTests.swift
git commit -m "Add TypingDiff and the TypingObserver actor"
```

---

## Task 6: Wire typing into AX notifications, the capture path, and structured content

Three deliverables that only make sense together: the observer needs an input, the `typing` event needs a writer, and the typed text has to reach the next capture's structured content so a summary can see it.

**Files:**
- Create: `Sources/MaxMiCapture/ComposerDraft.swift`
- Create: `Tests/MaxMiCaptureTests/ComposerDraftTests.swift`
- Create: `Tests/MaxMiCaptureTests/Fixtures/slack-composer-draft.json`
- Modify: `Tests/MaxMiCaptureTests/Fixtures/README.md` (one table row)
- Modify: `Sources/MaxMiCapture/FocusObserver.swift:103` (add `onAXNotification`), `:273-288` (`handleAXNotification`)
- Modify: `Sources/MaxMiCapture/GenericPageExtractor.swift:131-133` (mark the focused input's block)
- Modify: `Sources/MaxMiCapture/SlackParser.swift:12-23`
- Modify: `Sources/MaxMiCapture/NativeConversationParser.swift:128-144`
- Modify: `Sources/MaxMiCapture/WebAppCaptureParser.swift:63-90`
- Modify: `Sources/MaxMi/AppWiring.swift` (`typingObserver` + `typingPollGate` + `typingThreadIDs` properties, observer construction ~`:983-1007`, `finishCapture` event block, new `handleValueChangeNotification` + `pollFocusedFieldTyping` + `recordTypingEvent`, and the `:1175-1176` shutdown)
- Test: `Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift` (extend)

**Interfaces:**
- Consumes: `TypingObserver`, `TypingPollGate`, `FocusedFieldKey(app:focused:)`, `FocusedElement(node:)` (Task 5); `Store.recordCaptureEvent(kind:appBundle:threadID:versionID:trigger:payload:nowMs:)`, `CaptureEventKind.typing` (Task 2); `AXReader.focusedElementSnapshot(pid:) -> AXNode?`, `AXReader.focusedWindowID(pid:) -> UInt32?` (Phase A), `AXReader.focusedWindowTitle(pid:) -> String?` (Task 4), `GenericPageExtractor.listContainerRoles`; `AppWiring.isActivityEligible(bundleID:)`; `Message(id:sender:text:timestamp:timeString:isUser:isDraft:)`; `Block(type:text:authoredByUser:)`; `CaptureAccumulator.boundHard(_:to:)`; `GenericPageExtractor.menuRoles`, `.secureSubrole`, `.inputRoles`.
- Produces:
  - `ComposerDraft.draft(window: AXNode) -> Message?` — the focused composer's value as a `Message(id: "draft:<identifier or role>", sender: "You", isUser: true, isDraft: true)`, or nil.
  - `ComposerDraft.messageListContainerRoles: Set<String>` — `GenericPageExtractor.listContainerRoles` plus `"AXTable"`; the ancestor roles that disqualify a focused field from being the composer.
  - `FocusObserver.onAXNotification: (@MainActor (_ isValueChange: Bool, _ bundleID: String, _ pid: pid_t) -> Void)?`
  - `AppWiring.handleValueChangeNotification(bundleID:pid:)`, `AppWiring.pollFocusedFieldTyping(bundleID:pid:)` and `AppWiring.recordTypingEvent(app:focused:trigger:threadID:versionID:)` — all private.
  - `Block.authoredByUser == true` on the block produced by the focused, non-secure input node.

- [ ] **Step 1: Write the failing composer-draft and authorship tests**

Create `Tests/MaxMiCaptureTests/Fixtures/slack-composer-draft.json` — a Slack-shaped window at a nonzero origin with two message rows and a focused composer below them. All content is invented:

```json
{
  "role": "AXWindow",
  "title": "general - Invented Workspace - Slack",
  "focused": false,
  "frame": { "x": 320, "y": 140, "width": 1100, "height": 800 },
  "children": [
    {
      "role": "AXList",
      "identifier": "message-list",
      "focused": false,
      "frame": { "x": 620, "y": 200, "width": 780, "height": 480 },
      "children": [
        {
          "role": "AXRow",
          "focused": false,
          "frame": { "x": 620, "y": 220, "width": 780, "height": 40 },
          "children": [
            { "role": "AXStaticText", "value": "Ana Invented", "focused": false,
              "frame": { "x": 620, "y": 220, "width": 120, "height": 18 }, "children": [] },
            { "role": "AXStaticText", "value": "the budget test is green", "focused": false,
              "frame": { "x": 620, "y": 240, "width": 400, "height": 18 }, "children": [] }
          ]
        },
        {
          "role": "AXRow",
          "focused": false,
          "frame": { "x": 620, "y": 280, "width": 780, "height": 40 },
          "children": [
            { "role": "AXStaticText", "value": "Bo Invented", "focused": false,
              "frame": { "x": 620, "y": 280, "width": 120, "height": 18 }, "children": [] },
            { "role": "AXStaticText", "value": "merging after review", "focused": false,
              "frame": { "x": 620, "y": 300, "width": 400, "height": 18 }, "children": [] }
          ]
        },
        {
          "role": "AXRow",
          "focused": false,
          "frame": { "x": 620, "y": 340, "width": 780, "height": 40 },
          "children": [
            { "role": "AXTextArea", "identifier": "editing-bubble",
              "value": "an edited bubble, not the composer", "focused": true,
              "frame": { "x": 620, "y": 340, "width": 400, "height": 18 }, "children": [] }
          ]
        }
      ]
    },
    {
      "role": "AXTextArea",
      "identifier": "message-input",
      "placeholder": "Message #general",
      "value": "shipping phase b today",
      "focused": true,
      "frame": { "x": 620, "y": 700, "width": 780, "height": 60 },
      "children": []
    }
  ]
}
```

Add to `Tests/MaxMiCaptureTests/Fixtures/README.md`'s table:

```
| `slack-composer-draft.json` | Hand-authored Slack-shaped window at a nonzero origin with a focused composer, plus a second focused text area inside the message `AXList` | `ComposerDraft` picking the composer, not the list descendant |
```

Create `Tests/MaxMiCaptureTests/ComposerDraftTests.swift`:

```swift
import XCTest
@testable import MaxMiCapture
import MaxMiCore

final class ComposerDraftTests: XCTestCase {
    /// Same loader shape as `GenericPageBudgetTests.fixture`.
    private func fixture(_ name: String) throws -> AXNode {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    private func node(role: String, value: String?, identifier: String? = nil,
                      focused: Bool = false, subrole: String? = nil,
                      children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil, frame: nil, focused: focused,
               children: children, identifier: identifier, subrole: subrole)
    }

    func testPicksTheComposerAndNotTheFocusedRowTextArea() throws {
        let draft = try XCTUnwrap(ComposerDraft.draft(window: try fixture("slack-composer-draft")))
        XCTAssertEqual(draft.text, "shipping phase b today")
        XCTAssertEqual(draft.id, "draft:message-input")
        XCTAssertEqual(draft.sender, "You")
        XCTAssertTrue(draft.isUser)
        XCTAssertTrue(draft.isDraft)
        XCTAssertNil(draft.timestamp)
    }

    func testNoDraftWhenNothingIsFocused() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "not focused", identifier: "message-input"),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForAnEmptyComposer() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "   ", identifier: "message-input", focused: true),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForASecureField() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextField", value: "hunter2", identifier: "password", focused: true,
                 subrole: GenericPageExtractor.secureSubrole),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testNoDraftForAFocusedFieldInsideAMessageListRow() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXList", value: nil, identifier: "message-list", children: [
                node(role: "AXRow", value: nil, children: [
                    node(role: "AXTextArea", value: "an edited bubble", identifier: "bubble",
                         focused: true),
                ]),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    /// The case the old rows/cells rule missed. Spec 5c disqualifies any descendant of the
    /// MESSAGE-LIST node, and plenty of chat surfaces parent an editable bubble directly to the
    /// list with no row wrapper — Electron re-renders in particular. Under a rows/cells-only test
    /// that field is read as the user's draft and attributed to `You`.
    func testNoDraftForAFocusedFieldParentedDirectlyByTheMessageList() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXList", value: nil, identifier: "message-list", children: [
                node(role: "AXTextArea", value: "somebody else's message, being edited",
                     identifier: "bubble", focused: true),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    /// A focused row OUTSIDE any list, table or outline is not a message list, so it is not
    /// disqualified — the rule is about the container, not about rows.
    func testAFocusedFieldInABareRowIsStillTheComposer() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXRow", value: nil, children: [
                node(role: "AXTextArea", value: "typed into a toolbar row", identifier: "input",
                     focused: true),
            ]),
        ])
        XCTAssertEqual(ComposerDraft.draft(window: window)?.text, "typed into a toolbar row")
    }

    func testMenuSubtreesAreNotSearched() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXMenu", value: nil, children: [
                node(role: "AXTextField", value: "spotlight query", focused: true),
            ]),
        ])
        XCTAssertNil(ComposerDraft.draft(window: window))
    }

    func testIdentifierFallsBackToTheRole() {
        let window = node(role: "AXWindow", value: nil, children: [
            node(role: "AXTextArea", value: "typed", focused: true),
        ])
        XCTAssertEqual(ComposerDraft.draft(window: window)?.id, "draft:AXTextArea")
    }

    func testSlackParserAppendsTheDraftAsTheLastMessage() throws {
        let app = AppInfo(bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
                          windowTitle: "general - Invented Workspace - Slack")
        let content = try XCTUnwrap(
            SlackParser().parseStructured(window: try fixture("slack-composer-draft"), app: app))
        guard case .conversation(let conversation) = content else {
            return XCTFail("expected a conversation")
        }
        let last = try XCTUnwrap(conversation.messages.last)
        XCTAssertTrue(last.isDraft)
        XCTAssertEqual(last.text, "shipping phase b today")
        XCTAssertEqual(conversation.messages.filter(\.isDraft).count, 1)
        XCTAssertTrue(ContentRenderer.render(content, style: .full).contains("(draft)"))
    }
}
```

Append to `Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift`:

```swift
    /// The block the user is typing into is marked, so the next capture's summary can say the
    /// user wrote it rather than that the page contains it.
    func testFocusedInputBlockIsMarkedAuthoredByUser() {
        let window = AXNode(
            role: "AXWindow", value: nil, title: "Note", url: nil,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), focused: false,
            children: [
                AXNode(role: "AXStaticText", value: "existing paragraph", title: nil, url: nil,
                       frame: CGRect(x: 0, y: 0, width: 400, height: 18), focused: false,
                       children: []),
                AXNode(role: "AXTextArea", value: "the line I am writing", title: nil, url: nil,
                       frame: CGRect(x: 0, y: 30, width: 400, height: 18), focused: true,
                       children: [], identifier: "body"),
            ])
        let page = GenericPageExtractor.extract(window: window, focusedElement: nil, url: nil).page
        let blocks = page.regions.flatMap(\.blocks)
        XCTAssertEqual(blocks.filter(\.authoredByUser).map(\.text), ["the line I am writing"])
        XCTAssertFalse(try! XCTUnwrap(blocks.first).authoredByUser)
    }

    func testFocusedSecureFieldIsNotMarkedAuthoredByUser() {
        let window = AXNode(
            role: "AXWindow", value: nil, title: "Login", url: nil,
            frame: CGRect(x: 0, y: 0, width: 400, height: 200), focused: false,
            children: [
                AXNode(role: "AXTextField", value: nil, title: nil, url: nil,
                       frame: CGRect(x: 0, y: 0, width: 200, height: 18), focused: true,
                       children: [], subrole: GenericPageExtractor.secureSubrole),
            ])
        let blocks = GenericPageExtractor.extract(window: window, focusedElement: nil, url: nil)
            .page.regions.flatMap(\.blocks)
        XCTAssertEqual(blocks.map(\.text), [GenericPageExtractor.secureMask])
        XCTAssertFalse(blocks[0].authoredByUser)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "ComposerDraftTests|GenericPageExtractorTests/testFocused"`
Expected: compile FAIL — `ComposerDraft` does not exist and no block is marked `authoredByUser`.

- [ ] **Step 3: Implement `ComposerDraft`**

Create `Sources/MaxMiCapture/ComposerDraft.swift`:

```swift
import Foundation
import MaxMiCore

/// The user's in-progress message in a chat composer, as a draft `Message`.
///
/// Read from the focused text field only. A secure field is never read (Phase A nils its value at
/// the source), and a focused field anywhere inside the MESSAGE LIST is not the composer — it is a
/// bubble being edited or a virtualised list cell, and treating it as a draft would attribute
/// somebody else's message to the user.
///
/// The disqualifying test is the ancestor CONTAINER, not the row: spec 5c says "not a descendant of
/// the message-list node", and a rows/cells-only test misses a field parented directly to the list
/// (common in Electron re-renders) while wrongly disqualifying a toolbar field that happens to sit
/// in a bare `AXRow`. `GenericPageExtractor.listContainerRoles` already names the container roles
/// the text walk treats as lists, so it is reused rather than re-listed; `AXTable` is added because
/// a table is a message list in the same sense an `AXList` is.
///
/// Phase D's per-parser configs name the composer anchor explicitly; until then this is the generic
/// rule spec 5c describes.
public enum ComposerDraft {
    static let composerRoles: Set<String> = ["AXTextArea", "AXTextField"]
    /// Ancestor roles that mean "inside the message list", so a focused field below one of them is
    /// history being edited rather than a draft being written.
    static let messageListContainerRoles: Set<String> =
        GenericPageExtractor.listContainerRoles.union(["AXTable"])

    public static func draft(window: AXNode) -> Message? {
        guard let field = focusedComposer(window, inMessageList: false) else { return nil }
        let text = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Message(
            id: "draft:\(field.identifier ?? field.role)",
            sender: "You",
            text: text,
            timestamp: nil,
            timeString: nil,
            isUser: true,
            isDraft: true
        )
    }

    /// Depth-first, first match wins. Menu subtrees are skipped for the same reason the text walk
    /// skips them: a Spotlight or menu search field is not this window's content.
    static func focusedComposer(_ node: AXNode, inMessageList: Bool) -> AXNode? {
        if GenericPageExtractor.menuRoles.contains(node.role) { return nil }
        let inList = inMessageList || messageListContainerRoles.contains(node.role)
        if node.focused, composerRoles.contains(node.role),
           node.subrole != GenericPageExtractor.secureSubrole, !inList {
            return node
        }
        for child in node.children {
            if let found = focusedComposer(child, inMessageList: inList) { return found }
        }
        return nil
    }
}
```

- [ ] **Step 4: Append the draft in the three conversation paths**

`Sources/MaxMiCapture/SlackParser.swift`:

```swift
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        var messages = messages(in: window, windowX: window.frame?.origin.x ?? 0)
        guard !messages.isEmpty else { return nil }
        // The composer's current text, so the next summary can see what the user is writing. The
        // accumulator keeps at most one draft per sender and never merges a draft into history.
        if let draft = ComposerDraft.draft(window: window) { messages.append(draft) }
        let conversation = Conversation(
            channel: channel(fromTitle: app.windowTitle),
            isGroup: isGroup(fromTitle: app.windowTitle),
            messages: messages
        )
        // Newest-anchored HARD cap on the STRUCTURED value: the rendered text is derived from it,
        // so capping the string afterwards would be undone by CaptureEnvelope, and one
        // pathological message must not bloat a version unboundedly.
        return CaptureAccumulator.boundHard(.conversation(conversation), to: Self.contentCap)
    }
```

`Sources/MaxMiCapture/NativeConversationParser.swift` — replace the `Conversation` construction in `extract` (WhatsApp and Teams both route through it):

```swift
        let identity = conversation ?? meaningfulWindowTitle(app.windowTitle, excluding: sourceApp) ?? "unknown"
        var typedMessages = bubbles.map {
            message(sender: $0.sender, text: $0.text,
                    labelsUserAsYou: usesWhatsAppSenderLabels)
        }
        if let draft = ComposerDraft.draft(window: window) { typedMessages.append(draft) }
        let typed = Conversation(
            channel: identity,
            // WhatsApp and Teams headers expose no group marker; Phase D's anchored parsers
            // read the participant list.
            isGroup: false,
            messages: typedMessages
        )
```

`Sources/MaxMiCapture/WebAppCaptureParser.swift` — the conversation branch. `let typedMessages` becomes `var typedMessages` and the draft is appended; nothing else in the function changes:

```swift
        var typedMessages = isConversation ? messages(in: window) : []
        // Only when there IS a conversation: a draft alone is not a chat, and the generic page
        // path already carries the composer's text as an `authoredByUser` block.
        if !typedMessages.isEmpty, let draft = ComposerDraft.draft(window: window) {
            typedMessages.append(draft)
        }
```

The two later uses of `typedMessages` — the `if !typedMessages.isEmpty` branch selector and the
`truncated = bounded.messages.count < typedMessages.count` check — stay exactly as they are. The
truncation check remains correct because the draft is in the list `bound` was given, so shedding it
still counts as truncation.

- [ ] **Step 5: Mark the focused input's block**

In `Sources/MaxMiCapture/GenericPageExtractor.swift`'s `walk`, replace:

```swift
        if let block = block(for: node, listDepth: listDepth) {
            claims[currentClaim].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
```

with:

```swift
        if var block = block(for: node, listDepth: listDepth) {
            // The block the user is typing into. `dedupKey` intentionally ignores authorship, so
            // marking a block cannot change dedup behaviour.
            if node.focused, inputRoles.contains(node.role), node.subrole != secureSubrole {
                block = Block(type: block.type, text: block.text, authoredByUser: true)
            }
            claims[currentClaim].entries.append(BlockEntry(
                y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0, order: order, block: block))
```

- [ ] **Step 6: Run the capture tests to verify they pass**

Run: `swift test --filter "ComposerDraftTests|GenericPageExtractorTests|SlackParserTests|StructuredConversationParserTests|WebAppStructuredTests|NativeConversationParserTests"`
Expected: PASS, including all 10 `ComposerDraftTests` and the 2 new `GenericPageExtractorTests`. If a conversation-parser golden string now ends with an extra `(draft)` line, that fixture's window has a focused composer and the new line is correct — update the golden, do not remove the draft.

- [ ] **Step 7: Commit the composer draft and authorship**

```bash
git add Sources/MaxMiCapture/ComposerDraft.swift Sources/MaxMiCapture/SlackParser.swift \
        Sources/MaxMiCapture/NativeConversationParser.swift \
        Sources/MaxMiCapture/WebAppCaptureParser.swift \
        Sources/MaxMiCapture/GenericPageExtractor.swift \
        Tests/MaxMiCaptureTests/ComposerDraftTests.swift \
        Tests/MaxMiCaptureTests/GenericPageExtractorTests.swift \
        Tests/MaxMiCaptureTests/Fixtures/slack-composer-draft.json \
        Tests/MaxMiCaptureTests/Fixtures/README.md
git commit -m "Carry the focused composer into structured content as a draft message"
```

- [ ] **Step 8: Expose the value-change notification from `FocusObserver`**

`FocusObserver` already registers `kAXValueChangedNotification` (`:92`) and already classifies it (`CaptureNotificationClassifier.trigger`, `:37-44` — `:44` maps it to `.webContentChanged` for browsers, and the `guard isBrowser else { return .accessibilityChanged }` at `:37` covers everything else). It just never tells anyone. Add the hook next to `onFocusChanged`:

```swift
    public var onFocusChanged: (@MainActor (AppInfo, _ isCapturable: Bool, pid_t) -> Void)?
    /// Every AX notification this observer receives, before it decides whether to schedule a
    /// capture. `isValueChange` is computed here rather than passing the raw notification name so
    /// callers do not have to import ApplicationServices to compare it.
    ///
    /// The typing observer needs this: a value change on the focused field is exactly the signal
    /// that the user typed, and it already arrives — no new notification plumbing.
    public var onAXNotification: (@MainActor (_ isValueChange: Bool, _ bundleID: String, _ pid: pid_t) -> Void)?
```

and fire it first in `handleAXNotification`:

```swift
    func handleAXNotification(_ notification: String) {
        guard let current else { return }
        onAXNotification?(notification == kAXValueChangedNotification,
                          current.bundleID, current.pid)
        let trigger = CaptureNotificationClassifier.trigger(
            notification: notification,
            isBrowser: ApplicationRegistry.isBrowser(current.bundleID),
            isConversationApp: ApplicationRegistry.descriptor(for: current.bundleID)?.kind == .chat
        )
        if trigger == .conversationChanged {
            scheduleConversationCapture()
        } else {
            scheduleCapture(trigger: trigger)
        }
    }
```

- [ ] **Step 9: Own the `TypingObserver` in `AppWiring`**

Add the property next to `var observer: FocusObserver?`:

```swift
    var observer: FocusObserver?
    /// Focused-field typing. Nothing is persisted inside it; the LRU is in-actor memory and is
    /// gone on quit (spec 5c).
    var typingObserver: TypingObserver?
    /// Gates the AX READ, per app, before it happens. `onAXNotification` fires ahead of
    /// `FocusObserver`'s capture debounce and for every value change any element publishes, so
    /// without this a progress bar would buy a main-actor AX round trip per tick.
    var typingPollGate = TypingPollGate()
    /// Thread id of the last capture that produced a typing event for a given field, so a value
    /// change arriving BETWEEN captures is still attributable to a thread. In-memory only, bounded
    /// to `TypingObserver.maxTrackedFields` entries, cleared on shutdown.
    var typingThreadIDs: [FocusedFieldKey: String] = [:]
    var typingThreadIDOrder: [FocusedFieldKey] = []
```

In `start()`, after `observer.onFocusChanged = { ... }` and before `observer.start()`:

```swift
        observer.onFocusChanged = { [weak self] app, isCapturable, pid in
            self?.handleFocusChange(app: app, isCapturable: isCapturable, pid: pid)
        }
        // Consent and per-app exclusion are checked on the main actor in
        // `pollFocusedFieldTyping`/`recordTypingEvent` via `isActivityEligible`; the observer's
        // own predicate is the pure denylist guard (plan Ruling 5).
        typingObserver = TypingObserver(isEligible: { !Denylist.isSensitiveApp($0) })
        observer.onAXNotification = { [weak self] isValueChange, bundleID, pid in
            guard isValueChange else { return }
            self?.handleValueChangeNotification(bundleID: bundleID, pid: pid)
        }
        observer.start()
```

Add the four methods next to `recordCaptureEvents`:

```swift
    /// Decides whether this value change is allowed to cost an AX read, BEFORE taking one.
    ///
    /// A burst is coalesced into one trailing read rather than dropped, so the last value of the
    /// burst is still seen — which is the value the user finished typing.
    private func handleValueChangeNotification(bundleID: String, pid: pid_t) {
        switch typingPollGate.admit(key: bundleID, nowMs: epochNowMs()) {
        case .read:
            pollFocusedFieldTyping(bundleID: bundleID, pid: pid)
        case .alreadyScheduled:
            return
        case .schedule(let afterMs):
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(afterMs))
                guard let self else { return }
                self.typingPollGate.completeScheduled(key: bundleID, nowMs: epochNowMs())
                self.pollFocusedFieldTyping(bundleID: bundleID, pid: pid)
            }
        }
    }

    /// The focused field changed value without a capture running. `focusedElementSnapshot` wakes
    /// `AXManualAccessibility` itself, so this works for Electron apps that expose nothing until
    /// an assistive client asks. Never called directly from the notification —
    /// `handleValueChangeNotification` gates it first.
    private func pollFocusedFieldTyping(bundleID: String, pid: pid_t) {
        guard !isShuttingDown, !isLifecycleSuspended,
              isActivityEligible(bundleID: bundleID),
              let node = AXReader.focusedElementSnapshot(pid: pid) else { return }
        let app = AppInfo(
            bundleID: bundleID,
            name: NSWorkspace.shared.frontmostApplication?.localizedName ?? bundleID,
            // BOTH window inputs, exactly as the capture path supplies them.
            // `AXReader.focusedWindowID(pid:)` returns nil for a window with no CGWindowID, and
            // `FocusedFieldKey` then falls back to the title — so passing `windowTitle: nil` here
            // would mint a DIFFERENT key from the capture path for the same field, make every
            // notification a first sighting, and emit nothing for that app forever. Both calls
            // read `kAXTitleAttribute` of the same focused window, so the titles agree.
            windowTitle: AXReader.focusedWindowTitle(pid: pid),
            windowID: AXReader.focusedWindowID(pid: pid)
        )
        recordTypingEvent(app: app, focused: FocusedElement(node: node),
                          trigger: .accessibilityChanged, threadID: nil, versionID: nil)
    }

    /// One `typing` event, if the observer decides the value change was meaningful. The observer
    /// owns the emit debounce, the diff and the secure-field refusal; this method owns the thread
    /// attribution and the DB write.
    private func recordTypingEvent(
        app: AppInfo,
        focused: FocusedElement,
        trigger: CaptureTrigger,
        threadID: String?,
        versionID: String?
    ) {
        guard let typingObserver, !focused.isSecure else { return }
        let key = FocusedFieldKey(app: app, focused: focused)
        // The capture path knows the thread; the poll path does not, because no capture ran. Reuse
        // the thread the last capture of this SAME field established, so typing between captures is
        // still attributable. nil until there has been such a capture, which is one of the reasons
        // capture_events.thread_id is nullable (spec 12 Q4).
        if let threadID { rememberTypingThreadID(threadID, for: key) }
        let resolvedThreadID = threadID ?? typingThreadIDs[key]
        let nowMs = epochNowMs()
        Task { @MainActor [weak self] in
            guard let event = await typingObserver.observe(focused, key: key, nowMs: nowMs),
                  let self else { return }
            do {
                try self.store.recordCaptureEvent(
                    kind: .typing, appBundle: app.bundleID, threadID: resolvedThreadID,
                    versionID: versionID, trigger: trigger, payload: event, nowMs: nowMs
                )
            } catch {
                SafeLogger.shared.log(
                    .error, subsystem: .capture, event: .captureEventWriteFailed, error: error
                )
            }
        }
    }

    /// Most-recently-used last, bounded to the same 32 fields the observer tracks — the two maps
    /// are keyed identically, so neither can outgrow the other.
    private func rememberTypingThreadID(_ threadID: String, for key: FocusedFieldKey) {
        typingThreadIDOrder.removeAll { $0 == key }
        typingThreadIDOrder.append(key)
        typingThreadIDs[key] = threadID
        while typingThreadIDOrder.count > TypingObserver.maxTrackedFields {
            typingThreadIDs[typingThreadIDOrder.removeFirst()] = nil
        }
    }
```

In the shutdown path (`Sources/MaxMi/AppWiring.swift:1175-1176`, `observer?.stop()` then `observer = nil`), add these three lines immediately after `observer = nil`, so no tracked field values or thread ids outlive the process's capture lifecycle:

```swift
        typingObserver = nil
        typingThreadIDs.removeAll()
        typingThreadIDOrder.removeAll()
```

`typingPollGate` needs no reset: it holds only timestamps, and its own `staleAfterMs` prune makes a
stale entry indistinguishable from an absent one. Leave the lifecycle-suspend path (`:1144`) alone:
a suspend is temporary and re-establishing every baseline on resume would report the whole field as
freshly typed.

- [ ] **Step 10: Feed the capture path's focused element to the observer**

In `finishCapture`, extend the committed-capture block from Task 4:

```swift
            if case .committed(let versionID, _, let delta) = result {
                let eventThreadID = (try? store.threadID(sourceApp: parsed.sourceApp,
                                                         sourceKey: cleanKey)) ?? nil
                recordCaptureEvents(
                    app: appInfo, eligible: eligible, threadID: eventThreadID,
                    versionID: versionID, result: result, delta: delta, trigger: trigger,
                    browserURL: browserURL, previousURL: previousURL, nowMs: nowMs
                )
                // The capture's own focused element is the primary source: it was resolved from
                // the tree we already walked. `focusedElementSnapshot` is the fallback for the
                // shapes that carry no `GenericPage` (conversations, terminals, tasks).
                let focusedForTyping: FocusedElement? = {
                    if case .generic(let page) = envelope.structured, let focused = page.focused {
                        return focused
                    }
                    return AXReader.focusedElementSnapshot(pid: pid).map(FocusedElement.init(node:))
                }()
                if let focusedForTyping {
                    recordTypingEvent(app: appInfo, focused: focusedForTyping, trigger: trigger,
                                      threadID: eventThreadID, versionID: versionID)
                }
            }
```

`appInfo` (`AppWiring.swift:1436-1438`) carries **both** window inputs — the authoritative
`AXReader` window title and `AXReader.focusedWindowID(pid:)` — and `pollFocusedFieldTyping` now
resolves both as well, so the two paths build the same `FocusedFieldKey` whether or not the app
exposes a `CGWindowID`. Do not "simplify" either call site to pass only one of the two: with a
window id the title is ignored, and without one the title is the only discriminator there is.

`recordTypingEvent` is also what remembers the thread id for this field, so a later poll-path event
on the same field is attributed to the same thread instead of writing `thread_id IS NULL`.

- [ ] **Step 11: Build and run the suite**

Run: `swift build 2>&1 | grep -E "error:|warning:"`
Expected: no output.

Run: `swift test 2>&1 | tail -20`
Expected: exactly the 3 known-red failures.

- [ ] **Step 12: Commit the wiring**

```bash
git add Sources/MaxMiCapture/FocusObserver.swift Sources/MaxMi/AppWiring.swift
git commit -m "Record typing events from focused-field value changes"
```

---

## Task 7: Viewport-anchored trimming for `.document` and `.generic`

Phase A trims a region by dropping blocks from the END, which keeps the top of the page. For a long document the user is almost never at the top, so an over-budget note stores the title and the first screen and throws away the paragraph being edited. Phase A's final review deferred this here (ledger item I1).

**Files:**
- Modify: `Sources/MaxMiCapture/GenericPageExtractor.swift:78-102` (`extract`)
- Modify: `Sources/MaxMiCapture/GenericPageExtractor+Budgets.swift:25-78` (`applyBudgets`; the `.main` trim is `:61`) and add `anchorIndex`/`trimAnchored`
- Test: `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift` (extend)

**Interfaces:**
- Consumes: `GenericPageExtractor.trim(_:to:) -> (blocks: [Block], truncated: Bool)`, `GenericPageExtractor.renderedSize(_:) -> Int`, `GenericPageExtractor.resolveFocusedElement(in:fallback:) -> FocusedElement?`, `ContentRenderer.renderBlock(_:) -> String`, `FocusedElement.value`/`.isSecure`.
- Produces:
  - `GenericPageExtractor.anchorText(_ focused: FocusedElement?) -> String?`
  - `GenericPageExtractor.anchorIndex(in blocks: [Block], text: String?) -> Int?`
  - `GenericPageExtractor.trimAnchored(_ blocks: [Block], to allowance: Int, anchorIndex: Int?) -> (blocks: [Block], truncated: Bool)`
  - `GenericPageExtractor.applyBudgets(_ regions: [Region], anchorText: String? = nil, options: Options) -> (regions: [Region], truncated: Bool)` — `anchorText` defaults to nil, so `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift`'s existing calls and `trim`'s own tests compile unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift`:

```swift
    // MARK: - Viewport-anchored trimming

    private func paragraph(_ text: String) -> Block { Block(type: .paragraph, text: text) }

    func testAnchorTextIsTheFocusedFieldValue() {
        let focused = FocusedElement(role: "AXTextArea", identifier: "body",
                                    value: "  the paragraph I am editing  ",
                                    selectedText: nil, isSecure: false)
        XCTAssertEqual(GenericPageExtractor.anchorText(focused), "the paragraph I am editing")
    }

    func testAnchorTextRefusesSecureBlankAndTinyValues() {
        XCTAssertNil(GenericPageExtractor.anchorText(nil))
        XCTAssertNil(GenericPageExtractor.anchorText(FocusedElement(
            role: "AXTextField", identifier: nil, value: "secret", selectedText: nil,
            isSecure: true)))
        XCTAssertNil(GenericPageExtractor.anchorText(FocusedElement(
            role: "AXTextArea", identifier: nil, value: "   ", selectedText: nil,
            isSecure: false)))
        XCTAssertNil(GenericPageExtractor.anchorText(FocusedElement(
            role: "AXTextArea", identifier: nil, value: "x", selectedText: nil, isSecure: false)))
    }

    func testAnchorIndexPrefersAnExactTrimmedMatchThenContainment() {
        let blocks = [paragraph("intro"), paragraph("the target line"),
                      paragraph("wrapping the target line inside more text")]
        XCTAssertEqual(GenericPageExtractor.anchorIndex(in: blocks, text: "the target line"), 1)
        XCTAssertEqual(GenericPageExtractor.anchorIndex(in: blocks, text: "wrapping the target"), 2)
        XCTAssertNil(GenericPageExtractor.anchorIndex(in: blocks, text: "absent"))
        XCTAssertNil(GenericPageExtractor.anchorIndex(in: blocks, text: nil))
    }

    func testTrimAnchoredWithoutAnAnchorIsExactlyTheOldTopOfPageBehaviour() {
        let blocks = (0..<10).map { paragraph("line \($0)") }
        let anchored = GenericPageExtractor.trimAnchored(blocks, to: 30, anchorIndex: nil)
        let plain = GenericPageExtractor.trim(blocks, to: 30)
        XCTAssertEqual(anchored.blocks.map(\.text), plain.blocks.map(\.text))
        XCTAssertEqual(anchored.truncated, plain.truncated)
    }

    func testTrimAnchoredKeepsTheWindowAroundTheAnchor() {
        let blocks = (0..<20).map { paragraph("line \($0)") }
        // "line 10" costs 7 + 1 separator; the allowance fits the anchor plus four neighbours.
        let result = GenericPageExtractor.trimAnchored(blocks, to: 8 * 5, anchorIndex: 10)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.blocks.contains { $0.text == "line 10" })
        XCTAssertFalse(result.blocks.contains { $0.text == "line 0" })
        // Page order is preserved, and the kept blocks are contiguous.
        let indexes = result.blocks.map { Int($0.text.dropFirst("line ".count))! }
        XCTAssertEqual(indexes, Array(indexes.min()!...indexes.max()!))
        // Forward-first expansion: the anchor's continuation matters more than its preamble.
        XCTAssertTrue(result.blocks.contains { $0.text == "line 11" })
    }

    func testTrimAnchoredAlwaysKeepsTheAnchorEvenWhenItAloneExceedsTheAllowance() {
        let blocks = [paragraph("short"), paragraph(String(repeating: "L", count: 500))]
        let result = GenericPageExtractor.trimAnchored(blocks, to: 10, anchorIndex: 1)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.blocks[0].text.count, 500)
        XCTAssertTrue(result.truncated)
    }

    func testTrimAnchoredWithAnOutOfRangeAnchorFallsBackToTopOfPage() {
        let blocks = (0..<5).map { paragraph("line \($0)") }
        let result = GenericPageExtractor.trimAnchored(blocks, to: 20, anchorIndex: 99)
        XCTAssertEqual(result.blocks.first?.text, "line 0")
    }

    /// End to end: an over-budget document whose focused field sits near the bottom keeps the
    /// bottom, not the top.
    func testOverBudgetDocumentKeepsWhatTheUserIsLookingAt() {
        var children: [AXNode] = (0..<40).map { index in
            text(String(repeating: "body ", count: 20) + "\(index)", y: 320 + CGFloat(index) * 18)
        }
        children.append(node("AXTextArea", value: "the line I am editing", identifier: "body",
                             frame: CGRect(x: 520, y: 320 + 40 * 18, width: 400, height: 18),
                             focused: true))
        var options = GenericPageExtractor.Options()
        options.totalBudget = 900
        let result = extract(children, options: options)
        let texts = blocks(result, .main).map(\.text)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(texts.contains("the line I am editing"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasSuffix(" 0") }, "the top of the page was dropped")
    }

    /// No focused field means no anchor, so an over-budget page still keeps its top — the Phase A
    /// contract every other budget test in this file asserts.
    func testOverBudgetDocumentWithoutAFocusedFieldStillKeepsTheTop() {
        let children: [AXNode] = (0..<40).map { index in
            text(String(repeating: "body ", count: 20) + "\(index)", y: 320 + CGFloat(index) * 18)
        }
        var options = GenericPageExtractor.Options()
        options.totalBudget = 900
        let texts = blocks(extract(children, options: options), .main).map(\.text)
        XCTAssertTrue(texts.first?.hasSuffix(" 0") == true, "\(texts.prefix(1))")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter GenericPageBudgetTests`
Expected: FAIL — `anchorText`, `anchorIndex` and `trimAnchored` do not exist.

- [ ] **Step 3: Resolve the focused element before budgeting**

In `Sources/MaxMiCapture/GenericPageExtractor.swift`, replace the tail of `extract`:

```swift
        let budgeted = applyBudgets(assemble(claims), options: options)
        return Result(
            page: GenericPage(
                regions: budgeted.regions,
                focused: resolveFocusedElement(in: window, fallback: focusedElement),
                url: url
            ),
            truncated: budgeted.truncated
        )
```

with:

```swift
        // Resolved BEFORE budgeting: what the user is looking at decides which part of an
        // over-budget page survives (spec 4e final-review amendment).
        let focused = resolveFocusedElement(in: window, fallback: focusedElement)
        let budgeted = applyBudgets(assemble(claims), anchorText: anchorText(focused),
                                    options: options)
        return Result(
            page: GenericPage(regions: budgeted.regions, focused: focused, url: url),
            truncated: budgeted.truncated
        )
```

and add, next to `resolveFocusedElement`:

```swift
    /// The focused field's value, when it is usable as a trim anchor. A secure field has no value
    /// at all; a blank or single-character value would match almost any block and would anchor
    /// the window somewhere arbitrary.
    static func anchorText(_ focused: FocusedElement?) -> String? {
        guard let focused, !focused.isSecure,
              let value = focused.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 2 else { return nil }
        return value
    }
```

- [ ] **Step 4: Anchor the `.main` trim**

In `Sources/MaxMiCapture/GenericPageExtractor+Budgets.swift`, change the signature and the `.main` trim, leaving the dialog and rest arithmetic exactly as it is:

```swift
    static func applyBudgets(_ regions: [Region], anchorText: String? = nil,
                             options: Options) -> (regions: [Region], truncated: Bool) {
```

and replace:

```swift
        let mainResult = trim(regions.first(where: { $0.kind == .main })?.blocks ?? [], to: mainAllowance)
        truncated = truncated || mainResult.truncated
```

with:

```swift
        // `.main` alone is viewport-anchored: chrome regions have no "where the user is looking"
        // and their blocks are short enough that the top of the region is the right thing to keep.
        let mainBlocks = regions.first(where: { $0.kind == .main })?.blocks ?? []
        let mainResult = trimAnchored(mainBlocks, to: mainAllowance,
                                      anchorIndex: anchorIndex(in: mainBlocks, text: anchorText))
        truncated = truncated || mainResult.truncated
```

Append the two helpers to the same extension:

```swift
    /// Index of the `.main` block the focused field produced, or nil.
    ///
    /// Exact trimmed-text match first — an `.input` block's text IS the field's value — then
    /// containment, which covers a document body whose paragraph block holds the field value plus
    /// surrounding text.
    static func anchorIndex(in blocks: [Block], text: String?) -> Int? {
        guard let text else { return nil }
        if let exact = blocks.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }) {
            return exact
        }
        return blocks.firstIndex { $0.text.contains(text) }
    }

    /// A nil or out-of-range anchor keeps Phase A's behaviour exactly: whole blocks dropped from
    /// the END, so the top of the page survives. With an anchor, the contiguous window of blocks
    /// AROUND the anchor survives instead — what the user is looking at, not what the page starts
    /// with.
    ///
    /// Expansion alternates, forward first, so the anchor's continuation is preferred over its
    /// preamble; it stops at the first neighbour that does not fit rather than hunting for a
    /// smaller one further out, which keeps the kept range contiguous and the result
    /// deterministic. The anchor block itself is always kept, even when it alone exceeds the
    /// allowance — the same soft cap `trim` applies to a page's first block.
    static func trimAnchored(_ blocks: [Block], to allowance: Int,
                             anchorIndex: Int?) -> (blocks: [Block], truncated: Bool) {
        guard let anchorIndex, blocks.indices.contains(anchorIndex) else {
            return trim(blocks, to: allowance)
        }
        var low = anchorIndex
        var high = anchorIndex
        var used = ContentRenderer.renderBlock(blocks[anchorIndex]).count
        var forward = true
        while low > 0 || high < blocks.count - 1 {
            let canGoForward = high < blocks.count - 1
            let index = (forward && canGoForward) || low == 0 ? high + 1 : low - 1
            let cost = ContentRenderer.renderBlock(blocks[index]).count + 1
            if used + cost > allowance { break }
            used += cost
            if index > high { high = index } else { low = index }
            forward.toggle()
        }
        let kept = Array(blocks[low...high])
        return (kept, kept.count != blocks.count)
    }
```

- [ ] **Step 5: Run the budget tests to verify they pass**

Run: `swift test --filter GenericPageBudgetTests`
Expected: PASS, 9 new tests plus every pre-existing test in the file (they pass no `anchorText`, and their fixtures have no focused field inside `.main`).

Run: `swift test --filter "GenericPage|GenericV2|GenericAX"`
Expected: PASS.

Anchored `.main` trimming is **not** confined to the native path: `WebAppCaptureParser` calls
`GenericPageExtractor.extract` for the browser `.generic` branch (`WebAppCaptureParser.swift:92-97`),
so a browser page with a focused field now keeps a different slice of `.main` than it did before.
The filters above do not touch a single browser test, so run them explicitly rather than discovering
the breakage in Task 10:

Run: `swift test --filter "WebAppStructuredTests|BrowserCapturePipelineTests"`
Expected: PASS. If a browser golden string changes, read the fixture: a focused field inside `.main`
means the new slice is the correct one and the golden is what should move. A change in a fixture with
**no** focused field is a bug in `anchorIndex` — `trimAnchored` with a nil anchor must be
byte-identical to `trim`, which `testTrimAnchoredWithoutAnAnchorIsExactlyTheOldTopOfPageBehaviour`
asserts directly.

- [ ] **Step 6: Run the perf bound**

Anchoring adds one `firstIndex` scan over `.main` and no extra rendering, so the 20k-node bound must still hold.

Run: `swift test -c release --filter GenericPageExtractorPerformanceTests`
Expected: PASS, under the 150 ms bound.

- [ ] **Step 7: Commit**

```bash
git add Sources/MaxMiCapture/GenericPageExtractor.swift \
        Sources/MaxMiCapture/GenericPageExtractor+Budgets.swift \
        Tests/MaxMiCaptureTests/GenericPageBudgetTests.swift
git commit -m "Anchor main-region trimming to the focused block"
```

---

## Task 8: `TimelineBuilder` — the model, the build, and the render

`MaxMiActivity` turns app visits plus capture events into a compact, deterministic text timeline. This is the read side of everything Tasks 2–6 wrote, and Phase C's prompts consume it. It never embeds a full dump: per-visit metadata plus at most 200 characters of that visit's added content.

**Files:**
- Create: `Sources/MaxMiActivity/TimelineBuilder.swift`
- Test: `Tests/MaxMiActivityTests/TimelineBuilderTests.swift` (create)

**Interfaces:**
- Consumes (all `MaxMiCore`, which is `MaxMiActivity`'s only dependency): `EpochMs`, `CaptureEventKind`, `CaptureDelta`, `TypingEvent`, `CaptureTrigger`, `CaptureContentKind`, `Block`, `Message`, `TerminalSegment`, `ContentRenderer.renderBlocks(_:)`, `ContentRenderer.renderMessage(_:)`, `ContentRenderer.renderSegment(_:)`.
- Produces:
  - `TimelineEntry(startMs:endMs:appLabel:threadID:sourceTitle:url:kind:cwd:deltaSummary:newItemCount:typedCount:typedSample:)` — `Codable, Sendable, Equatable`.
  - `ActivityTimeline(fromMs:toMs:entries:)` — `Codable, Sendable, Equatable`.
  - `TimelineRawEvent(kind:atMs:threadID:trigger:delta:typing:toURL:)` — `Sendable, Equatable`.
  - `TimelineThreadMeta(sourceApp:sourceTitle:kind:url:cwd:)` — `Sendable, Equatable`.
  - `protocol TimelineRepository: Sendable` with `appVisits(fromMs:toMs:) throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)]`, `captureEvents(fromMs:toMs:) throws -> [TimelineRawEvent]`, `threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta]`.
  - `TimelineBuilder(repo: any TimelineRepository)`, `build(fromMs:toMs:) throws -> ActivityTimeline`, `static render(_ timeline: ActivityTimeline, budgetChars: Int) -> String`.
  - Internal (not part of the public surface, and no later task references it): `TimelineBuilder.BuiltEntry(bundleID: String, entry: TimelineEntry)`, `static coalesce(_ built: [BuiltEntry]) -> [TimelineEntry]`, `static mergeable(_ lhs: BuiltEntry, _ rhs: BuiltEntry) -> Bool`.
  - `TimelineBuilder.deltaSummaryCap = 200`, `.typedSampleCap = 120`, `.urlCap = 60`, `.omissionLine = "(earlier activity omitted)"`.

**Decisions this task pins (so nothing downstream has to guess):**
- A visit with **no** events is still emitted: the app was focused, which is activity. Its `kind` is `.generic`, its `threadID` is nil.
- An entry's `threadID` is the thread of the **first** attached event that has one; entries are coalesced with the next one when the `threadID`s are equal, or — when both are nil — when the **`bundleID`s** are equal (spec §5d). `appLabel` is NOT the coalescing key: two bundles can share one display name (Chrome and Chrome Beta, two Electron builds of the same product) and merging them would report one stretch of activity that never happened. `TimelineEntry`'s field list is pinned by the spec and has no `bundleID`, so the bundle id rides on an internal `BuiltEntry` that `build` pairs with each entry and `coalesce` consumes; it never reaches the public type.
- `endMs` for an open visit (`endedAt == nil`) is the window's `toMs`.
- `render` drops whole entries **oldest first** and prepends `omissionLine` when anything was dropped. It never drops the last remaining entry, mirroring Phase A's never-return-empty rule for budgeting.
- Unit words are fixed plurals — `msgs`, `paragraphs`, `segments`, `rows` — so a rendered line is byte-stable and no pluralisation logic can drift.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MaxMiActivityTests/TimelineBuilderTests.swift`:

```swift
import XCTest
@testable import MaxMiActivity
import MaxMiCore

/// Deterministic stub. Not an actor: `TimelineRepository` is synchronous and throwing, matching
/// the store reads it adapts.
struct StubTimelineRepository: TimelineRepository {
    var visits: [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] = []
    var events: [TimelineRawEvent] = []
    var metadata: [String: TimelineThreadMeta] = [:]

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        visits
    }
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] { events }
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        metadata.filter { threadIDs.contains($0.key) }
    }
}

final class TimelineBuilderTests: XCTestCase {
    /// 2026-09-07 09:00:00 UTC. Every `render` assertion below compares against times formatted
    /// in the CURRENT time zone, computed the same way the renderer does, so the test is
    /// timezone-independent.
    private let t0 = EpochMs(1_788_512_400_000)

    private func hhmm(_ ms: EpochMs) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func deltaEvent(atMs: EpochMs, threadID: String?, delta: CaptureDelta) -> TimelineRawEvent {
        TimelineRawEvent(kind: .contentDelta, atMs: atMs, threadID: threadID, trigger: .periodic,
                         delta: delta, typing: nil, toURL: nil)
    }

    private func typingEvent(atMs: EpochMs, threadID: String?, text: String) -> TimelineRawEvent {
        TimelineRawEvent(
            kind: .typing, atMs: atMs, threadID: threadID, trigger: .accessibilityChanged,
            delta: nil,
            typing: TypingEvent(insertedText: text, fieldRole: "AXTextArea",
                                fieldIdentifier: "composer", totalLength: text.count,
                                replaced: false),
            toURL: nil)
    }

    private func message(_ sender: String, _ text: String) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: "09:20", text: text),
                sender: sender, text: text, timestamp: nil, timeString: "09:20",
                isUser: false, isDraft: false)
    }

    // MARK: - build

    func testVisitWithoutEventsIsStillAnEntry() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.reader", appLabel: "Reader",
             startedAt: t0, endedAt: t0 + 60_000),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.fromMs, t0)
        XCTAssertEqual(timeline.toMs, t0 + 600_000)
        XCTAssertEqual(timeline.entries.count, 1)
        let entry = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(entry.appLabel, "Reader")
        XCTAssertNil(entry.threadID)
        XCTAssertEqual(entry.kind, .generic)
        XCTAssertEqual(entry.newItemCount, 0)
        XCTAssertNil(entry.deltaSummary)
    }

    func testOpenVisitEndsAtTheWindowEnd() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.reader", appLabel: "Reader", startedAt: t0, endedAt: nil),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.entries.first?.endMs, t0 + 600_000)
    }

    func testEntriesAreChronologicalRegardlessOfRepositoryOrder() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "c", appLabel: "Third", startedAt: t0 + 200_000, endedAt: t0 + 300_000),
            (bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "b", appLabel: "Second", startedAt: t0 + 100_000, endedAt: t0 + 200_000),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.entries.map(\.appLabel), ["First", "Second", "Third"])
    }

    func testEventsAttachToTheVisitContainingThem() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "b", appLabel: "Second", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "one")],
                                               addedChars: 3)),
                deltaEvent(atMs: t0 + 150_000, threadID: "t2",
                           delta: CaptureDelta(addedMessages: [message("Ana", "hello")],
                                               addedChars: 5)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Reader", sourceTitle: "A doc",
                                         kind: .document, url: nil, cwd: nil),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#invented",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.threadID), ["t1", "t2"])
        XCTAssertEqual(entries.map(\.kind), [.document, .conversation])
        XCTAssertEqual(entries.map(\.sourceTitle), ["A doc", "#invented"])
        XCTAssertEqual(entries.map(\.newItemCount), [1, 1])
    }

    func testEventsOutsideEveryVisitAreDropped() throws {
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 10_000)],
            events: [deltaEvent(atMs: t0 + 500_000, threadID: "t1",
                                delta: CaptureDelta(addedChars: 9))])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.threadID)
    }

    func testAdjacentSameThreadVisitsCoalesce() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Editor", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "a", appLabel: "Editor", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "one")],
                                               addedChars: 3)),
                typingEvent(atMs: t0 + 60_000, threadID: "t1", text: "abc"),
                deltaEvent(atMs: t0 + 150_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "two")],
                                               addedChars: 3)),
                typingEvent(atMs: t0 + 160_000, threadID: "t1", text: "def"),
            ],
            metadata: ["t1": TimelineThreadMeta(sourceApp: "Editor", sourceTitle: "Draft",
                                                kind: .document, url: nil, cwd: nil)])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.startMs, t0)
        XCTAssertEqual(entry.endMs, t0 + 200_000)
        XCTAssertEqual(entry.newItemCount, 2)
        XCTAssertEqual(entry.typedCount, 2)
        XCTAssertEqual(entry.typedSample, "def", "the latest sample wins")
        XCTAssertEqual(entry.deltaSummary, "two", "the latest delta summary wins")
    }

    func testAdjacentThreadlessVisitsOfTheSameAppCoalesce() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "a", appLabel: "Reader", startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "a", appLabel: "Reader", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
        ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.endMs, t0 + 200_000)
    }

    /// Spec 5d coalesces threadless entries by BUNDLE ID, not by display name. Two bundles that
    /// present the same name — a release and a beta channel, two Electron builds of one product —
    /// are two apps, and merging them would invent a stretch of activity that never happened.
    func testThreadlessVisitsOfDifferentBundlesWithTheSameLabelDoNotCoalesce() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.browser", appLabel: "Browser",
             startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "com.example.browser.beta", appLabel: "Browser",
             startedAt: t0 + 100_001, endedAt: t0 + 200_000),
        ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 2, "one display name, two bundles, two entries")
        XCTAssertEqual(entries.map(\.startMs), [t0, t0 + 100_001])
    }

    func testDifferentThreadsInTheSameAppDoNotCoalesce() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Chat", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "a", appLabel: "Chat", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1", delta: CaptureDelta(addedChars: 1)),
                deltaEvent(atMs: t0 + 150_000, threadID: "t2", delta: CaptureDelta(addedChars: 1)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#one",
                                         kind: .conversation, url: nil, cwd: nil),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#two",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.threadID), ["t1", "t2"])
    }

    func testDeltaSummaryIsCappedAtTwoHundredCharactersAndSingleLine() throws {
        let long = (0..<20).map { Block(type: .paragraph, text: "paragraph number \($0) of a long addition") }
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "Editor", startedAt: t0, endedAt: t0 + 100_000)],
            events: [deltaEvent(atMs: t0 + 10_000, threadID: "t1",
                                delta: CaptureDelta(addedBlocks: long, addedChars: 900))],
            metadata: ["t1": TimelineThreadMeta(sourceApp: "Editor", sourceTitle: "Draft",
                                                kind: .document, url: nil, cwd: nil)])
        let summary = try XCTUnwrap(
            TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries.first?.deltaSummary)
        XCTAssertLessThanOrEqual(summary.count, TimelineBuilder.deltaSummaryCap)
        XCTAssertFalse(summary.contains("\n"), "a timeline line is one line")
        XCTAssertEqual(summary.prefix(9), "paragraph")
    }

    func testTypedSampleIsCappedAtOneHundredAndTwentyCharacters() throws {
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "Chat", startedAt: t0, endedAt: t0 + 100_000)],
            events: [typingEvent(atMs: t0 + 10_000, threadID: nil,
                                 text: String(repeating: "t", count: 400))])
        let sample = try XCTUnwrap(
            TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries.first?.typedSample)
        XCTAssertEqual(sample.count, TimelineBuilder.typedSampleCap)
    }

    func testTerminalAndConversationDeltasCountTheirOwnShapes() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Terminal", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "b", appLabel: "Chat", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 10_000, threadID: "t1", delta: CaptureDelta(
                    addedSegments: [
                        TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
                        TerminalSegment(command: "git status", output: "clean", isRunning: false),
                    ], addedChars: 40)),
                deltaEvent(atMs: t0 + 110_000, threadID: "t2", delta: CaptureDelta(
                    addedMessages: [message("Ana", "one"), message("Bo", "two")], addedChars: 6)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Terminal", sourceTitle: "shell",
                                         kind: .terminal, url: nil, cwd: "~/code/project"),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#invented",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.newItemCount), [2, 2])
        XCTAssertEqual(entries.first?.cwd, "~/code/project")
    }

    // MARK: - render

    func testRenderedTerminalLineNamesTheKindAndCwd() throws {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 600_000, appLabel: "Terminal", threadID: "t1",
            sourceTitle: "shell", url: nil, kind: .terminal, cwd: "~/code/project",
            deltaSummary: "ran swift test", newItemCount: 3, typedCount: 3, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: [entry]),
            budgetChars: 4_000)
        XCTAssertEqual(
            text,
            "\(hhmm(t0))–\(hhmm(t0 + 600_000)) Terminal (terminal ~/code/project): "
                + "ran swift test; new since last: 3 segments; typed 3 edits")
    }

    func testRenderedWebLineQuotesTheTitleAndTruncatesTheURL() throws {
        let url = "https://example.invalid/" + String(repeating: "p", count: 120)
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Browser", threadID: "t1",
            sourceTitle: "An invented page", url: url, kind: .webpage, cwd: nil,
            deltaSummary: nil, newItemCount: 4, typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertTrue(text.contains("Browser \"An invented page\" ("), text)
        XCTAssertTrue(text.contains("new since last: 4 paragraphs"), text)
        XCTAssertFalse(text.contains(url), "the full url must be truncated")
        XCTAssertTrue(text.contains(String(url.prefix(TimelineBuilder.urlCap))), text)
    }

    func testRenderedConversationLineQuotesTheTypedSample() throws {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Chat", threadID: "t1",
            sourceTitle: "#invented", url: nil, kind: .conversation, cwd: nil,
            deltaSummary: "2 new lines", newItemCount: 2, typedCount: 1,
            typedSample: "shipping today")
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertTrue(text.hasSuffix("new since last: 2 msgs; typed 1 edits \"shipping today\""), text)
    }

    func testEntryWithNoFactsRendersOnlyItsHead() {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Reader", threadID: nil,
            sourceTitle: nil, url: nil, kind: .generic, cwd: nil,
            deltaSummary: nil, newItemCount: 0, typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertEqual(text, "\(hhmm(t0))–\(hhmm(t0 + 60_000)) Reader")
    }

    func testRenderIsChronologicalOneLinePerEntry() {
        let entries = (0..<3).map { index in
            TimelineEntry(startMs: t0 + EpochMs(index) * 60_000,
                          endMs: t0 + EpochMs(index + 1) * 60_000,
                          appLabel: "App\(index)", threadID: nil, sourceTitle: nil, url: nil,
                          kind: .generic, cwd: nil, deltaSummary: nil, newItemCount: 0,
                          typedCount: 0, typedSample: nil)
        }
        let lines = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: entries),
            budgetChars: 4_000).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("App0"))
        XCTAssertTrue(lines[2].hasSuffix("App2"))
    }

    func testBudgetDropsOldestFirstAndAddsTheOmissionLine() {
        let entries = (0..<10).map { index in
            TimelineEntry(startMs: t0 + EpochMs(index) * 60_000,
                          endMs: t0 + EpochMs(index + 1) * 60_000,
                          appLabel: "App\(index)", threadID: nil, sourceTitle: nil, url: nil,
                          kind: .generic, cwd: nil,
                          deltaSummary: String(repeating: "s", count: 60), newItemCount: 0,
                          typedCount: 0, typedSample: nil)
        }
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: entries), budgetChars: 300)
        XCTAssertTrue(text.hasPrefix(TimelineBuilder.omissionLine + "\n"), text)
        XCTAssertLessThanOrEqual(text.count, 300)
        XCTAssertFalse(text.contains("App0"), "the oldest entry is dropped first")
        XCTAssertTrue(text.contains("App9"), "the newest entry always survives")
    }

    func testBudgetNeverDropsTheLastEntry() {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Reader", threadID: nil,
            sourceTitle: nil, url: nil, kind: .generic, cwd: nil,
            deltaSummary: String(repeating: "s", count: 900), newItemCount: 0,
            typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 10)
        XCTAssertTrue(text.contains("Reader"), "an over-budget single entry is still reported")
    }

    func testEmptyTimelineRendersEmpty() {
        XCTAssertEqual(
            TimelineBuilder.render(ActivityTimeline(fromMs: t0, toMs: t0 + 1, entries: []),
                                   budgetChars: 4_000),
            "")
    }

    func testTimelineIsCodableRoundTrippable() throws {
        let timeline = ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [
            TimelineEntry(startMs: t0, endMs: t0 + 60_000, appLabel: "Chat", threadID: "t1",
                          sourceTitle: "#invented", url: nil, kind: .conversation, cwd: nil,
                          deltaSummary: "two lines", newItemCount: 2, typedCount: 1,
                          typedSample: "hi"),
        ])
        let data = try CapturedContentEnvelope.makeEncoder().encode(timeline)
        XCTAssertEqual(
            try CapturedContentEnvelope.makeDecoder().decode(ActivityTimeline.self, from: data),
            timeline)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter TimelineBuilderTests`
Expected: compile FAIL — none of `TimelineEntry`, `ActivityTimeline`, `TimelineRawEvent`, `TimelineThreadMeta`, `TimelineRepository` or `TimelineBuilder` exists.

- [ ] **Step 3: Implement the timeline**

Create `Sources/MaxMiActivity/TimelineBuilder.swift`:

```swift
import Foundation
import MaxMiCore

/// One coalesced stretch of activity: an app visit plus whatever capture events landed inside it.
public struct TimelineEntry: Codable, Sendable, Equatable {
    public let startMs: EpochMs
    public let endMs: EpochMs
    public let appLabel: String
    public let threadID: String?
    public let sourceTitle: String?
    public let url: String?
    public let kind: CaptureContentKind
    /// Terminal threads only.
    public let cwd: String?
    /// At most `TimelineBuilder.deltaSummaryCap` characters of the added content, rendered and
    /// flattened to one line. Never a full dump.
    public let deltaSummary: String?
    /// `addedMessages + addedBlocks + addedSegments` summed over this entry's content deltas.
    public let newItemCount: Int
    public let typedCount: Int
    /// At most `TimelineBuilder.typedSampleCap` characters from the LAST typing event.
    public let typedSample: String?

    public init(startMs: EpochMs, endMs: EpochMs, appLabel: String, threadID: String?,
                sourceTitle: String?, url: String?, kind: CaptureContentKind, cwd: String?,
                deltaSummary: String?, newItemCount: Int, typedCount: Int, typedSample: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.appLabel = appLabel
        self.threadID = threadID
        self.sourceTitle = sourceTitle
        self.url = url
        self.kind = kind
        self.cwd = cwd
        self.deltaSummary = deltaSummary
        self.newItemCount = newItemCount
        self.typedCount = typedCount
        self.typedSample = typedSample
    }
}

public struct ActivityTimeline: Codable, Sendable, Equatable {
    public let fromMs: EpochMs
    public let toMs: EpochMs
    public let entries: [TimelineEntry]

    public init(fromMs: EpochMs, toMs: EpochMs, entries: [TimelineEntry]) {
        self.fromMs = fromMs
        self.toMs = toMs
        self.entries = entries
    }
}

/// One decrypted `capture_events` row, shape-agnostic. The adapter decodes the payload; this
/// module never sees JSON.
public struct TimelineRawEvent: Sendable, Equatable {
    public let kind: CaptureEventKind
    public let atMs: EpochMs
    public let threadID: String?
    public let trigger: CaptureTrigger
    /// `kind == .contentDelta` only.
    public let delta: CaptureDelta?
    /// `kind == .typing` only.
    public let typing: TypingEvent?
    /// `kind == .navigation` only.
    public let toURL: String?

    public init(kind: CaptureEventKind, atMs: EpochMs, threadID: String?, trigger: CaptureTrigger,
                delta: CaptureDelta?, typing: TypingEvent?, toURL: String?) {
        self.kind = kind
        self.atMs = atMs
        self.threadID = threadID
        self.trigger = trigger
        self.delta = delta
        self.typing = typing
        self.toURL = toURL
    }
}

/// Per-thread metadata from `threads` + `latest_contexts`.
public struct TimelineThreadMeta: Sendable, Equatable {
    public let sourceApp: String
    public let sourceTitle: String?
    public let kind: CaptureContentKind
    public let url: String?
    public let cwd: String?

    public init(sourceApp: String, sourceTitle: String?, kind: CaptureContentKind,
                url: String?, cwd: String?) {
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
        self.kind = kind
        self.url = url
        self.cwd = cwd
    }
}

/// `MaxMiActivity` depends only on `MaxMiCore`, so the database is reached through this protocol
/// and never directly — the same pattern `ActivitySummaryRepository` and `AgentRepository` use.
public protocol TimelineRepository: Sendable {
    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)]
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent]
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta]
}

/// Deterministic: the same rows always produce the same timeline and the same text.
public struct TimelineBuilder: Sendable {
    public static let deltaSummaryCap = 200
    public static let typedSampleCap = 120
    public static let urlCap = 60
    public static let omissionLine = "(earlier activity omitted)"

    private let repo: any TimelineRepository

    public init(repo: any TimelineRepository) {
        self.repo = repo
    }

    /// Every visit in the window becomes an entry — a focused app with no capture events is still
    /// activity — and every event is attached to the visit whose span contains it. Adjacent
    /// entries of the same thread (or, when neither has a thread, the same app) are coalesced.
    ///
    /// Visits never overlap in practice: `AppWiring.handleFocusChange` closes all open visits
    /// before opening one. An event inside two overlapping visits would be attached to both,
    /// which is the honest answer for a state that cannot occur.
    public func build(fromMs: EpochMs, toMs: EpochMs) throws -> ActivityTimeline {
        let visits = try repo.appVisits(fromMs: fromMs, toMs: toMs).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.appLabel != $1.appLabel { return $0.appLabel < $1.appLabel }
            return $0.bundleID < $1.bundleID
        }
        let events = try repo.captureEvents(fromMs: fromMs, toMs: toMs).sorted { $0.atMs < $1.atMs }
        let metadata = try repo.threadMetadata(
            threadIDs: Array(Set(events.compactMap(\.threadID))).sorted())

        let raw = visits.map { visit -> BuiltEntry in
            // An open visit runs to the end of the window, not to "now": a timeline must not
            // depend on when it was rendered.
            let endMs = visit.endedAt ?? toMs
            return BuiltEntry(
                bundleID: visit.bundleID,
                entry: Self.entry(
                    appLabel: visit.appLabel, startMs: visit.startedAt, endMs: endMs,
                    events: events.filter { $0.atMs >= visit.startedAt && $0.atMs <= endMs },
                    metadata: metadata))
        }
        return ActivityTimeline(fromMs: fromMs, toMs: toMs, entries: Self.coalesce(raw))
    }

    /// A built entry plus the bundle id it came from. `TimelineEntry`'s field list is pinned by
    /// spec 5d and carries no bundle id, but coalescing needs one (spec 5d again: threadless
    /// entries merge on the bundle, not on the display name), so it rides alongside and is dropped
    /// as soon as coalescing is done.
    struct BuiltEntry: Equatable {
        let bundleID: String
        let entry: TimelineEntry
    }

    static func entry(appLabel: String, startMs: EpochMs, endMs: EpochMs,
                      events: [TimelineRawEvent],
                      metadata: [String: TimelineThreadMeta]) -> TimelineEntry {
        let threadID = events.compactMap(\.threadID).first
        let meta = threadID.flatMap { metadata[$0] }
        let deltas = events.compactMap(\.delta)
        let typings = events.compactMap(\.typing)
        return TimelineEntry(
            startMs: startMs,
            endMs: endMs,
            appLabel: appLabel,
            threadID: threadID,
            sourceTitle: meta?.sourceTitle,
            url: meta?.url,
            kind: meta?.kind ?? .generic,
            cwd: meta?.cwd,
            deltaSummary: deltas.last.flatMap(summary(of:)),
            newItemCount: deltas.reduce(0) { $0 + itemCount(of: $1) },
            typedCount: typings.count,
            typedSample: typings.last.map { String($0.insertedText.prefix(typedSampleCap)) }
        )
    }

    static func itemCount(of delta: CaptureDelta) -> Int {
        delta.addedMessages.count + delta.addedBlocks.count + delta.addedSegments.count
    }

    /// Rendered added content, flattened to one line and capped. Exactly one of the three arrays
    /// is non-empty for any delta (spec 5a), so the order of these branches is not a priority
    /// choice — it is just a switch.
    static func summary(of delta: CaptureDelta) -> String? {
        let rendered: String
        if !delta.addedMessages.isEmpty {
            rendered = delta.addedMessages.map(ContentRenderer.renderMessage).joined(separator: " ")
        } else if !delta.addedSegments.isEmpty {
            rendered = delta.addedSegments.map(ContentRenderer.renderSegment).joined(separator: " ")
        } else if !delta.addedBlocks.isEmpty {
            rendered = ContentRenderer.renderBlocks(delta.addedBlocks)
        } else {
            // `.tasks`/`.calendar` deltas carry only character counts, so there is nothing to
            // quote. `newItemCount` stays 0 and the entry still reports its visit.
            return nil
        }
        let flattened = rendered.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(deltaSummaryCap))
    }

    static func coalesce(_ built: [BuiltEntry]) -> [TimelineEntry] {
        var out: [BuiltEntry] = []
        for candidate in built {
            guard let previous = out.last, mergeable(previous, candidate) else {
                out.append(candidate)
                continue
            }
            // The bundle id of a merged pair is the same on both sides — `mergeable` only merges a
            // threadless pair when they match, and a threaded pair is the same thread, hence the
            // same app.
            out[out.count - 1] = BuiltEntry(bundleID: candidate.bundleID,
                                            entry: merge(previous.entry, candidate.entry))
        }
        return out.map(\.entry)
    }

    /// Same thread, or — when NEITHER has a thread — the same BUNDLE. A threadless entry never
    /// absorbs a threaded one: "the user was in the editor" and "the user edited this document"
    /// are different facts.
    ///
    /// The bundle id, not `appLabel`: `activity_app_visits` stores the pair per visit, not 1:1
    /// across apps, so two bundles can present one display name and must stay two entries
    /// (spec 5d).
    static func mergeable(_ lhs: BuiltEntry, _ rhs: BuiltEntry) -> Bool {
        if let left = lhs.entry.threadID, let right = rhs.entry.threadID { return left == right }
        if lhs.entry.threadID == nil, rhs.entry.threadID == nil {
            return lhs.bundleID == rhs.bundleID
        }
        return false
    }

    /// The later entry wins every single-valued field: a timeline reports the latest state of a
    /// stretch, not its first observation. Counts add.
    static func merge(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> TimelineEntry {
        TimelineEntry(
            startMs: min(lhs.startMs, rhs.startMs),
            endMs: max(lhs.endMs, rhs.endMs),
            appLabel: rhs.appLabel,
            threadID: rhs.threadID ?? lhs.threadID,
            sourceTitle: rhs.sourceTitle ?? lhs.sourceTitle,
            url: rhs.url ?? lhs.url,
            kind: rhs.threadID != nil ? rhs.kind : lhs.kind,
            cwd: rhs.cwd ?? lhs.cwd,
            deltaSummary: rhs.deltaSummary ?? lhs.deltaSummary,
            newItemCount: lhs.newItemCount + rhs.newItemCount,
            typedCount: lhs.typedCount + rhs.typedCount,
            typedSample: rhs.typedSample ?? lhs.typedSample
        )
    }

    // MARK: - Rendering

    /// One line per entry, chronological. When `budgetChars` is exceeded, whole entries are
    /// dropped OLDEST first and `omissionLine` is prepended. The last remaining entry is never
    /// dropped: an over-budget single entry is still reported, the same soft-cap rule Phase A's
    /// budgeting applies to a page's first block.
    public static func render(_ timeline: ActivityTimeline, budgetChars: Int) -> String {
        var lines = timeline.entries.map(line)
        guard !lines.isEmpty else { return "" }
        var omitted = false
        while lines.count > 1, joined(lines, omitted: omitted).count > max(0, budgetChars) {
            lines.removeFirst()
            omitted = true
        }
        return joined(lines, omitted: omitted)
    }

    static func joined(_ lines: [String], omitted: Bool) -> String {
        (omitted ? [omissionLine] + lines : lines).joined(separator: "\n")
    }

    /// `"HH:mm–HH:mm <app>"`, then the terminal's cwd or the quoted source title, then the
    /// truncated url, then `": "` and the semicolon-joined facts. Absent parts are omitted, and
    /// an entry with no facts is just its head.
    static func line(_ entry: TimelineEntry) -> String {
        var head = "\(hhmm(entry.startMs))–\(hhmm(entry.endMs)) \(entry.appLabel)"
        if entry.kind == .terminal {
            head += entry.cwd.map { " (terminal \($0))" } ?? " (terminal)"
        } else if let title = entry.sourceTitle, !title.isEmpty {
            head += " \"\(title)\""
        }
        if let url = entry.url, !url.isEmpty {
            head += " (\(String(url.prefix(urlCap))))"
        }
        var facts: [String] = []
        if let summary = entry.deltaSummary, !summary.isEmpty { facts.append(summary) }
        if entry.newItemCount > 0 {
            facts.append("new since last: \(entry.newItemCount) \(unit(for: entry.kind))")
        }
        if entry.typedCount > 0 {
            var typed = "typed \(entry.typedCount) edits"
            if let sample = entry.typedSample, !sample.isEmpty { typed += " \"\(sample)\"" }
            facts.append(typed)
        }
        return facts.isEmpty ? head : head + ": " + facts.joined(separator: "; ")
    }

    /// Fixed plurals. A rendered line has to be byte-stable across locales and counts, so there is
    /// no pluralisation and no localisation here.
    static func unit(for kind: CaptureContentKind) -> String {
        switch kind {
        case .conversation, .email: return "msgs"
        case .terminal:             return "segments"
        case .task, .calendar:      return "rows"
        default:                    return "paragraphs"
        }
    }

    static func hhmm(_ ms: EpochMs) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `DateFormatter` is thread-safe for formatting on macOS, and a timeline can carry hundreds
    /// of entries — the same reasoning `ContentRenderer.timestampFormatter` records.
    private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
```

- [ ] **Step 4: Run the timeline tests to verify they pass**

Run: `swift test --filter TimelineBuilderTests`
Expected: PASS, 21 tests.

If `testRenderedTerminalLineNamesTheKindAndCwd` fails on the dash, check the separator character: the template uses an EN DASH (`–`, U+2013) between the two times, matching the spec's example line, not a hyphen.

- [ ] **Step 5: Verify the module boundary**

Run: `grep -n "^import" Sources/MaxMiActivity/TimelineBuilder.swift`
Expected: exactly `import Foundation` and `import MaxMiCore`. `MaxMiActivity` has no GRDB, `MaxMiStore` or `MaxMiCapture` dependency in `Package.swift`, so anything else is a build error rather than a style problem — but check it explicitly, because the temptation to reach for `Store` here is the whole reason the protocol exists.

- [ ] **Step 6: Commit**

```bash
git add Sources/MaxMiActivity/TimelineBuilder.swift \
        Tests/MaxMiActivityTests/TimelineBuilderTests.swift
git commit -m "Add TimelineBuilder with deterministic build and budgeted render"
```

---

## Task 9: `StoreTimelineRepository` — the store reads and the payload decoding

The one place that knows both `MaxMiStore` and `MaxMiActivity`. It needs two new store reads, and it owns the JSON decode that `TimelineBuilder` must never see.

**Files:**
- Modify: `Sources/MaxMiStore/ActivityStore.swift` (add `ActivityVisitRecord` + `appVisits(fromMs:toMs:)` in the `// MARK: - Visits` section)
- Modify: `Sources/MaxMiStore/LatestContextStore.swift` (add `latestContextRecords(threadIDs:)`)
- Create: `Sources/MaxMi/StoreTimelineRepository.swift`
- Test: `Tests/MaxMiStoreTests/ActivityStoreTests.swift` (extend)
- Test: `Tests/MaxMiStoreTests/LatestContextStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `Store.captureEvents(fromMs:toMs:) -> [CaptureEventRecord]` and `CaptureEventRecord.payloadJSON` (Task 2); `TimelineRepository`, `TimelineRawEvent`, `TimelineThreadMeta` (Task 8); `Store.placeholders(_ count: Int) -> String` (`QueryAPI.swift:180`); `LatestContextRecord` and the private `record(from:)` mapper (`LatestContextStore.swift:125`); `CapturedContentEnvelope.makeDecoder()`; `CaptureDelta`; `TypingEvent`; `NavigationEventPayload`.
- Produces:
  - `ActivityVisitRecord(id: String, appBundle: String, appLabel: String, startedAtMs: EpochMs, endedAtMs: EpochMs?)`
  - `Store.appVisits(fromMs: EpochMs, toMs: EpochMs) throws -> [ActivityVisitRecord]`
  - `Store.latestContextRecords(threadIDs: [String]) throws -> [String: LatestContextRecord]`
  - `StoreTimelineRepository(store: Store)` conforming to `TimelineRepository`

- [ ] **Step 1: Write the failing store-read tests**

Append to `Tests/MaxMiStoreTests/ActivityStoreTests.swift`, inside the existing class. It already declares `var store: Store!`, `var db: MaxMiDatabase!` and `let t0 = EpochMs(496_000) * 3_600_000`, so both names below resolve:

```swift
    func testAppVisitsInWindowIncludeOverlapsAndOpenVisits() throws {
        _ = try store.openVisit(appBundle: "a", appLabel: "Before", nowMs: t0 - 100_000)
        try store.closeOpenVisits(nowMs: t0 - 90_000)
        let spanning = try store.openVisit(appBundle: "b", appLabel: "Spanning", nowMs: t0 - 10_000)
        try store.closeOpenVisits(nowMs: t0 + 10_000)
        let open = try store.openVisit(appBundle: "c", appLabel: "Open", nowMs: t0 + 20_000)

        let visits = try store.appVisits(fromMs: t0, toMs: t0 + 60_000)
        XCTAssertEqual(visits.map(\.appLabel), ["Spanning", "Open"])
        XCTAssertEqual(visits.map(\.id), [spanning, open], "ids, not just labels")
        XCTAssertNil(visits.last?.endedAtMs)
        XCTAssertEqual(visits.first?.appBundle, "b")
    }

    func testAppVisitsExcludeVisitsThatEndedBeforeTheWindow() throws {
        _ = try store.openVisit(appBundle: "a", appLabel: "Before", nowMs: t0 - 100_000)
        try store.closeOpenVisits(nowMs: t0 - 90_000)
        XCTAssertTrue(try store.appVisits(fromMs: t0, toMs: t0 + 60_000).isEmpty)
    }

    func testAppVisitsExcludeVisitsThatStartAfterTheWindow() throws {
        _ = try store.openVisit(appBundle: "a", appLabel: "After", nowMs: t0 + 90_000)
        XCTAssertTrue(try store.appVisits(fromMs: t0, toMs: t0 + 60_000).isEmpty)
    }
```

Append to `Tests/MaxMiStoreTests/LatestContextStoreTests.swift`, inside the existing class (`private var store: Store!`, `private let t0: EpochMs = 1_800_000_000_000`):

```swift
    func testLatestContextRecordsByThreadIDReturnsOnlyTheRequestedThreads() throws {
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:one", sourceTitle: "One",
                         content: "one"),
            nowMs: t0)
        _ = try store.commitCapture(
            CaptureInput(sourceApp: "Notes", sourceKey: "note:two", sourceTitle: "Two",
                         content: "two"),
            nowMs: t0 + 1_000)
        let one = try store.threadID(forKey: "note:one")
        let two = try store.threadID(forKey: "note:two")

        let records = try store.latestContextRecords(threadIDs: [one, "absent"])
        XCTAssertEqual(Set(records.keys), [one])
        XCTAssertEqual(records[one]?.sourceTitle, "One")

        XCTAssertEqual(try store.latestContextRecords(threadIDs: [one, two]).count, 2)
        XCTAssertTrue(try store.latestContextRecords(threadIDs: []).isEmpty)
    }

    func testLatestContextRecordsResolveTheStructuredShape() throws {
        let page = GenericPage(
            regions: [Region(kind: .main, blocks: [Block(type: .paragraph, text: "body")])],
            focused: nil, url: "https://example.invalid/page")
        _ = try store.commitCapture(
            CaptureEnvelope(
                sourceApp: "Web", sourceKey: "example.invalid/page", sourceTitle: "A page",
                content: "", contentKind: .webpage, parserID: "test", parserVersion: 2,
                accumulationPolicy: .replace, offscreenPolicy: .visibleOnly(),
                trigger: .browserNavigation, truncated: false, structured: .generic(page)),
            nowMs: t0)
        let threadID = try store.threadID(forKey: "example.invalid/page")
        let record = try XCTUnwrap(store.latestContextRecords(threadIDs: [threadID])[threadID])
        guard case .generic(let stored) = record.structured else { return XCTFail("expected generic") }
        XCTAssertEqual(stored.url, "https://example.invalid/page")
        XCTAssertEqual(record.contentKind, .webpage)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "ActivityStoreTests/testAppVisits|LatestContextStoreTests/testLatestContextRecords"`
Expected: compile FAIL — neither read exists.

- [ ] **Step 3: Add `appVisits`**

In `Sources/MaxMiStore/ActivityStore.swift`, add the record type next to `ActivitySession` and the read in the `// MARK: - Visits` section:

```swift
public struct ActivityVisitRecord: Sendable, Equatable {
    public let id: String
    public let appBundle: String
    public let appLabel: String
    public let startedAtMs: EpochMs
    /// nil for a visit that is still open.
    public let endedAtMs: EpochMs?

    public init(id: String, appBundle: String, appLabel: String, startedAtMs: EpochMs,
                endedAtMs: EpochMs?) {
        self.id = id
        self.appBundle = appBundle
        self.appLabel = appLabel
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }
}
```

```swift
    /// Visits that OVERLAP the window, chronologically. An open visit is treated as running to
    /// the end of the window, so a session in progress is not invisible.
    public func appVisits(fromMs: EpochMs, toMs: EpochMs) throws -> [ActivityVisitRecord] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, app_bundle, app_label, started_at, ended_at
                FROM activity_app_visits
                WHERE started_at <= ? AND coalesce(ended_at, ?) >= ?
                ORDER BY started_at ASC, id ASC
                """, arguments: [toMs, toMs, fromMs]).map { row in
                    ActivityVisitRecord(
                        id: row["id"],
                        appBundle: row["app_bundle"],
                        appLabel: row["app_label"],
                        startedAtMs: row["started_at"],
                        endedAtMs: row["ended_at"]
                    )
                }
        }
    }
```

- [ ] **Step 4: Add `latestContextRecords(threadIDs:)`**

In `Sources/MaxMiStore/LatestContextStore.swift`, add next to the other reads. The SELECT list is the same one the existing reads use, so `record(from:)` maps it unchanged:

```swift
    /// The stored contexts for a set of threads, keyed by thread id. Duplicates and unknown ids
    /// are harmless; the returned dictionary simply has fewer keys than were asked for.
    public func latestContextRecords(threadIDs: [String]) throws -> [String: LatestContextRecord] {
        let ids = Array(Set(threadIDs)).sorted()
        guard !ids.isEmpty else { return [:] }
        return try db.dbQueue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT c.thread_id, t.source_app, t.source_key, t.source_title,
                       c.content_ciphertext, c.structured_ciphertext, c.content_kind,
                       c.parser_id, c.parser_version,
                       c.accumulation_policy, c.offscreen_mode, c.offscreen_max_steps,
                       c.offscreen_max_chars, c.trigger, c.captured_at,
                       c.character_count, c.truncated, c.display_summary_ciphertext,
                       c.summary_status
                FROM latest_contexts c JOIN threads t ON t.id = c.thread_id
                WHERE c.thread_id IN (\(Store.placeholders(ids.count)))
                """, arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.compactMap(record(from:)).map { ($0.id, $0) })
        }
    }
```

- [ ] **Step 5: Run the store-read tests to verify they pass**

Run: `swift test --filter "ActivityStoreTests|LatestContextStoreTests"`
Expected: PASS except the known-red `ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`.

- [ ] **Step 6: Implement the adapter**

Create `Sources/MaxMi/StoreTimelineRepository.swift`:

```swift
import Foundation
import MaxMiActivity
import MaxMiCore
import MaxMiStore

/// The concrete `TimelineRepository`. This is the only type that knows both `MaxMiStore` and
/// `MaxMiActivity`, so it also owns the payload JSON decode: `TimelineBuilder` never sees JSON.
///
/// `@unchecked Sendable` for the same reason `StoreActivitySummaryRepository` is: `Store` wraps a
/// GRDB `DatabaseQueue`, which serialises its own access.
struct StoreTimelineRepository: TimelineRepository, @unchecked Sendable {
    let store: Store

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        try store.appVisits(fromMs: fromMs, toMs: toMs).map {
            (bundleID: $0.appBundle, appLabel: $0.appLabel,
             startedAt: $0.startedAtMs, endedAt: $0.endedAtMs)
        }
    }

    /// A payload that will not decode yields an event with nil payload fields rather than being
    /// dropped: the fact that something happened at that moment is still true.
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] {
        let decoder = CapturedContentEnvelope.makeDecoder()
        return try store.captureEvents(fromMs: fromMs, toMs: toMs).map { record in
            let data = record.payloadJSON.map { Data($0.utf8) }
            return TimelineRawEvent(
                kind: record.kind,
                atMs: record.atMs,
                threadID: record.threadID,
                trigger: record.trigger,
                delta: record.kind == .contentDelta
                    ? data.flatMap { try? decoder.decode(CaptureDelta.self, from: $0) }
                    : nil,
                typing: record.kind == .typing
                    ? data.flatMap { try? decoder.decode(TypingEvent.self, from: $0) }
                    : nil,
                toURL: record.kind == .navigation
                    ? data.flatMap { try? decoder.decode(NavigationEventPayload.self, from: $0) }?.toURL
                    : nil
            )
        }
    }

    /// `kind` comes from `latest_contexts.content_kind`, which is authoritative and overridable
    /// (spec 12 Q3) — never from the structured shape. Only `url` and `cwd` are read out of the
    /// shape, because no column carries them.
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        try store.latestContextRecords(threadIDs: threadIDs).mapValues { record in
            var url: String?
            var cwd: String?
            switch record.structured {
            case .generic(let page):   url = page.url
            case .document(let value): url = value.url
            case .terminal(let value): cwd = value.cwd
            default:                   break
            }
            return TimelineThreadMeta(
                sourceApp: record.sourceApp,
                sourceTitle: record.sourceTitle,
                kind: record.contentKind,
                url: url,
                cwd: cwd
            )
        }
    }
}
```

- [ ] **Step 7: Build and run the suite**

Run: `swift build 2>&1 | grep -E "error:|warning:"`
Expected: no output. `StoreTimelineRepository` has no production caller yet — Phase C's prompt rewiring is what consumes the timeline (§6b/§6d) — and Swift emits **no** warning for an unconstructed internal type or an unread stored property, so silence here is not evidence that the adapter works. What proves it is that it compiles against `TimelineRepository`: a missing or mistyped method is a conformance **error**, not a warning. Nothing else in this plan constructs it; that is deliberate and is stated in Task 10's live checklist.

Run: `swift test 2>&1 | tail -20`
Expected: exactly the 3 known-red failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/MaxMiStore/ActivityStore.swift Sources/MaxMiStore/LatestContextStore.swift \
        Sources/MaxMi/StoreTimelineRepository.swift \
        Tests/MaxMiStoreTests/ActivityStoreTests.swift \
        Tests/MaxMiStoreTests/LatestContextStoreTests.swift
git commit -m "Add the store-backed timeline repository"
```

---

## Task 10: Full suite, rebuild, and live verification

Phase B's write sites live in `AppWiring`, which has no unit-test target in `Package.swift`. The suite proves the pure parts; only a live run proves that events actually land, that typing is captured from a real composer, and that the retention gate does not fire on every capture.

**Files:**
- No source changes. Any fix this task uncovers is committed with a message naming what it fixed.

**Interfaces:**
- Consumes everything Tasks 1–9 produced. Produces nothing.

- [ ] **Step 1: Run the full suite in debug**

Run the suite once and keep the output, so the count check below reads the same run:

```bash
swift test 2>&1 | tee /tmp/m8b-suite.txt | tail -40
```

Expected: exactly 3 failures, and they are:
- `ActivityStoreTests.testNewSourceActivitySummaryWaitsForCloudReview`
- `CaptureDisplaySummarizerTests.testConversationSummaryUsesTrailingMessages`
- `PauseSettingsTests.testNewSourceIsHeldFromCloudUntilReviewed`

For reference the executed count should be about **805**: 689 baseline, plus 117 added
(11 `CaptureDeltaSignalsTests` + 1 `GenericV2ParserTests`; 6 `MigrationV11Tests`;
12 `CaptureEventStoreTests` in Task 2 and 9 more in Task 4; 3 `MemoryDataControlsTests` +
1 `CapturePrivacyCopyTests`; 27 `TypingObserverTests`; 10 `ComposerDraftTests` +
2 `GenericPageExtractorTests`; 9 `GenericPageBudgetTests`; 21 `TimelineBuilderTests`;
3 `ActivityStoreTests` + 2 `LatestContextStoreTests`), minus 1 removed
(`MigrationV10Tests.testCurrentIdentifierIsV10`, Task 2 Step 5).

**That total is information, not a gate.** A whole-suite count drifts with every unrelated commit and
cannot tell you *which* file went missing. The check that actually catches the failure it is meant to
catch — a new test file that never got compiled into a target — counts per class. XCTest prints one
`Test Case '-[<Module>.<Class> <method>]' passed` line per test, so:

```bash
for c in CaptureDeltaSignalsTests:11 MigrationV11Tests:6 CaptureEventStoreTests:21 \
         CapturePrivacyCopyTests:1 TypingObserverTests:27 ComposerDraftTests:10 \
         GenericPageBudgetTests:9 TimelineBuilderTests:21; do
  name=${c%%:*}; want=${c##*:}
  got=$(grep -c "\.${name} " /tmp/m8b-suite.txt)
  # Each test prints a "started" and a "passed"/"failed" line, so the raw count is doubled.
  got=$(( got / 2 ))
  [ "$got" -ge "$want" ] && echo "ok   $name $got" || echo "SHORT $name $got, wanted $want"
done
```

Expected: eight `ok` lines. `SHORT <name> 0` means that file is not in a target `Package.swift`
compiles — `Tests/MaxMiTests/` is **not** a target and nothing may be placed there.
`GenericPageBudgetTests` is a pre-existing class that only gained tests, so its number is a floor
rather than an equality — which is why the comparison is `-ge`.

- [ ] **Step 2: Confirm zero warnings**

Run: `swift build 2>&1 | grep warning:`
Expected: no output.

- [ ] **Step 3: Confirm the release perf bound still holds**

Run: `swift test -c release --filter GenericPageExtractorPerformanceTests 2>&1 | tail -10`
Expected: PASS. Task 7 added one `firstIndex` scan over the `.main` region per extraction and no extra rendering, so the 150 ms / 20k-node bound has ample headroom.

- [ ] **Step 4: Rebuild the app bundle**

Build the **worktree**, not `/Users/mafex/code/personal/MaxMi`, which is a different checkout on
branch `main` and does not contain any of this work:

```bash
cd /Users/mafex/code/personal/MaxMi/.worktrees/m8b-deltas-events-typing
git rev-parse --abbrev-ref HEAD   # must print m8b-deltas-events-typing
./packaging/make-app.sh
pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi" || true
sleep 2
open MaxMi.app
START_MS=$(( $(date +%s) * 1000 ))
echo "START_MS=$START_MS  ($(date '+%H:%M:%S'))"
```

**No `tccutil reset`.** Signed builds keep the Accessibility grant across rebuilds; resetting it
would force a re-grant for no reason.

Record `START_MS`. `capture_events.at_ms` is epoch **milliseconds**, so `HH:MM:SS` is not a value any
query below can use — every live check must compare against `START_MS` and trust only rows strictly
after it. Keep the shell open so `$START_MS` stays in scope, or write it down.

Confirm the new process:

```bash
pgrep -f "MaxMi.app/Contents/MacOS/MaxMi"
```

- [ ] **Step 5: Confirm the events table is populated**

Use the read-only MCP server (`mcp__maxmi__get_latest_context`) to confirm captures are landing after the recorded start time, then read the events directly. The DB path is `~/Library/Application Support/MaxMi/maxmi.db`; open it read-only so capture is never blocked:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT kind, count(*) FROM capture_events GROUP BY kind ORDER BY 2 DESC;"
```

Expected, after switching between a browser, a terminal and a chat app for a couple of minutes:
- `focus` rows — one per frontmost change
- `content_delta` rows — one per committed capture that changed something
- `navigation` rows — after visiting two pages in one browser tab
- `typing` rows — after typing into a composer (Step 6)
- `dialog` rows only if a sheet actually appeared; their absence is not a failure

Also confirm `hour_bucket` and `payload_ciphertext` look right:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT kind, at_ms, app_bundle, thread_id IS NULL AS no_thread,
          substr(payload_ciphertext,1,7)
   FROM capture_events ORDER BY at_ms DESC LIMIT 10;"
```

Expected: every `payload_ciphertext` starts with `enc:v1:`, and every row has a non-null
`app_bundle`.

`no_thread` is `1` for **`focus` rows and for early `typing` rows**, not for `focus` alone: a `focus`
event fires before any thread exists for that window (spec §12 Q4), and a poll-path `typing` event
has no capture behind it, so it carries a thread only once a capture of that same field has committed
and `recordTypingEvent` has remembered its thread id (Task 6 Step 9). So the shape to expect is:

- `focus` — always `no_thread = 1`
- `typing` — `1` for the first value changes in a field, then `0` once that field has been captured
- `content_delta`, `dialog`, `navigation` — always `0`; these only exist for a committed capture

A `content_delta` row with `no_thread = 1` is a real bug: `Store.threadID(sourceApp:sourceKey:)`
returned nil for a thread that was just committed.

- [ ] **Step 6: Confirm typing reaches structured content**

Open Slack (or WhatsApp), type a short invented sentence into the composer, and **do not send it**. Wait for the next capture (the periodic sweep is 30 s for registered parsers), then:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT count(*) FROM capture_events WHERE kind='typing' AND at_ms > $START_MS;"
```

Expected: at least one row, and materially fewer rows than characters typed. Two 800 ms gates make
that true and they fail differently, so distinguish them if the count looks wrong:

- `TypingPollGate` (Task 5) caps how often an AX **read** happens, per app.
- `TypingObserver.debounceMs` caps how often an **event** is emitted, per field.

A row per keystroke means the emit debounce is not being applied. A visible main-thread stall or fan
spin while an unrelated app animates a progress bar means the poll gate is not — check that
`onAXNotification` calls `handleValueChangeNotification` and not `pollFocusedFieldTyping` directly.

Then read the capture itself through MCP `get_latest_context` for that thread and confirm the rendered content ends with a draft line:

```
(From: You (draft)) <the sentence you typed>
```

For a document app (Notes, or any generic-fallback app with a text area), confirm instead that the focused paragraph is marked. `authoredByUser` is not rendered, so check the stored JSON:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT substr(structured_ciphertext,1,7) FROM latest_contexts ORDER BY captured_at DESC LIMIT 3;"
```

Expected `enc:v1:` — the payload itself is encrypted, so the `authoredByUser` check is the unit test in Task 6 Step 1, not a live grep. Do not add a plaintext dump path to verify it.

- [ ] **Step 7: Confirm the retention gate is not firing per capture**

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT value FROM settings WHERE key='capture_events_last_trim_at';"
```

Expected: one value, and it does **not** advance on every capture. Read it, capture a few more windows, read it again — it must be unchanged until an hour has passed. An advancing value means the gate comparison is inverted and every capture is paying for a DELETE.

- [ ] **Step 8: Confirm the Privacy copy is visible**

Open MaxMi's Privacy settings and confirm the retention card reads "Activity events are kept for 30 days." under the existing "Older memories are removed when you run cleanup in Data Controls." line.

- [ ] **Step 9: Confirm nothing is recorded for an excluded app**

This is exit criterion 4's second half — "nothing is written for a denylisted, excluded, or
non-consented app" — and the plaintext `app_bundle` column exists so that it is a query rather than a
guess. Before the column, the only app identifier in a row was inside the encrypted `focus` payload
and a bare `count(*)` could not attribute anything.

Pick an app that is currently being captured, note its bundle id, and record the moment you exclude it:

```bash
BUNDLE="com.tinyspeck.slackmacgap"   # whichever app you are about to exclude
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT count(*) FROM capture_events WHERE app_bundle='$BUNDLE';"
```

Expected: a non-zero count — the app is being recorded right now, which is what makes the next step
meaningful. Now exclude it in Activity privacy settings, and record the cutoff:

```bash
EXCLUDED_MS=$(( $(date +%s) * 1000 ))
echo "EXCLUDED_MS=$EXCLUDED_MS"
```

Focus that app, type a sentence in it, switch away and back so a capture is attempted, wait 60 s, then:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT kind, count(*) FROM capture_events
   WHERE app_bundle='$BUNDLE' AND at_ms > $EXCLUDED_MS GROUP BY kind;"
```

Expected: **no rows at all.** Any row here is `isActivityEligible` failing on the real path — either a
write site that does not call it, or `recordCaptureEvents` re-deriving it instead of using the
`eligible` it was handed.

Then confirm the rest of the world kept working, so the gate is not simply off for everyone:

```bash
sqlite3 "file:$HOME/Library/Application Support/MaxMi/maxmi.db?mode=ro" \
  "SELECT app_bundle, count(*) FROM capture_events
   WHERE at_ms > $EXCLUDED_MS GROUP BY app_bundle ORDER BY 2 DESC;"
```

Expected: rows for other apps, and the excluded bundle absent from the list.

- [ ] **Step 10: Confirm no event tap shipped**

```bash
nm -u MaxMi.app/Contents/MacOS/MaxMi | grep -iE "CGEventTap|EventTapCreate|addGlobalMonitor" || echo "clean"
```

Expected: `clean`. This is exit criterion 5 at the binary level; the source-level grep is `TypingObserverTests.testNoEventTapAnywhereInSources`.

- [ ] **Step 11: Record the result and commit any fixes**

If Steps 5–10 all pass, Phase B is done. Note in the SDD progress ledger:
- the process start time used for verification
- the per-kind event counts observed
- the typing-row count versus characters typed (the debounce evidence)
- the excluded bundle id, its `EXCLUDED_MS`, and the empty result that proves criterion 4
- that `StoreTimelineRepository` has no production caller yet, by design: Phase C (§6b, §6d) is what feeds the timeline into `DisplaySummarizer` and `HourlyAgent`

If any step fails, fix it, re-run Step 1, rebuild, and re-verify the failing step only. Commit each fix on its own:

```bash
git add <the files you changed>
git commit -m "<what the fix does, plain imperative>"
```

---

## What Phase B deliberately does not do

Stated so a reviewer does not read these as gaps.

- **Nothing consumes the timeline yet.** `StoreTimelineRepository` and `TimelineBuilder` are built and tested here; wiring them into `DisplaySummarizer` and `HourlyAgent` is Phase C (§6b, §6d). §10 makes this explicit: "B alone ships the event log and timeline with today's prompts".
- **No prompt changes.** `CaptureDisplaySummarizer`, `DisplaySummarizer`, `ExtractPrompt` and `HourlyAgent` are untouched. `CaptureDisplaySummaryFormat.fallback(app:title:)` (§12 Q7) and the `CaptureSummaryStore` invalidation-predicate generalisation (§12 Q8) are Phase C.
- **No new MCP surface.** `search_memory`, `list_active_threads`, `get_latest_context` and `meeting_memory` keep their request and response shapes. `capture_events` is not exposed over MCP in M8.
- **No raw-content embedding.** §12 Q15 settled facts-only embedding for M8; Phase B adds no `vec0` table. Phase C's `context_embeddings` migration takes `v12`.
- **No reminder slots.** §12 Q9 dropped the slot legend from M8 entirely; it arrives with M9's todo panel, which adds the columns and the legend together.
- **Per-parser composer anchors stay generic.** §5c names Phase D's per-parser configs as the eventual source of the composer anchor. Task 6 implements the generic rule (the focused text field with no `AXList`/`AXOutline`/`AXTable` ancestor), which is what §5c specifies for the generic path.
- **Group-chat sender attribution is still incomplete.** Inherited from Phase A Task 11: WhatsApp group chats leave third-party senders unknown until Phase D's anchored parsers read the participant list. A draft is always attributed to `You`, which is correct regardless.
- **The Capture Health window does not show events.** `recentCaptureEvents` exists so it can, and §10 says "visible in the Capture Health window" — but that is a UI addition with no spec-pinned layout, and adding it here would put an unreviewed view between Phase B and Phase C. The data is queryable; the view is not in this plan.
