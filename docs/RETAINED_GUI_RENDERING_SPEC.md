# Rendering Simplification Spec

The rendering pipeline has too many parts, too many lines of code, and is unnecessarily complicated for what it does. This spec defines a simpler architecture and a strategy for getting there without losing capabilities.

## Status

Phases 1, 2, 3, and the full-frame part of Phase 4 moved the architecture in the right direction, but the implementation stopped short of the full data-shape goal. Phase 1 unified the GUI chrome path, Phase 2 introduced `Minga.RenderModel.Window` for GUI buffer windows, Phase 3 added instrumentation, and Phase 4 added BEAM-authored row IDs with Swift atlas reuse keyed by stable row identity instead of display row. Phase 6 now routes production TUI command building through `Minga.RenderModel`: buffer windows use the shared TUI window adapter, and remaining cell-grid chrome is narrowed into `Minga.RenderModel.UI.CellLayer` compatibility data instead of being read from `DisplayList.Frame` during emit. Phase 7 has started with the smallest safe delta: cursor and cursorline updates carry `window_id + content_epoch`, and Swift ignores stale deltas instead of reusing mismatched retained state. The remaining debt is explicit now: some ownership boundaries are still editor-heavy, broader reset semantics still need macOS runtime validation, and several UI models still need to move from pre-encoded compatibility payloads to semantic core structs.

The remediation plan below is the source of truth for completing the simplification work before broader delta protocol work.

## Remediation plan

This plan closes the gap between the retained GUI rendering spec and the implementation that landed in Phases 1, 2, and 3.

### Current diagnosis

The first stack moved Minga in the right direction, but it mixed path unification with data-shape redesign. Path unification mostly landed. Data-shape redesign did not land for every surface.

Three things are now true:

1. GUI chrome has one orchestration path: `MingaEditor.RenderModel.UI.Builder` builds UI models, `Minga.Frontend.Adapter.GUI` encodes them, and `MingaEditor.Frontend.Emit` sends the commands.
2. GUI buffer windows have a real core model: `Minga.RenderModel.Window` carries rows, spans, gutter, cursorline, indent guides, selections, search matches, diagnostics, highlights, and annotations.
3. Instrumentation exists for BEAM model build time, adapter encode byte counts, emit preparation, Swift atlas reuse, row rasterization, texture uploads, and frame timing.

The remaining problem is that several structures are named like render models but still contain encoded protocol binaries. That keeps old encoding shapes alive and prevents the render model from being the single visible truth.

### What must be fixed now

The remediation has four goals:

1. Replace pre-encoded UI payloads with semantic core models.
2. Make `Minga.RenderModel` a real top-level frame model, not separate `ui_model` and `window_models` values carried through `emit_gui/4`.
3. Finish the GUI window model contract: wrapped visual rows, pane geometry, input hit regions, non-buffer window surfaces, agent ownership boundaries, content epochs, and reset semantics.
4. Start retained rendering only after model ownership is fixed, using stable row IDs and epochs rather than display-row cache keys.

### Non-negotiable rules

These rules prevent the same compromise from repeating:

- A `Minga.RenderModel.*` struct must not store a protocol command binary as its primary payload.
- A `MingaEditor.RenderModel.*Builder` must not call `MingaEditor.Frontend.Protocol.GUI.encode_gui_*`.
- A core GUI encoder must accept a semantic model and return bytes. It must not call `Buffer`, `Options`, `Language`, `MingaEditor`, or any process.
- A component is not migrated until the old `ProtocolGUI.encode_gui_*` function is deleted or moved to a core protocol module with a semantic-model interface.
- Adapter caches may store fingerprints and last encoded state. They must not become the visible model.
- Pane rendering and input routing must be window-scoped. No GUI renderer or input path may use active-window gutter geometry, global frame width, or row-only cursorline state for pane-local drawing or hit testing.
- No new delta protocol work starts until content epochs and full reset behavior exist.

### Remediation stack

#### 0. Add guardrails before more rendering work

Add cheap checks that make the intended architecture hard to drift away from.

Acceptance criteria:

- A test or Credo check fails when a new `Minga.RenderModel.UI.*` struct defines `:encoded`, `:selection_encoded`, `:cmd`, or another protocol-binary payload field. Existing pre-encoded components remain in an explicit legacy allowlist that must shrink as each component migrates.
- A test or Credo check fails when a new file under `lib/minga_editor/render_model/` references `MingaEditor.Frontend.Protocol.GUI`. Existing legacy references remain in an explicit allowlist that must shrink as each builder migrates.
- `MingaEditor.Renderer.Caches` no longer carries stale `last_gui_*` fields that are not read anywhere.
- `docs/RETAINED_GUI_RENDERING_SPEC.md` and the executable guardrail allowlists agree on what counts as remaining legacy debt.

#### 1. Introduce the top-level render model

Create the object the spec originally asked for: one BEAM-owned visible frame model.

Target shape:

```elixir
%Minga.RenderModel{
  windows: [%Minga.RenderModel.Window{}],
  ui: %Minga.RenderModel.UI{},
  cursor: cursor_model,
  title: title,
  window_bg: window_bg
}
```

Acceptance criteria:

- `emit_gui/4` receives or builds one `%Minga.RenderModel{}` and passes that to `Minga.Frontend.Adapter.GUI.encode/2`.
- The adapter owns command ordering between Metal-critical commands and SwiftUI chrome commands.
- `emit_gui/4` no longer separately threads `window_models`, `ui_model`, `metal_ui_cmds`, and `adapter_cmds` as independent render truths.
- Existing wire format remains unchanged.

#### 2. Finish the GUI window model, pane geometry, and hit-region contract

`Minga.RenderModel.Window` is the best current data shape, but it is not finished. Every GUI window needs one BEAM-authored pane geometry model derived from `Layout.get/1` and `WindowTree`. It must include the window id, total rect, content rect, text rect, gutter rect and metrics, clip rect, viewport summary, and input hit regions for text, gutter and fold controls, status/modeline targets, and split dividers. Swift may convert points to pixels and render native effects, but it must not infer pane ownership from active-window state, frame width, or global gutter fields.

Acceptance criteria:

- Wrapped lines produce multiple `Row` structs with `row_type: :wrap_continuation`, correct text slices, correct spans, correct cursor display coordinates, and tests with long ASCII, Unicode, tabs, and virtual text.
- `RenderModel.Window` carries BEAM-authored pane geometry: `window_id`, total/content/text/gutter rects, clip rect, viewport, gutter metrics, and divider/hit-region metadata.
- The GUI adapter sends enough window-scoped geometry for Swift to build one authoritative `PaneGeometry` per `window_id`; stale geometry is cleared on window destruction, split close, buffer switch, resize, frontend ready, and protocol recovery.
- `CoreTextMetalRenderer` clips text, overlays, cursorline, gutters, indent guides, diagnostics, and selections to the owning pane rect. It no longer uses global `frameState.cols`, viewport width, or global `gutterCol` for pane-local drawing.
- Cursorline is window-scoped, not row-only. In side-by-side splits, the active pane cursorline is clipped to that pane and never spans another pane.
- `EditorNSView` hit testing resolves through the same pane geometry used for rendering. Pixel-to-cell conversion, gutter hover, fold chevrons, scroll targeting, and divider detection use clicked-pane geometry, not active/global gutter state.
- Divider hover, press, drag, and release use one shared hit-region contract. If hover shows a resize cursor, the subsequent drag routes as split resize, not text selection.
- Smooth scroll fractional offset is bound to the gesture's initial `window_id` until the gesture ends. Pointer movement or focus changes during the gesture must not transfer the offset to another pane.
- BEAM mouse handling uses clicked-window targets for fold gutter, buffer content, resize, and scroll actions. Regression coverage includes inactive-pane gutter clicks, split close stale geometry, side-by-side clipping, cursorline pane clipping, divider drag, and smooth scroll across focus transitions.
- `RenderModel.Window` gets `content_epoch` and reset triggers for frontend ready, window creation, window destruction, buffer switch, resize, font change, theme change, fold or wrap mode change, parser reset, and protocol recovery.
- `full_refresh` is tied to epoch/reset semantics instead of being a loose flag that is always true.
- Non-buffer window content is either encoded as first-class `content_kind` models or explicitly excluded from the GUI adapter with a tracked follow-up and no misleading `additional_window_models` path.
- GUI window content tests cover folds, wraps, virtual lines, block decorations, diagnostic overlays, document highlights, search overlays, cursor visibility, horizontal scroll, pane-local hit testing, and divider resizing.

