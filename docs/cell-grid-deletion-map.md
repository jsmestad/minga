# Cell-grid deletion map

This is the blocking audit artifact for the cell-grid deletion wave (epic #2218, audit ticket #2224). It inventories every producer and consumer of cell-grid output across the BEAM, the protocol schema, Go, Swift, and Zig; verifies each TUI surface has a working semantic path; rules on every protocol opcode; and proposes the deletion-wave child tickets. Each deletion PR can cite the rows below as proof that what it removes is unreferenced in production.

The method mirrors the parity audit in `docs/go-tui-parity.md`: drive from `docs/protocol_schema.toml` outward so no surface hides, and from the `Capabilities.gui?` branch sites inward to catch BEAM-side cell logic that never touches the wire. All evidence is `file:line`.

## Headline numbers

- Protocol opcodes ruled on: 99 (`[[opcodes]]` entries in `docs/protocol_schema.toml`). Cell-paradigm opcodes that die: 9 (`draw_text`, `set_cursor`, `clear`, `define_region`, `clear_region`, `destroy_region`, `set_active_region`, `scroll_region`, `draw_styled_text`). Transport-level survivors among the `render` category: 4 (`batch_end`, `set_cursor_shape`, `set_title`, `set_window_bg`).
- BEAM cell compositor + cell chrome cluster: about 4,300 lines across 8 modules (`renderer/composition.ex`, `render_pipeline/compose.ex`, `render_pipeline/compose_helpers.ex`, `shell/traditional/chrome/tui.ex`, `shell/traditional/layout/tui.ex`, `shell/traditional/tree_renderer.ex`, `picker_ui.ex`, `display_list.ex`), of which the styled-run IR (`DisplayList`, `Composition`) must be retained or refactored, not deleted outright (see the consumer note below).
- GUI/TUI command branching cluster: 13 `gui?` call sites plus the `Commands.*.TUI` submodules (`commands/ui/tui.ex`, `commands/buffer_management/tui.ex`, about 53 lines) and the dispatch helpers in `commands/ui.ex:92` and `commands/buffer_management.ex:2493`.
- Go fallback cluster: the `cellLines` fallback and `applyDraw`/`cells` cell store in `go/tui/internal/ui/render_content.go` and `model.go`, plus the `DrawText`/`DrawStyledText` decoders in `go/tui/internal/protocol/commands.go` (about 1,340 lines of files touched, far fewer deleted).
- Swift legacy decode cluster: the `.drawText`/`.drawStyledText`/`.clearRegion` no-op cases in `macos/Sources/Renderer/CommandDispatcher.swift` and the cell decoders in `macos/Sources/Protocol/ProtocolDecoder.swift` (about 4,100 lines of files touched, a small slice deleted).

## Key architectural finding

There is no live cell-opcode emit path in production today. The cell-grid deletion is not "find the code that emits cells and delete it"; that code is already gone. What remains is the cell-painting IR producers (`DisplayList` window/chrome frames built by `Chrome.TUI`, `tree_renderer.ex`, `picker_ui.ex`, `Compose`) that now feed the semantic render-model builder, plus the dead decode paths in each frontend, plus the dead opcode definitions in the schema.

Concretely, the single production emit path is `MingaEditor.Frontend.Emit.emit/4` (`lib/minga_editor/frontend/emit.ex:28`). It builds a semantic render model (`RenderModelBuilder.build`, `emit.ex:39`), encodes it through `Minga.Frontend.Adapter.GUI.encode` (`emit.ex:44`), and sends `metal_commands ++ chrome_commands ++ [batch_end]` plus `register_font`, `set_title`, `set_window_bg` side channels (`emit.ex:50-63`). It never emits `draw_text`, `draw_styled_text`, or any region opcode. The cell drawing opcode encoders (`encode_draw_text`, `encode_define_region`, etc.) do not even exist in `lib/minga_editor/frontend/protocol.ex`; that module only defines transport encoders (`encode_cursor`, `encode_clear`, `encode_batch_end`, `encode_cursor_shape`, `encode_set_title`, `encode_set_window_bg`, font encoders).

This means the deletion wave's risk is lower than the epic's 10k estimate implies for emit, and higher than expected for the IR: `DisplayList` has 40 consumers in `lib/` and is the intermediate representation the semantic builder reads, so it cannot be deleted in one PR. Epic #2218 AC 3 already anticipates this: "styled-run production retained for the semantic window encoder."

## AC 1: producer and consumer inventory

### BEAM emit paths

| Component | file:line | Role | Disposition |
|---|---|---|---|
| Single emit path | `lib/minga_editor/frontend/emit.ex:28` `emit/4` | Builds semantic model, encodes via Adapter.GUI, sends metal+chrome+batch_end | Semantic only. No cell opcodes. Retain. |
| Transport encoders | `lib/minga_editor/frontend/protocol.ex:195-307` | `encode_cursor`, `encode_clear`, `encode_batch_end`, `encode_cursor_shape`, `encode_set_title`, `encode_set_window_bg`, `encode_set_font*`, `encode_register_font` | Mixed: `set_title`/`set_window_bg`/`register_font`/`batch_end` live and survive; `encode_cursor`/`encode_clear`/`encode_cursor_shape` are defined but have no live caller in `lib/` (cursor is carried in `gui_window_content`). |
| Cell opcode encoders | (do not exist in `lib/`) | `draw_text`, `draw_styled_text`, `define_region`, etc. are not defined as encoders anywhere in `lib/`. References in `protocol.ex:55,287` are docstring mentions only. | Already absent. Schema/generated constants still define them (see protocol cluster). |
| Composition IR | `lib/minga_editor/renderer/composition.ex:1` | Shared text composition (conceal, virtual text, splitting) used by BOTH `Renderer.Line` (draw path) and the semantic window builder (`render_model/window/builder.ex`). Consumers: `renderer/line.ex`, `render_model/window/builder.ex`. | Retain. Feeds semantic builder. Not cell-only. |
| Compose stage | `lib/minga_editor/render_pipeline/compose.ex:1`, `compose_helpers.ex:1` | Merges content `WindowFrame` + `Chrome` into a `Frame`, injects modeline draws, resolves cursor. Output consumed by `Emit.emit` then semantic builder. | Refactor, not delete. Modeline-draw injection into cell frames becomes dead once `Chrome.TUI` is gone; the `Frame`/cursor resolution stays. |
| Cell chrome (TUI) | `lib/minga_editor/shell/traditional/chrome/tui.ex:1` | Builds cell draws for modeline, tab bar, minibuffer, file tree, separators, overlays for the Zig cell-grid frontend. Selected by `chrome.ex:34` only when `gui?` is false. | Delete. Cell-only. The GUI/semantic branch (`Chrome.GUI`) replaces it for every live frontend. |
| Cell layout (TUI) | `lib/minga_editor/shell/traditional/layout/tui.ex:1` | Computes cell-grid screen rectangles for the Zig frontend. Selected by `layout.ex:21` only when `gui?` is false. | Delete. Cell-only. |
| File tree cell renderer | `lib/minga_editor/shell/traditional/tree_renderer.ex:1` | Renders the file tree into `DisplayList.draw()` tuples (cell positions). | Delete. The semantic file tree is `gui_file_tree` (0x93) built by `render_model/ui/file_tree_builder.ex`. |
| Picker cell UI | `lib/minga_editor/picker_ui.ex:1` (1,664 lines) | Cell-era fuzzy picker overlay (open, key handling, cell rendering, close). | Delete. The semantic picker (`gui_picker` 0x77) is built by `render_model/ui/picker_builder.ex` and `ui/picker.ex`. Retires the known dual-picker duplication. |
| DisplayList IR | `lib/minga_editor/display_list.ex:1` (300 lines), 40 consumers in `lib/` | Styled-text-run intermediate representation that sits between editor state and semantic encoding. NOT a wire format. | Retain or refactor behind the TUI adapter. Deleting it breaks the semantic builder. See `docs/RETAINED_GUI_RENDERING_SPEC.md:240` "Move DisplayList behind the TUI adapter." |
| `CellLayer` | (not present in code) | Ticket and `AGENTS.md:855` reference `Minga.RenderModel.UI.CellLayer`, but no such module exists in `lib/` today (stale reference; already removed or never landed). | No action. Remove the stale `CellLayer` mention from `AGENTS.md` during the docs cleanup in the command-branching cluster. |

### GUI/TUI branch sites (the `gui?` convention)

The branch that selects cell chrome vs semantic chrome is `lib/minga_editor/shell/traditional/chrome.ex:31` (`build_chrome`) and `chrome.ex:41` (`chrome_fingerprint`), plus `lib/minga_editor/shell/traditional/layout.ex:21`. `gui?` is defined at `lib/minga_editor/frontend/capabilities.ex:129` and returns true only for `frontend_type: :native_gui`. The 13 live `gui?` call sites: `render_pipeline/buffer_prefetch.ex:482`, `render_pipeline/content.ex:130,142,573,615,881`, `frontend/emit/context.ex:139`, `shell/traditional/layout.ex:21`, `shell/traditional/chrome.ex:31,41`, `startup.ex:485,522,539`, `key_dispatch.ex:299`, `commands/ui.ex:92,166`, `commands/buffer_management.ex:2493`, `minga_editor.ex:948,968`. The `Commands.*.TUI` submodules selected by `commands/ui.ex:92` and `commands/buffer_management.ex:2493` are `commands/ui/tui.ex` and `commands/buffer_management/tui.ex`.

Caveat worth flagging for the deletion PRs: `gui?` is false for the Go TUI (Go reports `frontend_type: tui, semantic_ui: true`, per `docs/go-tui-parity.md:84`). So today the Go TUI takes the `Chrome.TUI` (cell) branch in `build_chrome`, then `Emit.emit` converts that cell `Frame` to the semantic model anyway. The cell chrome builder is still exercised as an IR producer for Go, not just for Zig. The command-branching cluster must replace the `gui?` switch with `semantic_ui?` (or remove the branch and always build the semantic chrome) so that deleting `Chrome.TUI` does not strand the Go path. This is the single most important sequencing constraint in the wave.

### Go fallback and diagnostic

| Component | file:line | Role | Disposition |
|---|---|---|---|
| `cellLines` fallback | `go/tui/internal/ui/render_content.go:335`, called at `render_content.go:25` | Renders the `m.cells` store as text when no semantic windows and no cells-diagnostic case applies | Dead in production. Reached only if `len(m.windows) == 0 && len(m.cells) == 0`, which never happens because the BEAM emits semantic windows. Delete. |
| Cell diagnostic | `go/tui/internal/ui/render_content.go:28` `legacyCellGridDiagnosticLines`, gated at `render_content.go:22` | Shows "Semantic UI required: received legacy cell-grid frame" when `m.cells` is non-empty | Guard rail. Keep until the protocol-retirement PR removes the cell decoders, then delete with them. |
| Cell store + applyDraw | `go/tui/internal/ui/model.go:36` (`cells map`), `model.go:230` `applyDraw`, dispatched at `model.go:192` `CommandDrawText` | Stores decoded `draw_text` cells | Dead. Delete with the protocol cluster. |
| DrawText decoders | `go/tui/internal/protocol/commands.go:212` `decodeDrawText`, `commands.go:236` `decodeDrawStyledText`, dispatched at `commands.go:157-160` | Decode `0x10`/`0x1C` payloads | Delete after schema regen drops the opcodes. |
| `withLegacyCursorline` | `go/tui/internal/ui/render_content.go:25` (in the `cellLines` chain) | Applies cursorline bg to cell fallback | Dead with `cellLines`. Note: the semantic cursorline path (`gui_cursorline` 0x7A, render_content withLegacyCursorline on semantic rows) is separate and survives. Confirm during deletion which `withLegacyCursorline` is cell-only. |

### Swift legacy decode paths

| Component | file:line | Role | Disposition |
|---|---|---|---|
| Dispatch no-op | `macos/Sources/Renderer/CommandDispatcher.swift:99` `case .drawText, .drawStyledText: break` | Legacy cell text; explicitly discarded with comment "All content now flows through gui_window_content (0x80)" | Dead. Delete the case after the decoder is gone. |
| clearRegion no-op | `macos/Sources/Renderer/CommandDispatcher.swift:146` `case .clearRegion: break` | Cell clearing; discarded | Dead. Delete. |
| Region tracking | `CommandDispatcher.swift:142` `defineRegion`, `:151` `destroyRegion`, `:157` `setActiveRegion` | Track regions for cursor offset only | Becomes dead once cell opcodes are gone; cursor offset is now carried in window content. Delete with the cluster. |
| Decoders | `macos/Sources/Protocol/ProtocolDecoder.swift:174,175,180,181` (enum cases), `:380,398,434,438` (decode bodies) | Decode `draw_text`, `draw_styled_text`, `define_region`, `clear_region` wire bytes | Delete after schema regen drops the opcodes. |
| Window content renderer | `macos/Sources/Renderer/WindowContentRenderer.swift:6`, `WindowContent.swift:6` | The live semantic path: "renders via CoreText rather than cell-grid draw_text commands" | Retain. This is the replacement, not a deletion target. |

### Zig renderer consumption

The Zig/libvaxis frontend is the original cell-grid consumer. Per the epic, Zig is no longer the default (it survives only behind `MINGA_FRONTEND=zig` until #2223) and `docs/RETAINED_GUI_RENDERING_SPEC.md:18` documents it as a cell-grid renderer. Zig consumes `draw_text`/`draw_styled_text`/region opcodes through `zig/src/generated/protocol_opcodes.zig` (generated). Its deletion is downstream of #2223 (Zig retirement) and is out of scope for the wave's first pass except that the protocol-retirement PR must regenerate `zig/src/generated/*` after the opcodes are removed, which will fail the Zig build until #2223 lands. Sequencing note below.

## AC 2: per-surface semantic verification

Every TUI surface the ticket names has a BEAM semantic builder under `lib/minga_editor/render_model/ui/` and a Go decode+render path verified in `docs/go-tui-parity.md`. The parity doc is the per-surface evidence; this table maps each named surface to its builder, its opcode, and the parity row.

| Surface | Semantic builder (BEAM) | Opcode | Go evidence | Status |
|---|---|---|---|---|
| Minibuffer | `render_model/ui/minibuffer_builder.ex` | gui_minibuffer 0x7F | parity doc "Minibuffer" row: decode `chrome_editor.go:152`, render `render_chrome.go:265`, test `TestDecodeMinibufferChrome` | PASS (semantic path live) |
| Dired / file tree | `render_model/ui/file_tree_builder.ex` | gui_file_tree 0x93, gui_file_tree_selection 0x94 | parity doc "File tree" / "File tree selection" rows: decode `chrome_editor.go:187`, render `render_content.go:702`, click routing `semantic_mouse.go:121` | PASS |
| Hover popup | `render_model/ui/hover_popup_builder.ex` | gui_hover_popup 0x81, gui_hover_action 0x96 | parity doc "Hover popup" / "Hover action" rows: decode `chrome_overlays.go:253`, render `render_surfaces.go:56` | PASS for display; mouse hover_open_action is gap G6 (keyboard works) |
| Messages / bottom panel | `render_model/ui/bottom_panel_builder.ex` | gui_bottom_panel 0x7C | parity doc "Bottom panel" row: decode `chrome_panels.go:115`, render `render_surfaces.go:138`, wheel scroll `semantic_mouse.go:30` | PASS for display + scroll; secondary mouse actions are gap G6 |
| Observatory | `render_model/ui/observatory_builder.ex` | gui_observatory 0x9A | parity doc "Observatory" row: decode `chrome_panels.go:367`, render `render_surfaces.go:256` | PASS for display; observatory_inspect mouse is gap G6 (keyboard works) |
| Pickers | `render_model/ui/picker_builder.ex` + `ui/picker.ex` | gui_picker 0x77, gui_picker_preview 0x7D | parity doc "Picker" / "Picker preview" rows: decode `chrome_overlays.go:83`, render `picker_overlay.go:15` | PASS |
| Popups (float / signature) | `render_model/ui/float_popup_builder.ex`, `signature_help_builder.ex` | gui_float_popup 0x83, gui_signature_help 0x82 | parity doc "Float popup" / "Signature help" rows: decode `chrome_overlays.go:362` / `:301`, render `render_surfaces.go:86` / `:69` | PASS |

No cell-only surface was found. Every surface the cell chrome built is also built semantically and rendered by Go. The only open items are the G6 mouse-convenience gaps from the parity audit (already filed as non-blocking follow-ups #2228-#2230), and they are reachable by keyboard. No gap ticket is needed for this audit: there is no surface that exists only in the cell paradigm.

BEAM-side runtime evidence that the semantic surfaces are what production actually emits: the headless-port integration tests (`test/support/headless_port.ex:521` `project_semantic_grid`) decode the real emitted command stream into a semantic grid and assert on rendered content; `test/minga_editor/integration/file_tree_test.exs` (4 tests) passes on this branch driving the file-tree surface through that path.

## AC 3: Swift legacy decode dead-at-runtime verification

Evidence level achieved: documented fallback at full strength, plus real-decoder runtime evidence through the Swift test harness. The one piece I could not perform in this environment is a live windowed GUI session under a window server; that is marked REMAINING with exact instructions and is now turnkey because of the instrumentation added below. I did not downgrade the standard silently; here is exactly what each layer proves.

### (a) Static proof: no BEAM path emits a cell opcode when capabilities are GUI

Traced function by function from the single emit path:

1. `MingaEditor.Frontend.Emit.emit/4` (`emit.ex:28`) is the only production emit entry. `Renderer.render_buffer/1` calls `RenderPipeline.run/1` (`renderer.ex:150`), and `RenderPipeline.run` calls `Emit.emit` at `render_pipeline.ex:166`. The splash/dashboard path (`renderer.ex:137`) also calls `Emit.emit`. There is no second emit function.
2. `Emit.emit` -> `emit_semantic/4` (`emit.ex:36`) builds the command list at `emit.ex:50-53`: `flush_font_registration_commands() ++ encoded_frame.metal_commands ++ encoded_frame.chrome_commands ++ [Protocol.encode_batch_end()]`. The only opcodes producible here are `register_font` (0x52), whatever `Adapter.GUI.encode` produces, and `batch_end` (0x13).
3. `Minga.Frontend.Adapter.GUI.encode` builds `metal_commands = window_content_cmds ++ metal_ui_cmds` (`adapter/gui.ex:82`) and `chrome_cmds`. The window content encoder "replaces draw_text commands for buffer windows" (`adapter/gui/window_encoder.ex:6`) and emits `gui_window_content` (0x80). No encoder under `lib/minga/frontend/adapter/gui/` references any cell opcode constant.
4. Grep backstop: there are zero references to the cell opcode constants (`Opcodes.draw_text`, `Opcodes.draw_styled_text`, `Opcodes.define_region`, `Opcodes.clear_region`, `Opcodes.scroll_region`, `Opcodes.set_active_region`, `Opcodes.destroy_region`) anywhere in `lib/`. The only files mentioning these names in `lib/` are `frontend/protocol.ex` (docstring text at lines 55, 287) and `adapter/gui/window_encoder.ex:6` (a comment saying it replaces draw_text). The cursor opcodes `encode_cursor`/`encode_cursor_shape` are defined in `protocol.ex:195,211` but have no live caller in `lib/`; cursor state is carried inside `gui_window_content` (`adapter/gui.ex:368-372`).
5. The `gui?` branch is irrelevant to cell emission: both branches of `build_chrome` (`chrome.ex:31`) produce a `Chrome` struct that `Emit.emit` converts to the semantic model. Even the `frontend_type: :tui` path emits semantic. This is the conclusion, not an assumption: the test in step (b) drives exactly the `tui + semantic_ui` capability set and asserts no cell clear.

Conclusion: no BEAM code path can emit a cell opcode in any capability configuration. The cell opcodes are decode-only contracts in the frontends and dead encoder definitions in the generated schema constants.

### (b) Runtime decode evidence through the real Swift decoder

I built the headless Swift test harness (`mix swift.harness`, output `_build/dev/lib/minga/priv/minga-test-harness`) and ran the GUI protocol integration suite. The harness is a real `swiftc`-compiled binary that decodes BEAM-emitted protocol bytes through the production `macos/Sources/Protocol/ProtocolDecoder.swift` and projects each decoded command to JSON (`macos/TestHarness/main.swift:473` `decodeCommands`).

Result: `mix test test/minga_editor/integration/gui_protocol_test.exs --include swift_harness` -> 27 passed. These tests round-trip every semantic surface (agent chat, picker, file tree, status bar, observatory, etc.) from the BEAM encoder through the real Swift decoder. None of them produces or asserts a cell command type. The harness `main.swift:336` still has a `.drawText` JSON projection, so if the BEAM had emitted a `draw_text`, the harness would have decoded and reported it; it never appears for the semantic surfaces these tests drive.

BEAM-side emit assertion (the complementary half): `test/minga_editor/frontend/emit_test.exs` captures the actual command list sent by `Emit.emit` and asserts the frame opens with a chrome opcode (`first_opcode >= 0x70`) and not a cell clear (`refute match?([<<0x12>> | _], commands)`), including a case driven with `frontend_type: :tui, semantic_ui: true` (`emit_test.exs:91`, Go's exact capabilities). Result: 8 passed on this branch.

### (c) Live windowed GUI session: REMAINING (turnkey)

I added temporary instrumentation so a human can confirm the dispatch-side no-op never fires in a real windowed session. In `macos/Sources/Renderer/CommandDispatcher.swift` I added a static counter `legacyCellDecodeCount` and a `noteLegacyCellDecode` logger, and call it from the two legacy dispatch cases: `.drawText/.drawStyledText` (`CommandDispatcher.swift:99` region) and `.clearRegion` (`:146` region). Each call logs `[#2224 cell-decode]` via `PortLogger.info`.

Why this is REMAINING and not done here: the macOS app is a Metal/AppKit GUI that requires a window server and a full Xcode build (`macos/project.yml` pins Metal toolchains); a live windowed session is not reliably automatable from this environment. The harness in (b) compiles only `ProtocolDecoder.swift`, not `CommandDispatcher.swift`, so it exercises the decode entry point but not the dispatch no-op. The instrumentation covers the dispatch no-op for the human run.

Exact human run:

1. From `macos/`, build and launch the GUI app normally (the same way you run the dev build: `xcodegen generate` then build/run the `Minga` scheme in Xcode, or your usual run script).
2. Exercise a full session: open files, edit, open the file tree, the command palette/picker, hover popups, the bottom panel, agent chat. Spend a couple of minutes covering every surface.
3. Quit, then check the app log for any line containing `[#2224 cell-decode]`. Expected outcome: zero such lines (dead path confirmed). If `CommandDispatcher.legacyCellDecodeCount` is nonzero, a cell opcode reached the Swift dispatcher and the deletion is blocked until the source emit is found.
4. After recording the result, remove the instrumentation: the `// TEMP INSTRUMENTATION (cell-grid deletion audit, ticket #2224)` block and the two `noteLegacyCellDecode(...)  // TEMP #2224` call lines in `CommandDispatcher.swift`.

This instrumentation must not ship; it is for the audit's one live run only.

## AC 4: opcode-by-opcode ruling

`docs/protocol_schema.toml` has 99 opcodes. Direction breakdown: 8 `frontend_to_beam` (input), 17 `beam_to_parser` (parser commands), 15 `parser_to_beam` (parser responses), 59 `beam_to_frontend` (render + config + gui chrome + gui semantic + gui_action subtypes). The `gui_action` input subtypes (`select_tab` 0x01 ... `extension_action` 0x58) are categorized `gui_semantic` but flow frontend-to-beam under the `gui_action` (0x07) envelope; they survive as input contracts and are not cell-paradigm. Below I rule on the cell-relevant set explicitly and summarize the rest.

### Render category (0x10-0x1C): the cell-paradigm core

| Opcode | Value | Ruling | Rationale |
|---|---|---|---|
| draw_text | 0x10 | DIES | Cell text painting. Replaced by `gui_window_content` (0x80). No live emitter; decoders are dead in Go/Swift/Zig. |
| set_cursor | 0x11 | DIES | Standalone cell cursor position. Cursor is now carried inside `gui_window_content` per window (`adapter/gui.ex:369`). `encode_cursor` has no live caller. |
| clear | 0x12 | DIES | Cell frame clear. The semantic frame uses `batch_end` framing; `refute match?([<<0x12>> | _], ...)` is asserted in `emit_test.exs:44`. No live emitter. |
| batch_end | 0x13 | SURVIVES (transport) | Frame boundary, not cell content. Emitted on every frame at `emit.ex:53`. A latency-instrumentation PR (#2215) adds a u32 echo to `batch_end` for key_press/batch_end correlation; treat `batch_end` as surviving transport-level framing regardless of cell deletion. The schema framing (`fixed:1`) will change to carry the u32 under #2215; that is orthogonal to this wave. |
| define_region | 0x14 | DIES | Cell region geometry. Regions only existed to offset cell coordinates; semantic windows carry their own geometry. |
| set_cursor_shape | 0x15 | SURVIVES (transport) | Cursor shape is a terminal/GUI attribute, not cell content. `encode_cursor_shape` exists; shape is also carried per window in content, but the standalone opcode is a legitimate transport-level cursor attribute. Keep unless the regen PR proves no frontend reads it standalone; safe default is keep. |
| set_title | 0x16 | SURVIVES (transport) | Window title side channel. Live: `emit.ex:60` `send_title`. Not cell-paradigm. |
| set_window_bg | 0x17 | SURVIVES (transport) | Window background color side channel. Live: `emit.ex:61` `send_window_bg`. Not cell-paradigm. |
| clear_region | 0x18 | DIES | Cell region clear. Swift case is already a no-op (`CommandDispatcher.swift:146`). No live emitter. |
| destroy_region | 0x19 | DIES | Cell region teardown. Dies with `define_region`. |
| set_active_region | 0x1A | DIES | Cell region activation for coordinate offset. Dies with `define_region`. |
| scroll_region | 0x1B | DIES | Cell-grid hardware scroll optimization. Semantic windows re-send content/deltas. No live emitter. |
| draw_styled_text | 0x1C | DIES | Styled cell text painting. Replaced by `gui_window_content` styled runs. No live emitter; Swift case `:99` is a no-op. |

### Config category (0x50-0x52): font transport

| Opcode | Value | Ruling | Rationale |
|---|---|---|---|
| set_font | 0x50 | SURVIVES (transport) | Frontend font configuration, not cell content. |
| set_font_fallback | 0x51 | SURVIVES (transport) | Font fallback chain. Referenced by styled runs via `font_id`. |
| register_font | 0x52 | SURVIVES (transport) | Font registration. Live: `emit.ex:51,90` `flush_font_registration_commands`. |

### Parser categories (0x20-0x40 commands, 0x30-0x3E responses): SURVIVE

All 17 parser commands and 15 parser responses survive unchanged. They are a separate process boundary (`beam_to_parser` / `parser_to_beam`), used for tree-sitter highlighting, folds, indentation, text objects, and structural navigation. They have nothing to do with the cell paradigm and are consumed by the parser process, not a rendering frontend. One-line rationale for the set: parser opcodes are the BEAM-to-parser RPC contract and are orthogonal to rendering.

### Input category (0x01-0x07, 0x60): SURVIVE

`key_press` (0x01), `resize` (0x02), `ready` (0x03), `mouse_event` (0x04), `capabilities_updated` (0x05), `paste_event` (0x06), `gui_action` (0x07), `log_message` (0x60) all survive. They are frontend-to-BEAM input, paradigm-independent. The #2215 latency correlation adds a u32 to `key_press`/`batch_end`; `key_press` survives as input transport regardless of cell deletion.

### gui_chrome and gui_semantic categories (0x71-0xA3) and gui_action subtypes: SURVIVE

All 21 `gui_chrome` and 22 `gui_semantic` opcodes survive; they are the semantic paradigm that replaces cells. The `gui_action` subtypes (`select_tab` through `extension_action`, plus the section/struct names that share value bytes inside `gui_action`) survive as the input action contract. The `clipboard_write` (0x90) opcode is a transport side channel and survives (live at `frontend.ex:232`). Per the semantic-surface freeze (`AGENTS.md:859`), none of these change in this wave except via #2218/#2219 exemptions.

Summary count: of the 13 `render`-category opcodes, 9 die (`draw_text`, `set_cursor`, `clear`, `define_region`, `clear_region`, `destroy_region`, `set_active_region`, `scroll_region`, `draw_styled_text`) and 4 survive as transport (`batch_end`, `set_cursor_shape`, `set_title`, `set_window_bg`). Every other opcode in the schema survives.

## AC 5: deletion-wave child tickets (ready to paste)

These are one per cluster, sequenced. File them against epic #2218. Each carries its inventory slice as Developer Notes and cites this map. The hard sequencing constraint: the command-branching cluster must land before the cell-chrome cluster, because the Go TUI currently takes the `Chrome.TUI` branch and would lose its chrome if `Chrome.TUI` were deleted while the `gui?` switch still routes Go to it.

---

### Ticket A (#2234): Replace the GUI/TUI command branching with a semantic capability check

**Type:** Chore (refactor, no behavior change)

**Scope.** Remove the `Capabilities.gui?` render/command branching convention so the semantic path is the only path. Replace the `gui?` switch in chrome/layout/command dispatch with `semantic_ui?` (or drop the branch entirely and always build semantic chrome), so that every live frontend (GUI and Go TUI) takes the semantic chrome builder. This unblocks deleting `Chrome.TUI`/`Layout.TUI` later without stranding the Go path, which today reports `frontend_type: tui` and therefore currently takes the cell branch. Delete the `Commands.*.TUI` submodules and the `__MODULE__.GUI/TUI` dispatch helpers. Remove the `gui?`-branch documentation from ARCHITECTURE.md and AGENTS.md, and remove the stale `Minga.RenderModel.UI.CellLayer` reference from `AGENTS.md:855`.

**Inventory slice.** `lib/minga_editor/frontend/capabilities.ex:128-130` (`gui?`); 13 call sites listed in AC 1 (notably `shell/traditional/chrome.ex:31,41`, `shell/traditional/layout.ex:21`, `commands/ui.ex:92,166`, `commands/buffer_management.ex:2493`); `commands/ui/tui.ex`, `commands/buffer_management/tui.ex` (about 53 lines). Keep `gui?` itself if other non-render code needs it; the goal is removing render/command branching.

**Expected test fallout.** Tests that assert `Chrome.TUI` is selected for `frontend_type: :tui` change to assert the semantic builder. `emit_test.exs` already asserts the `tui + semantic_ui` path emits semantic, so it stays green. New/updated tests in `commands/ui_test.exs` and `commands/buffer_management_test.exs` for the collapsed dispatch.

**Sequencing.** First in the wave. Blocks Ticket B.

---

### Ticket B (#2235): Delete the BEAM cell chrome and cell layout builders

**Type:** Chore (deletion)

**Scope.** Delete the cell-painting chrome and layout builders that only the cell-grid frontend consumed: `Chrome.TUI`, `Layout.TUI`, and the cell file-tree renderer. Retain the styled-run IR (`DisplayList`, `Composition`) and the semantic builders. Refactor `Compose` to drop modeline-draw injection into cell frames (the modeline is now `gui_status_bar` 0x76) while keeping the `Frame`/cursor resolution the semantic builder needs.

**Inventory slice.** Delete `lib/minga_editor/shell/traditional/chrome/tui.ex`, `shell/traditional/layout/tui.ex`, `shell/traditional/tree_renderer.ex`. Refactor `render_pipeline/compose.ex`, `compose_helpers.ex` to remove cell-modeline injection. Do NOT delete `display_list.ex` or `renderer/composition.ex` (40+ consumers, feeds the semantic builder; track `DisplayList` adapter-isolation separately per `docs/RETAINED_GUI_RENDERING_SPEC.md:240`). About 1,600 lines deleted across the three TUI builders.

**Expected test fallout.** Delete `chrome/tui_test.exs`, `layout/tui_test.exs`, `tree_renderer_test.exs` and the cell-chrome cases in `emit/tui_test.exs`. Semantic file-tree tests (`render_model/ui/file_tree_builder_test.exs`) and the headless-port file-tree integration tests stay green.

**Sequencing.** After Ticket A. Independent of C (picker) but commonly landed adjacent.

---

### Ticket C (#2236): Delete the cell-era picker and its dual-picker duplication

**Type:** Chore (deletion)

**Scope.** Delete `picker_ui.ex`, the cell-rendered fuzzy picker (command palette, file finder, buffer list). The semantic picker (`gui_picker` 0x77 via `render_model/ui/picker_builder.ex` and `ui/picker.ex`) is the replacement and is already live and Go-verified. This retires the known dual-picker duplication called out in epic #2218 Developer Notes.

**Inventory slice.** Delete `lib/minga_editor/picker_ui.ex` (1,664 lines). Repoint any caller still invoking `PickerUI` to the semantic `UI.Picker` source. Audit `ui/picker/source.ex` and the picker key-dispatch path for residual `PickerUI` references.

**Expected test fallout.** Delete `picker_ui_test.exs`; keep `ui/picker_test.exs` and `render_model/ui/picker_builder_test.exs`. The Go parity "Picker" row stays PASS.

**Sequencing.** After Ticket A. Parallel-safe with Ticket B.

---

### Ticket D (#2237): Retire cell-paradigm opcodes from the schema and regenerate

**Type:** Chore (protocol)

**Scope.** Remove the 9 dying cell opcodes from `docs/protocol_schema.toml` (`draw_text` 0x10, `set_cursor` 0x11, `clear` 0x12, `define_region` 0x14, `clear_region` 0x18, `destroy_region` 0x19, `set_active_region` 0x1A, `scroll_region` 0x1B, `draw_styled_text` 0x1C). Keep `batch_end`, `set_cursor_shape`, `set_title`, `set_window_bg` (transport survivors). Bump the schema `version`. Run `mix protocol.gen` to regenerate Elixir/Swift/Zig/Go constants. Add a version-mismatch error so a stale frontend shows an explicit error instead of desyncing.

**Inventory slice.** `docs/protocol_schema.toml` opcode entries above; generated outputs `.generated/protocol/elixir/...`, `macos/.generated/protocol/ProtocolOpcodes.generated.swift`, `zig/src/generated/protocol_opcodes.zig`, `go/tui/internal/generated/opcodes.go`, and the command-size generators. Coordinate with #2215: do not regenerate over its `batch_end` u32 change; rebase whichever lands second.

**Expected test fallout.** `protocol_schema_test.exs` and `protocol.gen` golden tests update. The Zig build (`protocol_opcodes.zig`) will fail to compile against the cell decoders until #2223 retires Zig; gate Zig regen behind #2223 or land D after #2223. Swift/Go decoders for the removed opcodes are deleted in Tickets E and F, which must land in the same wave so the generated constants and the decoders stay consistent.

**Sequencing.** After the BEAM no longer references the opcodes (it already does not), and coordinated with Tickets E and F (frontend decoder removal). Blocked by #2215 only for `batch_end` framing. Hard constraint: Zig consumers (#2223) must be retired or the Zig regen gated, or the Zig build breaks.

---

### Ticket E (#2238): Remove Go's cell decoders and `cellLines` fallback

**Type:** Chore (deletion)

**Scope.** Delete Go's cell store, draw decoders, and fallback once the schema drops the opcodes. Remove `cells`, `applyDraw`, the `CommandDrawText` dispatch, the `decodeDrawText`/`decodeDrawStyledText` decoders, the `cellLines`/`withLegacyCursorline`(cell) fallback chain, and the `legacyCellGridDiagnosticLines` guard.

**Inventory slice.** `go/tui/internal/ui/model.go:36,190,192,230` (cells/applyDraw/dispatch), `go/tui/internal/ui/render_content.go:22-33` (diagnostic), `:25,335` (`cellLines`, cell `withLegacyCursorline`), `go/tui/internal/protocol/commands.go:16,31,43,157-160,212-260` (DrawText type and decoders), generated `go/tui/internal/generated/opcodes.go` cell constants (via regen), `command_size.go:49` cell sizing entries.

**Expected test fallout.** Delete Go tests covering `decodeDrawText`/`applyDraw`/`cellLines`; the semantic guardrail test (`semantic_guardrail_test.go`) and decode tests stay green. `go test ./...` from `go/tui/` must remain green (parity baseline 189 tests).

**Sequencing.** Lands in the same wave as Ticket D (schema regen) so generated constants and decoders stay consistent. After D regenerates Go constants.

---

### Ticket F (#2239): Remove Swift's legacy cell decode and dispatch paths

**Type:** Chore (deletion)

**Scope.** Delete the Swift legacy cell decode and dispatch no-ops once the schema drops the opcodes: the `.drawText/.drawStyledText` and `.clearRegion`/`define_region`/`destroy_region`/`set_active_region` handling and the corresponding `ProtocolDecoder` cases and enum variants. Remove the temporary `#2224` instrumentation if it has not already been removed after the audit's live run.

**Inventory slice.** `macos/Sources/Renderer/CommandDispatcher.swift:99,142,146,151,157` (dispatch cases + region tracking), `macos/Sources/Protocol/ProtocolDecoder.swift:174,175,180,181` (enum cases) and `:380,398,434,438` (decode bodies), `macos/TestHarness/main.swift:330-337` (harness JSON projection for draw_text/draw_styled_text). Keep `WindowContentRenderer.swift` / `WindowContent.swift` (the live semantic path). Regenerate `macos/.generated/protocol/ProtocolOpcodes.generated.swift` via Ticket D.

**Expected test fallout.** Update `CommandDispatcherTests.swift`, `ProtocolTests.swift`, `DecoderFuzzTests.swift`, and the swift_harness `gui_protocol_test.exs` to drop cell cases. The 27 swift_harness semantic tests stay green.

**Sequencing.** Lands in the same wave as Ticket D. After D regenerates Swift constants. Confirm the AC 3 live-session instrumentation result is recorded before removing the instrumentation here.

---

## Files inspected

Schema and prior art: `docs/protocol_schema.toml`, `docs/go-tui-parity.md`, `docs/RETAINED_GUI_RENDERING_SPEC.md`, `AGENTS.md`. BEAM: `lib/minga_editor/frontend/emit.ex`, `frontend/protocol.ex`, `frontend/protocol/gui.ex`, `frontend/capabilities.ex`, `frontend.ex`, `renderer.ex`, `render_pipeline.ex`, `renderer/composition.ex`, `render_pipeline/compose.ex`, `render_pipeline/compose_helpers.ex`, `shell/traditional/chrome.ex`, `shell/traditional/chrome/tui.ex`, `shell/traditional/layout.ex`, `shell/traditional/layout/tui.ex`, `shell/traditional/tree_renderer.ex`, `picker_ui.ex`, `display_list.ex`, `commands/ui.ex`, `commands/buffer_management.ex`, `lib/minga/frontend/adapter/gui.ex`, `adapter/gui/window_encoder.ex`, `render_model/ui/*_builder.ex`, `mix/protocol_generator.ex`, `lib/mix/tasks/swift_harness.ex`. Go: `go/tui/internal/ui/render_content.go`, `ui/model.go`, `protocol/commands.go`, `generated/opcodes.go`, `generated/command_size.go`. Swift: `macos/Sources/Renderer/CommandDispatcher.swift`, `Protocol/ProtocolDecoder.swift`, `Renderer/WindowContentRenderer.swift`, `Renderer/WindowContent.swift`, `TestHarness/main.swift`, `Tests/MingaTests/CommandDispatcherTests.swift`, `Tests/MingaTests/BoardFrontendRuntimeTests.swift`, `macos/project.yml`. Tests: `test/support/headless_port.ex`, `test/minga_editor/frontend/emit_test.exs`, `test/minga_editor/integration/gui_protocol_test.exs`, `test/minga_editor/integration/file_tree_test.exs`, `test/test_helper.exs`.

## Validation run

- `mix test test/minga_editor/integration/file_tree_test.exs`: 4 passed (semantic render pipeline).
- `mix swift.harness`: built `_build/dev/lib/minga/priv/minga-test-harness`.
- `mix test test/minga_editor/integration/gui_protocol_test.exs --include swift_harness`: 27 passed (real Swift decoder round-trip).
- `mix test test/minga_editor/frontend/emit_test.exs`: 8 passed (BEAM emits semantic, not cell, including the `tui + semantic_ui` case).
- `go build ./...` from `go/tui/`: OK.
