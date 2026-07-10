# MaxMi — M5: Meeting Capture (Detection + Right-Lane Recorder + Transcription)

**Date:** 2026-07-11
**Status:** Draft for review (Codex gpt-5.6-terra)
**Milestone:** M5 — the first genuinely new *capability* since M1 (audio, not AX-tree). Everything prior captured on-screen text; M5 adds system-audio meeting capture + transcription + a meeting memory surface.
**North star:** match Minimi's behaviour and UI/UX, reverse-engineered from the installed app (`/Applications/Minimi.app` — native helpers + `main.jsc` + `rightLane` React bundle). See [[project_minimi_reverse_engineering]], [[project_maxmi]], [[project_maxmi_ax_capture]].

## 1. What we're building

When the user joins a meeting, MaxMi (a) **detects** it automatically, (b) shows a **small rounded rectangle popup docked to the right edge of the screen** offering to record, (c) on accept, **captures system + mic audio and transcribes it**, (d) stores the transcript as a **meeting-kind memory**, extracted and searchable, and (e) serves it through the now-real **`meeting_memory` MCP tool**. Behaviour and UX mirror Minimi.

**Success test:** join a Zoom/Meet/Teams call → within a few seconds a right-edge recorder popup appears → click Record → speak → end the call → a meeting thread exists with a transcript, encrypted at rest, extracted to facts, and `meeting_memory` (action `list`/`search`/`get_context`) returns it; clicking "Don't record" dismisses and captures nothing.

## 2. How Minimi does it (reverse-engineered evidence — the reference to match)

**Detection** — `Resources/exec/meetings-coreaudio` (native helper). Uses a private CoreAudio "responsibility SPI" (`responsibility_get_pid_responsible_for_pid`, `runningApplicationWithProcessIdentifier:`) to determine *which app owns the active microphone*. When a known meeting app starts using the mic it emits `meetingAppChanged` JSON on stdout. Known apps observed in the binary: `us.zoom.xos`, `com.microsoft.teams2`, `com.cisco.webexmeetingsapp`, plus browsers (`com.google.Chrome`, `com.apple.Safari`, Edge, Brave, Opera, Vivaldi, Arc/Atlas) and `com.tinyspeck.slackmacgap`, Discord. Fallbacks: `google-meet-monitor` (browser tab monitor) and a macOS unified-log-stream detector (`[MeetingDetector] falling back to log-stream detector`). Primary is core-audio (`[MeetingDetector] core-audio detector started (primary)`).

**UI/UX** — a `rightLane.html` Electron `BrowserWindow`: frameless, transparent, `alwaysOnTop`, `setIgnoreMouseEvents` when idle, positioned against the right edge via `getPrimaryDisplay().workArea` + `setBounds`, repositioned on `display-metrics-changed`. Shows a "meeting-nudge" card with **Record** and **"DontRecord"** (skip) actions and a live audio-level meter (`onAudioLevel`, `right-lane-window-update`, `resize-right-lane-window`, `hide-right-lane-window`). On skip → `[MeetingCapture] user skipped`.

**Audio → transcription** — `Resources/exec/captureAudio` streams audio to Deepgram over a WebSocket (`/transcribe?token=`, `[AudioCapture] Deepgram ready`, `deepgram_ready`). Transcript is committed as a `memory_versions` row with `metadata {"kind":"meeting"}`; extraction via backend `/api/memory/extract-meeting` + `/api/activity/summarize-meeting`. `meeting_memory` MCP tool queries `WHERE v.metadata LIKE '%"kind":"meeting"%'`.

**Storage** — meetings are ordinary threads/versions tagged by `metadata.kind="meeting"` (not a separate table), so they reuse encryption, extraction, and search.

## 3. MaxMi adaptation (what differs, and why)

MaxMi is **all-Swift, in-process, local-first** (no Electron, no always-on cloud relay beyond the existing Gemini extraction). So:

