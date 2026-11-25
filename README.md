<p align="center">
  <a href="https://mingacode.dev">
    <img src="site/assets/og-minga.png" alt="Minga: a programmable workbench where text is the interface" width="840">
  </a>
</p>

<p align="center">
  <a href="https://mingacode.dev"><strong>Website</strong></a> ·
  <a href="https://mingacode.dev/learn/"><strong>Learn</strong></a> ·
  <a href="https://mingacode.dev/why-minga"><strong>Why Minga</strong></a> ·
  <a href="https://mingacode.dev/architecture"><strong>Architecture</strong></a> ·
  <a href="https://mingacode.dev/extending"><strong>Extending</strong></a> ·
  <a href="https://mingacode.dev/docs/"><strong>API Docs</strong></a>
</p>

# Minga

**A programmable workbench where text is the interface.**

Minga is a native macOS and terminal code editor built on Elixir and the Erlang VM (BEAM) for editing code alongside parallel AI agents. Your open files, language servers, extensions, MCP servers, and agent sessions each run in isolated BEAM processes behind thin native frontends: a Swift and Metal desktop app on macOS and a Go/Bubble Tea client in the terminal.

> **Status:** Pre-release, building toward v0.1.0 ([roadmap & release gates](https://github.com/jsmestad/minga/issues/3542) · [ADR-0006](docs/adr/0006-the-spine.md) · [ADR-0004](docs/adr/0004-products-are-root-applets-over-a-fixed-engine.md)). Zero files are ever written to your Git repo; try it alongside your current editor with zero lock-in.

## Try it in 60 seconds

**macOS (Apple Silicon, signed and notarized Homebrew prereleases):**

```bash
brew install --cask jsmestad/minga/minga-mac && open -a Minga
```

**Linux (Arch and Omarchy, Ubuntu 24.04+, Debian 13+, Fedora; x86_64 and ARM64):** add Minga's signed package repository first, using the commands in [Get Started](https://mingacode.dev/getting-started#install). Then install with your package manager:

```bash
sudo apt install minga   # or: sudo dnf install minga, sudo pacman -Syu minga
```

[Get Started](https://mingacode.dev/getting-started#install) is the one place install steps live. It has the repository setup and signing key for each distribution, the terminal client for macOS, and the source build for older Linux and Intel Macs.

Press `Space` in Normal mode to open mnemonic menus (`SPC f f` find file, `SPC b b` switch buffer, `SPC s p` project search, `SPC a v` agent view, `SPC a a` tasks). The [key reference](docs/AGENTIC-KEYMAP.md) lists what the keys do, by where you are. Get Started continues from there: connect a model and review your first staged edit.

## Explore the site

Try Minga's ideas in your browser on [mingacode.dev](https://mingacode.dev):

| Page | What you can try |
| --- | --- |
| **[Learn](https://mingacode.dev/learn/)** | Four short lessons, one job each: find a command when you forget its key, see which lines are yours and which are Minga's, bring one setting from your old editor, and test a hook before you leave an agent working alone. Lessons 01 and 02 teach the v0.1.0 design, which is not in today's build yet. |
| **[Architecture](https://mingacode.dev/architecture)** | See why a slow language server does not freeze your typing, and step through how an approved edit waits for you. |
| **[Lesson 03](https://mingacode.dev/learn/elixir)** | Pick Neovim, Emacs or VS Code and read the same setting as one line of Minga config. |

## Why the Erlang VM matters for code + agents

When parallel agents stream output, run tools, and query LSP and MCP servers beside your editor, shared plugin heaps and single-threaded scripting loops are where stalls and cascading crashes show up. Minga runs each subsystem in its own Erlang VM process to isolate latency and failures, trading away single-binary startup speed.

- **Preemptive scheduling and per-process GC.** Buffers, LSPs, hooks, extensions, MCP servers, and agents run in separate BEAM processes with separate heaps, so background work never freezes typing.
- **Staged agent edits.** Agent file tools require a full-read revision token and stage changes off disk with crash-safe drafts (`~/.local/share/minga/staged_drafts`), syntax-highlighted review, and three-way merge (`SPC a p`); LSP inspects published open buffers and shell runs execute in a temp copy skipping `.git` and `node_modules`.
- **Native macOS and terminal parity.** Swift + Metal draws macOS, Go + Bubble Tea draws the terminal (packaged for macOS, Arch/Omarchy, Ubuntu, Debian, and Fedora), and Zig runs 50 tree-sitter grammars in a separate OS port.
- **Headless agent durability over SSH.** Run `minga --headless` on a Linux devbox and attach via `minga attach ssh://devbox/work/app` over Erlang distribution with a shared cookie; agent sessions and staged drafts survive laptop sleep without copying source locally.
- **Deterministic safety guardrails.** Gate tools with `PreToolUse` shell hooks, run crash-isolated stdio MCP servers (`mcp_<server>__*`), and plug in internal LLM routes (`MingaAgent.InferenceRoute`).

## Configure and extend in plain Elixir

`~/.config/minga/config.exs` uses the same Elixir runtime as the core, validates option types, and reloads live with `SPC h r`:

```elixir
use Minga.Config

set :theme, :catppuccin_frappe
set :line_numbers, :hybrid
set :tab_width, 2

for_filetype :go, tab_width: 4, indent_with: :tabs

on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end
```

Wrap built-in commands with `advise`, graduate to supervised Hex/Git/local packages via `minga_sdk`, compile custom tree-sitter grammars on demand, or switch to desktop shortcuts with `set :editing_model, :cua`.

## Documentation map

Read in this order:

1. **[Get Started](https://mingacode.dev/getting-started):** install Minga, connect a model, and review your first staged edit.
2. **[Learn](https://mingacode.dev/learn/):** hands-on lessons that pick up where Get Started ends.
3. **Reference, by task:** look up what you need when you need it. The [reference index](docs/REFERENCE.md) lists every published doc.
   - **Use Minga:** [Configuration](docs/CONFIGURATION.md) · [Projects](docs/PROJECTS.md) · [Model Selection](docs/AGENT-MODEL-SELECTION.md) · [Key reference](docs/AGENTIC-KEYMAP.md)
   - **Run agents unattended:** [Hooks](docs/HOOKS.md) · [MCP Servers](docs/MCP.md) · [Remote Agents](docs/REMOTE_AGENTS.md)
   - **Extend Minga:** [Extension API](docs/EXTENSION_API.md)
   - **How it works:** [Architecture](docs/ARCHITECTURE.md) · [Buffer-Aware Agents](docs/BUFFER-AWARE-AGENTS.md) · [Session Recovery](docs/SESSION-RECOVERY.md) · [Keymap Scopes](docs/KEYMAP-SCOPES.md) · [Port Protocol](docs/PROTOCOL.md) · [GUI Protocol](docs/GUI_PROTOCOL.md) · [Go TUI Renderer](docs/CHARM_TUI.md)
   - **Design and decisions:** [Design System](docs/design/README.md) · [Architecture Decisions (ADRs)](https://github.com/jsmestad/minga/tree/main/docs/adr)

Working on Minga itself? [Contributing](CONTRIBUTING.md) is the index for contributor docs: testing, performance gates, releasing, and the step-by-step recipes.

## License & acknowledgements

MIT licensed. Thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs), whose mnemonic leader-key UX inspired Minga's command grammar.

---

*Created by [Justin Smestad](https://evalcode.com). Built in Colorado.*
