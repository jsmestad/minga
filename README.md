# 🥨 Minga

**A modal text editor built for the age of AI agents, where any process can
crash without taking down your editor.**

AI coding agents are rewriting your files, spawning subprocesses, and racing
against your keystrokes. Most editors bolt this on and hope nothing breaks.
Minga was designed from the ground up with isolated, supervised processes.
When an agent hangs, a plugin crashes, or a renderer glitches, it restarts
itself. Your buffers, undo history, and unsaved work stay untouched.

Minga combines the modal editing of Neovim, the runtime flexibility of Emacs,
and a modern architecture: **Elixir on the BEAM VM** for editor logic and
**Zig** for terminal rendering. Vim users get the motions, operators, and
text objects they think in. Emacs users get a living, mutable runtime where
you can redefine commands, override keybindings, and customize any buffer's
behavior, all without restarting. And unlike either, every component is an
isolated process that can crash and recover independently.

## Why Minga?

### The problem with editors

Text editors are single-process programs. When something crashes (a bad
plugin, a rendering glitch, a corrupted state) your whole editor goes down.
Unsaved work, gone. You restart, reopen, re-navigate, re-remember what you
were doing.

### What if the editor could crash… and keep going?

Minga runs as **two OS processes** with full fault isolation:

<p align="center">
  <img src="docs/images/architecture.svg" alt="Minga two-process architecture" width="720"/>
</p>

The Erlang VM (the BEAM) was designed to run telephone switches,
systems
that literally cannot go down. It uses lightweight isolated processes
with supervision trees that detect failures and restart components
automatically. If the renderer crashes? The supervisor restarts it. Your
buffers, cursor position, undo history: untouched. No data loss. No
corrupted state.

This isn't theoretical. It's how Erlang has worked in telecom, banking, and
messaging infrastructure for 30+ years. Minga just points that reliability at
a text editor.

### Why hasn't anyone done this before?

Because the BEAM doesn't talk to terminals. It's a server-side VM, great at
concurrency but terrible at drawing characters on your screen. So Minga doesn't
try. It delegates rendering to a Zig binary compiled against
[libvaxis](https://github.com/rockorager/libvaxis), a modern terminal UI
library. Zero NIFs. Zero shared memory. Just a clean binary protocol between
two processes that each do what they're best at.

## Features

Minga aims to bring the best of modern modal editing together:

- **Vim-style modal editing:** Normal, Insert, Visual, Operator-Pending,
  Replace, and Search modes with the motions and operators you already know
  (`d`, `c`, `y`, `w`, `b`, `e`, `iw`, `i"`, `a{`, and many more)
- **Space-leader keybindings:** organized mnemonic commands behind `SPC`:
  `SPC f f` to find files, `SPC b b` to switch buffers, `SPC s p` to search
  your project. Discoverable via Which-Key popup that shows you what's
  available as you type
- **Tree-sitter syntax highlighting:** 24 languages compiled in (Elixir,
  Ruby, TypeScript, Go, Rust, Python, Zig, and more), with user-overridable
  highlight queries
- **Fuzzy file finder and buffer switcher:** built-in pickers with
  incremental search
- **Persistent undo:** your undo history survives buffer switches
- **Fault-tolerant by design:** OTP supervision means components restart
  independently
- **Built for the agentic era:** AI coding agents spawn unreliable external
  processes. Minga's supervision model makes agent crashes recoverable events
  instead of editor-killing disasters (see [Architecture](docs/ARCHITECTURE.md))

### Current status

🚧 **Early development.** Minga is usable for editing but is not yet a daily
driver. Core editing, navigation, and syntax highlighting work. We're building
toward split windows, LSP support, and a plugin system.

See the [Roadmap](ROADMAP.md) for the full feature grid and what's coming next.
If you want to help shape what a BEAM-powered editor can be, now is a great
time to jump in.

## Quick start

### Prerequisites

- Elixir 1.19+ / OTP 28+
- Zig 0.15+
- See `.tool-versions` for exact pinned versions

### Build & run

```bash
# Clone and build
git clone https://github.com/justinsmestad/minga.git
cd minga
mix deps.get
mix compile        # Builds both Elixir and Zig

# Run tests
mix test                       # 1,393 Elixir tests
cd zig && zig build test       # 105 Zig tests

# Launch
mix minga path/to/file
```

## Architecture deep dive

For the curious, here's what makes Minga tick:

| Layer | Technology | Responsibility |
|-------|-----------|----------------|
| **Editor core** | Elixir on the BEAM | Gap buffer, modes, motions, operators, text objects, keymap trie, command registry, undo/redo, syntax highlight orchestration |
| **Renderer** | Zig + libvaxis | Terminal drawing, keyboard input, tree-sitter parsing, floating panels |
| **Protocol** | Length-prefixed binary over stdin/stdout | Typed opcodes for render commands (BEAM→Zig) and input events (Zig→BEAM) |
| **Supervision** | OTP supervisor tree | Automatic restart of crashed components with preserved editor state |

The BEAM side is a set of GenServers (one per buffer, one for the editor
orchestrator, one for the port manager) all supervised. The Zig side is a
single-threaded event loop that reads port commands, renders frames, and
forwards keyboard input. Tree-sitter runs in the Zig process with
pre-compiled queries for instant highlighting on file open.

## Coming from another editor?

- **[For AI-assisted developers](docs/FOR-AI-CODERS.md):** Using Claude Code, Cursor, Copilot, or Aider? Your editor wasn't designed for agents. Minga was.
- **[For Neovim users](docs/FOR-NEOVIM-USERS.md):** Same modal editing, better runtime. Why the BEAM solves problems Neovim can't fix without a rewrite.
- **[For Emacs users](docs/FOR-EMACS-USERS.md):** Same depth of customization, none of the single-threaded pain. Elixir is Minga's Elisp.

## Contributing

Minga is open to contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for
setup, testing, and how to add new commands, motions, and render features.

```bash
# Before committing
mix lint                          # Format + Credo + compile warnings
mix test --warnings-as-errors     # Tests
mix dialyzer                      # Typespec consistency
```

## License

MIT

## Acknowledgements

A heartfelt thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs). Its keybinding design, leader-key UX, and relentless focus on making a powerful editor feel fast and discoverable were a direct inspiration for Minga's command model.

---

*Created with 🥨 in Colorado.*
