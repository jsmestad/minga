# ZigZag PR stack audit

This audit records the correction to #2183-#2191. The first stack was too conservative: it mostly linked ZigZag, proved fit, and then made a final decision before adopting enough components or mirroring the Go/Bubble Tea runtime shape. The corrected stack moves adoption into the owning PRs and changes the conclusion.

## Correct standard

Use the Go/Charm pattern:

- BEAM owns semantic payloads, commands, query/filter/focus source-of-truth, durable editor state, and protocol meaning.
- stdout is BEAM Port packets only.
- The terminal framework owns TTY lifecycle and frame presentation.
- The Zig renderer owns local derived presentation state.
- ZigZag components should be used where they can render or compute from BEAM-owned state without taking over behavior.
- Minga’s adapter owns the bridge between BEAM stdin/stdout and ZigZag’s TTY runtime.

## Corrected PR-by-PR status

| PR | Ticket | Corrected status | What changed |
| --- | --- | --- | --- |
| #2192 | #2183 | Foundation | Links ZigZag into the current `minga-renderer` build without introducing a parallel renderer. |
| #2193 | #2184 | Foundation | Adds borrowed semantic view data so components can be fed from retained BEAM-owned packets. |
| #2194 | #2185 | Corrected | Structural chrome now uses `TabGroup`, `Tree`, `StatusBar`, and `SplitPane` as adapters while Minga keeps semantic state and protocol meaning. |
| #2195 | #2186 | Corrected boundary | Editor-body helpers exercise `Viewport`, `CodeView`, and `renderWithRanges`, but BEAM keeps semantic ownership for spans, Unicode, cursor, selections, diagnostics, and scroll-left. |
| #2196 | #2187 | Corrected | Overlays now adopt every feasible adapter from the evaluation: `Help`, `List`, `CommandPalette`, `VirtualList`, `Tooltip`, `Table`, `DataTable`, and `RichLog`. `Markdown`, `TextInput`, `TextArea`, and `Dropdown` remain blocked with explicit reasons. |
| #2197 | #2188 | Correct | Hit testing uses ZigZag `HitBox` and `MouseState` for local terminal coordinate mapping while BEAM keeps packet/action semantics. |
| #2198 | #2189 | Corrected implementation | Runtime now uses ZigZag `Program` against the TTY while stdout remains BEAM packet-only through `port_writer`. The selected `TuiRuntime` is ZigZag-backed; the old libvaxis runtime remains compiled as legacy transition coverage. |
| #2199 | #2190 | Corrected evidence | Bakeoff now counts broader component adoption and ZigZag Program adoption, not only hitboxes. |
| #2200 | #2191 | Corrected decision | Final decision is “adopt ZigZag as the Zig TUI framework under the Go/Bubble Tea Port boundary.” |

## Corrected component and runtime adoption

Runtime/path adoption:

- `Program`: terminal lifecycle and frame presentation on `MINGA_TTY` or `/dev/tty`.
- `TabGroup`: tab presentation state.
- `Tree`: file-tree row presentation derived from retained flat rows.
- `StatusBar`: right-segment layout.
- `SplitPane`: picker preview split geometry.
- `Help`: which-key row formatting with no ANSI leakage into semantic cells.
- `List`: completion visible-row and selected-item viewport computation.
- `CommandPalette`: picker row presentation over BEAM-owned query/filter/acceptance state.
- `VirtualList`: picker viewport row computation.
- `Tooltip`: plain hover/signature row shaping.
- `Table`: tool-manager row adaptation.
- `DataTable`: board row adaptation.
- `RichLog`: agent transcript visible-index computation over BEAM-owned transcript state.
- `HitBox`: semantic mouse hit regions.
- `MouseState`: transient local interaction metadata.

Fit/evidence-only adoption:

- `Viewport`, `CodeView`, and `renderWithRanges` for editor-body evaluation.
- `Markdown`, `TextInput`, `TextArea`, and `Dropdown` as explicit blocked follow-up candidates.

## Final decision impact

Yes, the correction changes the final decision and bakeoff result. ZigZag is now more than a narrow hitbox/helper dependency. It should stay as the Zig TUI framework and component-adapter dependency inside the current renderer path.

Do not create a permanent `minga-renderer-zigzag` path. Do not let ZigZag own stdout, command behavior, durable state, semantic payload meaning, or query/filter/focus source-of-truth. Do let ZigZag own terminal presentation on the TTY, and do use ZigZag predefined components where they safely adapt BEAM-owned state into local presentation data.
