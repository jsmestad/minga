# Native editor automation (minga-ipc)

Use the bundled `minga-ipc` helper when an automation or test harness needs to open files, inspect semantic targets, or drive navigation against a running macOS `Minga.app` instance with explicit readiness receipts.

## Wait for a native editor result

Use `minga-ipc open-ready` when an automation needs to know that one file open reached the editor's native interaction boundary. The GUI launcher bundled in `Minga.app`, and the existing `minga-ipc open` and `minga-ipc wait` commands, keep their semantic-only completion behavior.

```bash
MINGA_IPC="/Applications/Minga.app/Contents/Resources/bin/minga-ipc"
"$MINGA_IPC" open-ready --deadline-ms=10000 /absolute/path/to/notes.md
```

The command writes one JSON result to standard output and exits zero only when `receipt.outcome` is `ready`. Save the identity fields if a separate process must inspect the completed receipt later.

```json
{"receipt":{"app_instance_id":"...","core_instance_id":"...","operation_id":"...","phase":"terminal","outcome":"ready","target":{"path":"/absolute/path/to/notes.md","window_id":1},"application_revision":42,"evidence":{"boundary":"metal_drawable_completed","focus_ready":true},"detail":null}}
```

```bash
"$MINGA_IPC" wait-receipt --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --operation-id "$OPERATION_ID" --deadline-ms 10000
"$MINGA_IPC" receipt --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --operation-id "$OPERATION_ID"
```

`wait-receipt` only observes the original operation. It never opens the file again. A waiter has a finite deadline from 1 through 30,000 milliseconds. Disconnecting, cancelling, or timing out a waiter releases only that wait. It does not undo or repeat an editor action that the BEAM already applied.

The receipt separates three facts: `admitted` means the local service accepted the request, `applied` means the BEAM opened the exact target and recorded its semantic revision, and terminal `ready` means the matching editor target reached its native boundary with the required focus. The result includes the target token, pane, revision, renderer generation, frame sequence, and focus evidence so a newer unrelated frame cannot satisfy the request.

`metal_drawable_completed` is the strongest boundary the current editor surface can prove. CoreText and Metal completed the matching drawable submission, and the editor focus policy passed when focus was requested. It is not a claim that macOS composited pixels to a physical display. SwiftUI and AppKit surfaces that cannot prove their own requested readiness return `unavailable` instead of borrowing editor evidence.

Terminal outcomes are explicit. `rejected` means the BEAM could not apply the request. `presentation_failed`, `hidden`, and `unavailable` distinguish failed rendering, a hidden surface, and a missing native prerequisite. `superseded` means a newer target replaced the requested target before it became ready. `timeout` and `cancelled` describe the wait rather than the editor action. `app_replaced`, `core_replaced`, `expired`, and `unknown` mean the supplied receipt identity cannot be observed in the current generation. Failed receipts include a machine-readable outcome and may include a human-readable `detail`. After admission, even timeout or transport failure output preserves the accepted receipt identity. A lost response can leave execution indeterminate, so look up the saved receipt before deciding whether to retry.

Receipts are intentionally bounded. Minga accepts at most 64 active operations and 64 waiters, retains at most 128 terminal receipts for 60 seconds, and converts an operation that receives no native result within 30 seconds to `indeterminate`. Expired receipts retain no view or frame resources. The receipt includes `last_visible` when a newer attempted presentation fails, so callers can distinguish the failed target from the prior valid target, application revision, and frame.

## Inspect and navigate the native editor

Use `minga-ipc inspect` to obtain exact semantic targets before you navigate. The helper authenticates through the same private descriptor and AF_UNIX endpoint as `open-ready`.

```bash
"$MINGA_IPC" capabilities
"$MINGA_IPC" inspect --choice-limit 25
```

`capabilities` lists the finite command set, coordinate convention, page limits, receipt outcomes, and 64 KiB response limit. `inspect` returns two separate views. `authoritative` is current BEAM state, including tabs, panes, buffer identities and revisions, cursor positions, bounded viewport lines, and picker choices. `presented` is the last editor frame that the macOS frontend proved at the Metal completion boundary, including native focus evidence. A committed BEAM target can be newer than the last proven native presentation.

Copy identity, ids, revisions, and opaque target tokens from one inspection response. Do not derive or cache tokens across a core restart.

```bash
"$MINGA_IPC" select-tab --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --tab-id 2 --target-token "$TAB_TOKEN"
"$MINGA_IPC" focus-pane --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --tab-id 2 --pane-id 4 --target-token "$PANE_TOKEN"
"$MINGA_IPC" goto-location --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --tab-id 2 --pane-id 4 --target-token "$PANE_TOKEN" --buffer-id "$BUFFER_ID" --buffer-revision 17 --line 12 --column 6
"$MINGA_IPC" activate-picker-choice --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --target-token "$PICKER_TOKEN" --picker-generation 31 --activation-id 5 --choice-kind item
```

Successful navigation prints the terminal receipt as JSON. Native editor targets normally finish as `ready`; picker activation finishes as `applied` because the BEAM-owned picker workflow is the terminal boundary.

```json
{"type":"completed","receipt":{"kind":"focus_pane","outcome":"ready","result_code":"ready","target":{"requested_token":"761","token":"928","tab_id":2,"window_id":4},"evidence":{"boundary":"metal_drawable_completed","focus_ready":true}}}
```

A stale target returns a nonzero helper status and a structured rejection that can be inspected without replaying the action.

```json
{"type":"completed","receipt":{"kind":"goto_location","outcome":"rejected","result_code":"stale_revision","rejection":{"code":"stale_revision","stale_target":true}}}
```

Lines are one-based. Columns are zero-based UTF-16 code-unit offsets. `goto-location` rejects a line outside the document, a column outside the line, and any column that is not an exact Minga caret boundary, including positions inside surrogate pairs, combining sequences, and joined emoji. It does not clamp or redirect the request. Picker activation uses the same item or Actions entry route as native UI activation.

Inspection is bounded. The first response includes at most eight tabs, eight panes across that page, eight viewport lines per pane, and the requested picker choice page up to 25 choices. When `truncation.tabs`, `truncation.panes`, or `truncation.picker_choices` is true, pass the corresponding opaque value from `continuations.tabs`, `continuations.panes[tab_id]`, or `continuations.picker_choices` back to `inspect --continuation`. A continuation is valid only for the inspection revision that created it. Minga rejects it as stale after any relevant tab, pane, buffer, or picker change.

Every navigation command applies against the exact inspected target inside the serialized Editor process. An old app or core identity is rejected before admission. A removed tab or pane, replaced buffer or picker, outdated buffer revision, or missing offered choice produces a terminal `rejected` receipt with `result_code` and `rejection.code`. `rejection.stale_target` tells callers that a fresh inspection is required. Receipt lookup and wait observe the admitted operation and never replay it.

The endpoint accepts only the documented typed commands. It does not accept arbitrary code, selectors, key sequences, or accessibility queries. Requests and responses retain the existing 64 KiB frame limit. Invalid field types, zero-valued one-based ids, unsupported commands, and oversized responses fail explicitly.
