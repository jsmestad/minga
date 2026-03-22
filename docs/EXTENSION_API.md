# Extension API

> **First time?** This is the API reference. For a guided walkthrough of building your first extension from scratch, see the [Extension Authoring Guide](https://github.com/jsmestad/minga/issues/212). For the conceptual foundation (why Elixir is Minga's Elisp, how the BEAM makes extensions safe), read [Extensibility](EXTENSIBILITY.md).

Extensions are Elixir packages that run inside the editor. They have full access to the BEAM VM, the same way Emacs Lisp packages have full access to the Emacs runtime. Your extension's `init/1` callback is where everything happens: register commands, bind keys, hook into the advice system, declare config options.

This page covers every public API an extension can use, with copy-pasteable examples.

---

## Trust Model

Extensions run in the same BEAM VM as the editor. They can call any module, access any ETS table, and exec system commands. There's no sandboxing, no capability system, no permission flags. This is the same trust model as Emacs and Vim: the security boundary is at install time, not runtime.

When a user writes `extension :my_ext, git: "..."` in their config, they're choosing to trust that code. A confirmation prompt appears for first-time installs from git/hex sources. Pin git extensions to a specific `ref:` for reproducibility.

---

## The Extension Behaviour

Every extension implements four callbacks. `use Minga.Extension` gives you a default `child_spec/1` (an Agent holding your config), the `option/3` macro for declaring typed config options, and a generated `__option_schema__/0` function the framework reads at load time. Override `child_spec/1` if you need a custom GenServer or supervision tree.

```elixir
defmodule MingaOrg do
  use Minga.Extension

  # Declare typed config options (validated at load time)
  option :conceal, :boolean,
    default: true,
    description: "Hide markup delimiters and show styled content"

  option :pretty_bullets, :boolean,
    default: true,
    description: "Replace heading stars with Unicode bullets"

  option :heading_bullets, :string_list,
    default: ["◉", "○", "◈", "◇"],
    description: "Unicode bullets for heading levels"

  @impl true
  def name, do: :minga_org

  @impl true
  def description, do: "Org-mode support"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(config) do
    # config is the keyword list from the user's extension declaration.
    # Options declared above are already validated and stored in ETS.
    MingaOrg.Commands.register()
    MingaOrg.Keybindings.register()
    {:ok, %{}}
  end
end
```

The `option` macro follows the same pattern as Ecto's `field`: you declare it at the module level, and `use Minga.Extension` generates a `__option_schema__/0` function from the accumulated declarations. You never write the introspection function yourself.

**Lifecycle:** The user declares the extension in `config.exs`. Minga compiles it, validates config options against the schema, calls `init/1`, then starts `child_spec/1` under `Extension.Supervisor`. On config reload (`SPC h r`), all extensions stop and re-load from scratch.

Each extension runs under a `DynamicSupervisor` with `:one_for_one` strategy. If your extension crashes, only your extension restarts. The editor and other extensions keep running.

---

## Commands

Commands are named functions that users invoke via keybindings or the command palette (`SPC :`). Every command is a `fn(state) -> state` function: it receives the full editor state, does something, and returns the (possibly modified) state.

```elixir
Minga.Command.Registry.register(
  Minga.Command.Registry,
  :org_cycle_todo,                     # unique atom name
  "Cycle TODO keyword on heading",     # shown in command palette
  &MyExtension.Todo.cycle/1            # fn(state) -> state
)
```

The state map contains `buffers.active` (the active buffer's PID), `vim.mode`, window layout, and everything else. You'll mostly interact with the buffer through `Buffer.Server` (covered below).

**Naming convention:** Prefix your command names with your extension's domain to avoid collisions. `:org_cycle_todo`, not `:cycle_todo`.

---

## Keybindings

Bind key sequences to commands. Bindings can be scoped to a filetype so they only activate (and only appear in which-key) when the right kind of file is focused.

```elixir
bind = &Minga.Keymap.Active.bind/5

# SPC m is the conventional "local leader" for filetype-specific commands
bind.(:normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org)
bind.(:normal, "SPC m x", :org_toggle_checkbox, "Toggle checkbox", filetype: :org)

# Alt+hjkl for structural editing (evil-org convention)
bind.(:normal, "M-h", :org_promote_heading, "Promote heading", filetype: :org)
bind.(:normal, "M-l", :org_demote_heading, "Demote heading", filetype: :org)

# Global bindings (no filetype: option)
bind.(:normal, "SPC X", :quick_capture, "Quick capture")
```

**Key notation:** `SPC` (space), `C-` (ctrl), `M-` (alt/meta), `S-` (shift), `TAB`, `RET` (enter), `ESC`. Multi-key sequences are space-separated: `"SPC m e h"`.

**Filetype scoping** is the key feature here. Without it, your org-mode bindings would shadow global bindings for every file. With `filetype: :org`, they only exist in the org context.

---

## Config Advice

The advice system lets you wrap, intercept, or replace any existing command. This is how extensions add filetype-specific behavior without forking the command. If you've used Emacs's `define-advice`, this is the same idea.

```elixir
# Run something after every save
Minga.Config.Advice.register(:after, :save, fn state ->
  Minga.Editor.log_to_messages("Saved!")
  state
end)

# Intercept a command with full control over whether it runs
Minga.Config.Advice.register(:around, :insert_newline, fn execute, state ->
  if org_list_context?(state) do
    insert_list_continuation(state)
  else
    execute.(state)
  end
end)
```

Four phases are available:

| Phase | Arity | What it does |
|-------|-------|--------------|
| `:before` | 1 | Transforms state before the command runs |
| `:after` | 1 | Transforms state after the command finishes |
| `:around` | 2 | Receives `(execute_fn, state)`. You decide if and how the command runs |
| `:override` | 1 | Replaces the command entirely. The original never executes |

All advice is wrapped in try/rescue. If your advice function crashes, it logs a warning and the command proceeds normally. Your bug won't take down the editor.

---

## Config Options

Extension options are declared with the `option/3` macro in your module (see [The Extension Behaviour](#the-extension-behaviour) above) and configured by users in the extension declaration. No flat `set` calls, no namespace collisions, no separate DSL.

**Declaring options** (in your extension module):

```elixir
option :conceal, :boolean,
  default: true,
  description: "Hide markup delimiters and show styled content"

option :pretty_bullets, :boolean,
  default: true,
  description: "Replace heading stars with Unicode bullets"

option :heading_bullets, :string_list,
  default: ["◉", "○", "◈", "◇"],
  description: "Unicode bullets for heading levels"
```

**User configuration** (in `config.exs`, grouped under the extension):

```elixir
extension :minga_org, git: "https://github.com/jsmestad/minga-org",
  conceal: false,
  pretty_bullets: true,
  heading_bullets: ["•", "◦"]
```

Values are validated against your declared types at load time. Setting `:conceal` to `"yes"` gives a clear error telling the user it must be a boolean. Unknown keys produce a warning log.

Two extensions can both declare a `:conceal` option without conflict. Options are namespaced under the extension name in ETS.

**Supported types:** `:boolean`, `:pos_integer`, `:non_neg_integer`, `:integer`, `:string`, `:string_or_nil`, `:string_list`, `:atom`, `{:enum, [atoms]}`, `:map_or_nil`, `:any`.

**Reading values at runtime:**

```elixir
Minga.Config.Options.get_extension_option(:minga_org, :conceal)
# => false

# With filetype override support:
Minga.Config.Options.get_extension_option_for_filetype(:minga_org, :conceal, :org)
```

**Setting values at runtime** (e.g., from a toggle command):

```elixir
Minga.Config.Options.set_extension_option(:minga_org, :conceal, false)
```

**Overriding per filetype** (e.g., disable conceal only for org files):

```elixir
Minga.Config.Options.set_extension_option_for_filetype(:minga_org, :org, :conceal, false)
```

**Overriding at runtime** (e.g., from a toggle command):

```elixir
Minga.Config.Options.set_extension_option(:minga_org, :conceal, false)
```

---

## Picker

The picker is a fuzzy-filter selection UI (like `SPC :` for the command palette or `SPC f f` for file finder). Extensions use it to present lists of choices to the user.

You implement a `Picker.Source` behaviour module, then open it from a command.

```elixir
defmodule MyExtension.FormatPicker do
  @behaviour Minga.Picker.Source

  @impl true
  def title, do: "Export format"

  @impl true
  def candidates(_context) do
    [
      %Minga.Picker.Item{id: :html, label: " HTML", description: "Export as HTML"},
      %Minga.Picker.Item{id: :pdf, label: " PDF", description: "Export as PDF"},
      %Minga.Picker.Item{id: :md, label: " Markdown", description: "Export as Markdown"}
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

Then register a command that opens it:

```elixir
Minga.Command.Registry.register(
  Minga.Command.Registry,
  :org_export,
  "Export org file",
  fn state -> Minga.Editor.PickerUI.open(state, MyExtension.FormatPicker) end
)
```

That's all the wiring you need. The picker handles fuzzy filtering, keyboard navigation, and rendering.

**`Picker.Item` fields:**

| Field | Required | What it does |
|-------|----------|--------------|
| `:id` | yes | Unique identifier (any term). Passed to `on_select` |
| `:label` | yes | Display text. Fuzzy matching runs against this |
| `:description` | no | Secondary text (dimmed, below or beside the label) |
| `:annotation` | no | Right-aligned metadata (keybinding hint, status) |
| `:icon_color` | no | 24-bit RGB for the first grapheme of the label |
| `:two_line` | no | Render description on a second line instead of inline |

**Optional callbacks** for advanced behavior:

| Callback | Default | What it does |
|----------|---------|--------------|
| `preview?/0` | `false` | Live-preview the selection while navigating |
| `layout/0` | `:bottom` | `:bottom` (minibuffer-style) or `:centered` (floating window) |
| `keep_open_on_select?/0` | `false` | Don't close after selection (useful for toggle-style pickers) |
| `actions/1` | `[]` | Alternative actions shown in the `C-o` menu |
| `on_action/3` | n/a | Execute an alternative action |

---

## Prompt

The prompt collects free-form text input. It's the counterpart to the picker: where the picker selects from a list, the prompt asks the user to type something. This is the equivalent of Emacs's `read-from-minibuffer`.

```elixir
defmodule MyExtension.CaptureTitle do
  @behaviour Minga.Prompt.Handler

  @impl true
  def label, do: "Capture title: "

  @impl true
  def on_submit(text, state) do
    # text is whatever the user typed
    insert_capture(state, text)
  end

  @impl true
  def on_cancel(state), do: state
end
```

Open it from a command or from a picker's `on_select` (for multi-step flows):

```elixir
# Simple: open directly
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle)

# With pre-filled text:
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle, default: "TODO ")

# With context data the handler can read:
Minga.Editor.PromptUI.open(state, MyExtension.CaptureTitle,
  context: %{template: selected_template}
)
```

**Composability** is the key design here. A picker's `on_select` can open a prompt, letting you build multi-step flows: select a capture template (picker), then enter a title (prompt). Each primitive is small and composable.

Picker and prompt are mutually exclusive. Opening one closes the other.

---

## Buffer Operations

Buffers are GenServer processes. The active buffer's PID lives at `state.buffers.active` in your command functions. Read and write through `Minga.Buffer.Server`:

```elixir
buf = state.buffers.active

# Reading
{line, col} = Minga.Buffer.Server.cursor(buf)
lines = Minga.Buffer.Server.get_lines(buf, start_line, count)
total = Minga.Buffer.Server.line_count(buf)
filetype = Minga.Buffer.Server.filetype(buf)
path = Minga.Buffer.Server.file_path(buf)

# Writing (use apply_text_edit for all text changes)
Minga.Buffer.Server.apply_text_edit(buf, start_line, start_col, end_line, end_col, new_text)

# Batch edits (multiple ranges, applied as one undo entry)
Minga.Buffer.Server.apply_text_edits(buf, [
  {{start_line, start_col}, {end_line, end_col}, new_text},
  {{other_start_line, other_start_col}, {other_end_line, other_end_col}, other_text}
])

# Move the cursor
Minga.Buffer.Server.move_to(buf, {line, col})
```

**Use `apply_text_edit` for all text changes**, even single characters. Don't loop over `insert_char` for multi-character text; that creates pathological undo stack growth and is O(n²) on the gap buffer.

**Create a wrapper module.** Put all your `Buffer.Server` calls behind a thin delegator module (e.g., `MyExtension.Buffer`). This isolates you from API changes and gives you a natural seam for [test stubs](#testing).

---

## Decorations

Decorations are visual overlays that don't modify buffer content: highlight ranges (bold, colored text), conceal ranges (hide delimiters, show replacement characters), and virtual text (inline or end-of-line annotations).

Always use `batch_decorations` for bulk updates. It defers tree rebuilding until the batch completes, preventing frame stutter when replacing many decorations at once.

```elixir
Minga.Buffer.Server.batch_decorations(buf, fn decs ->
  # Clear your previous decorations
  decs = Minga.Buffer.Decorations.remove_group(decs, :org_markup)

  # Highlight: styled content (bold, italic, colored)
  {_id, decs} = Minga.Buffer.Decorations.add_highlight(
    decs,
    {line, start_col},
    {line, end_col},
    style: [bold: true, fg: 0x61AFEF],
    group: :org_markup
  )

  # Conceal: hide text, optionally show a replacement character
  {_id, decs} = Minga.Buffer.Decorations.add_conceal(
    decs,
    {line, start_col},
    {line, end_col},
    replacement: "•",
    group: :org_markup
  )

  decs
end)
```

**Always use a group.** The group atom (`:org_markup`, `:org_links`, `:org_pretty`) is how you clear and re-apply your decorations without touching other extensions' decorations. Each `remove_group` + batch add cycle replaces exactly your decorations. Groups are cheap; use a separate one for each visual concern.

**Style properties:** `:fg`, `:bg` (24-bit RGB integers like `0x61AFEF`), `:bold`, `:italic`, `:underline`, `:strikethrough`, `:reverse`.

### Line Annotations

Line annotations attach visual metadata to buffer lines: colored pill badges, inline dimmed text, and gutter icons. Each frontend renders them natively (GUI renders pill badges with rounded rect backgrounds; TUI renders styled text at end of line).

Three annotation kinds are supported:

| Kind | Description | Example use |
|------|-------------|-------------|
| `:inline_pill` | Colored pill badge after line content | Org tags (`:work:`, `:urgent:`), diagnostic counts |
| `:inline_text` | Styled text after line content (no background) | Git blame, inline hints |
| `:gutter_icon` | Symbol in the gutter sign column | Bookmarks, breakpoints |

```elixir
# Add annotations inside a batch_decorations call
Minga.Buffer.Server.batch_decorations(buf, fn decs ->
  # Clear previous annotations from this group
  decs = Minga.Buffer.Decorations.remove_group(decs, :org_tags)

  # Pill badge: colored background + contrasting text
  {_id, decs} = Minga.Buffer.Decorations.add_annotation(decs, line, "work",
    kind: :inline_pill, fg: 0xFFFFFF, bg: 0x6366F1, group: :org_tags)

  {_id, decs} = Minga.Buffer.Decorations.add_annotation(decs, line, "urgent",
    kind: :inline_pill, fg: 0xFFFFFF, bg: 0xDC2626, group: :org_tags)

  # Inline text: dimmed annotation (git blame style)
  {_id, decs} = Minga.Buffer.Decorations.add_annotation(decs, line, "J. Smith, 2d ago",
    kind: :inline_text, fg: 0x888888, group: :git_blame)

  decs
end)
```

**Options:**

- `:kind` (default `:inline_pill`) -- `:inline_pill`, `:inline_text`, or `:gutter_icon`
- `:fg` (default `0xFFFFFF`) -- foreground color, 24-bit RGB
- `:bg` (default `0x6366F1`) -- background color, 24-bit RGB (only used by `:inline_pill`)
- `:group` -- atom for bulk removal via `remove_group/2`
- `:priority` (default `0`) -- ordering when multiple annotations share a line (lower first)

Annotations are line-anchored: they automatically shift when lines are inserted or deleted above them. Deleting the line an annotation is on removes the annotation.

---

## Tree-Sitter Grammars

Extensions can ship tree-sitter grammar source files and have Minga compile and load them at runtime. One call does everything: compile, cache, load, register filetype, send highlight query.

```elixir
Minga.TreeSitter.register_grammar(
  "org",
  "/path/to/tree-sitter-org/src",
  highlights: "/path/to/queries/org/highlights.scm",
  injections: "/path/to/queries/org/injections.scm",
  filetype_extensions: [".org"],
  filetype_atom: :org
)
```

The grammar's `parser.c` (and optional `scanner.c`) is compiled into a shared library using the system C compiler, then cached at `~/.local/share/minga/grammars/`. Subsequent startups skip compilation. If no C compiler is available, a warning is logged and the extension loads without highlighting.

For more detail on what `register_grammar/3` does under the hood, see the [Extensibility](EXTENSIBILITY.md#runtime-grammar-loading-for-extensions) page.

---

## Editor Utilities

```elixir
# Open a file in the editor (from a link-follow command, for example)
Minga.Editor.open_file("/path/to/file.org")

# Log to *Messages* (visible via SPC b m). Use for lifecycle events:
# file opened, export complete, LSP connected, etc.
Minga.Editor.log_to_messages("Exported to ~/notes.html")
```

---

## Folding

Provide custom fold ranges for your filetype. Org-mode headings, Markdown sections, whatever structure makes sense.

```elixir
# Compute fold ranges from your content
ranges = [
  Minga.Editor.FoldRange.new!(0, 15),
  Minga.Editor.FoldRange.new!(17, 30)
]

# Apply to the active window
win = Minga.Editor.State.active_window_struct(state)
state = Minga.Editor.State.update_window(state, win.id, fn w ->
  Minga.Editor.Window.set_fold_ranges(w, ranges)
end)

# Toggle a fold at a specific line
state = Minga.Editor.State.update_window(state, win.id, fn w ->
  Minga.Editor.Window.toggle_fold(w, line)
end)

# Fold/unfold everything
state = Minga.Editor.State.update_window(state, win.id,
  &Minga.Editor.Window.fold_all/1
)
state = Minga.Editor.State.update_window(state, win.id,
  &Minga.Editor.Window.unfold_all/1
)
```

Fold ranges are `{start_line, end_line}` pairs (both inclusive, 0-indexed). A range must span at least two lines. The start line is the "summary" line that stays visible when folded.

---

## Testing

In unit tests you don't want a running Minga instance. The solution is the same pattern Minga itself uses for `Git.Backend`:

**1. Separate pure logic from editor integration.** Parse text, transform strings, compute fold ranges as pure functions. Test these with zero dependencies.

**2. Create a buffer wrapper with a swappable backend.** Put all `Buffer.Server` calls behind a behaviour module. Use the real backend in production, an in-memory stub in tests.

```elixir
# lib/my_ext/buffer.ex (behaviour + delegator)
defmodule MyExt.Buffer do
  @backend Application.compile_env(:my_ext, :buffer_backend, MyExt.Buffer.Minga)
  def cursor(buf), do: @backend.cursor(buf)
  def line_at(buf, n), do: @backend.line_at(buf, n)
  # ...
end

# test/support/buffer_stub.ex (in-memory Agent)
# config/test.exs: config :my_ext, buffer_backend: MyExt.Buffer.Stub
```

The stub must actually apply text edits (not just record them), because functions like heading-move read, write, then read again in sequence.

**3. Extract registration data.** Put "what to register" in `*_definitions()` functions that return pure data. Test the data (right names, right filetype scoping, right function arities) without calling Minga APIs:

```elixir
# Test that all keybindings are scoped to the right filetype
for {_mode, _keys, _cmd, _desc, opts} <- Keybindings.binding_definitions() do
  assert Keyword.get(opts, :filetype) == :org
end
```

See [minga-org](https://github.com/jsmestad/minga-org) for a complete real-world example of this architecture.