#### 3. Replace pre-encoded UI models with semantic models

This is the Phase 1 debt. Work component by component, but do not call a component complete until the model is semantic and the old encoder path is gone.

Already semantic or mostly semantic:

- `theme`
- `breadcrumb`
- `which_key`
- `notifications`
- `search_state`
- `git_status`
- `agent_context` (semantic model, but `agent_context_builder` still has a tracked legacy `MingaEditor.Frontend.Protocol.GUI` type dependency)
- `gutter_separator`
- `split_separators`

Still pre-encoded and must be replaced:

- `status_bar`
- `observatory`
- `board`
- `tab_bar`
- `workspaces`
- `sidebars`
- `file_tree`
- `picker`
- `minibuffer`
- `completion`
- `signature_help`
- `agent_chat`
- `bottom_panel`
- `change_summary`
- `edit_timeline`
- `extension_overlay`
- `extension_panel`
- `hover_popup`
- `float_popup`

Recommended order:

1. Status bar, tab bar, workspaces. These are high-frequency and expose dirty markers, icons, and workspace summary shapes that should be semantic.
2. Sidebars and file tree. Preserve the file tree selection-only fast path, but make it a model-level fast path (`selection_epoch` or `selection_fingerprint`), not a pre-encoded command.
3. Input surfaces: picker, minibuffer, completion, signature help. These are focus-sensitive and need clean model ownership before more GUI input work.
4. Popups and extensions: hover popup, float popup, extension overlay, extension panel. These prove extension surfaces can publish model data without editor protocol surgery.
5. Agent surfaces: agent chat, bottom panel, change summary, edit timeline, board. These are the largest and should move with the MingaAgent boundary cleanup in step 4.
6. Cleanup: delete migrated `ProtocolGUI.encode_gui_*` functions, split remaining protocol helpers into focused core modules, and remove compatibility tests that only prove the deleted path.

Acceptance criteria per component:

- The core model struct has domain fields, not `encoded` binary fields.
- The builder accepts specific inputs and returns the semantic model.
- The encoder lives in `lib/minga/frontend/adapter/gui/` or a core protocol module it calls.
- The encoder is a pure function of the model and adapter caches.
- Tests exist at the model, builder, and encoder boundaries.
- The old `ProtocolGUI.encode_gui_*` function is deleted or moved to core with a semantic-model interface.
- Swift receives byte-identical output unless the component intentionally changes protocol shape with a documented decoder update.

#### 4. Move agent UI ownership out of the editor

The spec says `MingaAgent` should produce agent UI models. That is not true yet for the complex agent surfaces.

Acceptance criteria:

- Agent chat, prompt, board, change summary, bottom panel, and edit timeline model builders live in `MingaAgent` or consume input structs owned by `MingaAgent`.
- `MingaEditor.RenderPipeline.Content` no longer imports `MingaEditor.Agent.View.*` modules for agent rendering.
- `MingaEditor.RenderModel.UI.AgentChatBuilder` no longer reaches into `MingaEditor.Agent.UIState` or calls `MingaAgent.Session` directly. The editor extracts a narrow input contract and hands it to `MingaAgent`.
- `MingaAgent` imports core render model types but does not import `MingaEditor` for rendering.

#### 5. Use Phase 3 instrumentation to set the retained-rendering baseline

Do not optimize from intuition. Record the current behavior before changing row identity or protocol shape.

Measure these scenarios in the GUI frontend:

- Cursor move without scroll.
- One-line scroll.
- Page scroll.
- Text edit on one line.
- Text edit that changes syntax spans across multiple lines.
- Selection drag across visible rows.
- Search next and search previous.
- File tree cursor move.
- Picker typing with preview visible.
- Agent chat append while a response streams.

Record these metrics:

- BEAM window model build time.
- BEAM UI model build time.
- GUI adapter encode time.
- Row bytes, overlay bytes, gutter bytes, annotation bytes, metadata bytes, chrome bytes, and frame command bytes.
- Swift buffer rows rasterized.
- Swift buffer rows reused.
- Texture uploads and upload bytes.
- Frame render duration.

Acceptance criteria:

- The PR or linked measurement note contains baseline numbers for the scenarios above.
- Phase 4 work names the metric it is expected to improve before implementation starts.

#### 6. Add stable row identity and content epochs

This is where retained rendering becomes real. Before Phase 4, the Swift atlas keyed buffer rows by display row, which meant scrolling changed the key even when the same logical row was still visible.

Target row shape:

```elixir
%Minga.RenderModel.Window.Row{
  row_id: row_id,
  row_type: :normal,
  buffer_id: buffer_id,
  source_line: 12,
  visual_index: 0,
  decoration_id: nil,
  text: text,
  spans: spans,
  content_hash: content_hash
}
```

Acceptance criteria:

- BEAM rows include deterministic `row_id` values that distinguish normal lines, wrapped continuations, fold summaries, virtual lines, block decorations, and future widget rows.
- Swift decodes row IDs and uses `window_id + content_epoch + row_id + content_hash` for atlas reuse instead of `window_id + display_row + content_hash`.
- Cursor movement without scroll produces zero row rasterizations.
- One-line scroll rasterizes only the newly exposed durable rows in the common case.
- Text edits rasterize only affected rows plus rows whose syntax or layout actually changed.
- Epoch mismatch causes conservative recovery through a full refresh, not stale rendering.

#### 7. Move DisplayList behind the TUI adapter

Do this after GUI model ownership is fixed. The TUI adapter proof is useful, but it is not the production path yet.

Acceptance criteria:

- TUI output is derived from `Minga.RenderModel`, not from `DisplayList.WindowFrame` as the pipeline-level product.
- `DisplayList` remains only as a TUI adapter detail if it is still useful.
- Both GUI and TUI consume the same visible model for buffer windows and shared chrome data.

### Definition of complete

The rendering simplification is complete when all of these are true:

- There is one top-level `%Minga.RenderModel{}` for a rendered frame.
- Core render model structs contain semantic fields, not pre-encoded protocol binaries.
- GUI encoders live in core and are pure functions of render models plus adapter caches.
- `MingaEditor.Frontend.Protocol.GUI` no longer owns render-model encoding for migrated surfaces.
- GUI buffer row retention is keyed by BEAM-authored row identity and content epoch, not display row.
- Agent UI models are produced by `MingaAgent` or by agent-owned input contracts, not by editor render modules reaching into agent internals.
- TUI derives from the same model or has a documented adapter-only compatibility layer.

### What not to do next

- Do not add delta opcodes before stable row identity and content epochs are working.
- Do not migrate another component by wrapping a binary command in a model struct.
- Do not keep both old and new paths for the same component after a swap.
- Do not treat display-row atlas keys as retained rendering.
- Do not use instrumentation as a checkbox. Use it to decide the next optimization.


## The problem

The rendering pipeline is ~16,000 lines across ~30 modules. The weight comes from one structural issue: there is no single object that says "this is what the user should see." Because that concept is missing, multiple layers each reconstruct pieces of it.

The Content stage builds `DisplayList.WindowFrame` for TUI and `SemanticWindow` for GUI from the same editor state. The Emit stage sends cell commands for TUI, then `Emit.GUI` does a second pass assembling 25 UI component payloads by reaching back into editor state. These are parallel render truths, not one visible model with frontend adapters.

`Emit.GUI` is 2,320 lines. Most of that is not encoding. Each of its 25 `build_gui_*` functions extracts data from editor state, computes a fingerprint, checks a cache, and then encodes. Steps 1-3 are computing what's visible. Only step 4 is translation. The emit layer is doing rendering work that belongs upstream.

