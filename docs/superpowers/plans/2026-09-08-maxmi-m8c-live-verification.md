# MaxMi M8 Phase C live verification

This checklist is human-operated. Use only non-sensitive synthetic markers below; do not
put personal or confidential content into a capture merely to perform this check.

## Rebuild and start

Run these commands from the repository root. Do not reset TCC: the Accessibility grant
persists across signed rebuilds. Record the time immediately after the `open` command and
verify only captures timestamped strictly later than that time.

```bash
./packaging/make-app.sh
pkill -9 -x MaxMi
open MaxMi.app
```

Wait until the menu-bar app is running, then use the MCP client connected to the bundled
`MaxMi.app/Contents/MacOS/maxmi-mcp`.

## 1. Typed capture rendering

1. In a non-sensitive app, display a short synthetic sentence such as `typed-sentence-cobalt-271`.
2. Wait for a fresh capture after the recorded start time.
3. In the MCP client, call:

   ```text
   get_latest_context({"limit": 3})
   ```

Expected: the new context is readable structured prose/sentences. It is not an Accessibility
tree dump, and it contains none of `enc:v1:`, a JSON `structured` field, or `[user]`.

## 2. Conversation delta summary

1. Open a non-sensitive conversation that already contains the synthetic marker
   `history-only-linden-201`, and wait until MaxMi has captured it.
2. Add one new message containing `delta-only-aster-419`, then wait for the next capture.
3. Call:

   ```text
   get_latest_context({"content_kinds":["conversation"],"limit":1})
   ```

Expected: the newest conversation summary describes the new `delta-only-aster-419` message and
does not repeat the already-captured `history-only-linden-201` message.

## 3. Raw-content context match

1. Display the inert marker `raw-only-nebula-anchor-473` in the body of a new non-sensitive
   capture. Do not put it in the title or URL, and wait for the capture to commit.
2. Confirm the marker is absent from extracted facts, then call:

   ```text
   search_memory({"query":"raw-only-nebula-anchor-473","limit":10})
   ```

Expected: the response has a `### Matching context` section containing the marker. The result
has source, title, time, and thread metadata; it is supplementary to the unchanged fact
results/cursor/footer, has no more than five context rows, and each context snippet is compact
(at most 300 characters).

## 4. Hourly review source references

1. Enable Activity Synthesis and create a fresh, clearly actionable synthetic capture, for
   example `Follow up on hourly-review-cyan-638`.
2. Leave MaxMi running until the overdue-on-launch review or the next hourly review finishes.
   If no action item is created, add a distinct actionable capture and wait for the next review;
   do not mark this check complete for a no-op response.
3. In Terminal, inspect the most recent review and its source references:

   ```bash
   sqlite3 "$HOME/Library/Application Support/MaxMi/maxmi.db" \
     'SELECT id, prompt_version, status FROM agent_runs ORDER BY started_at DESC LIMIT 3;'
   sqlite3 "$HOME/Library/Application Support/MaxMi/maxmi.db" \
     'SELECT i.id, j.value AS source_version_id, EXISTS(SELECT 1 FROM versions AS v WHERE v.id=j.value) AS source_version_exists FROM agent_action_items AS i, json_each(i.source_refs) AS j WHERE i.source_refs IS NOT NULL ORDER BY i.updated_at DESC LIMIT 10;'
   ```

Expected: a completed recent run uses `agent-review-v2-versions`; every displayed
`source_version_id` is a version ID with `source_version_exists` equal to `1`.

## 5. Today card and manual check-in

1. Open the MaxMi menu-bar menu and select **Check in now**.
2. Open the tray popover and wait through a possible “being prepared” state.

Expected: a **Today** card appears with the generated check-in. The card remains dark even when
macOS is using a light appearance.

## 6. Dismissal for the local day

1. On the Today card, select **Dismiss**.
2. Close and reopen the tray popover during the same local day.

Expected: the Today card stays hidden for the rest of that local day.

## 7. Per-source privacy

1. Before showing the next marker, use **Pause capture for ▸** in the MaxMi menu to pause the
   selected non-sensitive source (the per-source privacy denylist).
2. In that paused source, display `private-redwood-956` and wait longer than one capture
   interval.
3. Call:

   ```text
   search_memory({"query":"private-redwood-956","limit":10})
   ```

4. Select **Check in now**, then inspect the Today card.
5. Resume the source from **Pause capture for ▸** after the check.

Expected: the marker and its source do not appear in context matches, and the Today card does
not mention the marker. A paused/denylisted source therefore contributes neither searchable raw
context nor a check-in.
