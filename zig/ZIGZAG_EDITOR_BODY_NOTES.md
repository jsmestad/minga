# ZigZag editor-body notes

Ticket #2186 evaluated the correctness-critical editor body against ZigZag helpers. The outcome is evidence-backed narrowing: keep runtime editor-body rendering on Minga's existing semantic cell path, and use ZigZag helper coverage as evidence for the final #2191 decision.

Why runtime editor-body rendering stays manual in this slice:

- Minga text rows, style spans, cursor placement, selections, search matches, diagnostics, indent guides, gutters, and scroll-left behavior are BEAM-owned semantic payloads.
- ZigZag `CodeView` owns lightweight syntax highlighting and line-number rendering, which would replace Minga parser/style spans instead of preserving them.
- ZigZag `TextArea` owns editable text state and cursor movement, which conflicts with BEAM-owned buffers, commands, and durable editor state.
- ZigZag `Viewport` can consume derived text for local viewport helpers, but it must not own Minga scroll-left, cursor, or style-span semantics.
- `renderWithRanges` is useful for ASCII byte-range style checks, but Minga spans are terminal-column semantics. Wide Unicode and combining graphemes make direct byte-range mapping unsafe without a dedicated semantic column mapper, so the fit test does not claim styled-range coverage for non-ASCII rows.

What was verified:

- `zig/src/zigzag_editor_fit.zig` adapts the existing full-editor semantic fixture into ZigZag `Viewport`, `CodeView`, and `renderWithRanges` helper views.
- A Unicode test covers wide and combining text and records that semantic spans cannot be blindly mapped to ZigZag byte ranges.
- Runtime editor-body rendering is unchanged, so the current renderer remains the visual correctness oracle.

Rejected direct component swaps:

- `CodeView`: useful for lightweight previews, but not for real editor buffers because it owns highlighting and line-number presentation.
- `TextArea`: not suitable for runtime editor buffers because it owns editing state and cursor behavior.
- `Viewport`: useful as a helper candidate, but not as the owner of Minga scroll/cursor/render semantics.
- Direct `renderWithRanges`: useful only after Minga column spans are mapped to byte ranges safely for Unicode.
