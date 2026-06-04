# Rust TUI Ticket Stack

These are the first three tickets for the semantic-only Rust TUI direction. They are intentionally sequential: do not start ticket 2 until ticket 1 has settled the contract language, and do not start ticket 3 until ticket 2 has made the old non-semantic path hard to use accidentally.

## Ticket 1: Lock Semantic UI Direction

Issue: https://github.com/jsmestad/minga/issues/2155

### Summary

Make Minga’s frontend contract direction explicit: the BEAM emits one Semantic UI contract, and GUI/TUI/native/web clients adapt through declared capabilities rather than separate product protocols.

### Developer Notes

Lane: Semantic UI Contract.

Inspect first:

- `docs/PROTOCOL.md`
- `docs/GUI_PROTOCOL.md`
- `docs/RETAINED_GUI_RENDERING_SPEC.md`
- `lib/minga_editor/frontend/capabilities.ex`
- `lib/minga_editor/frontend/emit.ex`
- `docs/CHARM_TUI.md`

Likely modified:

- `docs/PROTOCOL.md`
- `docs/GUI_PROTOCOL.md`
- `docs/RETAINED_GUI_RENDERING_SPEC.md`
- `docs/ARCHITECTURE.md`
- `docs/CHARM_TUI.md`

Required direction:

- Minga emits Semantic UI for shared visible UI.
- Frontend identity is opaque to product behavior.
- Capabilities describe rendering surfaces: terminal grid, desktop window, web, text measurement, color support, images, float support, and host mode.
- Existing `GUI_*` names may remain temporarily as historical wire names, but docs must describe the contract as Semantic UI rather than native-GUI-only chrome.

Forbidden changes:

- Do not change opcode values.
- Do not rewrite transport framing.
- Do not implement renderer behavior.
- Do not delete Zig parser/tree-sitter code.
- Do not add new Swift/Rust/Go product branches in BEAM code.

### Acceptance Criteria

- Docs state that GUI, terminal, and future frontends consume one Semantic UI contract.
- Docs distinguish historical `GUI` naming from the semantic contract direction.
- Docs say non-semantic shared UI work is stale scope unless the ticket is deleting old support.
- Capability negotiation is described as the only frontend adaptation mechanism for product behavior.
- `mix protocol.gen --check` still passes if protocol docs or schema are touched.

### Validation

Run the smallest relevant set:

```bash
mix protocol.gen --check
mix compile --warnings-as-errors
```

## Ticket 2: Remove Non-Semantic Frontend Support

Issue: https://github.com/jsmestad/minga/issues/2156

### Summary

Remove or quarantine non-semantic shared UI rendering support so future frontend work cannot silently route chrome through legacy cell-grid paths.

### Developer Notes

Lane: Semantic UI Contract plus Frontend Clients.

Inspect first:

- `lib/minga_editor/frontend/emit.ex`
- `lib/minga_editor/frontend/emit/tui.ex`
- `lib/minga_editor/frontend/emit/tui/cell_command_encoder.ex`
- `lib/minga_editor/frontend/adapter.ex`
- `lib/minga_editor/frontend/protocol/gui.ex`
- `go/tui/internal/ui/model.go`
- `go/tui/internal/ui/render_content.go`
- `rust/tui/src/semantic_renderer.rs`
- `rust/tui/src/semantic_state.rs`
- `rust/tui/src/semantic.rs`

Likely modified:

- BEAM frontend emit modules.
- Go TUI semantic guardrail tests.
- Rust TUI renderer or semantic-state code if it currently falls back silently.
- Protocol docs if behavior changes.

Required direction:

- Shared chrome must be modeled as Semantic UI.
- Legacy cell drawing may remain only for explicitly tracked temporary buffer-window compatibility, not shared chrome.
- If a frontend receives an unsupported legacy shared chrome path, it should fail loudly in tests or log an actionable warning in development.

Forbidden changes:

- Do not rewrite the Rust TUI from scratch in this ticket.
- Do not delete the Go semantic reference.
- Do not delete Zig parser/tree-sitter code.
- Do not change editor kernel behavior.
- Do not broaden this into protocol renaming.

### Acceptance Criteria

- BEAM-side shared UI emission has one semantic path.
- Go and Rust do not silently fall back to legacy cells for shared chrome.
- Tests or guardrails catch shared chrome added only via cell commands.
- Existing semantic Go TUI behavior remains usable as a reference.
- Validation covers BEAM protocol generation and affected frontend tests.

### Validation

Run the smallest relevant set:

```bash
mix protocol.gen --check
mix test.llm test/path/to/affected_test.exs
cd go/tui && go test ./...
cd rust/tui && cargo test
```

## Ticket 3: Build Fresh Rust Semantic TUI Skeleton

Issue: https://github.com/jsmestad/minga/issues/2157

### Summary

Create the fresh Rust terminal frontend skeleton around Ratatui plus Terminal, semantic state, and BEAM lifecycle discipline, without carrying forward the current mixed legacy renderer as the foundation.

### Developer Notes

Lane: Rust terminal frontend.

Inspect first:

- `rust/tui/Cargo.toml`
- `rust/tui/src/main.rs`
- `rust/tui/src/protocol.rs`
- `rust/tui/src/semantic.rs`
- `rust/tui/src/terminal.rs`
- `rust/tui/src/input.rs`
- `macos/Sources/BEAMProcessManager.swift`
- `lib/minga_editor/frontend/manager.ex`
- `go/tui/internal/protocol/events.go`
- `go/tui/internal/ui/model.go`

Likely modified:

- Rust TUI module layout.
- Rust protocol and semantic state tests.
- BEAM frontend manager only if a new Rust binary name or launch path is required.
- Docs for running the Rust TUI.

Required direction:

- Rust owns terminal lifecycle correctly through Ratatui and Terminal.
- BEAM remains the source of truth.
- The frontend can run as a BEAM-spawned port and preserve future connected/client-server options.
- The first renderer proves semantic decode and rendering, not full feature parity.

Forbidden changes:

- Do not port Zig parser/tree-sitter code.
- Do not remove Go reference code.
- Do not redesign the Semantic UI contract.
- Do not add a second frontend protocol.
- Do not make Rust own editor state.

### Acceptance Criteria

- Rust TUI has clear modules for protocol decode, semantic state, terminal lifecycle, input encode, BEAM host or connection lifecycle, and Ratatui rendering.
- Startup sends extended semantic capabilities.
- The frontend reads framed BEAM packets and updates semantic state without blocking input.
- A minimal semantic frame renders from retained state.
- Focused Rust tests cover ready encoding, semantic decode, retained state update, and at least one rendered semantic surface.

### Validation

Run the smallest relevant set:

```bash
cd rust/tui && cargo fmt --check
cd rust/tui && cargo test
mix compile --warnings-as-errors
```
