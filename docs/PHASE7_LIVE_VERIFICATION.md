# Phase 7 live verification

**Status:** Batches 7.0–7.3 complete; Batch 7.4 pending
**Started:** 2026-07-15  
**Plan:** [`PHASE7_RELIABILITY_PARITY_PLAN.md`](PHASE7_RELIABILITY_PARITY_PLAN.md)

This ledger contains only aggregate, content-free evidence. It must not contain captured
text, source keys, source titles, URLs, facts, summaries, transcripts, prompts, provider
credentials, MCP responses, or private application content.

## Batch 7.0 baseline

Run:

```bash
tools/check-phase7-baseline.sh
```

The checker opens SQLite read-only and reports only version/schema state, integrity,
aggregate row and queue counts, file sizes, and MaxMi process counts. Its source is
audited by automated tests to ensure it does not query content-bearing columns.

### Repository and build

| Field | Value |
|---|---|
| Baseline commit | `2d87ffa` |
| Branch | `main` |
| App version/build | `0.2.0` / `1` |
| Latest migration | `v9` (9 applied) |
| Automated suite | 450 tests pass, including 4 baseline-checker privacy/schema tests |

### Live database and runtime

| Check | Result |
|---|---:|
| Snapshot time | `2026-07-15T09:51:26Z` |
| SQLite integrity | `ok` |
| Database mode | `0600` |
| Threads | 664 |
| Versions | 1,001 |
| Facts | 4,076 |
| Latest contexts | 664 |
| Recordings | 0 |
| Capture Health rows | 500 (configured bound reached) |
| Retry total / overdue / max attempts | 0 / 0 / 0 |
| Context summaries pending / failed | 3 / 0 |
| Activity summaries pending / failed | 1 / 0 |
| Running/failed agent runs | 0 / 3 |
| Open action items | 0 |
| Database/WAL/SHM bytes | 53,080,064 / 2,097,112 / 32,768 |
| Application Support bytes | 419,098,624 (includes models and the Phase 7 backup) |
| Recording temp files | 0 |
| App/MCP process counts | 1 / 0 (MCP starts on demand) |

The live app was relaunched before the recorded snapshot. One action-agent run was
briefly active during startup and completed; the final snapshot has no running run or
retry backlog. Three cumulative failed agent runs are retained as a Phase 7.1 logging
and diagnostics investigation item. No error text or run content was queried.

### Pre-Phase-7 backup

| Field | Value |
|---|---|
| Backup path | `~/Library/Application Support/MaxMi/maxmi.db.bak-before-phase7-20260715-150033` |
| File mode | `0600` |
| SQLite integrity | `ok` (immutable read-only open) |
| Latest migration | `v9` |
| Aggregate count match | yes: 660 threads / 995 versions / 4,008 facts / 660 latest contexts at backup time |

## Installed live capture matrix

Existing detailed scenarios remain in the Phase 2–4 evidence documents. Phase 7.3 and
7.4 will copy only their dated pass/fail status here after live execution.

### Browsers

| Browser/version | URL route | Tab/SPA | Typing privacy | Scroll retention | Diagnostics | Date |
|---|---:|---:|---:|---:|---:|---|
| Zen 1.21.6b | pass | pass | controlled/automated | pass | pass | 2026-07-15 |
| Safari 26.5.2 | pass | pass | controlled/automated | pass | pass | 2026-07-15 |
| Chrome 150.0.7871.115 | pass | pass | controlled | pass | pass | 2026-07-15 |
| Arc 1.155.1 | pass | pass | controlled/automated | pass | pass | 2026-07-15 |

### Native applications

| App/version | Structured parser | Stable identity | Meaningful content | Accumulation | Diagnostics | Date |
|---|---:|---:|---:|---:|---:|---|
| WhatsApp 26.28.15 | pass | pass | visible-only | pending deep history | pass | 2026-07-15 |
| Mail 16.0 | pass | pass | rolling text | controlled draft only | pass | 2026-07-15 |
| Calendar 16.0 | pass | pass | replace detail | detail-only by design | pass | 2026-07-15 |
| Reminders 7.0 | pass | pass | replace detail | detail-only by design | pass | 2026-07-15 |
| Fantastical 4.1.11 | pass | pass | replace detail | detail-only by design | pass | 2026-07-15 |

## Meeting and voice acceptance

| Scenario | Detection | Capture | Cleanup | Persisted | App/MCP recall | Date |
|---|---:|---:|---:|---:|---:|---|
| Microphone voice note | explicit action | pass | pass | pass | pass | 2026-07-15 |
| Mic-only controlled meeting | pending | pending | pending | pending | pending | — |
| System + mic controlled meeting | pending | pending | pending | pending | pending | — |
| Permission-denied fallback | pending | pending | pending | pending | pending | — |
| Input-device switch | pending | pending | pending | pending | pending | — |
| Termination/relaunch recovery | explicit action | pass | pass | correctly omitted | n/a | 2026-07-15 |

The first live voice-note attempt exposed a Swift 6 executor trap in the AVAudioEngine
realtime tap. The tap callback is now created from a nonisolated function and sends
buffers only to the thread-safe mixer. On the rebuilt signed app, controlled synthetic
speech produced one completed `voice-note-mic` row, one encrypted version/context, and
a successful content-suppressed `meeting_memory` MCP list call. A second recording was
terminated by quitting MaxMi: relaunch consumed the content-free marker, created no
second recording, left no temporary audio, and resumed with one app process.

