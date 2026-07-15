# Phase 7 — Reliability, Live Parity, and Distribution Plan

**Status:** in progress; Batches 7.0–7.3 and 7.5 complete; Batch 7.4 has live
voice-note/termination evidence and still needs a controlled two-sided meeting
**Created:** 2026-07-15  
**Depends on:** Phases 0–6 on `main` through `4e14b37`  
**Reference:** Minimi 1.0.59

## 1. Why this plan exists

MaxMi now resembles Minimi at the feature and architecture level. It has encrypted
capture, content-aware accumulation, browser and native parsers, meetings and voice
notes, Activity, action items, tray summaries, privacy controls, and MCP retrieval.

That is not yet the same as dependable daily-use parity. Several paths are implemented
and covered by fixtures but have not been proven against the current versions of the
real applications on this Mac. MaxMi also lacks the soak, recovery, performance, and
release evidence needed to claim that it can run continuously like Minimi.

This document converts the remaining parity gap and the high-level Phase 7 roadmap in
`MINIMI_MAXMI_PARITY_BLUEPRINT.md` into ordered implementation batches.

## 2. Current baseline

At the start of Phase 7:

- Phases 0–6 are implemented on `main`.
- The automated suite passes 446 tests.
- The signed development app launches and captures on this Mac.
- The latest recorded live database baseline is 646 threads, 973 versions, and 646
  latest contexts with an `ok` SQLite integrity check.
- Capture Health is bounded and content-free.
- Backup-before-delete/retention, plaintext export, and delete-all exist.
- A Developer-ID/notarization script exists, but no notarized release has been proven.
- Browser, native-parser, meeting/audio, and real Claude recall matrices still contain
  pending live acceptance work.
- No seven-day soak or explicit CPU, memory, disk, queue, and helper-process budgets
  have been signed off.

The baseline must be refreshed at Phase 7 start without printing captured content.

## 3. Definition of dependable Minimi parity

Phase 7 is complete only when all of these statements are supported by evidence:

### Capture completeness

- Every browser used daily is routed through strict browser capture.
- High-value installed applications produce meaningful structured context or have an
  explicitly accepted generic fallback.
- Tab changes, SPA navigation, focus changes, edits, and bounded scrolling recapture
  within their declared latency.
- Scrolling does not erase previously accumulated conversation/document context.
- Skips and failures are visible in content-free diagnostics.

### Meetings and voice

- A controlled two-person meeting records both sides once and in order.
- System-audio denial reliably falls back to microphone-only mode.
- Input-device changes do not leave duplicate taps, observers, or helper processes.
- Start, stop, skip, timeout, app crash, and relaunch all clean up resources.
- Persisted meetings and voice notes are visible in the app and retrievable over MCP.

### Memory and retrieval

- Latest raw context and semantic facts remain distinct and useful.
- Claude can answer controlled fresh-context, learned-fact, structured task/calendar,
  and meeting-recall prompts with correct source/time filtering.
- Backup restore and version migration preserve encrypted data.
- Retry queues recover after network/process failure and remain bounded.

### Reliability and privacy

- Seven continuous days do not cause runaway CPU, memory, disk, queues, recordings,
  observers, or child processes.
- Logs and diagnostics contain identifiers and safe error categories, never captured
  text, titles, URLs, transcripts, prompts, API credentials, or MCP responses.
- Pause, block, review, and local-only choices survive relaunch and remain reversible.
- A distributed build does not contain a reusable Gemini provider secret.

### Distribution

- Upgrade and clean-install tests pass on a fresh user or second Mac.
- The chosen update flow has an explicit trust policy.
- A distributed artifact is Developer-ID signed, notarized, stapled, and accepted by
  Gatekeeper.

## 4. Delivery strategy

Work is divided into small batches. Each batch should be committed independently, keep
the full test suite green, update its evidence document, and avoid destructive live
operations unless the user explicitly approves them.

### Batch 7.0 — Freeze and measure the starting baseline

**Status:** complete on 2026-07-15 (`8cfbcd0`).

**Purpose:** make later reliability claims comparable.

Implementation:

1. Add `tools/check-phase7-baseline.sh` with content-free output only.
2. Record app version, commit, schema migrations, database integrity, aggregate row
   counts, retry counts/oldest age, log sizes, recording temp files, and MaxMi-related
   process inventory.
3. Create a mode-`0600` SQLite backup before Phase 7 migrations.
4. Record installed browser/native-app versions without opening private content.
5. Add `docs/PHASE7_LIVE_VERIFICATION.md` as the evidence ledger.

Tests:

