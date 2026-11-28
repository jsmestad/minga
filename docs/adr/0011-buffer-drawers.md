# ADR-0011: A drawer that shows a buffer is a window the BEAM lays out in rows

**Status:** Proposed (2026-11-27). Extends [ADR-0001](0001-frontend-owns-row-fit.md). Design: [runs.md](../design/runs.md). First user: the run drawer. The terminal drawer (ADR-0008) is the second.

## Decision

1. **Two kinds of drawer.** A list drawer (tasks, the switcher) shows a semantic list and is drawn by the frontend outside the editor grid, as today. A buffer drawer (runs, the terminal) shows a buffer, and its content is a real window.
2. **The BEAM lays out a buffer drawer in rows inside the reported grid.** The frontend reports the rows that fit, as it does for any window, and the drawer's chrome cost as a whole number of rows, rounded up. The BEAM decides in rows whether the drawer fits and how tall it is. No handshake is needed.
3. **The header is chrome.** It is drawn at 24 pt at every row pitch. Leftover points under the last content row are drawer background. The divider drags in points as a local preview and commits as a row count.
4. **The BEAM owns the drawer's interaction state:** whether it opened by itself or you opened it, whether you have touched it, a pending reveal with its settle and expiry, the no-flap timestamps, and the follow flag.
5. **The frontend reports facts, not decisions:** a gesture in progress (a held pointer button, a scroll or its momentum, a live resize, a full-screen transition), pointer enter and leave on the drawer, scrolled away from the bottom and back, and foreground. The scroll facts generalize the ones that exist for the agent chat today.
6. **Facts belong to the frontend that most recently sent a key.** When another frontend takes over, they reset to idle and pointer-outside. With no frontend attached, nothing reveals.

## Context

The tasks drawer sits outside the editor grid and the frontend owns its height. That works for a list. A buffer drawer shows text with a cursor, folds and row identity, and the BEAM is the layout authority for buffer content, so the BEAM has to know how many rows the drawer has.

The run design also opens a drawer without a keypress, when a check fails. Its rules depend on things only the frontend sees (a drag in progress, the pointer inside the drawer) and things only the BEAM sees (the mode, a pending operator, every keypress). An early draft had the frontend answer whether the drawer fits. That puts a layout decision on the wrong side: ADR-0001 says the frontend reports row fit and the BEAM lays out in the rows it is given.

## Options compared

**Draw buffer drawers outside the grid, like list drawers.** The frontend would lay out buffer text, which duplicates layout authority per frontend.

**Let the frontend decide whether a self-opening drawer fits.** It needs a request and a reply for a decision that is a comparison of two row counts.

**Report rows and facts; decide on the BEAM.** One layout authority, no round trip, and the rules about when a drawer may open by itself live in one place.

## Consequences

- `MingaEditor.Layout.GUI` gains a buffer-drawer region inside the grid. Native drawers outside the grid remain for lists.
- The protocol gains the chrome-cost report and the gesture and pointer facts. Both frontends send them.
- The Room test can be conservative by less than one row, because the chrome cost is rounded up.
- A buffer drawer under a split is a window, so it takes a window label when labels are showing ([ADR-0009](0009-one-modeline-and-window-labels.md)).
