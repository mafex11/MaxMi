# Phase 7 resource lifecycle

**Implemented:** 2026-07-15, Batch 7.2

This inventory defines a single owner and shutdown path for every long-lived MaxMi
runtime resource. Recovery metadata is content-free; MaxMi does not write temporary
meeting audio because PCM and partial transcription remain in memory until explicit
save.

| Resource | Owner | Normal stop | Sleep / user switch | Process termination |
|---|---|---|---|---|
| Accessibility observer and recapture timer | `FocusObserver` | `stop()` | stopped, then restarted on wake/active | stopped and released |
| Pipeline and capture-summary timers | `AppWiring` | app lifetime | gated while suspended | invalidated |
| Workspace notification tokens | `AppWiring` | app lifetime | callbacks suspend/resume capture | removed from `NSWorkspace` center |
| Background agent scheduler | `AppWiring` | app lifetime | macOS scheduler owns deferral | invalidated |
| Whisper preparation task | `AppWiring` | completes after model readiness | may complete while asleep but detector remains gated | cancelled |
| CoreAudio process listeners | `MeetingDetector` | `stop()` | stopped, then restarted | stopped and released |
| ScreenCaptureKit stream | `AudioCapture` | `stop()` | session interruption calls `stop()` | session shutdown calls `stop()` |
| Microphone engine, tap, device observer | `AudioCapture` | `stop()` | session interruption calls `stop()` | session shutdown calls `stop()` |
| Level and maximum-duration tasks | `MeetingSession` | stop/skip | cancelled | cancelled |
| Whisper transcriber | `MeetingSession` | `finish()` | finished without persistence | finished without persistence |
| Panel timer, auto-dismiss task, screen observer | `RightLanePanel` | hidden/state transition | panel hidden | cancelled/removed by `shutdown()` |
| Activity visits/sessions | `AppWiring` + store | focus/session close | closed | closed |
| MCP helper | invoking client | request/process end | independent on-demand process | counted in diagnostics; no app-owned persistent child |

## Interrupted recording recovery

Recording start atomically writes `RecordingState/active-recording.json` with mode
`0600` under a mode-`0700` directory. Its fixed schema contains only:

- format version;
- `meeting` or `voice_note`;
- start time in epoch milliseconds.

Explicit stop, skip, sleep/user-switch interruption, capture failure, and normal app
termination remove the marker. A marker remaining after an unexpected process exit is
consumed on next launch and produces the closed diagnostic event
`interrupted_recording_recovered`. Invalid metadata is removed. No transcript, title,
URL, application identifier, source key, or audio is recovered or uploaded silently.

## Termination policy

`NSApplicationDelegate.applicationShouldTerminate` requests asynchronous cleanup and
uses AppKit's terminate-later reply. A five-second deadline guarantees the process is
not held indefinitely. Cleanup is idempotent and prevents new capture work while it is
running.

Privacy-safe diagnostics expose current counts for audio engines, screen streams,
device observers, meeting detectors, and MCP helper processes. Counters clamp at zero
so repeated stop calls cannot create misleading negative values.

## Automated evidence

- 60 meeting/lifecycle tests pass.
- The complete suite passes 464 tests.
- Coverage includes skip cleanup, repeated shutdown, no persistence on interruption,
  recovery marker schema/modes/consumption, corrupt marker cleanup, and bounded
  watchdog counters.
