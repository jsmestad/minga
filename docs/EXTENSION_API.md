# Extension API Reference

This document covers the public APIs available to Minga extensions. For a tutorial on creating your first extension, see [#212](https://github.com/jsmestad/minga/issues/212).

## Security Model

Extensions run in the same BEAM VM as the editor and have full system access. The BEAM has no process-level capability system; any code in the VM can call any module, access any ETS table, and exec system commands. This is the same trust model as Emacs Lisp packages and Vim plugins.

The security boundary is at install time: the user explicitly declares `extension :name, git: "..."` in their config. A confirmation prompt appears for first-time installs from git/hex sources. Only install extensions you trust. Pin git extensions to a specific ref for reproducibility.

## Extension Behaviour

Every extension implements the `Minga.Extension` behaviour. The simplest extension:

```elixir
defmodule MyExtension do
  use Minga.Extension

  @impl true
  def name, do: :my_extension

  @impl true
  def description, do: "Does something useful"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(config) do
    # config is the keyword list from the extension declaration
    # Register commands, keybindings, advice, etc. here
    {:ok, %{}}
  end
end
```

`use Minga.Extension` provides a default `child_spec/1` that starts an Agent. Override it if your extension needs a custom GenServer or supervision tree.

**Lifecycle:** Config evaluation registers extensions -> `init/1` is called -> `child_spec/1` starts under `Extension.Supervisor` -> On config reload, all extensions stop and re-load.

## Command Registration

Register named commands that users can invoke via keybindings or the command palette.

**Module:** `Minga.Command.Registry`

```elixir
# In your init/1:
Minga.Command.Registry.register(
  Minga.Command.Registry,
  :my_command,           # atom name (must be unique)
  "Do something cool",  # description (shown in command palette)
  &my_function/1         # fn(state) -> state
)
```

Command functions receive the editor state map and must return it (possibly modified). The state contains `buffers.active` (the active buffer PID), `vim.mode`, and all other editor state.

## Keybinding Registration

Bind key sequences to commands, optionally scoped to a filetype.

**Module:** `Minga.Keymap.Active`

```elixir
# In your init/1:
bind = &Minga.Keymap.Active.bind/5

# Global binding
bind.(:normal, "SPC m x", :my_command, "Do something")

# Filetype-scoped binding (only active in .org files)
bind.(:normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org)

# Insert mode binding
bind.(:insert, "C-j", :my_insert_command, "Insert something")
```

**Key notation:** `SPC` (space), `C-` (ctrl), `M-` (alt/meta), `S-` (shift), `TAB`, `RET` (enter), `ESC`. Multi-key sequences use spaces: `"SPC m t"`.

**Filetype scoping:** When `filetype: :atom` is passed, the binding only appears in which-key and only activates when the active buffer's filetype matches. Use this for language-specific bindings.

## Config Advice

Wrap existing commands with before/after/around/override logic.

**Module:** `Minga.Config.Advice`

```elixir
# Run code after every save
Minga.Config.Advice.register(:after, :save, fn state ->
  # state is the editor state after save completed
  state
end)

# Intercept a command with full control
Minga.Config.Advice.register(:around, :insert_newline, fn execute, state ->
  if should_handle_specially?(state) do
    do_special_thing(state)
  else
    execute.(state)  # call the original command
  end
end)

# Completely replace a command
Minga.Config.Advice.register(:override, :format_buffer, fn state ->
  my_custom_format(state)
end)
```

| Phase | Arity | Behavior |
|-------|-------|----------|
| `:before` | 1 | Transforms state before the command |
| `:after` | 1 | Transforms state after the command |
| `:around` | 2 | Receives `(execute_fn, state)`, full control |
| `:override` | 1 | Replaces the command entirely |

Advice functions are wrapped in try/rescue. A crash in advice logs a warning but doesn't crash the editor.

## Config Option Registration

Register typed options that users can set in their `config.exs`.

**Module:** `Minga.Config.Options`

```elixir
# In your init/1:
Minga.Config.Options.register_extension_option(:org_conceal, :boolean, true)
Minga.Config.Options.register_extension_option(
  :org_heading_bullets,
  :string_list,
  ["◉", "○", "◈", "◇"]
)
```

Users then set these in their config like any built-in option:

```elixir
# In ~/.config/minga/config.exs:
set :org_conceal, false
set :org_heading_bullets, ["•", "◦", "▸"]
```

**Supported type descriptors:** `:boolean`, `:pos_integer`, `:non_neg_integer`, `:integer`, `:string`, `:string_or_nil`, `:string_list`, `:atom`, `{:enum, [atoms]}`, `:map_or_nil`, `:any`

**Collision protection:** Registering an option that collides with a built-in name returns `{:error, reason}`. Use a prefix for your extension's options (e.g., `org_`, `zen_`).

**Reading options:** `Minga.Config.Options.get(:org_conceal)` returns the current value. `Minga.Config.Options.get_for_filetype(:org_conceal, :org)` checks filetype overrides first.

## Picker API

Open a fuzzy-filter picker with custom candidates.

**Modules:** `Minga.Picker.Source` (behaviour), `Minga.Picker.Item` (struct), `Minga.Editor.PickerUI` (UI)

### 1. Define a source module

```elixir
defmodule MyExtension.FormatPicker do
  @behaviour Minga.Picker.Source

  @impl true
  def title, do: "Export format"

  @impl true
  def candidates(_context) do
    [
      %Minga.Picker.Item{id: :html, label: "HTML"},
      %Minga.Picker.Item{id: :pdf, label: "PDF"},
      %Minga.Picker.Item{id: :md, label: "Markdown"}
    ]
  end

  @impl true
  def on_select(%{id: format}, state) do
    do_export(state, format)
  end

  @impl true
  def on_cancel(state), do: state
end
```

### 2. Open the picker from a command

```elixir
Minga.Command.Registry.register(
  Minga.Command.Registry,
  :my_export,
  "Export file",
  fn state -> Minga.Editor.PickerUI.open(state, MyExtension.FormatPicker) end
)
```

### Optional callbacks

| Callback | Default | Purpose |
|----------|---------|---------|
| `preview?/0` | `false` | Live-preview selection while navigating |
| `actions/1` | `[]` | Alternative actions for C-o menu |
| `on_action/3` | — | Execute an alternative action |
| `layout/0` | `:bottom` | `:bottom` or `:centered` (floating window) |
| `keep_open_on_select?/0` | `false` | Stay open after selection |

### Picker.Item fields

| Field | Required | Purpose |
|-------|----------|---------|
| `:id` | yes | Unique identifier (any term) |
| `:label` | yes | Display text, used for fuzzy matching |
| `:description` | no | Secondary text |
| `:annotation` | no | Right-aligned metadata (keybinding, status) |
| `:icon_color` | no | 24-bit RGB for the first grapheme |
| `:two_line` | no | Render description on a second line |

## Prompt API

Collect free-form text input from the user. This is the text-input equivalent of the picker, similar to Emacs's `read-from-minibuffer`.

**Modules:** `Minga.Prompt.Handler` (behaviour), `Minga.Editor.PromptUI` (UI)

### 1. Define a handler module

```elixir
defmodule MyExtension.CaptureTitle do
  @behaviour Minga.Prompt.Handler

  @impl true
  def label, do: "Capture title: "

  @impl true
  def on_submit(text, state) do
    # text is the user's input
    do_capture(state, text)
  end

  @impl true
  def on_cancel(state), do: state
end
```

### 2. Open the prompt

```elixir
# From a command or picker's on_select:
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle)

# With pre-filled text:
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle, default: "TODO ")

# With context data:
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle,
  default: "",
  context: %{template: selected_template}
)
```

**Composability:** A picker's `on_select` can open a prompt, enabling multi-step flows. For example: select a capture template (picker), then enter a title (prompt).

**Mutual exclusion:** Opening a prompt closes any active picker, and vice versa.

## Buffer Operations

Read and modify buffer content.

**Module:** `Minga.Buffer.Server`

The active buffer PID is at `state.buffers.active` in command functions.

```elixir
buf = state.buffers.active

# Read
{line, col} = Minga.Buffer.Server.cursor(buf)
lines = Minga.Buffer.Server.get_lines(buf, start_line, count)
total = Minga.Buffer.Server.line_count(buf)
filetype = Minga.Buffer.Server.filetype(buf)
path = Minga.Buffer.Server.file_path(buf)

# Write
Minga.Buffer.Server.apply_text_edit(buf, start_line, start_col, end_line, end_col, new_text)
Minga.Buffer.Server.apply_text_edits(buf, [{{start_line, start_col}, {end_line, end_col}, text}])
# For single characters only. For multi-char text, use apply_text_edit.
Minga.Buffer.Server.insert_char(buf, "a")
Minga.Buffer.Server.move_to(buf, {line, col})
```

**Best practice:** Create a thin wrapper module in your extension (e.g., `MyExt.Buffer`) that delegates all `Buffer.Server` calls. This isolates your code from API changes and creates a natural seam for test stubs.

## Decorations

Apply visual overlays (highlights, conceals, virtual text) without modifying buffer content.

**Module:** `Minga.Buffer.Decorations`

```elixir
# Use batch_decorations for efficient bulk updates
Minga.Buffer.Server.batch_decorations(buf, fn decs ->
  # Clear previous decorations from your group
  decs = Minga.Buffer.Decorations.remove_group(decs, :my_group)

  # Add a highlight range (bold, colored, etc.)
  {_id, decs} = Minga.Buffer.Decorations.add_highlight(
    decs,
    {line, start_col},  # start position
    {line, end_col},    # end position
    style: [bold: true, fg: 0x61AFEF],
    group: :my_group
  )

  # Add a conceal range (hide text, optionally replace)
  {_id, decs} = Minga.Buffer.Decorations.add_conceal(
    decs,
    {line, start_col},
    {line, end_col},
    replacement: "•",   # optional replacement character
    group: :my_group
  )

  decs
end)
```

**Groups:** Always use a group atom (`:my_extension_markup`, `:my_extension_links`). This lets you clear and re-apply all your decorations in a single `remove_group` + batch add cycle without affecting other extensions' decorations.

**Style options:** `:fg`, `:bg` (24-bit RGB), `:bold`, `:italic`, `:underline`, `:strikethrough`, `:reverse`.

## Tree-Sitter Grammar Registration

Register a custom tree-sitter grammar for syntax highlighting.

**Module:** `Minga.TreeSitter`

```elixir
Minga.TreeSitter.register_grammar(
  "org",                    # grammar name
  "/path/to/src/",          # directory with parser.c (and optional scanner.c)
  highlights: "/path/to/highlights.scm",
  injections: "/path/to/injections.scm",  # optional
  filetype_extensions: [".org"],
  filetype_atom: :org
)
```

The grammar is compiled into a shared library (cached at `~/.local/share/minga/grammars/`) and loaded into the parser port. Subsequent startups skip compilation.

## Editor Utilities

**Module:** `Minga.Editor`

```elixir
# Open a file in the editor
Minga.Editor.open_file(path)

# Log a message to *Messages* buffer (visible via SPC b m)
Minga.Editor.log_to_messages("Export complete: ~/notes.html")
```

## Folding

Provide fold ranges for custom folding behavior.

**Modules:** `Minga.Editor.FoldRange`, `Minga.Editor.Window`, `Minga.Editor.State`

```elixir
# Create fold ranges
ranges = [
  Minga.Editor.FoldRange.new!(start_line, end_line),
  Minga.Editor.FoldRange.new!(10, 25)
]

# Apply to the active window
win = Minga.Editor.State.active_window_struct(state)
state = Minga.Editor.State.update_window(state, win.id, fn w ->
  Minga.Editor.Window.set_fold_ranges(w, ranges)
end)

# Toggle fold at a line
state = Minga.Editor.State.update_window(state, win.id, fn w ->
  Minga.Editor.Window.toggle_fold(w, line)
end)
```

## Extension Testing

Extensions should separate pure logic from editor integration. See the [minga-org](https://github.com/jsmestad/minga-org) extension for a complete example.

**Pure logic:** Test text parsing, transformation, and pattern matching directly. These tests run with zero Minga dependency.

**Buffer integration:** Create a behaviour for your buffer wrapper module with an in-memory stub backend for tests. Follow the `Git.Backend` / `Git.Stub` pattern from Minga core.

**Registration verification:** Extract "what to register" into `*_definitions()` functions that return pure data. Test the data (command names, filetype scoping, function arities) without calling Minga APIs.
