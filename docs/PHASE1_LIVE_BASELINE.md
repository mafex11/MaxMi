# Phase 1 live baseline — 2026-07-14

This baseline was collected from content-free diagnostics only. No captured text, URL, title, source key, fact, embedding, token, or raw error was written into this document.

## Safety and migration

- Created and integrity-checked a pre-Phase 1 SQLite backup under `~/Library/Application Support/MaxMi/`.
- Before the live Phase 1 session, the corpus contained 592 threads, 890 versions, and 3,534 derivatives/facts.
- The v7 migration completed against the real database.
- After normal live capture, the corpus contained 603 threads and 906 versions. Every one of the 603 threads had a `latest_contexts` row; counts only grew, so no existing corpus rows were lost.
- Existing newest encrypted versions were backfilled as `parser_id=legacy`; new captures replace that metadata with their structured parser profile.

## First live findings

| App | Before | Phase 1 result | Structured context |
|---|---|---|---|
| Cursor 3.11.19 | `GenericAXParser`, skipped/`parserNoContent` | captured 4,553–4,650 characters after `AXTextArea` support and Electron warm-up/retry | document, rollingText, accessibilityScroll(3) |
| Warp | captured, but raw snapshots previously replaced one another | captured/deduplicated through the new envelope | terminal, appendItems |

The scrubbed Cursor Accessibility shape is preserved as `Tests/MaxMiCaptureTests/Fixtures/cursor-editor.json`. Its contents are invented; only the role hierarchy reflects the live failure mode.

## Corpus review report

Run:

```bash
tools/report-phase1-corpus.sh
```

At baseline it reported:

- 601 migrated legacy contexts;
- 1 Cursor document context;
- 1 Warp terminal context;
- 5 historical self/system-noise thread candidates;
- 1 normalized-key collision group.

The report intentionally exposes only aggregate metadata. It does not delete or merge anything. Historical cleanup remains pending until the candidate records are reviewed against the pre-Phase 1 backup.

## Remaining live matrix

Arc, Chrome, Zen, Slack, Messages, Mail, and document scrolling still require controlled live passes. For each app, verify capture outcome, parser profile, accumulated character count, stable identity, and whether scrolling preserves earlier raw context without duplicating the whole snapshot.
