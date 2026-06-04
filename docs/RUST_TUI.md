# Rust TUI

The Rust terminal frontend is the semantic TUI target. It runs as a BEAM-spawned port by default and uses the same packet-4 framing as the Go reference and native GUI connected mode.

Build it with:

```bash
cd rust/tui
cargo build --release
```

Run Minga against it from the repo root with:

```bash
MINGA_TUI_IMPL=rust mix run --no-halt
```

The Rust binary owns terminal lifecycle through `Terminal` and Ratatui. The BEAM remains the source of truth for editor state and sends Semantic UI commands; the Rust frontend decodes framed packets, retains semantic view state, renders that state, and sends input, resize, ready, and log events back over the same port.
