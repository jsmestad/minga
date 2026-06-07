# ZigZag inventory for the current renderer

#2183 makes ZigZag available inside the existing `minga-renderer` build only. It does not add a `minga-renderer-zigzag` target, does not switch runtime behavior, and does not give ZigZag ownership of BEAM semantic meaning or durable editor state.

## Revision

- Source: `meszmate/zigzag`
- Release: `v0.1.5`
- Commit: `4286ed5a1f919c1ee19ef4831021a57d18322905`
- Zig package hash: `zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv`

## Parent inventory check

The parent epic inventory maps cleanly to the available ZigZag exports for the next slices:

- Chrome and layout: `TabGroup`, `StatusBar`, `StatusSegment`, `Tree`, `SplitPane`, `Breadcrumb`, `List`, `StyledList`, `Flex`, `join`, `place`, `layer`, `measure`
- Picker and overlays: `CommandPalette`, `TextInput`, `List`, `VirtualList`, `Tooltip`, `Modal`, `ContextMenu`, `Dropdown`, `Help`
- Agent and log surfaces: `RichLog`, `Markdown`, `TextArea`, `Viewport`, `Progress`, `Spinner`, `Toast`, `Notification`
- Code previews and editor-body candidates: `CodeView`, `DiffView`, `Viewport`, `renderWithRanges`, `renderWithHighlights`, Unicode measurement helpers
- Tables and structured surfaces: `Table`, `DataTable`, `SortableTable`, `Paginator`, `VirtualList`
- Mouse and input helpers: `HitBox`, `MouseState`, `KeyMap`, `KeyBinding`
- Forms and prompts: `Form`, `Confirm`, `Checkbox`, `CheckboxGroup`, `RadioGroup`, `Slider`, `TextInput`, `TextArea`, `Modal`
- Core primitives: `Style`, `Color`, `Border`, `Theme`, `AdaptivePalette`, `fuzzy`, `renderWithRanges`, `renderWithHighlights`, `measure`, `join`, `place`, `Flex`, `layer`
- Lower-priority future components are also present: `FilePicker`, `MenuBar`, `Calendar`, `Chart`, `BarChart`, `Sparkline`, `Heatmap`, `Canvas`, `BrailleCanvas`
- Runtime and terminal-adjacent exports are present for #2189 evaluation: `Program`, `Terminal`, and image command helpers such as `CacheImage`. Their presence is not approval to move Minga terminal ownership in this slice.

`zig/src/zigzag_bridge.zig` has a compile-time inventory test so renamed or missing components fail during `rtk zig build test`.

## Current boundary

This slice intentionally stops at dependency and import availability. Future tickets may adapt Minga semantic payloads into ZigZag component inputs, but the runtime target stays `minga-renderer`, stdout remains the BEAM port channel, and `/dev/tty` terminal handling remains with the current TUI runtime until #2189 proves a different boundary is safe.
