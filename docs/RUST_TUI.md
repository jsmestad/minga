# Rust TUI

The Rust terminal frontend is the semantic TUI target. It has one launch mode: BEAM-owned Port renderer. The BEAM starts first, spawns the Rust renderer, and keeps editor state under BEAM supervision.

`bin/minga-rust` or `MINGA_TUI_IMPL=rust bin/minga` starts Minga normally and spawns the Rust renderer as a Port. Rust opens `MINGA_TTY` or `/dev/tty` for Ratatui/Crossterm terminal I/O, while stdin/stdout remain the packet protocol.

Build it with:

```bash
mix native.build.rust_tui
```

Run the BEAM-owned Rust path from the repo root with:

```bash
bin/minga-rust
```

Or select Rust explicitly through the normal launcher:

```bash
MINGA_TUI_IMPL=rust bin/minga
```

The BEAM remains the source of truth for editor state and sends Semantic UI commands. Rust owns frontend concerns only: terminal lifecycle, input capture, resize handling, retained frontend view state, Ratatui rendering, and frontend capability reporting.

## Active Architecture

- `app.rs` owns the frontend event loop, BEAM host wiring, input forwarding, resize reporting, side-effect application, and render scheduling.
- `beam_host.rs` owns the BEAM-owned Port packet transport over stdin/stdout.
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

## Go Reference Deletion Gate

The Go TUI remains the semantic terminal reference until Rust proves parity with tests and manual comparison. Do not delete the Go renderer unless a final parity PR shows all of these checks passing:

- `cargo test --manifest-path rust/tui/Cargo.toml`
- `cargo clippy --manifest-path rust/tui/Cargo.toml -- -D warnings`
- `mix protocol.gen --check`
- `mix compile --warnings-as-errors`
- `cd go/tui && go test ./...`
- Manual comparison of `bin/minga-rust` against `MINGA_TUI_IMPL=go bin/minga` for editor chrome, file tree, picker and overlays, agent chat, semantic chrome, and mouse routing.

Every frontend-visible Rust behavior change on the path to deletion should have a Rust parity test that names the Go contract it mirrors. Go is reference-only during this work; do not refactor Go as part of Rust parity unless the final deletion PR explicitly scopes it.
