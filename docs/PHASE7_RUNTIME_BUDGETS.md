# Phase 7 runtime budgets

**Instrumentation implemented:** 2026-07-15  
**Long-run status:** eight-hour controlled profile pending

## Repeatable checks

- `tools/check-runtime-health.sh` prints one content-free process, queue, capture,
  database, disk, temporary-file, and log snapshot.
- `tools/check-runtime-health.sh --assert` evaluates provisional budgets and exits
  nonzero on failure.
- `tools/profile-runtime.sh` samples repeatedly. The eight-hour command is:
  `tools/profile-runtime.sh --samples 480 --interval 60`.

Neither script queries titles, source keys, URLs, captured text, summaries, facts,
error messages, or encrypted content columns. Automated tests enforce that boundary.

## Provisional budgets

| Surface | Budget |
|---|---:|
| App processes | exactly 1 while running |
| Persistent MCP helpers | at most 1 |
| Resident memory | ≤ 512 MiB |
| Threads | ≤ 128 |
| Open files | ≤ 256 |
| Capture-health rows | ≤ 500 |
| Retry rows / overdue | ≤ 1,000 / ≤ 100 |
| Pending latest-context summaries | ≤ 1,000 |
| Running agent jobs | ≤ 1 |
| Database | ≤ 5 GiB |
| Application Support | ≤ 10 GiB |
| Recording temp files while idle | 0 |
| Runtime logs | ≤ 5 files and ≤ 25 MiB total |

CPU and wakeups need a time-series comparison rather than a single hard threshold.
Wakeups require a privileged macOS sampler and are reported as unavailable by the
unprivileged health script.

## Short signed-app profile

A six-sample, two-second-interval idle/background profile passed on 2026-07-15:

| Metric | Observed |
|---|---:|
| RSS | 30.7–45.8 MiB |
| CPU snapshot | 0.0–2.0% |
| Threads | 8–12 |
| Open files | 51 |
| Capture-health rows | 500, bounded |
| Capture failures in retained window | 0 |
| Mean / maximum capture duration | 440 ms / 15,151 ms |
| Retry / overdue rows | 0 / 0 |
| Pending summaries | decreased from 9 to 7 |
| Recording temp files | 0 |
| Runtime logs | 1 file, 28,686 bytes |

RSS did not grow monotonically in this short sample, queues continued draining, and
`--assert` passed. This is a smoke profile, not a substitute for the required eight-hour
normal-use run. The 15-second retained capture-duration outlier should be correlated
with parser/trigger metadata during the long profile without inspecting content.