- script rejects or omits forbidden content columns;
- script works with an explicit `MAXMI_DB_PATH` fixture;
- database is opened read-only for reporting.

Acceptance:

- baseline report contains no user content;
- integrity is `ok` and the backup opens read-only;
- the working tree and app version are recorded.

### Batch 7.1 — Structured rotating logs and lifecycle diagnostics

**Status:** complete on 2026-07-15 (`89ea48a`, `70c73d4`, `8f52aaf`).

**Purpose:** diagnose long-running failures without exposing captured data.

Implementation:

1. Introduce a single logging facade with typed subsystem, event, severity, safe error
   code, parser ID, trigger, outcome, duration, and aggregate counts.
2. Prohibit free-form captured strings at the logging API boundary.
3. Write rotating local logs under Application Support with restrictive permissions.
4. Use a bounded policy such as five 5 MiB files; confirm the exact budget through a
   stress test.
5. Replace capture-, worker-, meeting-, MCP-, and migration-path `NSLog` calls with
   structured safe events.
6. Add a Settings action to reveal or export a redacted diagnostics bundle containing
   logs, versions, permissions state, process counts, health aggregates, and schema
   state—but no memory content.

Tests:

- rotation and retention;
- mode/permissions;
- concurrent writes;
- forbidden-field and secret redaction tests;
- diagnostics archive schema and content audit.

Acceptance:

- forced capture/parser/network/audio failures produce actionable safe events;
- a repository-wide audit finds no content-bearing values passed to logs;
- log storage remains within its configured bound.

### Batch 7.2 — Crash and process cleanup

**Status:** complete on 2026-07-15. See `PHASE7_RESOURCE_LIFECYCLE.md`.

**Purpose:** ensure capture and audio resources cannot leak across failure paths.

Implementation:

1. Inventory every task, timer, notification observer, audio tap, ScreenCaptureKit
   stream, temporary recording, and child process with an owner and shutdown path.
2. Add an application lifecycle coordinator for normal termination, session stop,
   sleep, wake, fast user switching, and unexpected previous-run recovery.
3. Persist only minimal content-free session state required to detect an interrupted
   meeting/voice recording.
4. On launch, clean stale temporary files and finalize or quarantine recoverable audio
   without silently uploading it.
5. Make stop/cancel idempotent and enforce a maximum shutdown deadline.
6. Add watchdog counters for active audio engines, streams, observers, and helper PIDs.

Tests:

- repeated start/stop/cancel;
- failure at each audio initialization stage;
- device change during capture;
- app termination during prompt/record/transcribe/persist;
- launch recovery with stale session metadata and temp files;
- no duplicate observers/taps after recovery.

Acceptance:

- zero MaxMi audio/helper processes remain after stop or app exit;
- relaunch can start a new meeting/voice note successfully;
- stale resources are reported and bounded rather than silently accumulated.

### Batch 7.3 — Live capture parity matrix

**Status:** implementation and installed-app route matrix complete on 2026-07-15;
deep-history and broader SPA soak remain Phase 7.9 evidence items.

**Purpose:** prove that implemented parsers capture the apps actually used.

Implementation and verification:

1. Complete the browser matrix for installed Zen, Safari, Chrome, and Arc builds.
2. For each browser verify launch/focus, URL identity, tab switch, SPA navigation,
   page load, focused address-bar typing protection, blocked URL classes, and one
   controlled scrolling/accumulation scenario.
3. Complete installed native-app checks for WhatsApp, Mail, Calendar, Reminders, and
   Fantastical with a representative non-private fixture/test item selected.
4. Mark uninstalled parsers as fixture-tested—not live-verified.
5. Compare Capture Health parser IDs, outcomes, latency, and quality with the expected
   route after every scenario.
6. Fix any fallback to generic capture that loses meaningful structure.

Acceptance:

- every installed daily browser has a dated passing row;
- every installed high-value app has a parser-specific passing row or a documented,
  accepted limitation;
- controlled scroll tests show retained earlier context;
- blocked/sensitive pages produce skip outcomes without stored content.

### Batch 7.4 — Meeting and voice live acceptance

**Purpose:** close the largest unproven real-device path.

Verification order:

1. Microphone-only voice note.
2. Browser meeting detection without recording.
3. Mic-only controlled meeting.
4. System-audio plus mic controlled two-person meeting.
5. Screen Recording denied/revoked fallback.
6. Audio-device switch while recording.
7. Four stop paths: explicit stop, meeting-ended grace, skip, and app termination.
8. Recording history, summary/facts, local search, and MCP retrieval.

Rules:

- use synthetic or controlled speech, not a private real meeting;
- do not print transcripts during verification;
- compare only duration, source counts, speaker-side presence, ordering, status, and
  retrieval identifiers.