## Batch 7.2 lifecycle and recovery

Implemented and automatically verified on 2026-07-15:

- AppKit terminate-later coordination with an idempotent cleanup path and five-second
  maximum deadline;
- sleep, wake, session-resign, and session-active handling for Accessibility capture,
  meeting detection, in-progress recording, and Activity session closure;
- owned and removable workspace/panel observers, cancellable panel/model tasks, and
  invalidated app timers/background scheduler;
- a `0600` content-free interrupted-recording marker that is consumed on launch;
- fixed skip behavior so the transcriber is finished instead of leaked;
- process-local watchdog counters for audio engines, screen streams, audio-device
  observers, and meeting detectors, plus MCP helper counts in diagnostics export.

The complete automated suite passes 465 tests. The exact ownership and shutdown
inventory is recorded in `PHASE7_RESOURCE_LIFECYCLE.md`. Real microphone, meeting,
device-switch, and termination/relaunch acceptance remains in Batch 7.4 and is not
claimed by these automated results.

Normal lifecycle smoke on the signed development app passed on 2026-07-15: AppleEvent
quit emitted `app_cleanup_started`, `app_cleanup_completed`, then `app_stopped`; the
application and MCP process counts reached zero; no active-recording marker remained;
and the same signed build relaunched successfully. This proves the idle termination
path only—the active-recording termination scenario remains in Batch 7.4.

That relaunched build subsequently exposed a CoreAudio listener dictionary race in a
macOS crash report. The listener graph was serialized onto one private queue, covered
by a 200-call concurrent regression test, and the rebuilt signed app survived 60 rapid
audio-process starts/stops. The crash was treated as failed evidence and is not counted
as a passing residency run; longer soak coverage remains in Batch 7.9.

## Recovery, performance, release, and soak

These sections will be populated by their corresponding batches without backfilling
claims from unit tests as live evidence.

- Backup restore drill: pass on a disposable two-version corpus through the isolated
  helper, 2026-07-15. The selected backup remained unchanged and the newer current
  database was preserved separately.
- N-1 migration/rollback drill: pass for `v8` → `v9`, including retained encrypted
  version rows and a portable pre-restore backup, 2026-07-15.
- CPU/memory/disk/queue profiles: pending Batch 7.6.
- Secure distributed AI path: pending Batch 7.7.
- Clean install, upgrade, signing, notarization, and Gatekeeper: pending Batch 7.8.
- Seven-day soak: pending Batch 7.9.

## Batch 7.1 structured logging and diagnostics

Implemented on 2026-07-15:

- a closed event vocabulary with no free-form message API;
- JSON-lines logs split by process and rotated at 5 MiB per file, with one active plus
  four archives per process;
- mode-`0700` log directory and mode-`0600` files;
- numeric system error codes only—localized descriptions and error domains are not
  written;
- typed parser/trigger/outcome/operation tokens restricted to a narrow character set;
- migration of app, capture, parser, store, pipeline, Activity, agent, meeting/audio,
  Settings, and MCP logging;
- a regression test that rejects `NSLog`, stderr writes, `print`, and OS logger calls in
  runtime source (the MCP stdout protocol reply is the only explicit exception);
- test-process logs redirected to a temporary directory rather than live Application
  Support;
- **Export Diagnostics…** and **Reveal Logs** controls inside the Settings popover;
- a fixed-schema aggregate manifest plus re-parsed/re-serialized logs that discard
  malformed lines, unknown keys, invalid events, and free-form values;
- diagnostics export refuses to replace an existing destination.

### Automated verification

The full suite passes 460 tests. New coverage verifies:

- concurrent log lines remain valid JSON;
- rotation never exceeds its configured file count/size;
- directory/file modes are `0700`/`0600`;
- secret-bearing error descriptions and domains never reach disk;
- potential free-form tokens are rejected;
- unstructured logging cannot be reintroduced in runtime source;
- a tampered log containing a private payload is excluded from diagnostics export;
- diagnostics manifests contain aggregate database state only;
- existing export destinations are preserved;
- baseline reporting includes bounded runtime-log count and bytes.

The pre-existing concurrent audio-mixer test was also corrected to use real nanosecond
timestamps spaced by 100 ms instead of adding 100 raw host ticks. It passed three
consecutive focused runs before the final full-suite pass.

### Signed live verification

| Check | Result |
|---|---|
| Signed app launched | yes; one MaxMi process |
| Signature verification | valid on disk; designated requirement satisfied |
| Log directory mode | `0700` |
| Runtime log files | 1 (`maxmi.log`) |
| Runtime log file mode | `0600` |
| Runtime log bytes at `2026-07-15T10:45:03Z` | 966 |
| Unknown JSON keys | 0 |
| Test log in live directory | none |
| Retry queue | 0 total / 0 overdue |
| Recording temp files | 0 |
| Settings diagnostics controls | compiled and model/writer tested; pending manual visual click |

The first safe live events were three `parser_no_content`, two `app_started`, and three
`agent_run_failed` events. The agent failures share numeric system error code `1`; no
error description, prompt, response, source identifier, or activity content was queried
or written. The live database has seven cumulative failed agent runs and no current run
or retry backlog. Root-cause remediation is carried forward as a reliability issue; the
new logging layer has achieved the intended content-safe observability.
