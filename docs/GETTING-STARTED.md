# Getting Started

This guide walks you from zero to editing files in Minga. It takes about five minutes.

## Install the toolchain

Minga needs three tools: Erlang/OTP, Elixir, and Zig. The easiest way to get the exact versions is with [asdf](https://asdf-vm.com/) (or any compatible version manager like [mise](https://mise.jdx.dev/)):

```bash
# Install asdf plugins (skip any you already have)
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add zig

# Clone and install pinned versions
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install
```

The `.tool-versions` file pins Erlang 28+, Elixir 1.19+, and Zig 0.15+. Running `asdf install` from the repo root gets you the right versions automatically.

## Build

```bash
mix deps.get
mix compile
```

The first build takes a few minutes. `mix compile` builds both the Elixir editor core and the Zig renderer binary. Subsequent builds are incremental and fast.

## Launch

```bash
bin/minga                  # Empty buffer
bin/minga path/to/file     # Open a file
bin/minga lib/ test/       # Open multiple files or directories
```

## Learn the keybindings

Minga uses **Vim-style modal editing**. You start in Normal mode.

| Keys | What it does |
|------|-------------|
| `i` | Enter Insert mode (start typing) |
| `Esc` | Back to Normal mode |
| `Space` | Open the Which-Key popup (shows all leader commands) |
| `:w` | Save |
| `:q` | Quit |
| `:wq` | Save and quit |

### The Space leader

Press `Space` in Normal mode to open the **Which-Key popup**. It shows every command organized by mnemonic prefix:

| Prefix | Category | Examples |
|--------|----------|----------|
| `f` | File | `SPC f s` save, `SPC f f` find file |
| `b` | Buffer | `SPC b b` switch buffer, `SPC b d` close buffer |
| `w` | Window | `SPC w v` vertical split, `SPC w h/j/k/l` move focus |
| `s` | Search | `SPC s p` search project, `SPC s s` search buffer |
| `g` | Git | `SPC g s` git status, `SPC g b` blame |
| `a` | Agent | `SPC a a` toggle agent panel, `SPC a t` agent view |
| `q` | Quit | `SPC q q` quit |

You don't need to memorize these. The Which-Key popup shows them as you type. Press `SPC`, read the menu, press the next key. After a few sessions, the muscle memory builds itself.

### Vim motions and operators

If you know Vim, everything works as expected: `dd` deletes a line, `ciw` changes a word, `yap` yanks a paragraph, `/` searches forward. If you don't know Vim, Minga isn't the place to learn it from scratch. Grab [Vim Adventures](https://vim-adventures.com/) or run `vimtutor` first, then come back.

## Configure

Minga reads config from `~/.config/minga/init.exs` on startup. It's just Elixir:

```elixir
use Minga.Config

# Set your preferred theme
set :theme, :catppuccin_mocha

# Relative line numbers
set :relative_number, true

# Tab width
set :tab_width, 2

# Use native AI agent provider
set :agent_provider, :native
set :agent_model, "anthropic:claude-sonnet-4-20250514"
```

See the [Configuration guide](configuration.html) for the full list of options.

## Use the AI agent

Toggle the agent panel with `SPC a a`, or open the full agent view with `SPC a t`.

```
SPC a a    Toggle agent split panel
SPC a t    Full-screen agent view
SPC a n    New agent session
```

Type your prompt and press Enter. The agent can read, edit, and create files in your project. You review its changes as inline diffs.

Slash commands control the session:

| Command | What it does |
|---------|-------------|
| `/model <name>` | Switch to a different model |
| `/thinking high` | Set extended thinking level |
| `/clear` | Start a fresh session |
| `/compact` | Compress conversation history |
| `/help` | Show all commands |

## Run tests

```bash
mix test                       # Elixir tests
cd zig && zig build test       # Zig renderer tests
```

## Next steps

- **[Configuration](configuration.html)** for the full options reference
- **[Keymap Scopes](keymap-scopes.html)** to understand how keybindings change per view
- **[Architecture](architecture.html)** if you're curious how the pieces fit together
- **[For Neovim Users](for-neovim-users.html)** or **[For Emacs Users](for-emacs-users.html)** if you're migrating
- **[Contributing](contributing.html)** if you want to get involved
