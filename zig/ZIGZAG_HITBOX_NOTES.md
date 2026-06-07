# ZigZag semantic hitbox notes

Ticket #2188 uses ZigZag hitbox primitives only for local coordinate mapping in the current renderer. Minga still owns the meaning of each mouse click through retained semantic state and the existing BEAM packet protocol.

What changed:

- `zig/src/semantic/hitbox.zig` wraps ZigZag `HitBox` and `MouseState` in terminal row/col terminology.
- Retained file tree body rows and directory toggles now route through that wrapper.
- Gutter fold toggles now route through that wrapper.
- Tab bar hit regions now route through that wrapper.
- Hover action hit regions now route through that wrapper.
- Modeline command segments now route through that wrapper and encode the existing `execute_command` GUI action string payload.
- Raw editor-body fallback is unchanged: when no semantic hitbox matches, `apprt/tui.zig` still encodes the original mouse event packet.

What stayed BEAM-owned:

- Action IDs and payloads are unchanged.
- File tree click/toggle, tab select, fold toggle, hover action, modeline command, and raw mouse fallback still encode the same packets as before.
- ZigZag does not dispatch editor commands or mutate durable editor state.
- ZigZag does not own semantic UI payloads.

Retained custom routing boundaries:

- File tree row semantics still come from retained BEAM row IDs and flags. ZigZag only maps the point into a row rectangle.
- Gutter fold actions still require retained buffer line and window IDs. ZigZag only maps the sign-column rectangle.
- Tab actions still use retained tab IDs. ZigZag only maps the painted tab span.
- Hover actions still use retained hover action visibility and the existing anchored overlay rect. ZigZag only maps the action row.
- Modeline command segments still use retained `StatusSegment.command` values. ZigZag only maps the segment span, right segments keep render-order priority over overlapping left segments, oversized commands are ignored so raw fallback remains available, and the existing `execute_command` GUI action remains the BEAM-owned command boundary.

Why this is narrowed:

ZigZag `HitBox` is a good fit for local coordinate mapping, but component-owned hitboxes are not yet used as runtime authorities because the renderer must preserve BEAM-owned packet meaning and current semantic precedence. This evidence is enough for #2191 to decide whether ZigZag stays as a narrow local-helper dependency.
