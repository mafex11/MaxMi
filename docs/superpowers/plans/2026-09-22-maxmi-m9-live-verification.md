# MaxMi M9 Live Verification

Run this after the full XCTest gate passes. This is verification only; do not modify source while following it. Do not reset TCC permissions.

## Rebuild and relaunch

- [ ] Quit the running app with the exact command:

  ```bash
  pkill -9 -x MaxMi
  ```

- [ ] Build the application bundle:

  ```bash
  ./packaging/make-app.sh
  ```

  Expected: command exits 0 and produces `MaxMi.app`.

- [ ] Launch the freshly built application:

  ```bash
  open MaxMi.app
  ```

- [ ] Grant MaxMi Accessibility access if macOS asks. Do not grant Input Monitoring solely for this feature.

## Double-tap panel behavior

- [ ] Keep another app frontmost, then tap and release Option twice with each hold at most 250 ms and the two downs 40–350 ms apart inclusive.
- [ ] Confirm the always-dark todo panel opens centered on the screen containing the mouse cursor and does not activate MaxMi or steal focus from the other app.
- [ ] Confirm a hold longer than 250 ms, a second tap beginning within 39 ms, and a second tap beginning at least 351 ms after the first down do not open the panel.
- [ ] Confirm that adding Shift, Control, Command, or Function to either tap resets the detector and does not open the panel. An Option+letter chord is not observable by the flags-only monitor; two such quick chords can toggle the panel and this is accepted.
- [ ] Confirm the panel is always dark, has a fixed 520-point width, and does not exceed 60% of the current screen’s visible height.
- [ ] Click inside the panel, then verify Up/Down wraps selection, Return resolves the selected row, Delete dismisses it, and Escape closes the panel.
- [ ] Reopen it, click outside it, and double-tap Option again; verify each closes it.

## Action-item and reminder behavior

- [ ] Ensure an open hourly-review action item exists. Open the panel and verify the newest items appear first, with at most 25 rows.
- [ ] Verify a row’s subtitle is `sourceApp · age`, and a row with `remind_at_ms` set but `reminded_at_ms` unset shows a clock glyph.
- [ ] Click **Done** on one row and verify it resolves the item, removes the row, and it remains absent on the next open.
- [ ] Click **Dismiss** on another row and verify it hides the row and it remains absent on the next open.
- [ ] Confirm an action item originating from a **Keep Local** source never appears in the panel.
- [ ] Stop MaxMi again, seed the most-recent existing open item one minute ahead while the database is closed, then relaunch:

  ```bash
  pkill -9 -x MaxMi
  MAXMI_DB="$HOME/Library/Application Support/MaxMi/maxmi.db"
  MAXMI_ITEM_ID="$(sqlite3 "$MAXMI_DB" "SELECT id FROM agent_action_items WHERE status='open' ORDER BY detected_at DESC, id ASC LIMIT 1;")"
  MAXMI_NOW_MS="$(( $(date +%s) * 1000 ))"
  test -n "$MAXMI_ITEM_ID"
  sqlite3 "$MAXMI_DB" "UPDATE agent_action_items SET remind_at_ms=$((MAXMI_NOW_MS + 60000)), reminded_at_ms=NULL WHERE id='$MAXMI_ITEM_ID' AND status='open';"
  open MaxMi.app
  ```

  Expected: `test -n` exits 0, one open action row receives a reminder exactly 60,000 ms ahead, and MaxMi relaunches.

- [ ] Wait through the next 30-second pipeline tick and confirm a notification appears with the action-item title and `sourceApp · age`, never item details or raw capture text.
- [ ] Confirm the first notification causes macOS to show the notification-permission prompt.
- [ ] Click the notification and confirm the todo panel opens.
- [ ] Deny notifications in System Settings, seed another due reminder, and confirm no notification appears while the panel still shows its clock glyph.
