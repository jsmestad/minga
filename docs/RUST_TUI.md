# Rust TUI

The Rust terminal frontend is the semantic TUI target. It supports two launch modes over the same packet-4 frontend protocol, but it has only one active rendering path: Semantic UI retained state rendered through Ratatui.

- Rust-parent mode: `bin/minga-rust` starts Rust first, Rust owns terminal stdin/stdout, and Rust launches the BEAM editor core as a connected child over private pipes.
- BEAM-parent mode: `MINGA_TUI_IMPL=rust bin/minga` keeps the existing BEAM-spawned renderer path for compatibility while this migration is in flight.

Build it with:

```bash
mix native.build.rust_tui
```

Run the Rust-parent path from the repo root with:

```bash
bin/minga-rust
```

Run the compatibility BEAM-parent path with:

```bash
MINGA_TUI_IMPL=rust bin/minga
```

In both modes, the BEAM remains the source of truth for editor state and sends Semantic UI commands. Rust owns frontend concerns only: terminal lifecycle, input capture, resize handling, retained frontend view state, Ratatui rendering, and frontend capability reporting.

## Active Architecture

- `app.rs` owns the frontend event loop, BEAM host wiring, input forwarding, resize reporting, side-effect application, and render scheduling.
- `beam_host.rs` owns the Rust-parent process boundary and the BEAM-parent compatibility transport.
- `protocol.rs` owns packet-4 framing and frontend control messages.
- `semantic.rs` owns the typed Semantic UI command decoder generated from the protocol schema.
- `semantic_state.rs` owns retained frontend state and maps decoded Semantic UI commands into renderable state plus terminal side effects.
- `semantic_renderer.rs` is the thin Ratatui renderer facade. It owns `SemanticRenderer::render`, cursor style coordination, terminal frame entry, and content-area clipping.
- `renderer/layout.rs` computes deterministic terminal-grid regions for chrome, editor body, sidebars, bottom panels, minibuffer, and status surfaces.
- `renderer/geometry.rs` owns clipping-safe rectangles for anchored popups, centered overlays, bounded dimensions, and semantic window placement.
- `renderer/theme.rs` centralizes Ratatui styles and Semantic UI color/attribute conversion.
- `renderer/surfaces.rs` orchestrates draw order. `renderer/chrome.rs`, `renderer/editor.rs`, and `renderer/overlays.rs` render the actual semantic surface groups.
- `terminal.rs` owns raw mode, alternate screen, synchronized updates, title/clipboard/cursor control sequences, and Ratatui backend access.
- `input.rs`, `signals.rs`, and `images.rs` stay frontend-local and do not define editor state.

Legacy cell-grid renderer support is removed from the Rust TUI. If the BEAM sends non-semantic legacy render commands, Rust should surface that as a protocol/state diagnostic instead of preserving another compatibility renderer.

Board-specific UI is not a Rust TUI parity target. Board experiments must live behind generic extension primitives or remain outside default builds; see GitHub issue #2167.