There is also a structural problem: the rendering infrastructure (render model types, protocol encoding, frontend adapters, frontend connection) is trapped inside `MingaEditor`. The agent system (`MingaAgent`) and extensions both contribute UI, but they can only reach the screen by going through the editor's rendering pipeline. The editor owns the frontend, so everything that wants to display anything must depend on the editor.

The pipeline today:

```text
EditorState
  ↓
RenderPipeline.Input
  ↓
Invalidation
  ↓
Layout
  ↓
Scroll
  ↓
Content
    ├─ DisplayList.WindowFrame (lines/gutter/tildes for TUI)
    └─ SemanticWindow (side payload for GUI)
  ↓
Chrome
  ↓
Compose
  ↓
Emit
    ├─ TUI cell-style frame commands
    ├─ gui_window_content for GUI buffer windows
    └─ 25 SwiftUI UI sync functions (compute + fingerprint + encode)
  ↓
Swift
    ├─ GUIWindowContent state
    ├─ CoreText line rasterization
    ├─ LineTextureAtlas (keyed by stable row identity)
    └─ Metal draw pass
```

The problem is not that none of the right pieces exist. `SemanticWindow` already has pre-resolved rows. Selection, search, diagnostics, and document highlights are already separate overlay-like payloads. The problem is that these are not the canonical model. They are a GUI-specific side payload attached to the TUI-centric `DisplayList.WindowFrame`.

## The destination

Minga is a platform with an editor as its primary product, not an editor with rendering bolted on. The rendering infrastructure belongs in core (`lib/minga`). The editor, agent system, and extensions are products and contributors that build on that platform.

This is the Emacs insight: Emacs is a Lisp runtime with a display engine, and the editor is the first product built on it. magit, org-mode, and mu4e prove the platform works because they build complete interfaces using the same core primitives without being text editors. Minga has an advantage: it does not need to force everything into the buffer/text metaphor. The render model can describe rich UI (tab bars, sidebars, panels, popups) as first-class concepts.

### Platform architecture

```text
Minga (core: lib/minga)
  ├─ Buffers, config, extensions, keymaps, commands, modes
  ├─ RenderModel types (the shared visible-truth contract)
  ├─ Frontend adapters (encode model → protocol)
  └─ Frontend protocol (binary format, opcodes, connection)

MingaEditor (product: lib/minga_editor)
  ├─ EditorState
  ├─ Render model builder (derives RenderModel from EditorState)
  ├─ Pipeline orchestration (invalidation, layout, scroll, dirty tracking)
  └─ Editor-specific window management

MingaAgent (product: lib/minga_agent)
  ├─ Sessions, tools, chat
  └─ Agent UI model producers

Extensions (via Minga.Extension)
  └─ UI model contributors through core types
```

The dependency direction:

```text
Minga (core)        ← defines RenderModel types, adapters, protocol
MingaEditor         ← builds full RenderModel, orchestrates frames
MingaAgent          ← produces agent UI models via core types
Extensions          ← produce UI model fragments via core types
```

Both `MingaAgent` and `MingaEditor` depend on `Minga` for the types and rendering infrastructure. Neither depends on the other. Extensions depend on `Minga`. A hypothetical `MingaNewUI` could build its own render model and use core adapters to get pixels on screen without importing `MingaEditor`.

### Render model

```text
EditorState (or any product's state)
  ↓ derive
Minga.RenderModel (visible UI truth, built once)
  ↓ adapt
Minga.Frontend.Adapter.TUI or .GUI (dumb encoders, in core)
  ↓ draw
Zig/libvaxis or Swift/Metal
```

Three rules:

```text
EditorState is editor truth.
RenderModel is visible truth.
Frontends are renderers and input sources, not truth owners.
```

`Minga.RenderModel` is a pure, BEAM-owned, derived data structure that describes what the user should see. Both frontends adapt the same model to their drawing surface. The adapters encode; they do not compute what is visible.

### Target `RenderModel` shape

```elixir
%Minga.RenderModel{
  windows: [
    %Minga.RenderModel.Window{
      id: window_id,
      content_kind: :buffer | :agent_chat | :dashboard,
      rect: rect,
      viewport: viewport_summary,
      content_epoch: 42,
      rows: durable_rows,
      overlays: overlay_state,
      gutter: gutter_model,
      cursor_visible_row: 7,
      indent_guides: indent_guide_model,
      modeline: modeline_model
    }
  ],
  ui: %Minga.RenderModel.UI{
    theme: theme_model,
    tab_bar: tab_bar_model,
    workspaces: workspaces_model,
    file_tree: file_tree_model,
    sidebars: sidebars_model,
    status_bar: status_bar_model,
    minibuffer: minibuffer_model,
    picker: picker_model,
    popups: popup_models,
    regions: hit_regions
  },
  cursor: cursor_model,
  title: title,
  window_bg: window_bg
}
```

The exact names can change. The point is ownership: this object is the canonical visible truth for both TUI and GUI, and its types live in core.

### What lives where

**`lib/minga` (core):** `Minga.RenderModel` and all its child types (`Minga.RenderModel.Window`, `Minga.RenderModel.UI`, `Minga.RenderModel.UI.FileTree`, `Minga.RenderModel.UI.AgentChat`, `Minga.RenderModel.Row`, etc.). Frontend adapters (`Minga.Frontend.Adapter.GUI`, `Minga.Frontend.Adapter.TUI`). Frontend protocol encoding. Frontend connection management.

**`lib/minga_editor`:** The render model builder that derives `Minga.RenderModel` from `EditorState`. Pipeline orchestration (invalidation, layout, scroll, content, compose). The editor is the compositor: it assembles the full render model from its own state plus contributions from agents and extensions, and hands it to core adapters.

**`lib/minga_agent`:** Agent UI model producers. `MingaAgent` builds `Minga.RenderModel.UI.AgentChat`, `Minga.RenderModel.UI.Board`, etc. using core types. It never imports `MingaEditor`.

This follows the same pattern as the existing extensions API: `Minga.Extension.Sidebar.Snapshot` (the type) lives in core, `MingaEditor.Extension.Sidebar` (the registry and runtime) lives in the editor. Data contracts in core, machinery in the product.

### Frontend adapters

Frontend-specific logic lives at the adapter edge, in core:

```elixir
model = MingaEditor.RenderModel.Builder.from_editor(state)
commands = Minga.Frontend.Adapter.GUI.encode(model, ctx)
Minga.Frontend.send_commands(ctx.port_manager, commands)
```

The TUI adapter turns the visible model into terminal cells and libvaxis commands. The GUI adapter turns the same visible model into row payloads, overlay payloads, native UI payloads, and Metal-critical commands.

The adapters do not decide editor semantics. They do not ask whether a fold changed row order, whether a diagnostic belongs to a buffer version, or how virtual text shifts a cursor. Those answers belong in `RenderModel` construction, which is the editor's job.

The TUI adapter is more than a serializer for window content. It composites rows-with-spans and overlay ranges into cell-level Face attributes. That is rendering computation, not editor semantics, and it belongs in the adapter. The principle is: adapters do not decide what is visible, but they absolutely do decide how to draw it on their surface.

### Adapter state and caching

The adapters are pure functions, not processes. Their signature is:

```elixir
Minga.Frontend.Adapter.GUI.encode(model, adapter_caches) :: {commands, adapter_caches}
```

The compositor (`Renderer.Server` in `MingaEditor`) holds the `adapter_caches` struct in its process state and passes it to the adapter on each frame. The adapter returns updated caches. This matches the current pattern where `Renderer.Caches` threads through `Emit.GUI`, but the GUI-specific fingerprint fields move into a core-defined `Minga.Frontend.Adapter.GUI.Caches` struct.

The remaining fields in `Renderer.Caches` (Chrome stage fingerprints, Content stage inter-frame caches, Emit stage viewport/gutter tracking) stay in `MingaEditor` because they serve the editor's pipeline orchestration, not the adapter.

### Scope: ProtocolGUI

