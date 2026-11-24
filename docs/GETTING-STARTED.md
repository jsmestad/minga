# Getting Started

Five minutes from install to editing and running your first agent session.

## Install

### macOS (Homebrew)

Install the native macOS app, the terminal client, or both from Homebrew:

```bash
brew install --cask jsmestad/minga/minga-mac  # Installs Minga.app
brew install jsmestad/minga/minga            # Installs the minga terminal command
```

Open the GUI from Applications or run `open -a Minga`. Run `minga` for the terminal client. Update rolling prereleases with `brew upgrade minga` or `brew upgrade --cask minga-mac`.

Minga appears under **Open With** in Finder for any file, including dotfiles and scripts without an extension. To make it the default editor for a kind of file, select one in Finder, choose **File → Get Info**, pick Minga under **Open with**, and click **Change All…**.

### Linux (packages)

The terminal client ships for x86_64 and ARM64 Linux with glibc 2.39 or newer: Ubuntu 24.04 and later, Debian 13 and later, current Fedora, and Arch, including Omarchy. Each package carries its own Erlang runtime under `/usr/lib/minga` and puts `minga` on your `PATH`.

Add Minga's package repository once, and your normal system updates keep Minga current. Every push to `main` publishes a new rolling build. The repository and every package in it are signed with this key:

```
Minga Packages <packages@mingacode.dev>
2C5D 2396 B82C 1278 D459  6A09 6571 1C0C 3853 857B
```

On Arch and Omarchy, trust the key, add the `[minga]` repository to `pacman.conf`, and install:

```bash
curl -fsSL https://packages.mingacode.dev/minga.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 2C5D2396B82C1278D4596A0965711C0C3853857B
curl -fsSL https://packages.mingacode.dev/arch/minga.conf | sudo tee -a /etc/pacman.conf > /dev/null
sudo pacman -Syu minga
```

On Ubuntu and Debian:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mingacode.dev/minga.asc | sudo tee /etc/apt/keyrings/minga.asc > /dev/null
curl -fsSL https://packages.mingacode.dev/apt/minga.sources | sudo tee /etc/apt/sources.list.d/minga.sources > /dev/null
sudo apt update && sudo apt install minga
```

On Fedora, `dnf` asks you to confirm the key on first install. Check that it shows the fingerprint above:

```bash
sudo curl -fsSLo /etc/yum.repos.d/minga.repo https://packages.mingacode.dev/rpm/minga.repo
sudo dnf install minga
```

To try a build without adding the repository, download the `.deb` or `.rpm` for your architecture from the newest [release](https://github.com/jsmestad/minga/releases) and install it with `sudo apt install ./minga_<version>_amd64.deb` or `sudo dnf install ./minga-<version>.x86_64.rpm`. A package installed this way does not update itself.

### From source

You need Erlang, Elixir, Go, and Zig. A version manager such as [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/) installs the exact versions pinned in `.tool-versions`:

```bash
# Install plugins if you do not have them
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add golang
asdf plugin add zig

# Clone and build
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install          # Installs pinned versions from .tool-versions
mix deps.get
mix compile           # Builds Elixir and the Go terminal renderer
make native.support   # Builds the Zig tree-sitter parser and helper binaries
```

The first build takes a few minutes while Zig compiles 50 tree-sitter grammars. Rebuilds after that are incremental.

Use the source build on Linux distributions older than the packages support, on Intel Macs, or when developing Minga itself.

## Launch

```bash
bin/minga                  # Empty buffer in the terminal
bin/minga path/to/file     # Open a file
bin/minga lib/ test/       # Open multiple files or directories
bin/minga-mac              # Launch the macOS GUI from a source checkout
```

## Your first 30 seconds

Minga supports both Vim modal editing and standard CUA editing. In Vim mode, you are always in one of two core modes:

**Normal mode** is for navigating and running commands. Move with `h/j/k/l`, delete lines with `dd`, search with `/`.

**Insert mode** is for typing text. Press `i` to enter it, `Esc` to leave.

## The Space leader (your command menu)

Press `Space` in Normal mode to open a popup listing every command grouped by mnemonic prefix. You do not need to memorize shortcuts upfront: read the menu, press the next key, and the popup narrows down. `Space` then `f` shows file commands. `Space` then `b` shows buffer commands.

| Keys | What happens |
|------|-------------|
| `SPC f f` | Find and open a file |
| `SPC f s` | Save the current file |
| `SPC b b` | Switch between open buffers |
| `SPC s p` | Search across your project |
| `SPC q q` | Quit |

## Configure Minga

Minga reads `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`) on startup. Configuration is ordinary Elixir:

```elixir
use Minga.Config

set :theme, :catppuccin_mocha
set :line_numbers, :relative
set :tab_width, 2
```

You do not need to know Elixir to write basic config: `set :option, value` covers options, and [Configuration](CONFIGURATION.md) documents themes, keybindings, hooks, advice, and extensions.

## Work with the agent

Open the agent view with `SPC a a`, or the conversation split with `SPC a v`. Every Minga key lives under `SPC a`; the less frequent ones sit in three groups, `SPC a q` Queue, `SPC a x` Context and `SPC a S` Session.

If your model provider uses an API key, open **Models and connections** with `/model` and choose the API key action for that provider (or run `/auth anthropic` for the same masked prompt). Enter the key in that prompt, not in the chat composer. Submitting saves the credential locally without sending your draft.

Open `/model` again and pick a model for the connected provider. Each hosted entry displays its protocol, credential profile, and capabilities. A saved session remembers the selected route, not the key. See [Agent model selection](AGENT-MODEL-SELECTION.md) for supported providers and route selection behavior.

Type a prompt and press Enter. Agent file edits route through in-memory buffer forks and stay staged for review until you publish or discard them; `SPC a p` offers both in one prompt. See [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md) for the staging and merge contract.

Useful slash commands:

| Command | What it does |
|---------|-------------|
| `/model <name>` | Switch models mid-conversation |
| `/thinking high` | Turn on extended thinking |
| `/clear` | Start a fresh session |
| `/help` | List available slash commands |

## Where to go from here

- **Customize and extend:** Read [Configuration](CONFIGURATION.md) for options, themes, keybindings, hooks, and extensions, and [Extension API](EXTENSION_API.md) for authoring extensions and model routes.
- **Understand the runtime:** Read [Architecture](ARCHITECTURE.md) for supervision trees, buffer processes, and the multi-frontend Semantic UI pipeline, and [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md) for staged agent edits and three-way merge.
- **Automate the native macOS app:** Read [Native editor automation (minga-ipc)](AUTOMATION-IPC.md) for `open-ready`, `inspect`, and typed navigation receipts.
- **Contribute:** Read [Contributing](../CONTRIBUTING.md) for the development setup, tests, and local lint gates.
