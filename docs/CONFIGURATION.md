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

```elixir
set :tab_width, 2
set :line_numbers, :hybrid
set :autopair, true
set :scroll_margin, 5
```

Invalid values show a clear error. Setting `:tab_width` to `-1` tells you it must be a positive integer.

For the full option API, see [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html).

## Per-filetype settings

Different languages have different conventions. `for_filetype/2` overrides global options for buffers of a specific language:

```elixir
for_filetype :go, tab_width: 8
for_filetype :python, tab_width: 4
for_filetype :elixir, tab_width: 2, autopair: true
```

When you open a Go file, `tab_width` is 8. When you open an Elixir file, it's 2. Buffers with no filetype (or filetypes without overrides) use the global value.

You can set any option that `set/2` accepts. The filetype atom matches what [`Minga.Filetype`](https://jsmestad.github.io/minga/Minga.Filetype.html) detects (`:elixir`, `:go`, `:python`, `:rust`, `:javascript`, etc.).

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

## Error handling

Minga is forgiving about config errors:

- **No config file**: editor starts with defaults, no error
- **Syntax error in config**: editor starts with defaults, error shown in status bar
- **Runtime error** (e.g., invalid option value): editor starts with defaults, error shown in status bar
- **Command crashes**: error shown in status bar, editor keeps running
- **Hook crashes**: error logged, other hooks still fire, editor keeps running

You can check for config load errors programmatically with [`Minga.Config.Loader.load_error/0`](https://jsmestad.github.io/minga/Minga.Config.Loader.html#load_error/0).

## Full example

```elixir
use Minga.Config

# ── Options ──────────────────────────────────────────────────────────
set :tab_width, 2
set :line_numbers, :relative
set :scroll_margin, 5
set :autopair, true

# ── Per-language ─────────────────────────────────────────────────────
for_filetype :go, tab_width: 8
for_filetype :python, tab_width: 4
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
```

## Further reading

- [`Minga.Config`](https://jsmestad.github.io/minga/Minga.Config.html) — the DSL module (`set`, `bind`, `command`, `on`, `for_filetype`)
- [`Minga.Config.Options`](https://jsmestad.github.io/minga/Minga.Config.Options.html) — typed option registry with per-filetype overrides
- [`Minga.Config.Loader`](https://jsmestad.github.io/minga/Minga.Config.Loader.html) — config file discovery and evaluation
- [`Minga.Config.Hooks`](https://jsmestad.github.io/minga/Minga.Config.Hooks.html) — lifecycle hook registry
- [`Minga.Keymap.Store`](https://jsmestad.github.io/minga/Minga.Keymap.Store.html) — mutable keymap (defaults + user overrides)
- [`Minga.Keymap.KeyParser`](https://jsmestad.github.io/minga/Minga.Keymap.KeyParser.html) — key sequence string parser
- [`Minga.API`](https://jsmestad.github.io/minga/Minga.API.html) — user-friendly editor API for commands and eval
- [Elixir is Minga's Elisp](https://jsmestad.github.io/minga/extensibility.html) — deep dive on how the BEAM enables Emacs-level extensibility