The core GUI adapter subsumes both `Emit.GUI` (~2,320 lines of compute-then-encode) and the corresponding encoding functions in `ProtocolGUI` (~4,769 lines of wire-format encoding). The total code being reorganized is ~7,000 lines, not ~2,320. `ProtocolGUI`'s encoding logic is largely correct (it takes structured data and produces bytes); what changes is that it accepts `Minga.RenderModel.UI.*` types instead of ad-hoc argument lists, and it lives in core instead of `MingaEditor`.

For each component swap in Phase 1, the corresponding `encode_gui_*` function in `ProtocolGUI` also moves to the core adapter or a core protocol module it calls. The encoding logic is preserved; the interface changes.

### ProtocolGUI cleanup

`ProtocolGUI` is 85% pure encoding, but 15% of the code has state queries embedded in the encoding path: `Buffer.dirty?(pid)` during tab bar encoding, `UI.Picker.marked_count(picker)` during picker encoding, `Options.get(options_server, name)` during config encoding, `Language.detect_filetype(label)` for icon resolution. These are "compute what's visible" calls that belong in the model, not the encoder. The render model migration fixes this: when the encoder receives a model with `dirty: true` already resolved, it never queries process state.

Each component swap must also address these items for the corresponding `encode_gui_*` function:

1. **Strip state dependencies.** Replace process calls (`Buffer.dirty?`, `Picker.marked?`, `Options.get`, etc.) with pre-computed fields on the model. The encoder must be a pure function of its input.
2. **Extract to a focused module.** The monolithic 4,769-line file splits as components migrate. Large encoders (`encode_gui_agent_chat` is 1,116 lines) get their own module.
3. **Deduplicate shared helpers.** `encode_section/2` is duplicated in `gui.ex` and `gui_window_content.ex`. Enum-to-byte mappers (`encode_markdown_style` with 14 clauses, `encode_completion_kind` with 11, etc.) and string encoding helpers (`utf8_prefix_bytes`, used 33+ times) move to a shared `Minga.Frontend.Protocol.Encoding` utilities module.

This is not a separate phase. It happens as part of each Phase 1 component swap. But it is required work: a component is not "swapped" until its encoder is a pure function in core with no state dependencies, no duplication, and no imports from `MingaEditor`.

### Process architecture

The process boundary does not change. `Renderer.Server` (a GenServer in `MingaEditor`) owns the render loop. It builds the render model, calls the core adapter, and sends commands via `Minga.Frontend.send_commands`. The dependency direction is Layer 2 (`MingaEditor`) calling Layer 0 (`Minga`), which is correct.

### What `EditorState` still owns

`EditorState` remains the source of truth for editor behavior: buffers, windows, cursor, mode, viewport, folds, diagnostics, search, selections, decorations, shell state, and frontend capabilities. `RenderModel` is derived from it, not a replacement for it.

### What Swift and Zig own

Platform renderers own drawing resources, not editor truth.

Swift owns: CoreText line creation, Metal textures and atlas slots, cursor animation and blink timing, scroll interpolation and frame pacing, SwiftUI native UI widgets, local coalescing of draw work.

Zig owns: terminal cell painting, libvaxis render behavior, terminal clipping and terminal-specific capabilities.

Neither frontend owns fold resolution, wrap decisions, diagnostic validity, cursor semantics, or selection semantics.

### Architectural invariants

These are commitments from the existing architecture docs (ARCHITECTURE.md, PROTOCOL.md, AGENTS.md) that this migration must preserve. They exist as an explicit checklist so that implementation does not accidentally violate a documented guarantee.

**1. DisplayList is the current stable contract.** ARCHITECTURE.md and PROTOCOL.md treat `DisplayList.WindowFrame` as the central pipeline product and TUI's primary input. Phase 6 deliberately replaces it as the canonical visible truth. This is an intentional, documented break from a prior architectural commitment. Until Phase 6, `DisplayList` continues to serve TUI unchanged. After Phase 6, it becomes a TUI adapter detail, not a pipeline-level concept.

**2. Dirty-line tracking survives.** Only changed lines should trigger re-rendering work. The render model migration preserves this through input fingerprints on builders (unchanged inputs produce no new model) and content hashes on durable rows (unchanged rows produce no new texture work on the frontend). If a migration step breaks dirty-line tracking, that is a bug, not a tradeoff.

**3. GUI-first, TUI-capable.** The existing architecture treats GUI as the primary frontend and TUI as secondary. The Phase 2 TUI adapter proof-of-concept validates that the render model serves both frontends; it does not gate GUI development. If the TUI proof-of-concept reveals model adjustments are needed, those adjustments must not regress GUI capabilities or delay GUI-path work. The TUI adapter is a compatibility constraint, not a design driver.

**4. Forward-compatible protocol envelopes.** PROTOCOL.md documents versioned opcode envelopes with length-prefixed framing. Any new opcodes introduced by the core adapter (during Phase 1 component swaps or Phase 7 delta protocol) must follow the existing envelope format. The frontend must be able to skip unknown opcodes without crashing. This is already the protocol's design; the constraint is that new core adapter code must not bypass it.

**5. Headless runtime is unaffected.** ARCHITECTURE.md documents that the headless runtime (used in tests and server mode) works without rendering. `Renderer.Server` is not started in headless mode today, and that does not change. `Minga.RenderModel` types moving to core does not mean core requires rendering. The types are passive data structures; construction is opt-in by the product that needs rendering. No core module should import or depend on a running `Renderer.Server`.

**6. Telemetry preservation.** Pipeline-level events in `Renderer.Server` (`:minga, :render, :pipeline`, `:coalesced`, `:frame_latency`) are unaffected by this migration. Component-level telemetry inside `Emit.GUI` (if any) must be preserved or deliberately replaced in the core adapter during each Phase 1 component swap. Phase 3 adds new instrumentation; it does not remove existing instrumentation unless the measured code path no longer exists.

**7. Credo EX9001 validates dependency direction.** AGENTS.md documents compile-time enforcement of the three-namespace layer dependency direction (Layer 0 `Minga` ← Layer 1 `MingaEditor`/`MingaAgent` ← Layer 2). When render model types move to `lib/minga` (Layer 0), EX9001 automatically enforces that `MingaEditor` and `MingaAgent` can import them but core cannot import the products. This is free validation of the spec's dependency direction. If a core adapter accidentally imports `MingaEditor`, the build fails.

## Why the current pipeline is large

The pipeline mixes several jobs under the word "rendering":

1. Editor semantics: cursor, mode, viewport, folds, diagnostics, search state, selections, active window, shell state.
2. Layout: where windows, UI components, file tree, modeline, agent panel, and overlays live.
3. Visual row derivation: folds, wraps, virtual text, conceal, syntax spans, annotations, tildes, gutters, cursor display coordinates.
4. TUI painting: cell-grid draw commands.
5. GUI painting: semantic rows, overlays, Metal-critical UI geometry, SwiftUI UI payloads.
6. Protocol packaging: binary opcodes, batching, reset behavior, port writes.
7. Frontend resource management: CoreText layout, texture atlases, glyph caches, animations, frame pacing, native widgets.

All of those jobs are real. The accidental complexity comes from jobs 4 and 5 being interleaved through the pipeline instead of isolated at the adapter edge, from job 5 being split between Content (buffer windows) and Emit (UI components) with Emit re-deriving visible state from editor state instead of receiving it pre-computed, and from jobs 4-6 being trapped in the editor when they are platform infrastructure.

## Migration strategy: inventory capabilities, write replacements, swap

The migration does not port or incrementally reshape existing code. It does not rewrite from scratch without reference. It inventories what each component can do, designs a replacement that expresses those capabilities cleanly, and swaps the old code out.

### Why not incremental porting

Incremental porting reshapes code in place, keeping it working during transition. In practice, the old code's shape becomes a gravity well. New types get designed to be "easy to wire into the existing flow" instead of "correct." Tests accumulate for both paths. The result is close to the target but not there.

### Why not a clean-room rewrite

A clean-room rewrite risks dropping capabilities. You design a clean model that handles 90% of cases, then discover six weeks later that the old code had a selection-only fast path for a reason and now the GUI flickers when you arrow through the file tree.

### The middle path

For each component being replaced:

