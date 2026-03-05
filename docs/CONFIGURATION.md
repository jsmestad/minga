# Configuration

Minga is configured with real Elixir code. Your config file is `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`). Press `SPC f p` to open it from inside the editor.

If the file doesn't exist, `SPC f p` creates it with a starter template.

## Quick start

```elixir
use Minga.Config

set :tab_width, 4
set :line_numbers, :relative
set :scroll_margin, 8
```

That's it. Save the file and restart Minga. Your options take effect immediately on startup.

## Options

`set/2` configures global editor options. These are the supported options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:tab_width` | positive integer | `2` | Number of spaces per indent level |
| `:line_numbers` | `:hybrid`, `:absolute`, `:relative`, `:none` | `:hybrid` | Line number display style |
| `:autopair` | boolean | `true` | Auto-insert matching brackets and quotes |
| `:scroll_margin` | non-negative integer | `5` | Lines to keep visible above/below cursor when scrolling |
| `:theme` | theme name atom | `:doom_one` | Color theme (see [Themes](#themes) below) |
| `:indent_with` | `:spaces` or `:tabs` | `:spaces` | Whether to indent with spaces or tab characters |
| `:trim_trailing_whitespace` | boolean | `false` | Strip trailing whitespace on save |
| `:insert_final_newline` | boolean | `false` | Ensure file ends with a newline on save |
| `:format_on_save` | boolean | `false` | Run the filetype's formatter before saving |
| `:formatter` | string or `nil` | `nil` | Override the default formatter command (see [Formatters](#formatters)) |
| `:font_family` | string | `"Menlo"` | Font family or name (see [Fonts](#fonts) below) |
| `:font_size` | positive integer | `13` | Font size in points (see [Fonts](#fonts) below) |

```elixir
set :tab_width, 2
set :line_numbers, :hybrid
set :autopair, true
set :scroll_margin, 5
set :theme, :catppuccin_mocha
set :font_family, "JetBrains Mono"
set :font_size, 14
```

Invalid values show a clear error. Setting `:tab_width` to `-1` tells you it must be a positive integer.

For the full option API, see [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html).

## Themes

Minga ships 7 built-in color themes. Set one in your config and restart, or browse them live with `SPC h t`.

```elixir
set :theme, :catppuccin_mocha
```

| Theme | Style |
|-------|-------|
| `:doom_one` | Dark (default), Doom Emacs |
| `:catppuccin_frappe` | Dark, Catppuccin family |
| `:catppuccin_latte` | Light, Catppuccin family |
| `:catppuccin_macchiato` | Dark, Catppuccin family |
| `:catppuccin_mocha` | Dark, Catppuccin family |
| `:one_dark` | Dark, Atom |
| `:one_light` | Light, Atom |

The theme picker (`SPC h t`) live-previews each theme as you navigate the list. Selecting one applies it for the current session. To make it permanent, add the `set :theme` line to your config file.

For theme internals, see [`Minga.Theme`](https://jsmestad.github.io/minga/Minga.Theme.html).

## Fonts

Font settings only apply to the GUI backend. **In TUI mode (the default), your terminal controls the font.** Change your font in your terminal emulator's preferences (Ghostty, Kitty, iTerm2, WezTerm, etc.) instead. The font options are accepted in TUI mode without error, they just have no effect.

```elixir
set :font_family, "JetBrains Mono"
set :font_size, 14
```

You can use any of these name formats:

- **Family name**: `"Fira Code"`, `"JetBrains Mono"`, `"Menlo"`
- **PostScript name**: `"FiraCode-Regular"`, `"JetBrainsMonoNF-Regular"`

If the font isn't found, Minga falls back to the system monospace font. The default is `"Menlo"` at size 13, which ships with every Mac.

## Per-filetype settings

Different languages have different conventions. `for_filetype/2` overrides global options for buffers of a specific language:

```elixir
for_filetype :go, tab_width: 8
for_filetype :python, tab_width: 4
for_filetype :elixir, tab_width: 2, autopair: true
```

When you open a Go file, `tab_width` is 8. When you open an Elixir file, it's 2. Buffers with no filetype (or filetypes without overrides) use the global value.

You can set any option that `set/2` accepts. The filetype atom matches what [`Minga.Filetype`](https://jsmestad.github.io/minga/Minga.Filetype.html) detects (`:elixir`, `:go`, `:python`, `:rust`, `:javascript`, etc.).

## Formatters

`SPC c f` formats the current buffer using the configured formatter for its filetype. Minga ships default formatters for common languages:

| Language | Default formatter |
|----------|-------------------|
| Elixir | `mix format --stdin-filename {file} -` |
| Go | `gofmt` |
| Rust | `rustfmt --edition 2021` |
| Python | `python3 -m black --quiet -` |
| JavaScript/TypeScript | `prettier --stdin-filepath {file}` |
| Zig | `zig fmt --stdin` |
| C/C++ | `clang-format` |

The `{file}` placeholder is replaced with the buffer's file path (useful for formatters that need it to find their config).

### Format-on-save

Enable per-filetype with `for_filetype`:

```elixir
for_filetype :elixir, format_on_save: true
for_filetype :go, format_on_save: true, indent_with: :tabs, tab_width: 8
for_filetype :rust, format_on_save: true
```

When you save (`:w` or `SPC f s`), the buffer is formatted before writing to disk. If the formatter fails, the buffer is saved unformatted and the error appears in the status bar.

### Custom formatters

Override the default formatter for any filetype:

```elixir
for_filetype :elixir, formatter: "mix format --stdin-filename {file} -"
for_filetype :ruby, formatter: "rubocop --stdin {file} --autocorrect"
for_filetype :javascript, formatter: "deno fmt --ext=js -"
```

### Save transforms

Two additional options clean up whitespace on save:

```elixir
# Strip trailing whitespace from every line
for_filetype :elixir, trim_trailing_whitespace: true

