# ZigZag static chrome notes

Ticket #2185 now adopts ZigZag structural chrome components as presentation and layout adapters inside the current `minga-renderer` path. The important boundary is not “no ZigZag components”; it is “no ZigZag ownership of semantic state, terminal output, or command behavior.”

## What changed

`zig/src/zigzag_chrome.zig` now uses ZigZag structural components to derive local presentation data from BEAM-owned semantic payloads:

- `TabGroup` derives tab active-state presentation for the tab strip. Tab IDs, labels, dirty/attention flags, and click actions remain semantic payloads owned by BEAM/Minga.
- `Tree` reconstructs file-tree hierarchy/presentation from Minga’s retained flat visible row model. Expansion, selection, focus, git status, diagnostics, editing text, and row actions remain BEAM-owned.
- `StatusBar` derives right-segment layout for modeline/status rendering. Segment text, styles, commands, and render priority remain Minga-owned.
- `SplitPane` computes picker preview split geometry. Picker query, selection, preview content, and command acceptance remain BEAM-owned.

The runtime still writes through Minga’s surface/cell renderer. ZigZag components produce derived presentation data or layout measurements; they do not write ANSI strings to the terminal and do not bypass the existing Port protocol.

## Why this is the right boundary

Direct component output is still unsafe because high-level ZigZag views render styled strings, while Minga’s TUI surface paints explicit cells with foreground, background, attrs, cursor placement, and hit-test parity. Writing those strings directly would bypass Minga’s semantic cell contract and risk ANSI escape leakage into the cell renderer.

The corrected approach follows the Go/Charm pattern: use components as presentation adapters over decoded semantic state, but keep protocol meaning, terminal writes, and behavior ownership separate.

## Verified coverage

- `TabGroup`, `Tree`, `StatusBar`, and `SplitPane` have focused adapter tests in `zig/src/zigzag_chrome.zig`.
- The existing `full_editor.bin` fixture still proves structural chrome can be represented from retained semantic packets at 80 columns and a wide terminal size.
- Runtime tab strip, file tree, modeline/status layout, and picker split geometry now call the adapter helpers while preserving the existing surface renderer.

## Still not adopted directly

- Direct `TabGroup.view`, `Tree.view`, or `StatusBar.view` output is not written into runtime cells because that would import ANSI/string styling into a cell renderer.
- `Breadcrumb` remains evidence-only for now because it was not needed to correct the structural chrome slice.
- `SplitPane` is used for local geometry, not as a pane owner. Minga layout and semantic payloads remain authoritative.
