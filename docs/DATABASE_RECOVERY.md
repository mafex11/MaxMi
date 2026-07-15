# Database backup, restore, and migration recovery

**Implemented:** 2026-07-15, Phase 7.5  
**Current migration:** `v9`

## Safety contract

- Backups are consistent SQLite copies with mode `0600` and portable `DELETE` journal
  mode; they do not depend on a WAL/SHM sidecar.
- Restore never opens or mutates the user-selected backup. It first copies the file to
  a private staging path beside the active database.
- The staging copy must have MaxMi migration history, contain no unknown future
  migration, upgrade successfully to the current schema, pass `PRAGMA integrity_check`,
  and contain the required core tables.
- MaxMi exits before replacement. The bundled signed recovery helper validates staging,
  creates a second portable backup of the current database, and uses same-volume renames
  for replacement.
- A failed validation leaves the active database untouched. A failed final rename rolls
  the original database back into place. The helper writes only a content-free result
  code and preserved-backup filename, then relaunches MaxMi.
- Repair is copy-first. Never run mutation, recovery, or salvage commands against the
  only database copy.

## User workflow

1. Open the tray popover, then Settings → Data Controls.
2. Choose **Restore Database Backup…** and select a MaxMi `.db` backup.
3. Confirm **Restore and Relaunch**.
4. MaxMi quits and the helper performs validation and replacement.
5. After relaunch, Data Controls shows success or failure. On success, the database that
   was active before restore remains under `Backups/maxmi-before-restore-<id>.db`.

## Corruption workflow

1. Quit MaxMi and copy `maxmi.db`, `maxmi.db-wal`, and `maxmi.db-shm` together if those
   sidecars exist.
2. Preserve that untouched copy before attempting diagnosis.
3. Prefer restoring a known-good MaxMi backup through the app workflow.
4. If no backup validates, retain every copy and perform SQLite recovery only on an
   additional disposable copy. Do not replace the active database with recovered output
   until integrity, migration history, required tables, encryption markers, and aggregate
   invariants pass.

## Migration manifest

| Version | Purpose | Restore verification |
|---|---|---|
| `v1` | Core threads, versions, facts, retry/settings, 1,536-dimension vector table | core tables and vector schema exist |
| `v2` | Message fingerprint deduplication | fingerprint table exists |
| `v3` | Meeting/voice history and version metadata | meetings table and metadata column exist |
| `v4` | Activity sessions, agent runs, and action items | activity/agent tables and foreign keys exist |
| `v5` | Agent cursor, lease, and idempotency constraints | lease/cursor columns and unique indexes exist |
| `v6` | Bounded content-free capture-health ledger | capture-health table/indexes exist |
| `v7` | Encrypted latest-context store | latest-context table and recent index exist |
| `v8` | Encrypted display-summary state and retry metadata | summary columns/index exist |
| `v9` | Structured calendar/task and recording context kinds | rebuilt context constraint and indexes pass |

Every future migration must update `Migrations.currentIdentifier`, this manifest, the
N-1 upgrade fixture, and post-upgrade integrity/invariant checks in the same batch.

## Automated evidence

The store suite verifies portable backup mode, successful restore from a disposable
corpus, rejection of a non-MaxMi database without changing the active copy, preservation
of the pre-restore current database, an isolated-helper restore, and a `v8` → `v9`
upgrade that retains encrypted rows.
