# 🥨 Minga

A BEAM-powered modal text editor with Doom Emacs-style keybindings.

Minga uses the Erlang VM's actor model for fault-tolerant editor internals and
a Zig terminal renderer for high-performance TUI output. If the renderer
crashes, the supervisor restarts it — no data loss, no corrupted state.

## Status

🚧 **Early development** — building the walking skeleton.

## Architecture

```
BEAM (Elixir)                    Zig (libvaxis)
─────────────                    ──────────────
Buffer GenServer (gap buffer)    Terminal rendering
Modal FSM (Normal/Insert/Visual) Raw input capture
Keymap trie + Which-Key popups   Screen drawing
Command registry                 Floating panels
Editor orchestration
Supervisor tree ("Stamm")

        ◄── input events ──┐
        ── render cmds ────►│
           (Port protocol)  │
```

Two OS processes. Full fault isolation. Zero NIFs.

## Prerequisites

- Elixir 1.19+ / OTP 28+
- Zig 0.15+
- See `.tool-versions` for exact versions

## Build

```bash
# Install dependencies
mix deps.get

# Compile (builds both Elixir and Zig)
mix compile

# Run tests
mix test            # Elixir tests
cd zig && zig build test  # Zig tests

# Launch (once implemented)
mix minga path/to/file
```

## License

MIT

---

*Created with 🥨 in Munich.*
