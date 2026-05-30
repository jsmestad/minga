# Extension API

> **First time?** This is the API reference. For a guided walkthrough of building your first extension from scratch, see the [Extension Authoring Guide](https://github.com/jsmestad/minga/issues/212). For the conceptual foundation (why Elixir is Minga's Elisp, how the BEAM makes extensions safe), read [Extensibility](EXTENSIBILITY.md).

Extensions are Elixir packages that run inside the editor. They have full access to the BEAM VM, the same way Emacs Lisp packages have full access to the Emacs runtime. Declarative contributions are described at compile time, and runtime setup happens in `init/1`.

This page covers every public API an extension can use, with copy-pasteable examples.

---

## Trust Model

Extensions run in the same BEAM VM as the editor. They can call any module, access any ETS table, and exec system commands. There's no sandboxing, no capability system, no permission flags. This is the same trust model as Emacs and Vim: the security boundary is at install time, not runtime.

When a user writes `extension :my_ext, git: "..."` in their config, they're choosing to trust that code. A confirmation prompt appears for first-time installs from git/hex sources. Pin git extensions to a specific `ref:` for reproducibility.

---

## The Extension Behaviour

Every extension implements four callbacks. `use Minga.Extension` gives you a default `child_spec/1` (an Agent holding your validated config), declarative macros for contributions, and generated schema functions the framework reads at load time. Override `child_spec/1` if you need a custom GenServer, persistent runtime state, or a supervision tree.

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

**Lifecycle:** The user declares the extension in `config.exs`. Minga compiles it, introspects its manifest, validates config options against the schema, calls `init/1`, then starts `child_spec/1` under `Extension.Supervisor`. On config reload (`SPC h r`), all extensions stop and re-load from scratch.

`init/1` is setup-only. It may register runtime-dynamic source-owned contributions and return `{:ok, state}` to report success, but the default child process does not receive that returned state. The default child stores the validated config keyword list so existing extensions keep working. If your extension has runtime state, put that state in your own GenServer or supervision tree and return it from your custom `child_spec/1`.

Each extension runs under a `DynamicSupervisor` with `:one_for_one` strategy. If your extension crashes, only your extension restarts. The editor and other extensions keep running.

### Lifecycle ordering and cleanup

The lifecycle contract is intentionally boring:

1. **Load:** path and git extensions compile from their local source, hex extensions load from the installed application.
2. **Manifest:** Minga records the extension name, version, source type, commands, keybindings, modeline segments, and declared capabilities before `init/1` runs.
3. **Options:** declared options are validated and registered.
4. **Init:** `init/1` runs. If it returns `{:error, reason}` or raises, startup fails.
5. **Child start:** `child_spec/1` starts under the extension supervisor.
6. **DSL registration:** declarative commands, keybindings, and modeline segments are registered with source `{:extension, name}`.

Stop, failed start, and reload all run source-owned cleanup. Cleanup families are aggregated: a failure in one family is logged and returned, but later cleanup families still run. This prevents a bad command cleanup from leaving stale keymaps, themes, languages, tool recipes, or modeline segments behind.

Reload is `stop -> cleanup -> load -> manifest -> options -> init -> child start -> DSL registration`. If stop cleanup reports an error, reload reports the error instead of pretending the extension restarted cleanly.

### Load Policies

By default, every extension loads eagerly at boot: compile, init, start child process, register contributions. This is correct for extensions that contribute first-paint UI (modeline segments, themes, dashboard widgets), but it means every installed extension adds to startup time, even ones the user rarely invokes.

The `load_policy` macro lets an extension declare when it should load. Minga registers lightweight stub commands and keybindings at boot without calling `init/1` or starting the child process. The first time a stub is triggered, the extension loads fully and the real handler takes over, all transparently within the same command dispatch.

```elixir
defmodule MingaBoard do
  use Minga.Extension

  # Load only when the user invokes :toggle_board
  load_policy {:on_command, [:toggle_board]}

  command :toggle_board, "Toggle The Board view",
    requires_buffer: false,
    execute: {MingaBoard.Commands, :toggle}

  keybind :normal, "SPC t b", :toggle_board, "Toggle The Board"

  @impl true
  def name, do: :minga_board
  # ...
end
```

**Available policies:**

| Policy | When it loads | Use for |
|--------|-------------|---------|
| `:eager` (default) | At boot, on the startup critical path | First-paint UI: modeline segments, themes, dashboard. Extensions that must be ready before the first frame. |
| `:deferred` | In the background, shortly after first paint | Extensions that should be ready soon but don't need to block the first frame. |
| `{:on_command, [atoms]}` | When any listed command is first invoked | Most extensions. Commands and keybindings appear in which-key at boot; the extension loads on first use. |
| `{:on_filetype, [atoms]}` | When a buffer with a matching filetype opens | Language-specific extensions (org-mode, markdown tools). *Reserved; stub commands autoload on invocation but filetype-open events do not yet trigger autoload automatically.* |
| `{:on_key, [{mode, key_string}]}` | When a matching key sequence is pressed | Extensions activated by a specific key chord. *Reserved; stub commands autoload on invocation but key-press events do not yet trigger autoload automatically.* |

**How it works:**

1. At boot, Minga compiles the extension (via the compile cache, so this is fast for unchanged sources) and reads its schema callbacks (`__command_schema__/0`, `__keybind_schema__/0`, etc.).
2. For non-eager extensions, Minga registers stub commands whose execute function triggers a synchronous autoload, then re-dispatches the command. Keybindings are registered normally (they reference command names, so the autoload happens via the stub command).
3. `init/1` and `child_spec/1` are NOT called until the trigger fires.
4. On first trigger: init runs, child starts, stub contributions are replaced with real handlers, and the original command executes. The user sees no difference besides first-invocation latency.

**What must stay eager:**

Extensions that contribute modeline segments (`modeline_segment/2`) or other first-paint UI must use `:eager`. If a lazy extension declared a modeline segment, the segment would be missing from the first frame and pop in when the extension loads, violating the "no flash of missing-then-appearing UI" guarantee. Minga does not enforce this at compile time, but the visual result of getting it wrong is obvious.

**Setting load policy from config:**

Users can also set the load policy from their config declaration, overriding the extension module's default:

```elixir
# In config.exs: make a normally-eager extension lazy
extension :my_ext, path: "~/.config/minga/extensions/my_ext",
  load_policy: {:on_command, [:my_cmd]}
```

The config `load_policy:` option takes precedence over the module's `load_policy` macro. This lets users tune loading behavior without forking the extension.

**Tradeoffs:**

- Lazy extensions still compile at boot (via the compile cache), so the BEAM loads their modules. The savings come from skipping `init/1` and the child process tree.
- First-trigger latency includes init time. For most extensions this is sub-millisecond. Extensions with expensive init (network calls, large file reads) should consider a `:deferred` policy instead, which loads in the background after first paint.
- An extension with a deliberate runtime error in `init/1` or a command handler will register its commands/keybindings normally at boot. The error surfaces only when the extension is first triggered, which is the intended behavior.

### Manifest and capabilities

Use the normal contribution macros to make declarations visible before runtime side effects run:

```elixir
command :org_cycle_todo, "Cycle TODO keyword", execute: {MingaOrg.Todo, :cycle}
keybind :normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org
modeline_segment :org_status, side: :right do
  nil
end
capability :ui, [:modeline]
```

Capabilities stay in declaration order. If you declare the same capability more than once, the manifest keeps every entry.

`Minga.Extension.manifest(MyExtension, :path)` returns a `%Minga.Extension.Manifest{}` with `:name`, `:description`, `:version`, `:source`, `:commands`, `:keybindings`, `:modeline_segments`, and `:capabilities`. Capabilities are stored as an ordered list of `{family, value}` tuples, so duplicate declarations stay visible. The shape is append-only. Future Minga releases may add fields, but existing fields keep their meaning.

`Minga.Extension.manifest/2` and `Minga.Extension.Manifest.from_module/2` call declaration callbacks directly, so callback failures can raise or exit. The extension supervisor catches those failures during startup and turns them into load errors instead.

### Lifecycle telemetry

Minga emits lifecycle telemetry for extension load, init, child start, stop, reload, cleanup, and crash/restart count. Handlers should listen for `[:minga, :extension, :lifecycle, :stop]` span events and read `metadata.extension` and `metadata.phase`. Crash/restart count uses `[:minga, :extension, :lifecycle, :crash_restart_count]` with `%{count: count}`.

Slow lifecycle phases are logged through `Minga.Log` with the extension name and phase. This gives users a path to answer "which extension slowed startup or reload?" without putting arbitrary extension callbacks in render or input hot paths.

### Hot-path rule

Extensions must publish cached data, snapshots, or declarative registrations. Input and render paths read registries and snapshots; they do not call arbitrary extension code per keystroke or frame.

The current `modeline_segment/3` callback is the narrow compatibility exception: it runs from a render path, so it must be cheap and read cached state only. Stateful or slow modeline data should be computed by the extension process ahead of time and exposed as a cached value. Future richer status/sidebar APIs should publish semantic snapshots instead of render callbacks.

Rich GUI features should publish semantic payloads that Minga's central protocol encoders and native frontend adapters understand, not raw GUI opcodes or raw terminal cells.

### Feature-owned UI state

Use feature-owned state when a UI feature needs per-workspace state but should not add a permanent field to `MingaEditor.Session.State`. Good examples are sidebar visibility, selected tree rows, drag state, panel filters, or cached UI projections. This state lives with the current workspace or tab snapshot, so switching tabs restores it with the rest of the editing context.

Feature state is keyed by source and feature id. Built-in code uses `:builtin` or `:config`. Extensions use `{:extension, extension_name}`. The feature id is an atom owned by that source.

```elixir
@source {:extension, :my_sidebar}
@feature :sidebar

def toggle_sidebar(state) do
  MingaEditor.State.update_feature_state(
    state,
    @source,
    @feature,
    %{visible?: false, selected: nil},
    fn sidebar -> %{sidebar | visible?: not sidebar.visible?} end
  )
end

def selected_path(state) do
  case MingaEditor.State.get_feature_state(state, @source, @feature) do
    nil -> nil
    sidebar -> sidebar.selected
  end
end

def close_sidebar(state) do
  MingaEditor.State.drop_feature_state(state, @source, @feature)
end
```

Missing state means inactive. Layout, input routing, render, GUI emit, and command code should treat `nil` as "this feature is not present" and fall back to normal buffer space. Do not pattern match on raw feature-state maps in random modules. Use the helpers on `MingaEditor.State` when you are transforming editor state, or `MingaEditor.Session.State` when you are already working with a workspace snapshot.

Feature state is not daemon-global runtime state. If your extension needs a long-lived process, cache, worker queue, connection, or subscription, keep that in your extension's own GenServer or supervision tree via `child_spec/1`. Use feature state only for UI state that belongs to a workspace or tab.

Reload and cleanup are source-owned. When an extension stops, fails, or reloads, Minga removes only feature state owned by `{:extension, extension_name}` from the live workspace and saved workspace snapshots. State owned by other extensions, config, or built-in features remains intact. Config reload runs inside the editor command path, so it first cleans `:config` and all extension-owned feature state before loading replacement config and extensions.

### Sidebar contributions

Use sidebar contributions for persistent left-side UI such as file trees, symbol outlines, bookmarks, search results, and source-control lists. A sidebar contribution has two parts: stable metadata registered once, and cached snapshots published whenever the extension state changes.

```elixir
source = {:extension, :my_outline}

:ok = MingaEditor.Extension.Sidebar.register(source, %{
  id: "my_outline",
  display_name: "Outline",
  description: "Symbols in the current file",
  placement: :left,
  priority: 40,
  preferred_width: 32,
  visible?: true,
  focused?: false,
  semantic_kind: "generic_tree",
  icon: "list.bullet",
  action_handler: {MyOutline.Actions, :handle_sidebar_action}
})

:ok = MingaEditor.Extension.Sidebar.publish_snapshot(source, "my_outline", %{
  rows: [
    %{id: "mod", text: "MyModule", icon: "symbol", indent: 0, selected?: true},
    %{id: "fun", text: "render/1", indent: 1, badge: "2"}
  ]
})
```

Snapshots include rows plus structural and selection fingerprints. If you do not provide fingerprints, Minga derives them from the row data. Selection-only changes keep the structural fingerprint stable so renderers can avoid treating cursor movement as a full sidebar rebuild.

The render path reads the latest snapshot from the registry. Do not provide `render_tui/2`, GUI binary builders, or per-frame callbacks. Extensions publish semantic rows with ids, text, icons, indentation, selection/active flags, badges, git status, diagnostics, and loading/error state. The TUI renders those rows inside the assigned sidebar rect. Native GUI frontends currently receive sidebar metadata through central protocol encoders and use compiled-in native adapters for known `semantic_kind` values; unknown kinds use the native generic fallback and do not render generic snapshot rows yet.

Actions route back through the editor action pipeline. A sidebar action handler receives `(state, action, context)` and returns the new editor state. This is the path for keyboard, mouse, and native GUI sidebar intents, so interactive sidebars can update editor state synchronously through public APIs instead of relying only on fire-and-forget messages to extension processes.

Sidebar ids are globally stable strings. Duplicate ids from different sources are rejected, and source cleanup removes only sidebars owned by the stopped extension.

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

The state map contains `buffers.active` (the active buffer's PID), `vim.mode`, window layout, and everything else. You'll mostly interact with the buffer through `Buffer` (covered below).

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

Buffers are GenServer processes. The active buffer's PID lives at `state.buffers.active` in your command functions. Read and write through `Minga.Buffer`:

```elixir
buf = state.buffers.active

# Reading
{line, col} = Minga.Buffer.cursor(buf)
lines = Minga.Buffer.lines(buf, start_line, count)
total = Minga.Buffer.line_count(buf)
filetype = Minga.Buffer.filetype(buf)
path = Minga.Buffer.file_path(buf)

# Writing (use apply_edit for all text changes)
Minga.Buffer.apply_edit(buf, start_line, start_col, end_line, end_col, new_text)

# Batch edits (multiple ranges, applied as one undo entry)
Minga.Buffer.apply_edits(buf, [
  {{start_line, start_col}, {end_line, end_col}, new_text},
  {{other_start_line, other_start_col}, {other_end_line, other_end_col}, other_text}
])

# Move the cursor
Minga.Buffer.move_to(buf, {line, col})
```

**Use `apply_edit/6` for all text changes**, even single characters. Don't loop over `insert_char` for multi-character text; that creates pathological undo stack growth and is O(n²) on the gap buffer.

**Create a wrapper module.** Put all your `Buffer` calls behind a thin delegator module (e.g., `MyExtension.Buffer`). This isolates you from API changes and gives you a natural seam for [test stubs](#testing).

---

## Decorations

Decorations are visual overlays that don't modify buffer content: highlight ranges (bold, colored text), conceal ranges (hide delimiters, show replacement characters), and virtual text (inline or end-of-line annotations).

Always use `batch_decorations` for bulk updates. It defers tree rebuilding until the batch completes, preventing frame stutter when replacing many decorations at once.

```elixir
Minga.Buffer.batch_decorations(buf, fn decs ->
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
Minga.Buffer.batch_decorations(buf, fn decs ->
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

## Language Packs

Language support is owned by language packs. A pack is a normal extension module that lists language definition modules and registers their `%Minga.Language{}` structs with a source tag. That source tag is what makes reload safe: unloading the pack removes the whole language record, so the language name, file extensions, exact filenames, shebang mappings, devicon, grammar metadata, formatter, and LSP defaults disappear together.

```elixir
defmodule MyLanguages do
  use Minga.Extension

  @languages [MyLanguages.Astro]

  @impl true
  def name, do: :my_languages

  @impl true
  def description, do: "Project language definitions"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    case Minga.Extensions.LanguagePacks.register_pack(__MODULE__) do
      :ok -> {:ok, %{languages: length(@languages)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def language_modules, do: @languages
end

defmodule MyLanguages.Astro do
  def definition do
    %Minga.Language{
      name: :astro,
      label: "Astro",
      comment_token: "// ",
      extensions: ["astro"],
      icon: "\u{E6B3}",
      icon_color: 0xFF5D01,
      grammar: "astro"
    }
  end
end
```

If you add a language to Minga itself, create a language module inside the bundled pack and add that module to the pack's `language_modules/0` list. Do not edit a central registry list or add hardcoded filetype maps in core.

---

## Tree-Sitter Grammars

Extensions can ship tree-sitter grammar source files and have Minga compile and load them at runtime. One call does everything: compile, cache, load, register filetype, send highlight query.

```elixir
Minga.Language.register(
  "org",
  "/path/to/tree-sitter-org/src",
  highlights: "/path/to/queries/org/highlights.scm",
  injections: "/path/to/queries/org/injections.scm",
  filetype_extensions: [".org"],
  filetype_atom: :org
)
```

The grammar's `parser.c` (and optional `scanner.c`) is compiled into a shared library using the system C compiler, then cached at `~/.local/share/minga/grammars/`. Subsequent startups skip compilation. `Minga.Language.register/3` returns `{:error, reason}` for compilation or other synchronous setup failures. A successful `:ok` means the parser load request was accepted, not that every parser process has already applied it. Your `init/1` decides whether that should fail the extension or continue without highlighting.

For more detail on what `Minga.Language.register/3` does under the hood, see the [Extensibility](EXTENSIBILITY.md#runtime-grammar-loading-for-extensions) page.

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

**2. Create a buffer wrapper with a swappable backend.** Put all `Buffer` calls behind a behaviour module. Use the real backend in production, an in-memory stub in tests.

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
