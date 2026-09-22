# MaxMi M8 Phase D native live verification

This is a human-run checklist. Automated tests and the app-package build do not prove the
Accessibility shapes exposed by installed apps. Do not record, copy, or commit live captured
content while completing this checklist.

## Rebuild ritual

First check whether MaxMi is already running:

```sh
pgrep -x MaxMi
```

If that prints a PID, do not launch another instance. Ask the human who owns that session to run
the ritual below. If it prints nothing, the human should still run this exact command from the
repository root:

```sh
./packaging/make-app.sh && pkill -9 -x MaxMi && sleep 2 && open MaxMi.app
```

Never run `tccutil reset`: the signed rebuild retains its Accessibility grant. Immediately after
`open` returns, record the local wall-clock time. Every capture accepted below must have a
timestamp strictly later than that time.

For each row, focus the named surface, perform the action, wait for a capture tick, and call
`get_latest_context` with the listed arguments. Confirm the returned capture is newer than the
recorded process-start time before inspecting its `content`.

| App | Action | `get_latest_context` arguments | Expected `content` |
|---|---|---|---|
| Terminal (Warp, Terminal.app, or iTerm2) | Run `swift build`, let it finish, and leave an idle prompt. Then start `swift test` and read while it runs. | `{"source":"<terminal app name>","content_kinds":["terminal"],"limit":1}` | Completed command has `$ swift build` followed by output with no `… (running)`; in-progress `swift test` ends with `… (running)`. |
| VS Code | Open a source file with the integrated terminal visible. | `{"source":"Visual Studio Code","content_kinds":["document"],"limit":1}` | `# <filename>` and file lines only; no shell prompt or terminal output. |
| Cursor | Open a source file. | `{"source":"Cursor","content_kinds":["document"],"limit":1}` | `# <filename>` and file lines. |
| Browser generic (Chrome) | Open a documentation article with a sidebar. | `{"source":"Web","content_kinds":["webpage"],"limit":1}` | First line is `URL: https://…`, followed by article content and `## Sidebar`; no address-bar text. |
| Browser generic (Safari) | Open the same kind of article on a second display. | `{"source":"Web","content_kinds":["webpage"],"limit":1}` | Ordered article body, not one alphabetized paragraph; confirms global-frame conversion. |
| Slack | Open a normal channel, type a draft without sending. | `{"source":"Slack","content_kinds":["conversation"],"limit":1}` | Sender-attributed message lines plus `(From: You (draft)): <draft>`. A normal channel must use the verified DOM anchors, not an unanchored row scan. |
| Discord | Open a channel containing two consecutive messages from one person. | `{"source":"Discord","content_kinds":["conversation"],"limit":1}` | Both messages have the same `(From: <name>)`; neither reads `(From: unknown)`. |
| Messages | Open a 1:1 thread containing messages in both directions. | `{"source":"Messages","content_kinds":["conversation"],"limit":1}` | Your messages render `(From: You)` and the other participant's render `(From: <contact>)`. |
| WhatsApp | Open a chat containing messages in both directions. | `{"source":"WhatsApp","content_kinds":["conversation"],"limit":1}` | Your message includes `(From: You)(sent <time>): …`. |
| Mail compose | Open a compose window and enter a subject and body. | `{"source":"Mail","content_kinds":["email"],"limit":1}` | `(From: You (draft)): <body>`. Mail remains AppleScript-sourced on its legacy route; it is not a v2 structured-map registration. |
| Notes | Open a note. | `{"source":"Notes","content_kinds":["document"],"limit":1}` | `# <note title>` followed by note body only; no folder or note-list text. |
| Notion | Open a page with properties and comments visible. | `{"source":"Notion","content_kinds":["document"],"limit":1}` | `# <page title>` followed by document headings/body; no property values or comment rail. |
| Obsidian | Open a note in edit mode, then optionally reading mode. | `{"source":"Obsidian","content_kinds":["document"],"limit":1}` | `# <note name>` followed by note body; no file navigator names. Edit-mode CodeMirror content wins in split view. |
| Finder | Open a folder in list view, select one file, and start a large copy. | `{"source":"Finder","content_kinds":["generic"],"limit":1}` | Pipe-joined rows, `* ` on the selected row, `## Sidebar`, and copy status under `## Toolbar`. |
| Calendar and Fantastical | Open an event with a video link in each installed app. | `{"source":"Calendar","content_kinds":["calendar"],"limit":1}` or `{"source":"Fantastical","content_kinds":["calendar"],"limit":1}` | `<date> — <title> @<location> / <organizer> [conference]`. |
| Reminders | Open a list with one completed and one open item. | `{"source":"Reminders","content_kinds":["task"],"limit":1}` | One `- [x] ` line and one `- [ ] ` line. |

## Cross-cutting checks

1. Open Capture Health. If an anchored parser returns `nil` for an unrecognized shape, its capture
   may fall through with a parser ID beginning
   `GenericPageExtractor.v2/fallback/`. A known non-content surface may instead be refused and
   stored nowhere. A normal anchored surface must not fall back.
2. In an app with a password field, type a unique throwaway value, wait for a capture, then call
   `get_latest_context` with `{"limit":5}`. None of the returned `content` may contain that value;
   `«secure field»` is the expected masked representation.
3. Record only pass/fail, parser ID, capture timestamp, and a short shape result in the verification
   log. Do not copy captured content, credentials, URLs, names, or message bodies into source,
   fixtures, commits, or this document.