# Ensure the file ends with a newline
for_filetype :elixir, insert_final_newline: true
```

These run before format-on-save, so the formatter gets clean input.

## Keybindings

`bind/4` adds or overrides leader-key bindings:

```elixir
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC g b", :git_blame, "Git blame"
bind :normal, "SPC t t", :toggle_tree, "Toggle file tree"
```

The first argument is the mode (currently `:normal` is supported). The second is a space-separated key sequence string. Special keys:

| Token | Key |
|-------|-----|
| `SPC` | Space |
| `TAB` | Tab |
| `RET` | Return/Enter |
| `ESC` | Escape |
| `C-x` | Ctrl + x |
| `M-x` | Alt/Meta + x |

User bindings override defaults. If you bind `SPC f f` to something else, it replaces the built-in "Find file" binding.

Invalid key sequences log a warning but don't crash the editor.

For key parser internals, see [`Minga.Keymap.KeyParser`](https://jsmestad.github.io/minga/Minga.Keymap.KeyParser.html). For how the keymap trie works, see [`Minga.Keymap.Store`](https://jsmestad.github.io/minga/Minga.Keymap.Store.html) and [`Minga.Keymap.Trie`](https://jsmestad.github.io/minga/Minga.Keymap.Trie.html).

## Custom commands

`command/3` defines a named command that can be bound to keys and appears in the command palette (`SPC :`):

```elixir
command :count_todos, "Count TODOs in buffer" do
  content = Minga.API.content()
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  Minga.API.message("#{count} TODOs found")
end

# Bind it to a key
bind :normal, "SPC c t", :count_todos, "Count TODOs"
```

Commands run inside a supervised Task. If your command raises an exception, the error shows in the status bar but the editor keeps running. You can't crash the editor with a buggy command.

The [`Minga.API`](https://jsmestad.github.io/minga/Minga.API.html) module provides a user-friendly interface for common operations inside commands: `content/0`, `insert/1`, `cursor/0`, `move_to/2`, `save/0`, `message/1`, and more.

## Lifecycle hooks

`on/2` registers functions that fire on editor events:

```elixir
on :after_save, fn _buffer_pid, path ->
  if String.ends_with?(path, ".ex") do
    System.cmd("mix", ["format", path])
  end
end

on :after_open, fn _buffer_pid, path ->
  Minga.API.message("Opened: #{Path.basename(path)}")
end