1. **Inventory the capabilities.** Document what the component can do, not how it does it. For the file tree emit, that might be: full tree send with active path, dirty indicators, git status, diagnostics, editing state, focus, selection; selection-only update when only the cursor moved; state transitions (hidden, scanning, ready, error); fingerprint-based skip when nothing changed. That is the thing you do not want to lose.

2. **Design the model from the target architecture.** What should the render model hand to a GUI encoder for this component? Design from the destination, not from the existing code. The capability inventory is a checklist, not a template.

3. **Write the replacement encoder.** It receives a pre-computed model and encodes it. It never touches `EditorState` or the emit context's broad fields.

4. **Swap.** Turn off the old path, turn on the new one. Delete the old `build_gui_*` function and its tests. The new tests assert on the UI model and the encoder separately.

5. **Verify against the capability inventory.** Every capability from step 1 is either present in the new code or explicitly dropped with a reason.

At no point are two paths maintained for the same component. The old path works until the day it is deleted. The new path is designed from the target, checked against capabilities, and swapped in as a clean break.

## Migration phases

The phases are reordered from the original spec. Simplification (collapsing parallel truths) comes first. Optimization (stable row identity, delta protocol) comes second.

### Phase 1: UI models and GUI adapter for UI components

This is the largest win per effort. `Emit.GUI`'s 25 UI component builders are ~1,800 lines of compute-then-encode. Replace them with pre-computed UI models (types in `lib/minga`, builders in the appropriate product) and a GUI adapter (in `lib/minga`) that only encodes.

Work through components one at a time. Start with simple, self-contained ones (theme, breadcrumb, status bar) to establish the pattern. Then pull one agent component forward early (agent context bar is small but crosses the `MingaEditor`/`MingaAgent` boundary) to prove the system boundary contract. Then continue with the remaining groups.

Each component swap follows the inventory-design-replace-swap process above.

**Component ordering:**

| Order | Group | Components | Why this order |
|-------|-------|-----------|----------------|
| 1 | Trivial standalone | theme, breadcrumb, which-key, notifications, search state, git status | Prove the pattern with zero risk |
| 2 | Agent boundary proof | agent context | Small, but proves MingaAgent produces its own UI models via core types |
| 3 | Status displays | status bar, observatory, board | Standalone, moderate complexity |
| 4 | Tab/workspace | tab bar, workspaces | Share `ChromeState`, swap together |
| 5 | Sidebar/tree | sidebars, file tree | Interact (file tree is a sidebar), swap together |
| 6 | Input | picker, minibuffer, completion, signature help | Focus-related, moderate interaction |
| 7 | Agent | agent chat, bottom panel, change summary, edit timeline | Share agent state, most complex |
| 8 | Extensions | extension overlay, extension panel | Extension system |
| 9 | Popups | hover popup, float popup | Standalone |

**Coexistence rule:** during Phase 1, the system has two patterns operating simultaneously: migrated components go through the core adapter, unmigrated components go through `Emit.GUI`. This is managed by a hard rule: the core adapter and `Emit.GUI` never share a component. The old `sync_swiftui_chrome` builder list shrinks by one each swap. The core adapter grows by one. The frame path calls both (core adapter for migrated components, then `Emit.GUI` for remaining ones). `Emit.GUI` only shrinks; it never gets new builders. When the last builder is swapped, `Emit.GUI` is deleted.

**Done when:** `Emit.GUI` is deleted. The core adapter encodes all UI from `Minga.RenderModel.UI`. Agent UI models are produced by `MingaAgent`, not derived by `MingaEditor`.

### Phase 2: Unify buffer window content

Stop building both `DisplayList.WindowFrame` and `SemanticWindow` for GUI frontends. The Content stage should produce one representation for buffer windows.

`SemanticWindow` is already close to the right shape. It has rows with text + spans, and overlays (selection, search, diagnostics, highlights) as separate ranges. The 0x80 `gui_window_content` encoder already consumes this. Promote it (or its successor) into `Minga.RenderModel.Window`. For GUI, the Content stage builds `Minga.RenderModel.Window` directly. For TUI, it still builds `DisplayList.WindowFrame` during the transition.

Agent chat windows get their own content kind (`:agent_chat`) in `Minga.RenderModel.Window`. `MingaAgent` builds the window's rows, overlays, and prompt model. `MingaEditor` places the window in the render model and treats it opaquely.

**TUI design constraint:** before finalizing `Minga.RenderModel.Window`, build a small TUI adapter proof-of-concept that derives cell output from the model for a simple case: one window, a few rows with syntax spans, one selection range, one search match. This proves the model serves both frontends before the GUI path commits to it. The TUI adapter composites rows-with-spans plus overlay ranges into cell-level Face attributes; if that compositing is unreasonably expensive or lossy compared to the current `DisplayList.WindowFrame` path, the model needs adjustment before Phase 6, not after.

**Done when:** the Content stage does not build `DisplayList.WindowFrame` lines for GUI buffer windows. One representation, not two. TUI proof-of-concept demonstrates the model is shared, not GUI-only.

### Phase 3: Instrumentation

Measure before optimizing. Add instrumentation for:

- BEAM render model build time.
- Bytes emitted per frame.
- Swift atlas hits and misses.
- Rows rasterized per frame.
- Texture uploads per frame.
- Frame render duration.
- Cursor move frame time.
- One-line scroll frame time.

This tells you whether row identity, protocol size, CoreText rasterization, or Metal uploads are the real bottleneck, and prevents optimizing the wrong thing.

### Phase 4: Stable row identity

Implementation status: the full-frame GUI path now includes `row_id` on every `Minga.RenderModel.Window.Row`, encodes it in `gui_window_content`, decodes it in Swift, and keys buffer row atlas entries by `window_id + row_id` with `content_epoch + content_hash` as the invalidation hash. Full frames are still sent.

Give durable rows a BEAM-generated stable identity. Change Swift to cache line textures by row identity plus content hash instead of display row.

Keep sending full frames. Do not add delta protocol yet.

#### Durable rows

A durable row is the smallest unit of text rasterization and row reuse. It represents one visual row, not necessarily one buffer line.

Durable rows include text content that affects the row texture: normal buffer text, syntax spans, inline virtual text, conceal results, fold summaries, wrap continuations, inline annotations, and text attributes that change glyph shape, color, or layout.

A durable row carries stable identity and invalidation data:

```elixir
%Minga.RenderModel.Row{
  row_id: row_id,
  row_kind: :normal,
  buffer_id: buffer_id,
  source_line: 12,
  visual_index: 0,
  decoration_id: nil,
  text: "def render(state) do",
  spans: spans,
  content_hash: content_hash,
  content_epoch: 42
}
```

`buf_line` alone is not enough. Folds, wrapping, virtual lines, block decorations, and future block widgets can produce multiple visual rows for one buffer line or rows with no direct source line.

Row identity should be deterministic and compact. Prefer a structured or numeric identity over allocating strings every frame.

The rule is:

```text
same row_id + same content_hash + same epoch = frontend may reuse retained drawing resources
```

#### Volatile overlays

Volatile overlays are visual state that can change often without changing the row texture: cursor, cursorline, selection, search matches, diagnostic underlines, LSP document highlights, navigation flash, scroll indicators, hover highlights.

Cursor movement should change overlays, not durable row content. Selection changes should change overlays, not row textures.

**Validation targets:**

```text
j/k without scroll: 0 row rasterizations
one-line scroll: ~1 newly exposed row rasterized
text edit: only affected rows rasterized
```

### Phase 5: Content epochs and reset semantics

Add a meaningful window content epoch. Define reset triggers: frontend ready, window creation/destruction, buffer switch, resize, font change, theme change, fold/wrap mode change, parser reset, protocol recovery.

The invariant:

```text
A frontend may retain render state, but every retained item must be invalidatable from BEAM-authored versioned model data.
```

Full reset means: discard retained row state for this window, accept the full row list as the new visible model, set the epoch to the BEAM-authored epoch.

### Phase 6: Move DisplayList behind the TUI adapter

`DisplayList` stops being the central visible truth. If the TUI still wants a display list, it is an adapter output:

