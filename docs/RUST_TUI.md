# Rust TUI

The Rust terminal frontend is the semantic TUI target. It supports two launch modes over the same packet-4 frontend protocol.

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