on :on_mode_change, fn old_mode, new_mode ->
  IO.puts("Mode: #{old_mode} -> #{new_mode}")
end
```

### Supported events

| Event | Arguments | Fires when |
|-------|-----------|------------|
| `:after_save` | `(buffer_pid, file_path)` | After a successful file save |
| `:after_open` | `(buffer_pid, file_path)` | After opening a file |
| `:on_mode_change` | `(old_mode, new_mode)` | When the editor mode changes |

Hooks run asynchronously. A slow `:after_save` hook (like running a formatter) won't block your typing. Each hook runs in its own supervised process, so crashes are logged but don't affect the editor.

Multiple hooks on the same event fire in registration order.

For the hooks API, see [`Minga.Config.Hooks`](https://jsmestad.github.io/minga/Minga.Config.Hooks.html).

## Command advice

`advise/3` wraps an existing command with before or after logic. This is similar to Emacs's advice system, but crash-isolated.

Four phases are supported, matching Emacs's advice system:

| Phase | Signature | Behavior |
|-------|-----------|----------|
| `:before` | `fn state -> state end` | Transforms state before the command |
| `:after` | `fn state -> state end` | Transforms state after the command |
| `:around` | `fn execute, state -> state end` | Receives the original command; decides whether/how to call it |
| `:override` | `fn state -> state end` | Completely replaces the command |

`:around` is the most powerful. It receives the original command as a function, so you can conditionally skip it, call it multiple times, or wrap it with custom logic:

```elixir
# Only format if there are no diagnostics errors. If the buffer has
# errors, formatting often makes things worse.
advise :around, :format_buffer, fn execute, state ->
  errors =
    state.buffers.active
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0 do
    execute.(state)
  else
    %{state | status_msg: "Format skipped: #{errors} error(s)"}
  end
end
```

`:override` replaces a command entirely. `:before` and `:after` still run around an overridden command, so you can override the core behavior while keeping other advice intact:

```elixir
# Replace the built-in save with one that also stages the file in git
advise :override, :save, fn state ->
  # Run the original save logic
  state = Minga.API.save()

  # Then auto-stage
  case Minga.Buffer.Server.file_path(state.buffers.active) do
    nil -> state
    path ->
      System.cmd("git", ["add", path], stderr_to_stdout: true)
      %{state | status_msg: "Saved and staged: #{Path.basename(path)}"}
  end
end
```

`:before` and `:after` handle simpler cases where you just need to transform state on the way in or out:

```elixir
# Ensure cursor is at line start before any search, so results
# are consistent regardless of where you were on the line
advise :before, :search_project, fn state ->
  Minga.API.move_to_column(0)
  state
end
```

Multiple advice functions for the same phase and command run in registration order. For `:around`, they nest outward (first registered is outermost). Crashes in any advice are logged and skipped; the editor keeps running.

### When to use advice vs. hooks

**Hooks** (`on/2`) are for fire-and-forget side effects: running an external tool after save, logging, sending notifications. They run asynchronously and can't change editor state.

**Advice** (`advise/3`) is for changing how a command behaves: conditionally skipping it, transforming editor state before or after it runs, or replacing the command entirely. Advice runs synchronously as part of the command, so it can affect what happens next.

For the advice API, see [`Minga.Config.Advice`](https://jsmestad.github.io/minga/Minga.Config.Advice.html).

## Error handling

Minga is forgiving about config errors:

- **No config file**: editor starts with defaults, no error
- **Syntax error in config**: editor starts with defaults, error shown in status bar
- **Runtime error** (e.g., invalid option value): editor starts with defaults, error shown in status bar
- **Command crashes**: error shown in status bar, editor keeps running
- **Hook crashes**: error logged, other hooks still fire, editor keeps running

You can check for config load errors programmatically with [`Minga.Config.Loader.load_error/0`](https://jsmestad.github.io/minga/Minga.Config.Loader.html#load_error/0).

## User modules

For anything beyond a quick command, you can write full Elixir modules. Drop `.ex` files in `~/.config/minga/modules/` and they're compiled and loaded at startup.

```elixir
# ~/.config/minga/modules/todo_tools.ex
defmodule TodoTools do
  def count(text) do
    text |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  end

  def list(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, "TODO") end)
    |> Enum.map(fn {line, num} -> "#{num}: #{String.trim(line)}" end)
    |> Enum.join("\n")
  end