```text
Minga.RenderModel.Window → TUI Adapter → DisplayList / cell commands
```

Implementation status: production TUI emit now builds commands from `Minga.RenderModel`, not from `DisplayList.Frame`. Buffer windows are adapted from `Minga.RenderModel.Window`, while remaining cell-grid chrome is carried as `Minga.RenderModel.UI.CellLayer` compatibility data until those surfaces become fully semantic UI models.

**Done when:** both frontends derive their output from `Minga.RenderModel`, and `DisplayList` is a TUI adapter detail.

### Phase 7: Delta protocol (only if measurements justify it)

Add delta messages only after stable row identity, separate overlays, content epochs, and full reset behavior are proven. Likely order:

1. Overlay-only cursor and cursorline updates.
2. Viewport updates that reference reusable row IDs and include newly exposed rows.
3. Row updates for changed content.

Implementation status: overlay-only cursor and cursorline deltas now use `gui_window_overlay_delta` (0xA0). The delta carries `window_id` and `content_epoch`, and Swift ignores it unless matching full window content is already retained for that epoch. The BEAM also emits the minimal overlay delta as the retained-window liveness marker on otherwise unchanged frames, because Swift prunes retained window content after clear-backed batches unless a window id appears in the batch. Viewport and durable-row snapshots now use `gui_window_viewport_delta` (0xA1) and `gui_window_rows_delta` (0xA2), both as complete visible-window snapshots with ordered ref-or-full row entries. Swift drops retained state if a referenced row is missing, and the BEAM follows row/viewport deltas with a full 0x80 recovery frame so backend caches do not silently advance forever after an un-applied delta. Full `gui_window_content` remains the first-frame, reset, epoch-change, and recovery path.

Every delta must carry `window_id` and `content_epoch`. If the frontend does not have that epoch, it ignores the update or requests recovery.

## Performance considerations

The performance bet is: spend modest BEAM CPU deriving stable visible rows, then let the frontend avoid expensive text rasterization and texture uploads.

### Model construction cost

The render model is built every frame. The GUI adapter fingerprints each UI model and skips encoding when nothing changed. But "build every frame" does not mean "allocate every struct every frame."

Today, `Emit.GUI` short-circuits before building data structures when fingerprint inputs haven't changed. That optimization must survive the migration. The pattern is a two-level fingerprint:

- **Input fingerprint** (cheap, in the builder): computed from the builder's inputs (the same fields that today's `Emit.GUI` uses for early bailout). If inputs haven't changed since the last frame, the builder returns the previously cached model without constructing a new one.
- **Output fingerprint** (on the model, in the adapter): computed from the full model struct when it's actually built. Used by the adapter to skip encoding.

For simple models (theme, breadcrumb), the input fingerprint is unnecessary because construction is trivially cheap. For expensive models (file tree with 500 entries, agent chat with 200 styled messages), the builder must accept a previous model and short-circuit on unchanged inputs.

The adapter does not know about input fingerprints. The builder does not know about encoding caches. Each optimizes independently at its own boundary.

### Costs and risks

- Row ID computation can allocate too much if implemented as per-frame strings.
- Content hashing can become expensive without caching.
- Naive BEAM-side diffing can become the new bottleneck.
- Full `gui_window_content` payloads keep protocol byte counts high until later phases.
- Epoch mistakes can cause stale visuals, so reset behavior must be conservative.

The initial implementation should keep full payloads and avoid BEAM-side row diffing. Let Swift use `row_id + content_hash` to reuse retained textures first. Only add delta protocol messages after instrumentation proves protocol bytes or encode time are a real bottleneck.

## System boundaries: MingaAgent

`MingaEditor` and `MingaAgent` are separate systems. Today the rendering pipeline blurs that boundary: `Emit.GUI` reaches into `MingaEditor.Agent.UIState` to build agent UI commands, `Content` imports agent view modules (`PromptRenderer`, `DashboardRenderer`), and `BufferPrefetch` has agent-specific prefetch logic. The rendering pipeline, which lives in `MingaEditor`, has direct knowledge of `MingaAgent` internals.

The render model enforces the boundary. `MingaAgent` is responsible for producing its own UI models using core types. `MingaEditor`'s render model builder receives those models; it does not compute them by reaching into agent state.

The contract:

```text
MingaAgent produces:  Minga.RenderModel.UI.AgentChat, .Board,
                      .AgentContext, .ChangeSummary, .EditTimeline
MingaEditor consumes: places them in Minga.RenderModel.UI, hands to core adapters
```

`MingaEditor` never imports agent view modules, agent UI state, or agent session state during rendering. `MingaAgent` becomes another contributor to the render model, not something the render pipeline reaches into.

### Agent view module migration

Today, agent view modules (`PromptRenderer`, `DashboardRenderer`, `PromptSemanticWindow`) live at `MingaEditor.Agent.View.*`. These are Layer 2 modules in the editor namespace that render agent UI. They need to move to `MingaAgent`, where they become agent-owned model builders that produce `Minga.RenderModel.*` types.

The input contract: these modules currently take `ViewContext`, a narrow projection of `EditorState`. In the new world, `MingaAgent` defines what inputs it needs to produce its UI models (buffer content, cursor position, viewport, styled messages, etc.). `MingaEditor` extracts those inputs from `EditorState` and passes them to `MingaAgent`'s builders. The context type can live in core if both systems need it, or `MingaAgent` can define its own input struct.

`MingaAgent` is also the proof-of-concept for the extensions-as-UI-contributors pattern. It is the first and most complex test case. If the render model contract is expressive enough for agent chat windows, board views, context bars, change summaries, and edit timelines, all produced by `MingaAgent` without `MingaEditor` importing a single agent module, then it is expressive enough for any extension. This is why one agent component is pulled forward to group 2 in the Phase 1 ordering.

## Extensions API alignment

The extensions API already uses the pattern this spec proposes: extensions register metadata, publish snapshots to ETS, and the render pipeline reads those snapshots during frame construction. Extensions never provide render callbacks. The rendering side is entirely owned by the pipeline.

Today, rendering extension contributions is hardcoded in `Emit.GUI` (`build_gui_sidebars_cmd`, `build_gui_bottom_panel_cmd`, etc.) and in the TUI's `SidebarRenderer`. Adding a new extension surface type requires adding a new `build_gui_*` function, a new protocol opcode, and a new TUI render path. That's core pipeline surgery for every new surface type.

With `Minga.RenderModel.UI` in core, the contract between extensions and rendering becomes the model itself. An extension publishes a model using core types. The core adapter encodes it. The editor is not in the path for extension UI.

Adding a new extension surface type means: define a `Minga.RenderModel.UI.*` struct (core), add an encode clause to the core adapter (core). Extensions can target it immediately. The editor does not need to change unless it also wants to render that surface type.

### What this spec delivers vs. what the platform requires

This spec delivers the infrastructure foundation: render model types in core, adapters in core, protocol in core, and the `MingaAgent` proof-of-concept proving the contract works across system boundaries. Extensions can produce `Minga.RenderModel.UI.*` types and have them encoded by core infrastructure.

The full platform vision requires additional work beyond this spec: a stable public API for model contribution (not just types but versioning and registration), a compositor that handles arbitrary model contributors (not just the hardcoded editor + agent + extensions the editor knows about), and lifecycle management for contributors. Today the editor is still the compositor that assembles all models into one frame. That is simpler than the current architecture but is not yet "any product can render independently." The platform direction is the motivation; this spec delivers the structural prerequisite.

## Server-client viability

This architecture works for local native frontends and future server-client frontends because retained state is cache only. The server sends stable, versioned visible model data. A client retains drawing resources if it can prove they match the BEAM-authored identity, hash, and epoch. On reconnect or epoch mismatch, the server sends a full reset.

## What not to do

