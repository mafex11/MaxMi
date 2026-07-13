# Phase 0 live capture smoke check

This check establishes which apps MaxMi captures today and why other attempts are missed. Capture Health stores and displays diagnostic metadata only: app identity, trigger, parser, outcome, reason, character count, duration, and truncation state. It does not store captured text, URLs, page titles, source keys, or raw errors.

## Before testing

1. Build and launch the current MaxMi app.
2. Grant Accessibility permission when macOS asks.
3. Confirm memory encryption is available in the menu.
4. If Activity is wanted, decline it once, then grant it from **Activity Privacy…** to verify consent recovery. Disable and re-enable it once.
5. Open **Capture Health…** from the MaxMi menu. An empty screen is expected before the first attempt.

## Controlled capture pass

For each daily browser and app, focus a normal, non-sensitive window for at least five seconds. In browsers, also focus the address field once and visit a blocked authentication or payment page. Do not use real secrets as test content.

Record the observed result here:

| App/site | Expected route | Outcome/reason | Useful capture? | Notes/date |
|---|---|---|---:|---|
| Safari normal page | BrowserTabExtractor |  |  |  |
| Chrome/Chromium normal page | BrowserTabExtractor |  |  |  |
| Firefox normal page | BrowserTabExtractor |  |  |  |
| Other installed browser | BrowserTabExtractor or explicitly excluded |  |  |  |
| Browser address field focused | BrowserTabExtractor | skipped/addressFieldFocused | n/a |  |
| Login, OTP, banking, or payment page | BrowserTabExtractor | skipped/blockedURL | n/a |  |
| Cursor/Xcode | structured parser or GenericAXParser |  |  |  |
| Terminal | TerminalParser |  |  |  |
| Slack/Discord/Messages/WhatsApp | app parser |  |  |  |
| Mail/document app | app parser |  |  |  |
| MaxMi/System Settings/login UI | PolicyGate | skipped/excludedApp | n/a |  |
| Paused app | its normal parser | skipped/appPaused | n/a |  |
| Global capture paused | its normal parser | skipped/globalPaused | n/a |  |

After each focus change, reopen **Capture Health…** and verify that the newest row explains the terminal outcome. A repeated `noWindow`, `parserNoContent`, `emptyContent`, or failure result is a real coverage gap to prioritize in Phase 1; it must not be treated as a successful capture.

## Content-free terminal report

Run:

```bash
tools/check-capture-health.sh
```

To inspect a different database:

```bash
MAXMI_DB_PATH=/path/to/maxmi.db tools/check-capture-health.sh
```

The script is read-only and selects only columns from `capture_health_events`. Review its outcome counts and latest 20 attempts, then add the verified app/version/date to the table above.

## Pass conditions

- Declined Activity consent can later be granted; disabling and re-enabling works.
- Every installed supported browser reports `BrowserTabExtractor`.
- Sensitive URLs are skipped before storage.
- MaxMi and transient/sensitive system apps are excluded.
- Every attempt ends as captured, unchanged, skipped with a reason, or failed with a reason.
- The app remains responsive during large Accessibility-tree reads.
- Existing memories and facts remain readable after migration.
- No captured text, URL, title, source key, or raw error appears in the health window or script.
