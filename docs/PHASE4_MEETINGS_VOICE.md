# Phase 4 meetings and voice notes

Date: 2026-07-14

## Live migration baseline

A consistent SQLite backup was created before applying v9:

`~/Library/Application Support/MaxMi/maxmi.db.bak-before-phase4-20260714-180439`

| Table | Before v9 | After v9 |
|---|---:|---:|
| threads | 631 | 631 |
| versions | 951 | 951 |
| latest contexts | 631 | 631 |
| meetings/voice notes | 0 | 0 |

The backup is mode `0600`. After migration, `grdb_migrations` ends at `v9`, the rebuilt latest-context constraint accepts calendar/task/meeting/voice-note kinds, and `PRAGMA integrity_check` returns `ok`.

No meeting transcript, voice-note transcript, title, URL, summary, or fact was read to produce this report.

## Detector contract

Browser microphone activity requires both a canonical browser bundle ID and an active URL matching a strict route:

| Platform | Required route evidence |
|---|---|
| Google Meet | `meet.google.com/<meeting-code>`; host root is insufficient |
| Zoom | Zoom host plus `/j/`, `/wc/`, or `/s/` route |
| Microsoft Teams | meeting-join path or meeting ID/join query |
| Slack | explicit huddle/call route; an ordinary Slack workspace is insufficient |
| Webex | meet/join route |

Native Zoom, Teams, Webex, Slack, and WhatsApp still use per-process CoreAudio input activity. Multiple helper PIDs are grouped by bundle ID; stopping one helper does not end the candidate while another remains active.

## Session safety contract

- A second candidate cannot replace an active prompt or recording.
- Resumed input from the same meeting cancels an end suggestion.
- Input stop waits eight seconds before suggesting Finish/Keep Recording.
- Ending input never silently persists or stops a recording; the user remains in control.
- A five-second cooldown prevents immediate re-prompt loops.
- A four-hour ceiling finishes an accidentally abandoned recording.
- Skip and failure paths stop active capture and cancel polling/timers.
- Screen-recording denial or system-audio failure degrades to mic-only.
- The panel docks to the screen containing the resolved meeting window.

## Audio alignment contract

System and microphone buffers are independently converted to 16 kHz mono. They are inserted into one timestamped timeline of 100 ms frames with a 150 ms holdback:

- samples that overlap are averaged once;
- single-source regions retain their original level;
- non-overlapping regions remain chronological;
- a meeting with two 100 ms source buffers at the same time produces 100 ms, not 200 ms;
- pending partial frames are flushed before transcription finishes.

This is covered with pure deterministic alignment tests plus AVAudioConverter integration and concurrent-producer tests. Real ScreenCaptureKit and device behavior still require live acceptance.

## Voice-note and history contract

**Start Voice Note** in the tray menu starts mic-only capture after microphone authorization. The right-lane panel shows level, elapsed time, partial transcript, and Stop. Stopping creates a distinct encrypted `Voice Note` thread, a meeting-table history record with `voice-note-mic` mode, a pending extraction version, and a pending latest-context summary.

Meetings and voice notes appear in the **Recordings** tab. Both remain available through the existing `meeting_memory` MCP tool, and their versions enter the normal fact extraction/embedding pipeline.

## Manual live acceptance

Run `tools/check-recording-health.sh` before and after each test. Do not conduct a real private meeting solely for testing; a controlled two-speaker test call is sufficient.

| Test | Expected result | Status |
|---|---|---|
| Ordinary browser site uses microphone | no meeting prompt | automated only |
| Zen opens Google Meet and microphone activates | one meeting prompt | pending live |
| Decline/skip prompt | no capture process or meeting row | automated; pending live |
| Accept with screen recording denied | mic-only recording persists | mocked; pending live |
| Accept with system+mic | both speakers appear once and chronologically | deterministic mixer; pending live |
| Change microphone during recording | tap restarts, recording continues | implementation present; pending live |
| Stop recording | encrypted transcript, history row, summary/facts queued | live pass for voice note, 2026-07-15; meeting pending |
| Start/stop tray voice note | encrypted voice-note row visible in Recordings and MCP | live pass, 2026-07-15 |
| Quit during active voice note, then relaunch | marker consumed; no partial row or temp audio | live pass, 2026-07-15 |
| Meeting window on secondary display | panel docks to that display | automated geometry; pending live |

The implementation is not considered fully live-accepted until the Zen Meet, two-speaker system+mic, device-switch, and tray voice-note rows are completed without exposing their content in diagnostics.
