# Getting Started

Five minutes from install to editing. Let's go.

## Install

> **Pre-release notice:** Minga hasn't cut a release yet. For now, you need to build from source. Homebrew and pre-built binaries are coming soon.

### From source

You'll need Erlang, Elixir, and Zig. A version manager like [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/) makes this painless:

```bash
# Install plugins if you don't have them
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add zig

# Clone and build
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install          # Installs pinned versions from .tool-versions
mix deps.get
mix compile           # Builds both Elixir and Zig
```

The first build takes a few minutes (Zig compiles tree-sitter grammars for 24 languages). After that, rebuilds are fast.

### After release (coming soon)

Once releases ship, installation will be simpler:

```bash
# macOS (Homebrew)
brew install jsmestad/minga/minga

# Or download a binary from GitHub Releases
# https://github.com/jsmestad/minga/releases
```

## Launch

```bash
bin/minga                  # Empty buffer
bin/minga path/to/file     # Open a file
bin/minga lib/ test/       # Open multiple files or directories
```

## Your first 30 seconds

Minga is a modal editor. If you've used Vim or Neovim, you're home. If you haven't, here's the short version: you're always in one of two modes.

**Normal mode** is for navigating and running commands. You move with `h/j/k/l`, delete with `dd`, search with `/`. You can't type text here.

**Insert mode** is for typing. Press `i` to enter it, `Esc` to leave.

That's the whole mental model. Normal mode is your command center. Insert mode is your typewriter. Everything else builds on top of these two.

## The Space leader (your command menu)

Here's the trick that makes Minga discoverable: press `Space` in Normal mode.

A popup appears showing every command, organized by mnemonic prefix. You don't memorize anything. You read the menu, press the next key, and the popup narrows down. `Space` then `f` shows file commands. `Space` then `b` shows buffer commands.

A few to try right now:

| Keys | What happens |
|------|-------------|
| `SPC f f` | Find and open a file |
| `SPC f s` | Save the current file |
| `SPC b b` | Switch between open buffers |
| `SPC s p` | Search across your project |
| `SPC q q` | Quit |

After a few sessions, these become muscle memory. The popup is always there when you forget.

## Configure it

Minga reads `~/.config/minga/init.exs` on startup. It's plain Elixir:

```elixir
use Minga.Config

set :theme, :catppuccin_mocha
set :relative_number, true
set :tab_width, 2
```

You don't need to know Elixir to write config. It's `set :option, value` for everything. The [Configuration guide](configuration.html) has the full list of options. Start with just a theme and line numbers; you can always add more later.

## Talk to an AI agent

Minga has a built-in AI coding agent. Toggle the panel with `SPC a a`, or open a full-screen agent view with `SPC a t`.

You'll need an API key. The quickest way is to set it in the agent chat:

```
/auth anthropic sk-ant-your-key-here
```

Or add it to your config for all sessions:

```elixir
# In ~/.config/minga/init.exs
set :agent_provider, :native
set :agent_model, "anthropic:claude-sonnet-4-20250514"
```

Type a prompt, press Enter. The agent reads, edits, and creates files in your project. You review every change as an inline diff before it hits disk.

Useful slash commands:

| Command | What it does |
|---------|-------------|
| `/model <name>` | Switch models mid-conversation |
| `/thinking high` | Turn on extended thinking |
| `/clear` | Fresh session |
| `/help` | See all commands |

## Where to go from here

You're up and running. Here's what to read based on what you care about:

**"I want to customize things."** Read the [Configuration guide](configuration.html). It covers themes, keybindings, per-filetype options, and hooks.

**"How does this thing actually work?"** The [Architecture doc](architecture.html) explains the two-process design and why the BEAM matters.

**"I'm coming from Neovim/Emacs."** The [Neovim](for-neovim-users.html) and [Emacs](for-emacs-users.html) migration guides explain what's the same, what's different, and what's better.

**"I want to contribute."** The [Contributing guide](contributing.html) has the build-from-source setup, testing, and how to add new commands and motions.
