<p align="center">
  <img src="assets/minga_dark-transparent.svg" alt="Minga logo" width="128">
</p>

# Minga

**A programmable workbench on the BEAM for editing code and working with AI agents.**

[Getting Started](docs/GETTING-STARTED.md) | [Configuration](docs/CONFIGURATION.md) | [Architecture](docs/ARCHITECTURE.md) | [Contributing](CONTRIBUTING.md)

Minga runs Elixir on the Erlang VM (BEAM) behind native frontends: a Swift and Metal desktop app on macOS and a Go/Bubble Tea terminal client. Your editing buffers, LSP servers, agent sessions, and extensions share one supervised Elixir runtime.

### Current status

Minga is pre-release (building toward v0.1.0; see [#3542](https://github.com/jsmestad/minga/issues/3542) and [ADR-0004](docs/adr/0004-products-are-root-applets-over-a-fixed-engine.md)). Check the [issue tracker](https://github.com/jsmestad/minga/issues) for active work and release gates.

## Why the BEAM matters

Single-threaded editors were designed for one human typing sequentially in one buffer. When AI agents stream long responses, run tools, and edit files alongside you, a single event loop and shared mutable state become bottlenecks.

The BEAM provides four runtime properties that fit concurrent human and agent work:

- **Fair scheduling and per-process GC.** The BEAM preemptively schedules lightweight processes and runs garbage collection per process heap rather than pausing the whole editor. Busy agent streams or LSP indexing do not starve keystrokes.
- **Fault isolation.** Buffers, agent sessions, LSP clients, and extensions run in separate processes under supervision trees. A crashed extension or failing tool call restarts its own subtree without touching your open buffers or undo history.
- **Buffer-aware agent edits.** Every buffer is its own process, and agent file edits route through in-memory forks and staged changesets instead of blind filesystem writes. You review and publish (`SPC a p`) or discard (`SPC a P`) staged changes without clobbering unsaved edits.
- **Headless durability.** `minga --headless` runs the runtime without a window so agent sessions keep working locally or on a remote host after clients detach.

The BEAM is not used for GPU rasterization or syntax parsing: Swift and Metal draw macOS, Go draws the terminal, and Zig runs the tree-sitter parser and process-group helpers. For the full technical design, read [Architecture](docs/ARCHITECTURE.md).

## What it feels like to use

Press `Space` in Normal mode to open a mnemonic command menu (`SPC f f` finds files, `SPC b b` switches buffers, `SPC s p` searches the project). Open the agent panel with `SPC a a` or the full agent workspace with `SPC a t`.

Your configuration at `~/.config/minga/config.exs` is plain Elixir, the same language as the core runtime:

```elixir
use Minga.Config

set :theme, :catppuccin_mocha
set :line_numbers, :relative
set :tab_width, 2

# Hooks run in their own processes so slow commands never block typing.
on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end
```

Define commands, add keybindings, attach hooks, wrap commands with before/after/around advice, and install extensions from local paths, Git repositories, or Hex packages.

## What ships today

- **Native frontends.** Swift + Metal on macOS (GUI-first) and Go + Bubble Tea in the terminal. Same core, same config, same Semantic UI protocol.
- **Vim modal and CUA editing.** Normal, Insert, Visual, Operator-Pending, Replace, and Search modes, text objects, registers, macros, marks, dot repeat, plus CUA editing support.
- **Space-leader command menus.** Doom-style `SPC` menus with Which-Key popups.
- **Tree-sitter highlighting.** 50 compiled language grammars via the Zig `minga-parser` Port.
- **Native multi-provider agent runtime.** Streaming turns, tool approvals, buffer-aware staged edits with three-way merge, session recovery, hooks, and MCP servers across Anthropic, OpenAI, OpenAI Codex, Google, OpenRouter, Groq, Mistral, and DeepSeek.
- **Headless runtime and remote sessions.** `minga --headless` and `MingaAgent.Runtime` support remote attach/detach and WebSocket + JSON-RPC clients.
- **Elixir extensibility.** Commands, keybindings, hooks, advice, and supervised extensions with isolated compilation and artifact validation.
- **Project management.** Automatic project-root detection, file finder, project search, and recent files per project.

## Quick start

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install && mix deps.get && mix compile && make native.support
bin/minga
```

Press `Space` to explore commands, or read [Getting Started](docs/GETTING-STARTED.md) for Homebrew installs, macOS GUI launch, and model setup.

## Documentation map

- **Start here:** [Getting Started](docs/GETTING-STARTED.md), [Configuration](docs/CONFIGURATION.md), [Projects](docs/PROJECTS.md).
- **Agent runtime:** [Agent Model Selection](docs/AGENT-MODEL-SELECTION.md), [Buffer-Aware Agents](docs/BUFFER-AWARE-AGENTS.md), [Session Recovery](docs/SESSION-RECOVERY.md), [Remote Agents](docs/REMOTE_AGENTS.md), [Agent Hooks](docs/HOOKS.md), [MCP Servers](docs/MCP.md).
- **Extending Minga:** [Extension API](docs/EXTENSION_API.md), [Keymap Scopes](docs/KEYMAP-SCOPES.md), [Agentic View Keymap](docs/AGENTIC-KEYMAP.md).
- **Architecture and internals:** [Architecture](docs/ARCHITECTURE.md), [Port Protocol](docs/PROTOCOL.md), [Semantic UI Protocol](docs/GUI_PROTOCOL.md), [Charm TUI Renderer](docs/CHARM_TUI.md).
- **Contributing and operations:** [Contributing](CONTRIBUTING.md), [Native Editor Automation (minga-ipc)](docs/AUTOMATION-IPC.md), [Preparing and Verifying Builds](docs/RELEASING.md).

## License

MIT

## Acknowledgements

Thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs). Its keybinding design, leader-key UX, and focus on making a deep editor fast and discoverable inspired Minga's command model.

---

*Created by [Justin Smestad](https://evalcode.com). Built in Colorado.*
