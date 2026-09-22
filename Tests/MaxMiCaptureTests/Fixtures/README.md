# Capture fixtures

Fixtures contain scrubbed Accessibility-tree shapes and invented content only.

| Fixture | Source evidence | Expected route |
|---|---|---|
| `cursor-editor.json` | Cursor 3.11.19, live-verified 2026-07-14; editor exposed as `AXTextArea` | `GenericAXParser`, document/rollingText |
| `chromium-gmail-thread.json` | Sanitized Chromium Gmail thread shape | email web profile |
| `gecko-slack-chat.json` | Sanitized Gecko Slack message-row shape | sender/message boundaries |
| `whatsapp-conversation.json` | Sanitized native WhatsApp split-pane shape | conversation identity and message rows |
| `calendar-event.json` | Sanitized native event-detail shape | event title/time/location/calendar |
| `reminder-task.json` | Sanitized reminder-detail shape | task status/list/due date |
| `pages-document.json` | Sanitized word-processing editor shape | stable document identity and rolling text |
| `chrome-article.json` | Chromium article shape | `BrowserTabExtractor` |
| `safari-domain-only.json` | Safari address fallback shape | `BrowserTabExtractor` |
| `slack-window.json` | Native Slack message-row shape | `SlackParser` |
| `zen-meet.json` | Gecko web-area shape | blocked meeting URL |
| `ax-attributes.json` | Hand-authored attribute coverage shape | `AXNode` decoding of subrole/headingLevel/selected/placeholder/selectedText/hidden |
| `finder-offset-window.json` | Hand-authored Finder-shaped window at a nonzero screen origin, including a row whose name cell is an editable text field | `GenericPageExtractor` sidebar/main/toolbar regions, joined table rows, text-field name cells |
| `web-table-with-columns.json` | Hand-authored web table that republishes its cells as `AXColumn`s | `GenericPageExtractor` emitting each cell once |
| `dialog-over-window.json` | Hand-authored sheet-over-window shape at a nonzero screen origin | `GenericPageExtractor` `.dialog` region and dialog-never-trimmed budgeting |
| `dom-attributes.json` | Hand-authored web-area DOM shape at a nonzero window origin | `AXNode` decoding of `domClassList`/`domIdentifier`, `AXQuery` `domClass`/`domId` predicates |
| `slack-composer-draft.json` | Hand-authored Slack-shaped window at a nonzero origin with a focused composer, plus a second focused text area inside the message `AXList` | `ComposerDraft` picking the composer, not the list descendant |
| `generic-empty-golden.json` | Hand-authored deterministic `CapturedContentEnvelope` for an empty generic page | Fixture loader golden encoder/decoder |
<!-- lane-c begin -->
| `finder-list.json` | Hand-authored scrubbed Finder list-view shape at the screen origin | `FinderParser` sidebar, listing, selection and toolbar regions |
| `finder-list-golden.json` | Golden `CapturedContentEnvelope` for `finder-list.json` | `FinderParser` |
| `finder-offset-copy.json` | Hand-authored scrubbed Finder copy-progress shape at a nonzero screen origin | `FinderParser` sidebar, listing, selection and toolbar regions |
| `finder-offset-copy-golden.json` | Golden `CapturedContentEnvelope` for `finder-offset-copy.json` | `FinderParser` |
| `calendar-event-golden.json` | Golden `CapturedContentEnvelope` for `calendar-event.json` | `CalendarParser` |
| `calendar-offset-event.json` | Hand-authored scrubbed Calendar event-detail popover at a nonzero screen origin | `CalendarParser` event detail, sidebar filtering and conference metadata |
| `calendar-offset-event-golden.json` | Golden `CapturedContentEnvelope` for `calendar-offset-event.json` | `CalendarParser` |
| `reminder-task-golden.json` | Golden `CapturedContentEnvelope` for `reminder-task.json` | `RemindersParser` detail fallback |
| `reminders-offset-list.json` | Hand-authored scrubbed Reminders list at a nonzero screen origin, with open/completed row checkboxes, due date and sidebar chrome | `RemindersParser` row status, ordering and chrome filtering |
| `reminders-offset-list-golden.json` | Golden `CapturedContentEnvelope` for `reminders-offset-list.json` | `RemindersParser` |
<!-- lane-c end -->

Never commit real page text, messages, file contents, URLs, names, or tokens. Preserve only the
minimum role/frame structure required for a regression test.

## Recording a fixture

1. Open the app and put the window you want to capture in front.
2. `swift tools/ax-snapshot-record.swift <bundle-id> /tmp/<name>.json`
3. **Hand-scrub `/tmp/<name>.json`**: replace every message body, file name, note body, person
   name, URL, e-mail address and token with invented equivalents of a similar shape and length.
   Delete subtrees the test does not need. Keep `role`, `subrole`, `frame`, `identifier`,
   `domClassList` and `domIdentifier` intact — those are what the parser anchors on.
4. Move it to `Tests/MaxMiCaptureTests/Fixtures/<name>.json` and add a row to the table above.
5. Golden `CapturedContent`: print `try goldenJSON(parsed)` from the test, scrub it the same way,
   and save it as `Fixtures/<name>-golden.json`.

At least one fixture per parser must be recorded with the window at a **nonzero screen origin**
(drag it onto a second display or away from the top-left corner first). `AXFrame` is global
screen coordinates, and a flush-at-origin fixture cannot catch a missing window-relative
conversion.
