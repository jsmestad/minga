# ZigZag final decision

Decision: **adopt ZigZag as the Zig TUI framework under the Go/Bubble Tea Port boundary**.

Keep ZigZag in the current `minga-renderer` path as the terminal framework, component-adapter library, and local derived-state helper. Do not introduce a `minga-renderer-zigzag` product path and do not let ZigZag own BEAM semantics. The corrected stack now mirrors the Go/Bubble Tea renderer shape: terminal framework on the TTY, stdout reserved for BEAM packets, BEAM-owned semantic state, and local frontend presentation adapters.

## What changed from the first decision

The first decision undercounted ZigZag because the earlier PR stack mostly recorded fit checks and then rejected runtime adoption. After correction, ZigZag is used or exercised across the current renderer path:

- Structural chrome: `TabGroup`, `Tree`, `StatusBar`, and `SplitPane` are used as presentation/layout adapters in #2194.
- Editor body: `Viewport`, `CodeView`, and `renderWithRanges` are exercised as fit helpers in #2195, while BEAM keeps semantic ownership for spans, selections, diagnostics, scroll-left, and durable editor state.
- Overlays: #2196 adopts every feasible overlay adapter from the evaluation: `Help`, `List`, `CommandPalette`, `VirtualList`, `Tooltip`, `Table`, `DataTable`, and `RichLog`. `Markdown`, `TextInput`, `TextArea`, and `Dropdown` remain blocked with explicit reasons.
- Hit testing: `HitBox` and `MouseState` are used for local coordinate mapping and transient interaction metadata in #2197.
- Runtime: #2198 adopts `zz.Program` with a Minga adapter loop, custom TTY input/output, stdout packet isolation, BEAM stdin packet handling, `port_writer` backpressure, semantic rendering, and recovery handling.

That changes the final recommendation. ZigZag is not just a fit-check dependency or a hitbox helper. It is the right Zig-side analogue to Go/Bubble Tea when it is adapted to Minga’s Port model.

## Correct boundary

The evidence from #2183 through #2190 points to a specific boundary:

- ZigZag may own terminal lifecycle and frame presentation on `MINGA_TTY` or `/dev/tty`.
- ZigZag components are valuable when they adapt retained semantic payloads into local presentation data.
- ZigZag predefined components should be used where they fit, following the Go/Charm adapter pattern.
- ZigZag must not write to stdout, own query/filter/focus source-of-truth, command dispatch, semantic payload meaning, durable editor state, or the Port protocol.
- `port_writer` remains the backpressure boundary for BEAM events.

The key distinction is not “runtime ownership is forbidden.” The key distinction is **TTY runtime is allowed, stdout/protocol/semantics ownership is not**.

## Approved ownership

ZigZag may own local frontend/runtime data that can be recomputed from BEAM-owned semantics:

- Terminal lifecycle on the TTY through `zz.Program`.
- Frame presentation as a terminal view derived from retained semantic packets.
- Presentation rows derived from retained semantic payloads.
- Local layout measurements and split geometry.
- Local hitbox computation and transient mouse metadata.
- Fit checks that prove whether a component can preserve Minga semantics.
- Component adapter internals, as long as their state mirrors BEAM-owned state and is not authoritative.

## Components used or evaluated

Used in the current renderer path:

- `Program`: owns terminal lifecycle and frame presentation on the TTY through the Minga adapter.
- `TabGroup`: derives tab active-state presentation for the tab strip.
- `Tree`: reconstructs file-tree row presentation from Minga’s retained flat visible row model.
- `StatusBar`: derives right-segment layout for status/modeline rendering.
- `SplitPane`: computes picker preview split geometry.
- `Help`: formats which-key binding rows without leaking ANSI output into Minga cells.
- `List`: computes completion visible rows and selected-item viewport behavior.
- `CommandPalette`: mirrors picker row presentation while query/filter/acceptance stay BEAM-owned.
- `VirtualList`: computes picker viewport rows for large candidate lists.
- `Tooltip`: shapes plain hover/signature rows while styled semantic hover rows fall back to Minga rendering.
- `Table`: adapts tool manager rows.
- `DataTable`: adapts board card rows.
- `RichLog`: computes agent transcript visible message indices.
- `HitBox`: maps local terminal coordinate regions for semantic mouse handling.
- `MouseState`: available for transient local interaction metadata.

Used as fit or feasibility evidence, not runtime owners:

- Editor body: `Viewport`, `CodeView`, and `renderWithRanges`.
- Blocked overlay candidates: `Markdown`, `TextInput`, `TextArea`, and `Dropdown`.

These components are allowed as adapters, not authorities. A ZigZag component may render or compute from BEAM-owned query text, selection, transcript state, table rows, hover content, or status segments. It must not become the source of truth for query state, focus, filtering, selection, command execution, semantic payloads, or protocol meaning.

## Surfaces that stay Minga/BEAM-owned

- Protocol encoding and decoding, including GUI action payload meaning.
- stdout as the BEAM Port packet stream.
- `port_writer` queueing and drain/backpressure behavior.
- Durable editor state, command dispatch, file buffers, focus ownership, and semantic UI payload ownership.
- Query/filter/focus source-of-truth, selected item state, transcript state, and overlay action routing.
- Editor-body semantic correctness contracts: Unicode width, semantic style spans, selections, diagnostics, scroll-left, gutters, and indent guides.

## Go/Charm precedent

Go/Charm is the quality-bar precedent. It uses Bubble Tea as the terminal runtime against `/dev/tty`, keeps stdout reserved for BEAM packets, decodes Semantic UI state, and uses components as adapters over that decoded state.

ZigZag should follow that pattern. The final decision now does that: use `zz.Program` for terminal lifecycle and frame presentation, then keep Minga’s adapter loop responsible for BEAM packet boundaries and semantic ownership.

## Runtime boundary

ZigZag must not write to stdout. Minga’s renderer is a BEAM Port process, so stdout is protocol data. Any terminal output on stdout risks corrupting the BEAM packet stream.

The corrected renderer keeps the safe boundary:

- stdout: BEAM packets only.
- TTY: ZigZag terminal interaction and frame presentation.
- stdin: BEAM-to-renderer length-prefixed semantic packets.
- resize: observed through ZigZag terminal state and routed to BEAM as resize packets.
- paste: parsed by ZigZag and routed to BEAM as one `paste_event` packet.
- keyboard/mouse: parsed by ZigZag, mapped through Minga protocol helpers, and routed to BEAM.
- backpressure: existing `port_writer` queue and drain path.

## Follow-up guardrails

1. Add a guardrail that rejects terminal output to stdout from renderer modules.
2. Require any ZigZag runtime use to pass explicit TTY input/output handles, never default stdout.
3. Keep adapter output plain before it reaches Minga cell data. ANSI belongs only in final TTY presentation, not semantic cells or retained payloads.
4. Require component adapters to document which state is BEAM-owned and which derived state ZigZag may compute locally.

## Final recommendation for #2182

Adopt ZigZag seriously in the current `minga-renderer` path. Use `zz.Program` as the Zig TUI framework, use predefined components where they fit as presentation adapters over BEAM-owned semantic state, and keep stdout, protocol meaning, commands, and durable editor semantics owned by Minga/BEAM.