Acceptance:

- both sides appear once in chronological order in the controlled mixed recording;
- every stop/failure path releases resources;
- recording persists encrypted and is retrievable through the app and MCP;
- mic-only fallback is clear to the user.

### Batch 7.5 — Backup restore, repair, and migration rollback

**Purpose:** make recovery operational rather than theoretical.

**Completed 2026-07-15:** the `SQLITE_CANTOPEN` blocker was traced to copied databases
retaining WAL journal mode while being reopened read-only without persistent sidecars.
Backups are now finalized in portable `DELETE` journal mode. Restore validates and
migrates a disposable writable copy, never the selected backup, then a signed helper
waits for MaxMi to exit, preserves the current database, performs an atomic same-volume
replacement, writes a content-free outcome, and relaunches the app.

Implementation:

1. Add a read-only integrity/diagnostics action.
2. Validate and migrate a disposable copied database before handing atomic replacement
   to the post-exit recovery helper.
3. Add repair guidance for SQLite corruption; never mutate the only copy.
4. Define a migration manifest containing version, preconditions, verification, and
   rollback/restore instructions.
5. Make every future migration start from a consistent backup and finish with
   integrity plus invariant checks.
6. Add version N-1 fixtures and an upgrade test that verifies encrypted rows, latest
   contexts, facts, settings, recordings, and vector dimensions.

Tests:

- successful restore;
- corrupt/incompatible backup rejection;
- interrupted atomic replacement;
- migration replay/idempotency;
- N-1 to current upgrade;
- rollback by restoring the pre-migration backup.

Acceptance:

- a copied test corpus can be backed up, upgraded, restored, and queried;
- failure never destroys the current and backup copies;
- the procedure is documented and repeatable.

### Batch 7.6 — Performance, battery, and queue bounds

**Purpose:** establish measurable continuous-use budgets.

Implementation:

1. Add content-free counters for capture attempts/outcomes, parser duration, worker
   queue depth/oldest age, Gemini request rate, audio buffer pressure, database size,
   log size, and temporary recording size.
2. Add a diagnostics sampler for app RSS, CPU time, wakeups where available, open file
   descriptors, task counts, and MaxMi helper PIDs.
3. Profile idle menu-bar operation, active browsing, rapid tab switching, native
   document editing, meeting recording, transcription, and MCP queries.
4. Remove hot polling, duplicate work, unbounded task creation, and oversized capture
   payloads discovered by the profiles.
5. Establish provisional budgets and revise them only with recorded evidence:
   - no monotonic RSS growth over an eight-hour controlled run;
   - no unbounded retry/summary/action queue growth;
   - logs remain within the rotation cap;
   - capture-health remains at its 500-row bound;
   - no orphan process, audio stream, observer, or temp recording after stop;
   - idle CPU and wakeups are comparable to a normal menu-bar utility on this Mac.

Acceptance:

- before/after profiles are attached to the evidence ledger;
- every queue and disk surface has an explicit bound or retention policy;
- regressions can be detected with a repeatable script.

### Batch 7.7 — Secure Gemini distribution architecture

**Purpose:** remove the need for end users to supply a provider credential without
shipping a reusable Gemini key inside a public macOS bundle.

Decision:

- Personal development builds may continue to use owner-controlled local runtime
  configuration.
- Distributed builds must use a MaxMi-controlled relay or short-lived scoped token.
- A static provider key must not be committed, copied into app resources, compiled
  into the binary, or treated as protected by obfuscation/Keychain after distribution.

Implementation:

1. Define the minimal relay contract for extraction, display summaries, embeddings,
   activity, action items, and meeting processing.
2. Add per-install authentication, request size limits, rate limits, quotas, key
   rotation, abuse controls, and revocation.
3. Preserve existing source-review and consent gates before plaintext leaves the Mac.
4. Log metadata only; never retain captured content by default.
5. Add fail-closed behavior and clear local-only degradation when the relay is offline.
6. Keep provider and model routing server-side.

Acceptance:

- extracting the app bundle yields no reusable provider credential;
- a revoked install cannot use the relay;
- offline/local capture and latest-context browsing still work;
- privacy disclosure accurately describes the network path and retention.

### Batch 7.8 — Update trust and release pipeline

**Purpose:** make shared builds installable and upgradable safely.

Implementation:

1. Choose either a signed automatic updater or an explicit manual release channel.
2. For manual releases, publish a signed version manifest and SHA-256 checksum over
   HTTPS; Settings must link to the official release rather than pretending to check.
3. Align the single source of version truth across Swift, Info.plist, DMG name, and
   release notes.
