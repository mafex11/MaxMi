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
| `slack-composer-draft.json` | Hand-authored Slack-shaped window at a nonzero origin with a focused composer, plus a second focused text area inside the message `AXList` | `ComposerDraft` picking the composer, not the list descendant |

Never commit real page text, messages, file contents, URLs, names, or tokens. Preserve only the minimum role/frame structure required for a regression test.
