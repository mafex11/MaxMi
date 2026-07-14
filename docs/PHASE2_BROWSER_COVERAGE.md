# Phase 2 browser coverage

Date: 2026-07-14
Scope: content-free browser inventory, fixtures, privacy behavior, and live capture health.

## Baseline on this Mac

Installed canonical browsers at the start of Phase 2:

| Browser | Bundle ID | Engine | Pre-v2 live history |
|---|---|---|---|
| Zen | `app.zen-browser.zen` | Gecko | 28 captured, 21 deduplicated, 5 skipped |
| Safari | `com.apple.Safari` | WebKit | no Capture Health rows |
| Google Chrome | `com.google.Chrome` | Chromium | 26 captured, 47 deduplicated, 8 skipped |
| Arc | `company.thebrowser.Browser` | Chromium | no Capture Health rows |

These counts are outcomes only. No URL, page title, page text, or summary was read to produce this document.

## Implemented coverage

| Capability | Chromium | WebKit | Gecko |
|---|---:|---:|---:|
| `AXDocument`/`AXURL` web-area URL | yes | yes | yes |
| Ranked active web area | yes | yes | yes |
| Guarded address fallback | yes | yes | yes |
| Focused-address typing protection | yes | yes | yes |
| Tab/title/load/SPA AX triggers | yes | yes | yes |
| 30-second recapture backstop | yes | yes | yes |
| Strict URL/privacy gate | yes | yes | yes |
| Engine/source/quality diagnostics | yes | yes | yes |

The registry includes Minimi's observed browser set plus verified engine-compatible release-channel aliases. Unknown browser-looking bundle IDs fail safe instead of falling through to generic native capture.

## Dedicated web profiles

| Site | Content profile | Stable identity behavior |
|---|---|---|
| Gmail | email / rolling text | Gmail mailbox/thread fragment retained |
| Slack | conversation / append items | team/channel path retained; message/thread suffix removed |
| Discord | conversation / append items | guild/channel retained; individual message suffix removed |
| WhatsApp | conversation / append items | canonical web origin |
| Teams | conversation / append items | ordinary Teams app allowed; meeting join routes blocked |
| Outlook | email / rolling text | volatile query state removed; item identity retained when exposed |
| LinkedIn | webpage or messaging conversation | messaging thread identity retained |

When a chat exposes message rows/list items or message-labelled AX containers, MaxMi stores one `sender: message` item per visible message. If the site exposes only flattened text, capture still succeeds with standard/fallback quality rather than inventing sender boundaries.

## Sanitized fixture matrix

| Fixture | Engine/site | Assertion |
|---|---|---|
| `chrome-article.json` | Chromium/generic | web-area URL wins over focused omnibox |
| `chromium-gmail-thread.json` | Chromium/Gmail | email profile and URL-keyed Web capture |
| `safari-domain-only.json` | WebKit/generic | schemeless address fallback, toolbar excluded |
| `zen-meet.json` | Gecko/Meet | web-area URL wins and meeting URL is blocked |
| `gecko-slack-chat.json` | Gecko/Slack | team/channel identity and sender/message rows |

All fixture content and identifiers are invented. Real browser content must never be committed.

## Live acceptance matrix

Run `tools/check-browser-coverage.sh` before and after the following test in each installed browser:

1. Open a normal HTTPS article and wait up to 2 seconds.
2. Switch to another normal tab and confirm a `browserNavigation` or capture event.
3. Navigate within a single-page app and confirm `webContentChanged`, `browserNavigation`, or the 30-second backstop.
4. Focus the address bar and type without submitting; confirm `addressFieldFocused` and no capture.
5. Open an internal/auth/meeting test route; confirm `blockedURL` and no stored version.

| Browser | Generic page | Tab switch ≤2s | SPA/backstop | Typing protected | Blocked route | Status |
|---|---:|---:|---:|---:|---:|---|
| Zen | fixture + legacy live | pending v2 live | pending v2 live | fixture | fixture | partial |
| Safari | fixture | pending | pending | fixture | fixture | automated only |
| Chrome | fixture + legacy live | pending v2 live | pending v2 live | fixture | fixture | partial |
| Arc | Chromium fixtures | pending | pending | fixture | fixture | automated only |

The matrix stays conservative until a new `BrowserWeb.v2/.../quality-*` Capture Health event is observed for that browser.
