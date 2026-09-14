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
# macOS GUI (installs Minga.app plus the GUI-aware `minga` launcher)
brew install --cask jsmestad/minga/minga-mac
minga .

# Linux standalone TUI
brew install jsmestad/minga/minga

# Or download an artifact from GitHub Releases
# https://github.com/jsmestad/minga/releases
```

On macOS, `minga FILE_OR_DIRECTORY` opens or reuses Minga.app. Use `minga --tui FILE_OR_DIRECTORY` (or the installed `minga-tui` command) for an explicit standalone terminal session. Terminal-only commands such as `--headless`, `attach`, `sessions`, `detach`, `kill-session`, and `login --manual` select the standalone runtime automatically. If Minga.app is missing or damaged, normal GUI opens fail with an installation error rather than silently falling back to a new TUI editor.

## Wait for a native editor result

Use the bundled `minga-ipc open-ready` command when an automation needs to know that one file open reached the editor's native interaction boundary. The ordinary `minga` command, and the existing `minga-ipc open` and `minga-ipc wait` commands, keep their semantic-only completion behavior.

```bash
MINGA_IPC="/Applications/Minga.app/Contents/Resources/bin/minga-ipc"
"$MINGA_IPC" open-ready --deadline-ms=10000 /absolute/path/to/notes.md
```

The command writes one JSON result to standard output and exits zero only when `receipt.outcome` is `ready`. Save the identity fields if a separate process must inspect the completed receipt later.

```json
{"receipt":{"app_instance_id":"...","core_instance_id":"...","operation_id":"...","phase":"terminal","outcome":"ready","target":{"path":"/absolute/path/to/notes.md","window_id":1},"application_revision":42,"evidence":{"boundary":"metal_drawable_completed","focus_ready":true},"detail":null}}
```

```bash
"$MINGA_IPC" wait-receipt --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --operation-id "$OPERATION_ID" --deadline-ms 10000
"$MINGA_IPC" receipt --app-instance-id "$APP_INSTANCE_ID" --core-instance-id "$CORE_INSTANCE_ID" --operation-id "$OPERATION_ID"
```

`wait-receipt` only observes the original operation. It never opens the file again. A waiter has a finite deadline from 1 through 30,000 milliseconds. Disconnecting, cancelling, or timing out a waiter releases only that wait. It does not undo or repeat an editor action that the BEAM already applied.

The receipt separates three facts: `admitted` means the local service accepted the request, `applied` means the BEAM opened the exact target and recorded its semantic revision, and terminal `ready` means the matching editor target reached its native boundary with the required focus. The result includes the target token, pane, revision, renderer generation, frame sequence, and focus evidence so a newer unrelated frame cannot satisfy the request.

`metal_drawable_completed` is the strongest boundary the current editor surface can prove. CoreText and Metal completed the matching drawable submission, and the editor focus policy passed when focus was requested. It is not a claim that macOS composited pixels to a physical display. SwiftUI and AppKit surfaces that cannot prove their own requested readiness return `unavailable` instead of borrowing editor evidence.

Terminal outcomes are explicit. `rejected` means the BEAM could not apply the request. `presentation_failed`, `hidden`, and `unavailable` distinguish failed rendering, a hidden surface, and a missing native prerequisite. `superseded` means a newer target replaced the requested target before it became ready. `timeout` and `cancelled` describe the wait rather than the editor action. `app_replaced`, `core_replaced`, `expired`, and `unknown` mean the supplied receipt identity cannot be observed in the current generation. Failed receipts include a machine-readable outcome and may include a human-readable `detail`. After admission, even timeout or transport failure output preserves the accepted receipt identity. A lost response can leave execution indeterminate, so look up the saved receipt before deciding whether to retry.

Receipts are intentionally bounded. Minga accepts at most 64 active operations and 64 waiters, retains at most 128 terminal receipts for 60 seconds, and converts an operation that receives no native result within 30 seconds to `indeterminate`. Expired receipts retain no view or frame resources. The receipt includes `last_visible` when a newer attempted presentation fails, so callers can distinguish the failed target from the prior valid target, application revision, and frame.

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

**"I use AI coding tools."** Read [For AI-Assisted Developers](for-ai-coders.html). It covers why Minga's architecture matters for agentic workflows and how it compares to what you're using today.

**"I want to contribute."** The [Contributing guide](contributing.html) has the build-from-source setup, testing, and how to add new commands and motions.