end
```

Then reference it in your config:

```elixir
# ~/.config/minga/config.exs
use Minga.Config

command :list_todos, "List TODO lines" do
  {:ok, content} = Minga.API.content()
  Minga.API.message(TodoTools.list(content))
end

bind :normal, "SPC c t", :list_todos, "List TODOs"
```

If a module has a compile error, Minga logs a warning and skips that file. Other modules and your config still load normally.

## Project-local config

Drop a `.minga.exs` file in your project root to set project-specific options. Project config runs after global config, so it overrides global settings.

```elixir
# /path/to/my-project/.minga.exs
use Minga.Config

set :tab_width, 4
for_filetype :go, tab_width: 8

on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".go"), do: System.cmd("gofmt", ["-w", path])
end
```

This is useful for team-shared settings. Check `.minga.exs` into your repo and everyone on the team gets the same tab width, formatters, and hooks.

**Note:** Project-local config is real Elixir code that runs when you open the editor in that directory. Review `.minga.exs` files in untrusted projects before opening them.

## Post-init hook (after.exs)

If you need config that depends on user modules being loaded first, put it in `~/.config/minga/after.exs`. This file runs last, after modules, global config, and project config.

```elixir
# ~/.config/minga/after.exs
use Minga.Config

# This works because TodoTools was compiled from modules/ first
set :tab_width, TodoTools.preferred_tab_width()
```

## Hot reload

Press `SPC h r` to reload your config without restarting the editor. This:

1. Stops all running extensions
2. Purges user modules
3. Resets options, keybindings, hooks, advice, and commands to defaults
4. Re-compiles modules, re-evaluates config.exs, .minga.exs, and after.exs
5. Restarts extensions

Changed keybindings and options take effect immediately. The status bar shows "Config reloaded" on success or an error message if something went wrong.

You can also reload from the command line with `:reload-config` (not yet wired as an ex command, use `SPC h r`).

## Load order

Minga loads config in this order. Each stage can override the previous one:

1. `~/.config/minga/modules/*.ex` (user modules, compiled alphabetically)
2. `~/.config/minga/config.exs` (global config)
3. `.minga.exs` in the current working directory (project-local config)
4. `~/.config/minga/after.exs` (post-init hook)
5. Extensions are started (from declarations in steps 2-4)

## Extensions

Extensions are reusable, self-contained editor plugins. Each extension runs under its own supervisor, so a crash in one extension never affects others or the editor.

### Writing an extension

An extension is a directory containing `.ex` files, with one module that implements the `Minga.Extension` behaviour:

```elixir
# ~/code/minga_todo/extension.ex
defmodule MingaTodo do
  use Minga.Extension

  @impl true
  def name, do: :minga_todo

  @impl true
  def description, do: "TODO tracking and highlighting"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(config) do
    keyword = Keyword.get(config, :keyword, "TODO")
    {:ok, %{keyword: keyword}}
  end
end
```

The `use Minga.Extension` macro gives you a default `child_spec/1` that starts a simple Agent holding your config. Override `child_spec/1` if your extension needs a GenServer or a full supervision tree:

```elixir
defmodule MingaTodo do
  use Minga.Extension

  # ... name, description, version, init callbacks ...

  @impl true
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {MingaTodo.Server, :start_link, [config]},
      restart: :permanent,
      type: :worker
    }
  end
end
```

Extensions can register commands, keybindings, and hooks using the standard config API:

```elixir
# Inside your extension's init/1 or a supporting module
def init(config) do
  Minga.Config.bind(:normal, "SPC c t", :todo_list, "List TODOs")

  Minga.Config.register_command(:todo_list, "List TODO lines", fn ->
    {:ok, content} = Minga.API.content()
    todos = find_todos(content)
    Minga.API.message(todos)
  end)

  {:ok, config}
end
```

### Loading an extension

Declare extensions in your config file with a local path:

```elixir
# ~/.config/minga/config.exs
use Minga.Config

extension :minga_todo, path: "~/code/minga_todo"
extension :my_formatter, path: "~/code/my_formatter", format_cmd: "prettier --stdin"
```

Extra keyword options (everything except `:path`) are passed to the extension's `init/1` callback.

### Listing extensions

Run `:extensions` (or `:ext`) in command mode to see all loaded extensions with their name, version, and status:

```
Extensions:
  minga_todo v0.1.0 [running]
  my_formatter v0.2.0 [running]
```

### Crash isolation

Each extension runs under its own supervisor. If an extension process crashes, it restarts automatically without affecting the editor or other extensions. If an extension fails to load (bad path, compile error, init failure), you get a clear error message and everything else keeps working.

### Extension lifecycle

- Extensions are compiled and started after all config files are evaluated
- `SPC h r` stops all extensions, reloads config, then restarts them
- Extension state is lost on reload (the process restarts fresh)

## Full example

```elixir
use Minga.Config

# ── Options ──────────────────────────────────────────────────────────
set :tab_width, 2
set :line_numbers, :relative
set :scroll_margin, 5
set :autopair, true
set :theme, :catppuccin_mocha

# Font (GUI backend only; no effect in TUI mode)
set :font_family, "JetBrains Mono"
set :font_size, 14

# ── Per-language ─────────────────────────────────────────────────────
for_filetype :elixir, format_on_save: true, trim_trailing_whitespace: true, insert_final_newline: true
for_filetype :go, tab_width: 8, indent_with: :tabs, format_on_save: true
for_filetype :python, tab_width: 4, format_on_save: true
for_filetype :ruby, tab_width: 2

# ── Keybindings ──────────────────────────────────────────────────────
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC c t", :count_todos, "Count TODOs"

# ── Commands ─────────────────────────────────────────────────────────
command :git_status, "Show git status" do
  {output, _} = System.cmd("git", ["status", "--short"])
  Minga.API.message(output)
end

command :count_todos, "Count TODOs in buffer" do
  content = Minga.API.content()
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  Minga.API.message("#{count} TODOs found")
end

# ── Hooks ────────────────────────────────────────────────────────────
on :after_save, fn _buf, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end

# ── Command advice ───────────────────────────────────────────────────
# Skip formatting if the buffer has errors
advise :around, :format_buffer, fn execute, state ->
  errors =
    state.buffers.active
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0, do: execute.(state), else: state
end

# ── Extensions ───────────────────────────────────────────────────────
extension :minga_todo, path: "~/code/minga_todo"
extension :my_formatter, path: "~/code/my_formatter", format_cmd: "prettier --stdin"
```

## Further reading

- [`Minga.Config`](https://jsmestad.github.io/minga/Minga.Config.html) — the DSL module (`set`, `bind`, `command`, `on`, `advise`, `for_filetype`)
- [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html) — typed option registry with per-filetype overrides
- [`Minga.Config.Loader`](https://jsmestad.github.io/minga/Minga.Config.Loader.html) — config file discovery and evaluation
- [`Minga.Config.Hooks`](https://jsmestad.github.io/minga/Minga.Config.Hooks.html) — lifecycle hook registry
- [`Minga.Config.Advice`](https://jsmestad.github.io/minga/Minga.Config.Advice.html) — before/after command advice
- [`Minga.Keymap.Store`](https://jsmestad.github.io/minga/Minga.Keymap.Store.html) — mutable keymap (defaults + user overrides)
- [`Minga.Keymap.KeyParser`](https://jsmestad.github.io/minga/Minga.Keymap.KeyParser.html) — key sequence string parser
- [`Minga.API`](https://jsmestad.github.io/minga/Minga.API.html) — user-friendly editor API for commands and eval
- [`Minga.Formatter`](https://jsmestad.github.io/minga/Minga.Formatter.html) — formatter execution and default formatter registry
- [`Minga.Extension`](https://jsmestad.github.io/minga/Minga.Extension.html) — extension behaviour and lifecycle
- [`Minga.Extension.Supervisor`](https://jsmestad.github.io/minga/Minga.Extension.Supervisor.html) — extension process management
- [Elixir is Minga's Elisp](https://jsmestad.github.io/minga/extensibility.html) — deep dive on how the BEAM enables Emacs-level extensibility
