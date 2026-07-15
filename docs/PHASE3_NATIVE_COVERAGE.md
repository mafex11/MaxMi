# Phase 3 native structured coverage

Date: 2026-07-14

This report records application inventory, parser contracts, sanitized fixtures, and content-free live outcomes. It does not read or print captured conversations, email bodies, event names, task names, or document text.

## Installed baseline

| Application | Bundle ID | Before Phase 3 | Phase 3 route |
|---|---|---|---|
| WhatsApp | `net.whatsapp.WhatsApp` | 3 generic captures, 1 generic deduplication | `WhatsAppParser` |
| Apple Mail | `com.apple.mail` | no recent Capture Health rows | `MailParser` |
| Apple Calendar | `com.apple.iCal` | no recent Capture Health rows | `CalendarParser` |
| Reminders | `com.apple.reminders` | no recent Capture Health rows | `RemindersParser` |
| Fantastical | `com.flexibits.fantastical2.mac` | no recent Capture Health rows | `FantasticalParser` |

Microsoft Teams, Outlook, Word, Pages, Microsoft To Do, Todoist, OmniFocus, Spark, and Toggl were not found in the application locations scanned at implementation time. Their known bundle variants are registered and fixture/unit-tested where applicable, but they are not claimed as live-verified.

## Capture contracts

| Class | Identity | Structured content | Accumulation |
|---|---|---|---|
| WhatsApp / Teams | active conversation header | atomic visible message rows; sender retained when AX exposes it | append items |
| Apple Mail | hash of selected message IDs | sender, subject, received date, visible message/thread body | rolling text |
| Outlook / Spark | hash of visible message window identity | visible message text | rolling text |
| Calendar / Fantastical | hash of title, time, and calendar | event, time, location, calendar, details | replace entity state |
| Reminders / task apps | hash of title and list/project | task, completion state, list/project, due date, notes | replace entity state |
| Word / Pages | normalized document title | visible editor text up to 32,000 characters | rolling text |

All raw capture content uses the existing encrypted context/version pipeline. Source keys for email, calendar, and task entities use short hashes so names and subjects are not added to those keys. Source titles remain plaintext thread metadata under the existing schema; raw captured content is encrypted at rest.

The off-screen policies are declared per parser, but Phase 3 still consumes the Accessibility nodes materialized by the application. Declaring a scroll bound does not itself force a virtualized application to materialize older content; deeper safe off-screen traversal remains an incremental coverage task.

## Sanitized fixtures

| Fixture | Contract |
|---|---|
| `whatsapp-conversation.json` | conversation header, sidebar exclusion, atomic message rows |
| `calendar-event.json` | event title, time, location, calendar, notes |
| `reminder-task.json` | task title, open/completed state, list, due date, notes |
| `pages-document.json` | stable document title and rolling editor content |
| pure Mail V2 records | selected message/thread boundary and body capture |

All names and contents in fixtures are invented.

## Live acceptance matrix

The signed Phase 3 build is installed and running. Complete the following with MaxMi unpaused, then run `tools/check-native-coverage.sh`:

| Installed app | Representative state | Expected parser/outcome | Status |
|---|---|---|---|
| WhatsApp | open a conversation containing several visible messages | `WhatsAppParser`, captured or deduplicated | pending v2 live |
| Mail | select an opened message/thread and allow MaxMi → Mail Automation if prompted | `MailParser`, captured or deduplicated | pending v2 live |
| Calendar | open an event detail popover | `CalendarParser`, captured or deduplicated | pending live |
| Reminders | select a task with list and due date visible | `RemindersParser`, captured or deduplicated | pending live |
| Fantastical | open an event detail | `FantasticalParser`, captured or deduplicated | pending live |

An empty/not-handled result is recorded as `parserNoContent`; registered parsers never silently fall through to generic capture. Capture Health stores the parser, trigger, outcome, reason, character count, truncation flag, and duration without storing diagnostic copies of content.

## Phase 7 live acceptance update

On 2026-07-15 the signed build was verified with synthetic, reversible items where
the application permits them. Only Capture Health parser/outcome/count metadata and
content-free AX role inventories were inspected. The Calendar event, Reminder, and
unsent Mail draft were removed after the check.

| Installed app | Controlled state | Parser result | Result |
|---|---|---|---|
| WhatsApp | existing visible conversation; no text inspected | `WhatsAppParser` captured 65 characters after Electron semantic-label support | pass for visible AX content; history depth remains a future limitation |
| Mail | unsent synthetic draft | `MailParser` captured/deduplicated | pass |
| Calendar | selected synthetic event detail | `CalendarParser` deduplicated a 104-character detail capture | pass |
| Reminders | selected synthetic reminder | `RemindersParser` captured 268 characters | pass |
| Fantastical | synthetic event-creation detail via its documented URL action | `FantasticalParser` captured 86 characters | pass |

Calendar and Fantastical intentionally require a focused detail/editor surface rather
than consuming the entire calendar grid. WhatsApp on this installed build exposes only
62 AX nodes and much of the visible text as button/heading descriptions; the parser now
uses those semantic labels within the conversation pane. It does not yet prove safe
deep-history traversal in WhatsApp.
