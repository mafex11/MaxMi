# Phase 7 live verification

**Status:** baseline in progress  
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
| Zen 1.21.6b | pending | pending | pending | pending | pending | — |
| Safari 26.5.2 | pending | pending | pending | pending | pending | — |
| Chrome 150.0.7871.115 | pending | pending | pending | pending | pending | — |
| Arc 1.155.1 | pending | pending | pending | pending | pending | — |

### Native applications

| App/version | Structured parser | Stable identity | Meaningful content | Accumulation | Diagnostics | Date |
|---|---:|---:|---:|---:|---:|---|
| WhatsApp 26.28.15 | pending | pending | pending | pending | pending | — |
| Mail 16.0 | pending | pending | pending | pending | pending | — |
| Calendar 16.0 | pending | pending | pending | pending | pending | — |
| Reminders 7.0 | pending | pending | pending | pending | pending | — |
| Fantastical 4.1.11 | pending | pending | pending | pending | pending | — |

## Meeting and voice acceptance

| Scenario | Detection | Capture | Cleanup | Persisted | App/MCP recall | Date |
|---|---:|---:|---:|---:|---:|---|
| Microphone voice note | pending | pending | pending | pending | pending | — |
| Mic-only controlled meeting | pending | pending | pending | pending | pending | — |
| System + mic controlled meeting | pending | pending | pending | pending | pending | — |
| Permission-denied fallback | pending | pending | pending | pending | pending | — |
| Input-device switch | pending | pending | pending | pending | pending | — |
| Termination/relaunch recovery | pending | pending | pending | pending | pending | — |

## Recovery, performance, release, and soak

These sections will be populated by their corresponding batches without backfilling
claims from unit tests as live evidence.

- Backup restore drill: pending Batch 7.5.
- N-1 migration/rollback drill: pending Batch 7.5.
- CPU/memory/disk/queue profiles: pending Batch 7.6.
- Secure distributed AI path: pending Batch 7.7.
- Clean install, upgrade, signing, notarization, and Gatekeeper: pending Batch 7.8.
- Seven-day soak: pending Batch 7.9.
