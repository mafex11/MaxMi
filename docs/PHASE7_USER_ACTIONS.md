# Remaining user actions to close Phase 7

Everything safely automatable on this Mac is implemented and verified. These items need
human interaction, external accounts, a second environment, or elapsed real-use time.

## 1. Controlled meeting acceptance

Use controlled test speech only; do not use a private meeting.

- Open a real Google Meet, Zoom, or Teams meeting and confirm MaxMi detects it once.
- Run one two-sided call using this Mac plus a second device/person. Confirm both system
  audio and microphone speech appear once and chronologically after stopping.
- Temporarily deny/revoke Screen Recording, repeat, and confirm MaxMi clearly records
  microphone-only rather than silently failing.
- While recording, switch to another microphone/input device and confirm recording
  continues.
- Exercise prompt Skip and meeting-ended grace behavior.
- If available, place the meeting on a second display and confirm panel placement.

Microphone voice-note capture, encrypted persistence/MCP listing, explicit stop, crash
fix, quit-during-recording cleanup, and relaunch recovery already pass live.

## 2. Eight-hour performance run

Run:

`tools/profile-runtime.sh --samples 480 --interval 60 > phase7-eight-hour-profile.txt`

During the run, use normal browsing/native apps, sleep/wake once, record one controlled
voice note or meeting, and make several MCP queries. Do not quit the sampler. At the end,
run `tools/check-runtime-health.sh --assert` and provide the content-free profile file.

## 3. Hosted MaxMi relay

- Choose and fund the hosting/provider account and production HTTPS domain.
- Provide access to the deployment project without pasting credentials into chat/source.
- Decide quotas, acceptable-use policy, captured-content retention (recommended: none),
  deletion behavior, support contact, and privacy disclosure.
- After deployment, run install registration, token revocation, quota/rate-limit,
  offline degradation, and production transport acceptance.

The app-side HTTPS client, scoped bearer protocol, Keychain token storage, request/response
limits, fail-closed behavior, and provider-key bundle scan are already complete.

## 4. Apple distribution and clean install

- Enroll in the paid Apple Developer Program if not already enrolled.
- Install a Developer ID Application certificate in the login Keychain.
- Configure the local `maxmi-notary` notarytool Keychain profile.
- Run `./release.sh`; retain the notary, stapler, Gatekeeper, checksum, and signed-manifest
  evidence.
- On a fresh macOS user account or second Mac, perform the clean-install and previous-
  version upgrade/rollback checklist in `RELEASE_CHECKLIST.md`.

The local pipeline already passes tests, version alignment, bundle scanning, app/helper
signatures, and correctly blocks distribution when Developer ID is absent.

## 5. Seven-day real-use soak and final sign-off

Keep MaxMi enabled for seven normal-use days including browsing, native apps, network
loss/recovery, sleep/wake, one controlled meeting, one voice note, MCP retrieval, at
least one relaunch, and the new release/upgrade path. Record only content-free health
evidence. Phase 7 closes after there is no unexplained resource growth, orphan process,
stuck audio session, stalled queue, lost capture route, or failed restore drill.