- **Detection:** a Swift `MeetingDetector` using CoreAudio to detect mic-active + the frontmost/responsible app's bundle id against a meeting-app allowlist (Zoom/Teams/Webex/Meet-in-browser/etc.). We do NOT need the private responsibility SPI for v1 — mic-active + frontmost-app heuristic is enough (documented limitation §11). Reuses AXReader's app-identity plumbing.
- **Popup:** a native **AppKit `NSPanel`** (`.nonactivatingPanel`, `.hud`/borderless, `isFloatingPanel`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`), docked to the right edge using `NSScreen.main.visibleFrame`. This is the Swift equivalent of Minimi's right-lane BrowserWindow — same placement and behaviour, no web layer.
- **Audio:** `ScreenCaptureKit` (`SCStream` audio) for **system audio** + `AVAudioEngine` for **mic**, mixed to a single stream. (ScreenCaptureKit audio is the modern, permission-scoped way to capture other apps' audio on macOS 13+.)
- **Transcription:** pluggable `Transcriber` protocol. v1 default = **on-device `SFSpeechRecognizer`** (no new cloud dependency, matches MaxMi's local-first stance and avoids shipping a Deepgram key). A `DeepgramTranscriber` implementation is allowed behind the same protocol if the user provides a key (parity option), but on-device is the default.
- **Storage/MCP:** meetings are versions with `metadata.kind="meeting"` (new `metadata` column, M5 migration), keyed `meeting:<app>/<title-or-time>`; the existing `meeting_memory` stub becomes a real query over that metadata. Reuses ThreadKeyDeriver + fingerprint dedup + encryption.

## 4. Non-goals (M5 v1)

- **No Deepgram/cloud transcription by default** (on-device SFSpeech; Deepgram is an optional pluggable impl, not shipped-on).
- **No speaker diarization / per-speaker labels** (transcript is one stream; diarization is a follow-up).
- **No private CoreAudio responsibility SPI** (mic-active + frontmost-app heuristic for v1).
- **No meeting video/screen recording** — audio + transcript only.
- **No auto-record** — always the popup prompt first (privacy: recording a meeting is consent-sensitive; never silent).
- **No editing below the Store boundary beyond the additive `metadata` column.**
- **No calendar integration** (title comes from the meeting app's window title, not calendar events — follow-up).

## 5. Architecture / components

```
Sources/MaxMiMeetings/                         NEW module (audio is heavy; isolate it)
  MeetingDetector.swift      CoreAudio mic-active + meeting-app allowlist -> onMeetingStart/End
  MeetingAppList.swift       bundle ids: us.zoom.xos, com.microsoft.teams2, webex, + browsers/Meet
  AudioCapture.swift         SCStream (system) + AVAudioEngine (mic) -> PCM buffers + level meter
  Transcriber.swift          protocol { start/feed/finish -> transcript }; SFSpeechTranscriber (default)
  MeetingSession.swift       orchestrates detect->prompt->capture->transcribe->commit; state machine
Sources/MaxMi/RightLanePanel.swift             NEW: NSPanel right-edge recorder popup (Record/Skip + level)
Sources/MaxMi/AppWiring.swift                  MODIFY: own MeetingSession; wire detector->panel->store
Sources/MaxMiStore/Migrations.swift            MODIFY: v3 adds versions.metadata TEXT
Sources/MaxMiStore/StoreAPI.swift              MODIFY: commitMeeting(transcript, app, title, metadata)
Sources/MaxMiMCP/MemoryQueries.swift           MODIFY: real meeting_memory over metadata.kind=meeting
Sources/MaxMiMCP/Tools.swift                   MODIFY: update meeting_memory description
packaging/Info.plist                           MODIFY: NSMicrophoneUsageDescription, ScreenCapture usage
```

Data flow: `MeetingDetector` (mic goes active in a meeting app) → `MeetingSession` shows `RightLanePanel` → user clicks **Record** → `AudioCapture` starts (SCStream+mic), streams buffers to `Transcriber`, panel shows live level → meeting ends (mic inactive / call app backgrounded / user Stop) → transcript finalized → `Store.commitMeeting` writes a version with `metadata.kind="meeting"` → normal extraction/embedding → `meeting_memory` MCP serves it.

## 6. UI/UX spec (the right-lane recorder — match Minimi)

- **Placement:** docked to the right edge of `NSScreen.main.visibleFrame`, vertically centered-ish (upper-right). Small rounded rectangle (~ 300×90 pt idle nudge; ~300×120 while recording). Reposition on screen-change (`NSApplication.didChangeScreenParametersNotification`).
- **States:**
  1. **Nudge** (meeting detected): "Meeting detected — record it?" with **Record** (primary) and **Don't record** (dismiss). Auto-dismiss after ~20s if ignored → treated as skip.
  2. **Recording:** red ● + "Recording…" + elapsed timer + live audio-level bar (from AudioCapture) + **Stop**.
  3. **Finishing:** "Saving meeting…" spinner, then auto-hide.
- **Behaviour:** frameless, translucent (vibrancy), always-on-top, joins all Spaces + fullscreen-aux (so it shows over a fullscreen Zoom), non-activating (doesn't steal focus), ignore-mouse when idle-nudge except on the buttons.
- **Consent/privacy:** never records without an explicit Record click. "Don't record" fully suppresses for that meeting. A per-app "never ask for this app" option (stored in settings) is a nice-to-have.

## 7. Storage & schema

- **Migration v3 (additive):** `ALTER TABLE versions ADD COLUMN metadata TEXT;` (nullable; existing rows null). No other schema change.
- **commitMeeting:** creates/【upserts】a thread keyed `meeting:<app-slug>/<title-slug>` (via ThreadKeyDeriver — meetings get a `meeting:` scheme), commits a version whose `content` = transcript (encrypted like all content) and `metadata` = JSON `{"kind":"meeting","app":"Zoom","startedAt":<ms>,"durationSec":N}`. Reuses fingerprint dedup (transcript chunks) + freeze-then-create.
- Extraction: meeting versions flow through the SAME extraction pipeline; a `kind=meeting` hint can bias the extraction prompt toward action-items/summary (optional).

## 8. MCP `meeting_memory` (make the stub real)

Replace the stub. Actions:
- `list` — recent meeting threads (query versions `WHERE metadata LIKE '%"kind":"meeting"%'`, newest first, cap 20), markdown.
- `search <query>` — semantic search restricted to meeting-kind derivatives (reuse the vec search, filter by kind).
- `get_context <thread>` — full transcript + facts for one meeting.
Returns markdown (matches existing MCP style). Decrypts via the field cipher like `search_memory`.

## 9. Permissions

- **Microphone** (`NSMicrophoneUsageDescription`) — for mic capture.
- **Screen Recording / ScreenCaptureKit** — required for system-audio capture (macOS gates SCStream audio behind Screen Recording permission). First use triggers the system prompt; if denied, fall back to **mic-only** capture (documented degradation, still useful).
- Both requested lazily on first Record, not at launch. Signed with the existing stable identity so grants persist (see [[project_maxmi_ax_capture]]).

## 10. Error handling

- Detector unavailable (non-macOS / CoreAudio error) → log, no meeting features, rest of app unaffected.
- Audio start failure → panel shows "Couldn't start recording", auto-dismiss; no partial thread.
- Transcriber failure mid-meeting → keep audio buffer, retry finalize; if unrecoverable, store whatever transcript exists + mark version `extract_status` normally (never crash, never lose the whole meeting).
- Screen Recording denied → mic-only fallback, panel notes "system audio unavailable".
- All meeting content encrypted at rest; consent-gated; fail-closed (no record → no capture).

## 11. Known limitations (v1, honest)

- Mic-active + frontmost-app heuristic can miss a meeting where the call app is backgrounded, or false-positive on non-meeting mic use (e.g. voice memo) — the popup is the safety valve (user just clicks Don't record). Minimi's private responsibility SPI is more precise; deferred.
- On-device SFSpeech is lower-accuracy than Deepgram for multi-speaker calls; Deepgram is available as a pluggable upgrade.
- No diarization; transcript is a single stream.
- Title from window title may be generic ("Zoom Meeting"); calendar integration deferred.

## 12. Testing

- **MeetingDetectorTests:** app-allowlist matching; mic-active state transitions → onStart/onEnd (fixture/mocked CoreAudio callback).
- **MeetingSessionTests:** state machine (detected→prompt→record→finish; skip path; error paths) with a mock AudioCapture + mock Transcriber.
- **Transcriber:** SFSpeech wrapper tested with a short fixture audio clip → non-empty transcript (or skipped in CI if unavailable).
- **commitMeeting / migration v3:** version has metadata.kind=meeting; thread keyed meeting:...; MigrationTests asserts metadata column exists.
- **meeting_memory MCP:** list/search/get_context over seeded meeting versions.
- **RightLanePanel:** placement math (right-edge of a mocked screen frame); state rendering is manual/live (AppKit UI not unit-tested, per M4 precedent for glue).
- Audio/detector live paths verified manually in §13; fixture-driven logic in CI.

## 13. Exit criteria

1. Joining a Zoom/Meet/Teams meeting shows the right-edge recorder popup within a few seconds.
2. Record → speak → stop produces a `meeting:` thread with a transcript, encrypted at rest.
3. Transcript is extracted to facts and returned by `meeting_memory` (list + search + get_context) and `search_memory`.
4. "Don't record" captures nothing; auto-dismiss after timeout = skip.
5. Mic + (Screen-Recording-gated) system audio both captured; denied Screen Recording → mic-only fallback works.
6. Popup matches Minimi's placement/behaviour (right edge, floating, over fullscreen, non-activating).
7. Full fixture suite green; no regressions; audio libs isolated in MaxMiMeetings.

## 14. Rollout

Spec → **Codex gpt-5.6-terra review** → revise → implementation plan → **Codex review (same chat)** → revise → subagent-driven build → live verify. Meetings is the last big capability to reach Minimi parity.