- Do not add `RenderModel` beside `DisplayList` and `SemanticWindow` while all three remain active truths. Each phase must remove a parallel truth, not add one.
- Do not start with row delta opcodes or overlay-only updates before content epochs and reset semantics exist.
- Do not key caches by display row or `buf_line` alone.
- Do not move fold, wrap, syntax, diagnostic, or cursor semantics into Swift.
- Do not build a dirty-region framework before fixing model ownership.
- Do not treat Metal clearing the drawable as the root architectural problem. Clearing each frame can be normal if retained textures are reused correctly.
- Do not optimize away full reset recovery. Boring recovery is what keeps retained rendering safe.
- Do not incrementally port existing code in place. Inventory capabilities, design from the target, write the replacement, swap.
- Do not import `MingaEditor` from `MingaAgent` or from extensions for rendering purposes. UI model types live in core. Products produce models using core types.

## Testing strategy

Follow the Sandi Metz message-origin grid from AGENTS.md. The render model creates a clean test seam, and the goal is to use it, not to test both sides of it redundantly.

### Two boundaries, tested separately

The render model splits rendering into two public promises:

1. **Model construction:** given editor state, does `Minga.RenderModel` contain the correct visible representation?
2. **Adapter encoding:** given a `Minga.RenderModel`, does the adapter produce the correct protocol output?

Test each at its own boundary. Do not test through both layers when one suffices.

### Model construction tests

The client of model construction is the adapter. The public promise is: "given this editor state, the render model contains these UI models, these window rows, these overlays."

- Assert on the `Minga.RenderModel` struct returned by the builder. This is an incoming query; assert the return value.
- Set up editor state with the minimum needed to exercise the behavior. If testing the file tree UI model, set up a file tree with the relevant states (ready, scanning, hidden), not a full editor session.
- Each UI component model (`Minga.RenderModel.UI.FileTree`, `Minga.RenderModel.UI.StatusBar`, etc.) has its own `build` function that takes specific inputs. Test those functions directly with their inputs; do not require a full `EditorState` or `RenderPipeline.Input` when the function takes 3 arguments.
- Prefer behavior-style test names: `"file tree model includes dirty indicators for unsaved buffers"`, `"status bar model reflects cursor position after move"`.

### Adapter encoding tests

The client of the adapter is the frontend (Swift or Zig, via the protocol). The public promise is: "given this render model, the adapter produces these protocol bytes."

- Assert on the encoded output given a hand-built `Minga.RenderModel` or UI model struct. This is an incoming query; assert the return value.
- Do not set up editor state for adapter tests. The adapter receives a model; give it a model.
- Protocol wire-format compatibility is a legitimate public contract. Exhaustive encoding tests are intentional, not over-testing.
- Fingerprint/cache skip behavior is adapter-level: "given the same model twice, the second call produces no output." Test this at the adapter, not by running two full render passes.

### What not to test

- Do not test model construction through the adapter. If you want to verify that a file tree with diagnostics produces the right UI model, assert on the model struct, not on the encoded bytes.
- Do not test adapter encoding through model construction. If you want to verify that a file tree UI model encodes correctly, hand-build the model struct, do not set up a file tree in editor state.
- Do not assert on internal state of the render model builder. If a builder caches intermediate results, test through the public return value, not the cache.
- Do not re-test behaviors that are already covered at a cheaper layer. If a pure `Minga.RenderModel.UI.Theme.build/1` test proves the theme model is correct, do not also test it through a full render model build unless you are specifically testing the orchestration.

### Deleting old tests

When a component is swapped (old `build_gui_*` deleted, new model + encoder in place), delete the old tests entirely. Do not keep them "for safety." The old tests asserted on a code path that no longer exists. The new tests cover the new public promises. If a behavior from the capability inventory is not covered by the new tests, that is a gap to fill, not a reason to keep the old tests.

### The refactor test

Before writing any test, ask: "If I refactored the internals of this module without changing any public function's behavior, would this test break?" If yes, the test is asserting on implementation, not behavior. This is especially relevant during the migration because the whole point is changing internals while preserving visible behavior.

## Open questions

1. What exact structured type should represent `row_id` on the BEAM?
2. Should row identity be scoped to a window content epoch or stable across windows?
3. Which row ID inputs are required for wrapped rows, fold summaries, virtual lines, block decorations, and future block widgets?
4. Should content epoch be per window, per buffer, or global to the frontend session?
5. Which theme changes should bump row content hashes versus bump an epoch?
6. Which overlays can always remain overlays, and which visual treatments need to become spans for contrast or accessibility?
7. How should Swift request recovery if it receives an update for an unknown epoch?
8. What inputs should `MingaAgent`'s UI model builders accept? Should the context type live in core or should `MingaAgent` define its own input contract?

## Implementation reference

This section gives a fresh implementor enough concrete detail to build from. The worked example, directory layout, and coexistence mechanics are the things most likely to cause false starts if left vague.

### Directory layout

New files follow the core/product split. Nothing is added to `MingaEditor` except the builder that derives models from `EditorState`.

```text
lib/minga/
  render_model.ex                          # %Minga.RenderModel{} top-level struct
  render_model/
    window.ex                              # %Minga.RenderModel.Window{}
    row.ex                                 # %Minga.RenderModel.Row{} (Phase 4)
    ui.ex                                  # %Minga.RenderModel.UI{} container struct
    ui/
      theme.ex                             # %Minga.RenderModel.UI.Theme{}
      breadcrumb.ex                        # %Minga.RenderModel.UI.Breadcrumb{}
      which_key.ex                         # ...one file per component
      notifications.ex
      search_state.ex
      git_status.ex
      tab_bar.ex
      ...
  frontend/
    adapter/
      gui.ex                               # Minga.Frontend.Adapter.GUI top-level encode/2
      gui/
        caches.ex                          # %Minga.Frontend.Adapter.GUI.Caches{}
        theme_encoder.ex                   # encode_theme(model, caches) :: {cmd | nil, caches}
        breadcrumb_encoder.ex              # ...one encoder per component
        ...
      tui.ex                               # Minga.Frontend.Adapter.TUI (later phases)
    protocol/
      encoding.ex                          # Shared helpers: utf8_prefix_bytes, encode_section, etc.

lib/minga_editor/
  render_model/
    builder.ex                             # MingaEditor.RenderModel.Builder.from_editor(state)
    ui/
      theme_builder.ex                     # build(theme_inputs) :: Minga.RenderModel.UI.Theme.t()
      breadcrumb_builder.ex                # ...one builder per component
      ...

test/minga/
  render_model/
    ui/
      theme_test.exs                       # Model struct tests
      ...
  frontend/
    adapter/
      gui/
        theme_encoder_test.exs             # Encoder tests
        ...

test/minga_editor/
  render_model/
    ui/
      theme_builder_test.exs               # Builder tests (inputs → model)
      ...
```

### Worked example: theme

This walks through the full inventory-design-replace-swap cycle for one component so the pattern is concrete.

#### Step 1: Inventory the capabilities

The existing `build_gui_theme_cmd` in `Emit.GUI` (line 191):

- **Inputs:** `ctx.theme` (a `MingaEditor.UI.Theme.t()` struct)
- **Fingerprint:** `phash2({theme.name, Slots.to_color_pairs(theme)})`
- **Cache field:** `caches.last_gui_theme` (integer fingerprint)
- **Skip behavior:** if fingerprint matches, returns `{nil, caches}` (no command sent)
- **Encoding:** calls `ProtocolGUI.encode_gui_theme(theme)`, which maps `Slots.to_color_pairs` to `<<slot::8, r::8, g::8, b::8>>` entries prefixed with `@op_gui_theme` and a count byte
- **State dependencies:** none. Pure function of the theme struct. This is the simplest possible case.
- **Capabilities:** send full theme color slot mapping when any slot changes; skip when unchanged

#### Step 2: Design the model

```elixir
defmodule Minga.RenderModel.UI.Theme do
  @type color_slot :: {slot_id :: non_neg_integer(), rgb :: non_neg_integer()}

  @type t :: %__MODULE__{
          name: String.t(),
          color_slots: [color_slot()]
        }

  @enforce_keys [:name, :color_slots]
  defstruct [:name, :color_slots]
end
```

The model is a pre-resolved list of `{slot_id, rgb}` pairs. The builder resolves `Slots.to_color_pairs` and filters nils. The encoder never calls `Slots` or `Theme`.

#### Step 3: Write the builder

