# MaxMi M8 Phase D web-host live verification

This is a human-run checklist for the five host-routed web parsers. Automated tests prove the
hand-authored, scrubbed fixtures and registration; they do not prove a browser's live
Accessibility shape.

Do not run `AXSnapshotRecord` or `tools/ax-snapshot-record.swift`, inspect an AX tree, copy a live
window, or commit captured content while completing this checklist. Record only pass/fail, capture
timestamp, Capture Health parser/outcome, and a short structural result.

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
`open` returns, record the local wall-clock time. Every accepted capture below must have a
timestamp strictly later than that time.

For each row, open the named surface in a browser tab, perform the action, wait for a capture tick,
and call `get_latest_context` with the listed arguments. Confirm that the returned capture is
newer than the recorded process-start time before checking only its structure.

| Host | Action | `get_latest_context` arguments | Expected structural result |
|---|---|---|---|
| Gmail (`mail.google.com`) | Open a thread with two expanded messages, then start an unsent reply. | `{"source":"Web","content_kinds":["email"],"limit":1}` | One nonempty attributed, timed line per expanded message, followed by an attributed draft line. No empty line from a collapsed message. |
| LinkedIn messaging (`linkedin.com/messaging`) | Open a conversation containing a reply from the signed-in user. Then open the LinkedIn feed. | `{"source":"Web","content_kinds":["conversation"],"limit":1}` | Other participants are attributed and timed; the signed-in user's message renders as `From: You`. The subsequent feed capture is generic, begins with `URL: https://www.linkedin.com/feed/`, and has region headers rather than conversation lines. |
| Outlook web (`outlook.office.com`) | Open a message in the reading pane. | `{"source":"Web","content_kinds":["email"],"limit":1}` | One attributed, timed line per message card. The body does not retain `From:` or `Sent:` header text. |
| Slack web (`app.slack.com`) | Open a channel, type a draft, and leave it unsent. | `{"source":"Web","content_kinds":["conversation"],"limit":1}` | Sender-attributed, timed message lines match native Slack's rendered form, followed by an attributed draft line. |
| Teams web (`teams.microsoft.com`) | Open a chat with messages from two different people. | `{"source":"Web","content_kinds":["conversation"],"limit":1}` | Two separately attributed lines. `From: unknown` is acceptable only if the documented AXDescription fallback is the active tier. |

## Cross-cutting checks

1. Gmail empty compose: open a Gmail compose window with an empty body, wait for a capture tick,
   then inspect Capture Health. The outcome is a skip with reason `parser_no_content`; it is not a
   failure and no empty capture is stored.
2. Gmail fallback: open a Gmail Settings surface with no matching content anchor. The next capture
   is generic, and Capture Health's parser starts
   `GenericPageExtractor.v2/fallback/GmailParser`.
3. Header provenance: re-read the `ANCHORS` block in `GmailParser.swift`,
   `LinkedInMessagingParser.swift`, `OutlookWebParser.swift`, `SlackParser.swift`, and
   `TeamsWebParser.swift`. The listed DOM class/identifier anchors must remain explicitly marked
   as fixture-verified or `NOT EXPOSED` with their replacement. Do not change that provenance to a
   live-verification claim: this checklist does not authorize AX-tree observation.

## Minimal execution record

Keep the completed record outside the repository unless it contains only the metadata below.
Never include message text, names, addresses, tokens, private URLs, or screenshots.

| Check | Capture timestamp after `open` | Parser/outcome or shape result | Pass |
|---|---|---|---|
| Gmail thread and draft |  |  |  |
| LinkedIn messaging and feed fallback |  |  |  |
| Outlook reading pane |  |  |  |
| Slack web channel and draft |  |  |  |
| Teams web chat |  |  |  |
| Gmail empty-compose refusal |  |  |  |
| Gmail Settings generic fallback |  |  |  |
| Parser-header provenance |  |  |  |