4. Make `release.sh` verify tests, clean state, signature identity, hardened runtime,
   entitlements, bundled helper signatures, notarization, stapling, checksum, and
   Gatekeeper assessment.
5. Run clean-install and N-1 upgrade tests on a fresh macOS user or second Mac.
6. Document permission prompts, Keychain behavior, uninstall, data location, backup,
   restore, and rollback.

External prerequisites:

- paid Apple Developer Program membership;
- Developer ID Application certificate;
- notarization credentials;
- second Mac or controlled fresh-user test environment;
- hosted release endpoint if updates are offered.

Acceptance:

- the DMG is Developer-ID signed, notarized, stapled, and Gatekeeper-approved;
- both binaries satisfy designated requirements;
- clean install and upgrade preserve expected data and permissions behavior;
- the release checklist can be followed by someone other than the implementer.

### Batch 7.9 — Seven-day soak and parity sign-off

**Purpose:** prove routine-use reliability.

Daily checks:

1. Process/helper inventory.
2. RSS/CPU/wakeup trend.
3. Database/log/temp-file sizes.
4. Queue counts and oldest pending item.
5. Capture Health outcomes by reason/parser.
6. One controlled latest-context recall prompt.
7. One controlled semantic recall prompt.
8. Pause/privacy state check after at least one relaunch during the week.

The soak must include browsing, native apps, sleep/wake, network loss/recovery, at least
one voice note, one controlled meeting, MCP queries, and an application upgrade or
relaunch. Private captured content must not be copied into the evidence document.

Acceptance:

- no unexplained monotonic resource growth;
- no orphan helpers or stuck audio session;
- no silently stalled capture/worker queue;
- restore drill succeeds from a soak-period backup;
- every installed daily-use parser retains a passing live-verification row;
- all remaining limitations are explicitly accepted or moved to a dated follow-up.

## 5. Required evidence artifacts

Phase 7 should produce and maintain:

- `docs/PHASE7_LIVE_VERIFICATION.md` — content-free baseline, live matrices, profiles,
  restore drill, soak log, and final sign-off;
- `docs/RELEASE_CHECKLIST.md` — repeatable local/distribution release procedure;
- `tools/check-phase7-baseline.sh` — aggregate read-only baseline;
- `tools/check-runtime-health.sh` — repeatable process/resource/queue check;
- scrubbed fixtures for every bug found during live parser verification;
- automated tests for every reliability fix;
- a release artifact manifest containing version, commit, hashes, signature, and
  notarization result.

## 6. Commit and verification policy

Recommended commit sequence:

1. `feat(logging): add bounded privacy-safe runtime logs`
2. `fix(lifecycle): clean up capture and audio resources`
3. `test(capture): complete installed app live parity matrix`
4. `test(meetings): verify real-device recording lifecycle`
5. `feat(recovery): add validated backup restore and migration rollback`
6. `perf(runtime): bound queues disk and background work`
7. `feat(relay): route distributed AI requests through scoped service`
8. `build(release): enforce signed notarized release checks`
9. `docs(reliability): record seven-day soak and parity sign-off`

Before each push:

- run focused tests for the changed subsystem;
- run the full Swift test suite;
- run `git diff --check`;
- build and verify the signed app when runtime code changed;
- relaunch for live checks without resetting macOS permissions;
- record only aggregate/content-free evidence.

## 7. Work that requires explicit user participation

The following cannot be truthfully automated or inferred:

- selecting controlled representative content in installed applications;
- granting/revoking Accessibility, microphone, and Screen Recording permissions;
- running a controlled two-person meeting/audio test;
- approving destructive restore tests against anything other than a copied corpus;
- providing Apple Developer/notarization credentials;
- choosing and funding a hosted AI relay;
- performing the second-Mac/fresh-user install test;
- completing the seven-day real-use soak.

## 8. Final Phase 7 exit checklist

- [ ] Structured logs are bounded, private, and useful.
- [ ] Audio/tasks/timers/observers/helpers clean up after every stop and crash path.
- [ ] Installed browser and native-app matrices pass.
- [ ] Controlled meeting and voice-note paths pass on real hardware.
- [ ] Backup restore and N-1 migration drills pass.
- [ ] Runtime resources, queues, and disk surfaces are bounded.
- [ ] Distributed builds contain no reusable Gemini provider key.
- [ ] Update/release trust policy is implemented.
- [ ] Clean-install and upgrade checks pass.
- [ ] Seven-day soak passes.
- [ ] Developer-ID/notarization/Gatekeeper checks pass if distributing.
- [ ] Known limitations and accepted deviations from Minimi are documented.