```elixir
defmodule MingaEditor.RenderModel.UI.ThemeBuilder do
  alias Minga.RenderModel.UI.Theme
  alias MingaEditor.UI.Theme, as: EditorTheme
  alias MingaEditor.UI.Theme.Slots

  @spec build(EditorTheme.t()) :: Theme.t()
  def build(%EditorTheme{} = theme) do
    slots =
      theme
      |> Slots.to_color_pairs()
      |> Enum.reject(fn {_slot, color} -> is_nil(color) end)

    %Theme{name: theme.name, color_slots: slots}
  end
end
```

The builder takes the editor's theme struct and produces a core render model. No caching here because construction is trivially cheap (simple map/filter). For expensive components (file tree, agent chat), the builder would accept a previous model and short-circuit on unchanged inputs.

#### Step 4: Write the encoder

```elixir
defmodule Minga.Frontend.Adapter.GUI.ThemeEncoder do
  alias Minga.RenderModel.UI.Theme
  alias Minga.Frontend.Adapter.GUI.Caches

  @op_gui_theme 0x21

  @spec encode(Theme.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Theme{} = theme, %Caches{} = caches) do
    fp = :erlang.phash2({theme.name, theme.color_slots})

    if fp != caches.last_gui_theme do
      cmd = encode_theme_cmd(theme)
      {cmd, %{caches | last_gui_theme: fp}}
    else
      {nil, caches}
    end
  end

  defp encode_theme_cmd(%Theme{color_slots: slots}) do
    entries =
      Enum.map(slots, fn {slot, rgb} ->
        <<slot::8, Bitwise.bsr(Bitwise.band(rgb, 0xFF0000), 16)::8,
          Bitwise.bsr(Bitwise.band(rgb, 0x00FF00), 8)::8,
          Bitwise.band(rgb, 0x0000FF)::8>>
      end)

    IO.iodata_to_binary([@op_gui_theme, <<length(slots)::8>> | entries])
  end
end
```

The encoder is a pure function: model in, binary out, caches updated. It uses the same opcode (`0x21`) and wire format as the existing `ProtocolGUI.encode_gui_theme`. No protocol change, no Swift change.

#### Step 5: Wire-up and swap

The top-level adapter dispatches to per-component encoders:

```elixir
defmodule Minga.Frontend.Adapter.GUI do
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder

  @spec encode_ui(Minga.RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%Minga.RenderModel.UI{} = ui, %Caches{} = caches) do
    {theme_cmd, caches} = ThemeEncoder.encode(ui.theme, caches)
    # ... more encoders added as components migrate ...

    cmds = Enum.reject([theme_cmd], &is_nil/1)
    {cmds, caches}
  end
end
```

In `sync_swiftui_chrome`, the theme builder is removed from the old list:

```elixir
builders = [
  # &build_gui_theme_cmd/2,          # REMOVED: now handled by core adapter
  &build_gui_tab_bar_cmd/2,
  &build_gui_workspaces_cmd/2,
  # ... rest unchanged ...
]
```

The frame path calls the core adapter first, then `sync_swiftui_chrome` for remaining components. Both produce command lists that get sent via `Frontend.send_commands`.

#### Step 6: Verify against inventory

- Full theme send when any slot changes: covered by encoder fingerprint mismatch
- Skip when unchanged: covered by encoder fingerprint match
- No state dependencies: builder takes theme struct, encoder takes model struct

Delete `build_gui_theme_cmd`, `theme_fingerprint`, and the corresponding `ProtocolGUI.encode_gui_theme`. Delete their tests. Write new tests at the three boundaries (builder, model struct, encoder).

### Coexistence mechanics during Phase 1

During the migration, both the core adapter and the shrinking `Emit.GUI` produce commands for the same frame. The wire-up in the render pipeline looks like:

```text
1. Builder produces Minga.RenderModel (with UI models for migrated components)
2. Core adapter encodes migrated components → command list A
3. Emit.GUI encodes remaining components → command list B
4. Both command lists sent via Frontend.send_commands
```

The hard rule: a component is in exactly one path. The core adapter's `encode_ui` function grows a clause per swap. The `sync_swiftui_chrome` builder list shrinks by one per swap. They never overlap.

When the last builder is removed from `sync_swiftui_chrome`, `Emit.GUI`'s chrome path is deleted. When all of `Emit.GUI`'s functions are migrated (including `build_metal_commands` and the gutter/cursorline/separator geometry in later phases), the entire `gui.ex` file is deleted.

### Capability inventories for Group 1 (trivial standalone)

These are the six simplest components. Each is self-contained with no cross-component dependencies.

**Theme** (see worked example above)
- Inputs: `ctx.theme`
- States: full color slot set
- Fingerprint: `phash2({name, color_pairs})`
- State dependencies: none

**Breadcrumb** (`Emit.GUI` line 674)
- Inputs: active buffer path, file tree root
- States: path + root displayed, or nil (no active buffer)
- Fingerprint: `phash2({file_path, root})`
- State dependencies: `Buffer.file_path(buf)` (process call in `active_buffer_path`). Must be pre-resolved in builder.

**Which-key** (`Emit.GUI` line 608)
- Inputs: `ctx.shell_state.whichkey`
- States: visible (with key bindings), hidden (nil whichkey)
- Fingerprint: `phash2(wk)`
- State dependencies: none

**Notifications** (`Emit.GUI` line 1766)
- Inputs: `ctx.notifications`
- States: list of notification structs
- Fingerprint: `phash2(ctx.notifications)`
- State dependencies: none

**Search state** (`Emit.GUI` line 2133)
- Inputs: `ctx.search.gui_search`, search pattern, match stats
- States: active search (with match count, current index, options), inactive (no search)
- Fingerprint: `phash2({active?, match_count, current_index, gui_search})`
- State dependencies: `compute_search_stats` calls into buffer/search state. Must be pre-resolved in builder.

**Git status** (`Emit.GUI` line 567)
- Inputs: `ctx.shell_state.git_status_panel`, `ctx.git_syncing`, `ctx.git_toast`
- States: repo with status data (branch, ahead/behind, entries, stash, commit msg), not-a-repo
- Fingerprint: `phash2(enriched_map)` for repo state, `{:no_git, syncing, toast}` for non-repo
- State dependencies: none (git data is already pre-fetched into shell state)

### Key implementation notes

**Opcode reuse.** The core adapter produces the same binary opcodes as the existing `ProtocolGUI` functions. No Swift changes are needed for Phase 1. The protocol wire format does not change; only the Elixir code that produces it changes.

**`Minga.Frontend.Adapter.GUI.Caches` starts small.** Create it with just `last_gui_theme` for the first swap. Add one field per component as each migrates. When Phase 1 is complete, move the remaining GUI fingerprint fields from `MingaEditor.Renderer.Caches` to this struct and delete them from the editor's caches.

**Builder input contract.** For Group 1, builders take simple, specific arguments (a theme struct, a file path + root string, a whichkey struct). They do not take the full `ctx` or `EditorState`. The render model builder orchestrator (`MingaEditor.RenderModel.Builder`) extracts the right inputs from `EditorState` and calls each component builder. This keeps builders testable without constructing a full editor state.

**Process calls must move to the builder.** `active_buffer_path` calls `Buffer.file_path(buf)`. `compute_search_stats` queries buffer state. These are "compute what's visible" calls. They happen in the builder (which runs in `MingaEditor`'s process context and can call `Buffer`), not in the encoder (which is a pure function in core).

**`ProtocolGUI` functions migrate with each swap.** When theme moves to the core adapter, `ProtocolGUI.encode_gui_theme` is either deleted (if the core encoder reimplements the encoding) or moved to a core protocol module. The function must not remain as dead code in `MingaEditor`.

## Recommendation

Lead with simplification, not optimization. The rendering pipeline's problem is not primarily cache misses or missing row identity. It is too many parallel representations of "what the user sees," and rendering infrastructure trapped in the wrong layer. The first work should collapse those representations and move the render model types and adapters to core. The optimization work (stable row identity, delta protocol) is valuable but comes after the structural simplification, when there is one model in the right place to optimize.
