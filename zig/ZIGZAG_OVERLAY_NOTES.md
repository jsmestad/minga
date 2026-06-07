# ZigZag overlay and agent-surface notes

Ticket #2187 now adopts every evaluated overlay component that can safely act as a presentation adapter over BEAM-owned state. Components that would own editing, selection, filtering, or raw styled terminal output remain blocked with explicit reasons.

## Runtime adapters added

`zig/src/zigzag_component_adapters.zig` now backs these runtime paths:

- `Help`: which-key binding rows from retained BEAM-owned binding payloads.
- `List`: completion visible rows and selected-item viewport behavior.
- `CommandPalette`: picker row presentation state, with query/filter/acceptance still BEAM-owned.
- `VirtualList`: picker viewport calculation for large candidate lists, with selected index mirrored from BEAM state.
- `Tooltip`: plain hover/signature row shaping. Styled hover segments still fall back to the existing semantic renderer so Minga style spans remain authoritative.
- `Table`: tool manager row adaptation.
- `DataTable`: board card row adaptation.
- `RichLog`: agent transcript viewport/index helper, while transcript entries remain BEAM-owned.

All runtime writes still go through Minga’s cell renderer. No raw ZigZag ANSI component output is written into runtime cells.

## Components still blocked

| Component | Status | Why |
| --- | --- | --- |
| `Markdown` | Fit-only ANSI renderer | Useful parser/shape evidence, but direct output emits styled terminal text. Runtime adoption needs a span/plain-row adapter, not raw output. |
| `TextInput` | Blocked as behavior owner | Owns value, cursor, validation, suggestions, and editing behavior. Runtime use would compete with BEAM-owned minibuffer/picker state. |
| `TextArea` | Blocked as behavior owner | Owns text, cursor, viewport, and editing behavior. Not safe for prompts or editor buffers without a strict BEAM-owned mirror. |
| `Dropdown` | Blocked as behavior owner | Owns selected indices, filtering, expansion, and acceptance. Useful shape, but not runtime-safe until behavior is mirrored back to BEAM. |

## Evaluation coverage

`zig/src/zigzag_overlay_fit.zig` records feasibility classifications for the full remaining set: `CommandPalette`, `Tooltip`, `Table`, `DataTable`, `RichLog`, `Markdown`, `VirtualList`, `TextInput`, `TextArea`, and `Dropdown`. Each evaluation records status, direct-output ANSI risk, behavior-ownership risk, semantic-preservation check, and recommendation.

## Boundary for overlays

Minga overlay precedence remains a renderer contract: picker suppresses generic overlays, which-key competes with picker, hover/signature/float/bottom-panel positioning is ordered, and BEAM owns the semantic payloads. Components may adapt those payloads into rows, measurements, local presentation state, or viewport calculations, but they must not become the source of truth for focus, filtering, query text, selected item, command acceptance, or transcript state.

## Verification focus

The important regression risks are ANSI leakage, selected-item visibility, and accidentally letting a component own behavior. Adapter tests cover no-ANSI output for adopted plain adapters, selected-item visibility for completion fallback behavior, picker viewport behavior, table/board row preservation, agent transcript index preservation, and explicit feasibility classifications for the blocked components.
