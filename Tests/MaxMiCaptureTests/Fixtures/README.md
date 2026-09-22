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
<!-- // lane-b begin -->
| `slack-dom-messages.json` | Hand-authored Slack DOM-class message list with an invented composer draft | `SlackParser` DOM-class message and draft anchors |
| `slack-dom-messages-golden.json` | Golden `CapturedContentEnvelope` for `slack-dom-messages.json` | `SlackParser` DOM-class conversation output |
| `discord-messages.json` | Hand-authored Discord transcript list at the origin with grouped messages, reaction chrome, and a sidebar | `DiscordParser` tree-order sender attribution |
| `discord-messages-golden.json` | Golden `CapturedContentEnvelope` for `discord-messages.json` | `DiscordParser` conversation output |
| `discord-offset-messages.json` | Hand-authored Discord transcript list at a nonzero origin with the same semantic content | `DiscordParser` geometry-free output |
| `messages-thread.json` | Hand-authored Messages thread for invented Priya Vantar at the origin, with left and right bubbles plus a delivery status | `MessagesParser` bubble-side authorship |
| `messages-thread-golden.json` | Golden `CapturedContentEnvelope` for `messages-thread.json` | `MessagesParser` conversation output |
| `messages-offset-thread.json` | Hand-authored Messages thread for invented Priya Vantar at a nonzero origin with the same left and right bubble geometry | `MessagesParser` window-relative authorship |
| `messages-offset-thread-golden.json` | Golden `CapturedContentEnvelope` for `messages-offset-thread.json` | `MessagesParser` conversation output |
| `whatsapp-bubbles.json` | Hand-authored WhatsApp bubble-cell thread at the origin with a sidebar and timestamp nodes | `WhatsAppParser` bubble-cell anchor |
| `whatsapp-bubbles-golden.json` | Golden `CapturedContentEnvelope` for `whatsapp-bubbles.json` | `WhatsAppParser` conversation output |
| `whatsapp-offset-bubbles.json` | Hand-authored WhatsApp bubble-cell thread at a nonzero origin with the same semantic content | `WhatsAppParser` window-relative authorship |
| `whatsapp-offset-bubbles-golden.json` | Golden `CapturedContentEnvelope` for `whatsapp-offset-bubbles.json` | `WhatsAppParser` conversation output |
| `whatsapp-group-senders.json` | Hand-authored WhatsApp group chat with combined named bubble-cell labels | `WhatsAppParser` structural sender attribution |
| `whatsapp-group-senders-golden.json` | Golden `CapturedContentEnvelope` for `whatsapp-group-senders.json` | `WhatsAppParser` group conversation output |
| `whatsapp-direct-senders.json` | Hand-authored WhatsApp 1:1 chat for invented Priya Vantar, with left and right bubble cells | `WhatsAppParser` bubble-side user attribution |
| `whatsapp-direct-senders-golden.json` | Golden `CapturedContentEnvelope` for `whatsapp-direct-senders.json` | `WhatsAppParser` direct conversation output |
<!-- // lane-b end -->

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
