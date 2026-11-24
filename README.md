<p align="center">
  <a href="https://mingacode.dev">
    <img src="site/assets/og-minga.png" alt="Minga: a programmable workbench where text is the interface" width="840">
  </a>
</p>

<p align="center">
  <a href="https://mingacode.dev"><strong>Website</strong></a> ·
  <a href="https://mingacode.dev/learn/"><strong>Interactive Learn Labs</strong></a> ·
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

**macOS (Apple Silicon, signed & notarized Homebrew prereleases):**

```bash
# Desktop App (Minga.app)
brew install --cask jsmestad/minga/minga-mac && open -a Minga

# Terminal Client
brew install jsmestad/minga/minga && minga .
```

**Arch Linux & Omarchy (signed `pacman` repo, x86_64/ARM64):**

```bash
curl -fsSL https://packages.mingacode.dev/minga.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 2C5D2396B82C1278D4596A0965711C0C3853857B
curl -fsSL https://packages.mingacode.dev/arch/minga.conf | sudo tee -a /etc/pacman.conf > /dev/null
sudo pacman -Syu minga
```

Signing key: `Minga Packages <packages@mingacode.dev>`, fingerprint `2C5D 2396 B82C 1278 D459 6A09 6571 1C0C 3853 857B`.

<details>
<summary>Ubuntu 24.04+, Debian 13+, Fedora, and building from source</summary>

**Ubuntu & Debian (`apt`):**

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mingacode.dev/minga.asc | sudo tee /etc/apt/keyrings/minga.asc > /dev/null
curl -fsSL https://packages.mingacode.dev/apt/minga.sources | sudo tee /etc/apt/sources.list.d/minga.sources > /dev/null
sudo apt update && sudo apt install minga
```

**Fedora (`dnf`):**

```bash
sudo curl -fsSLo /etc/yum.repos.d/minga.repo https://packages.mingacode.dev/rpm/minga.repo
sudo dnf install minga
```

**From source (older Linux or Intel Mac):**

```bash
git clone https://github.com/jsmestad/minga.git && cd minga
mise install # or: asdf install
mix deps.get && mix compile && make native.support
bin/minga
```

</details>

Press `Space` in Normal mode to open mnemonic menus (`SPC f f` find file, `SPC b b` switch buffer, `SPC s p` project search, `SPC a a` agent). Full platform setup and model configuration: [Quickstart](https://mingacode.dev/getting-started).

## Explore the interactive site

Test Minga's keybindings, fault isolation, and Elixir configuration in your browser on [mingacode.dev](https://mingacode.dev):

| Lab | What you can try live |
| --- | --- |
| **[Learn Labs](https://mingacode.dev/learn/)** | Playable key sandbox, Twist co-authoring simulator, and remote fault lab. |
| **[BEAM Fault Lab](https://mingacode.dev/architecture)** | Trigger real-time faults (`Block Plugin`, `Crash Parser`, `Crash :after_save`) beside a shared-loop editor and step through 3-way staged merges. |
| **[Elixir Translator](https://mingacode.dev/learn/elixir)** | Convert Neovim Lua, Emacs Elisp, or VS Code JSON into `config.exs` with live theme previews. |

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

- **Start here:** [Getting Started](docs/GETTING-STARTED.md) · [Configuration](docs/CONFIGURATION.md) · [Projects](docs/PROJECTS.md)
- **Agent runtime:** [Model Selection](docs/AGENT-MODEL-SELECTION.md) · [Buffer-Aware Agents](docs/BUFFER-AWARE-AGENTS.md) · [Session Recovery](docs/SESSION-RECOVERY.md) · [Remote Agents](docs/REMOTE_AGENTS.md) · [Hooks](docs/HOOKS.md) · [MCP Servers](docs/MCP.md)
- **Extending Minga:** [Extension API](docs/EXTENSION_API.md) · [Keymap Scopes](docs/KEYMAP-SCOPES.md) · [Agentic View Keymap](docs/AGENTIC-KEYMAP.md)
- **Architecture & protocols:** [Architecture](docs/ARCHITECTURE.md) · [Port Protocol](docs/PROTOCOL.md) · [GUI Protocol](docs/GUI_PROTOCOL.md) · [Go TUI Renderer](docs/CHARM_TUI.md) · [Architecture Decisions (ADRs)](https://github.com/jsmestad/minga/tree/main/docs/adr)
- **Contributing:** [Contributing](CONTRIBUTING.md) · [Automation IPC](docs/AUTOMATION-IPC.md) · [Releasing](docs/RELEASING.md)

## License & acknowledgements

MIT licensed. Thank you to [Henrik Lissner](https://github.com/hlissner) and all contributors to [Doom Emacs](https://github.com/doomemacs/doomemacs), whose mnemonic leader-key UX inspired Minga's command grammar.

---

*Created by [Justin Smestad](https://evalcode.com). Built in Colorado.*
