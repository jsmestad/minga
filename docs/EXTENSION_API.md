# Extension API

> **First time?** This is the API reference. For user-facing configuration and installing extensions, see [Configuration](CONFIGURATION.md#optional-extensions). For the extension code-generation boundary, see [ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md).

Extensions are Elixir packages that run inside the editor. They have full access to the BEAM VM, the same way Emacs Lisp packages have full access to the Emacs runtime. Declarative contributions are described at compile time, and runtime setup happens in `init/1`.

This page covers every public API an extension can use, with copy-pasteable examples.

---

## Trust Model

Extensions run in the same BEAM VM as the editor. They can call any module, access any ETS table, and exec system commands. There's no sandboxing, no capability system, no permission flags. This is the same trust model as Emacs and Vim: the security boundary is at install time, not runtime.

When a user writes `extension :my_ext, git: "..."` in their config, they're choosing to trust that code. First-time installs run automatically at boot for declared `git:` and `hex:` sources because the config declaration is the explicit consent. Updates (`SPC h e u`) prompt for confirmation with a git log inspection before applying. Pin git extensions to a specific `ref:` for reproducibility.

Runtime containment is not a sandbox. Minga does contain failures when extension-owned code enters an Editor callback surface, which keeps one broken optional callback from crashing the Editor process. Built-in and core callbacks do not use that containment and keep normal OTP supervision behavior.

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

**Lifecycle:** The user declares the extension in `config.exs`. Minga resolves the source to one admitted current-generation artifact, introspects its manifest, validates config options against the schema, calls `init/1`, then starts `child_spec/1` beneath that extension's runtime supervisor. Runtime lifecycle and code activation are separate: Minga can stop, disable, lazily start, or restart an extension in the current session, but changed extension code activates only after Minga starts a fresh BEAM OS process. See [ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md) for the accepted contract and migration scope.

`init/1` is setup-only. It may register runtime-dynamic source-owned contributions and return `{:ok, state}` to report success, but the default child process does not receive that returned state. The default child stores the validated config keyword list so existing extensions keep working. If your extension has runtime state, put that state in your own GenServer or supervision tree and return it from your custom `child_spec/1`.

Each declaration has one stable `Minga.Extension.Instance` process beneath `Minga.Extension.RootSupervisor`. Calls through the compatible `Minga.Extension.Supervisor` facade route start, stop, lazy activation, deferred activation, failure, restart, and unload through that Instance mailbox. The current runtime PID is not the extension's identity. It is a projection of the Instance's current phase, along with status, module, manifest, and last error, in `Minga.Extension.Registry`.

The per-extension `Minga.Extension.Root` uses `rest_for_one` and starts `Minga.Extension.RuntimeSupervisor` before the Instance. A runtime supervisor failure therefore replaces the Instance after a new empty runtime supervisor exists. An Instance failure leaves its local runtime supervisor in place, so the replacement Instance can recover only that extension's child. Other extensions and the editor remain unaffected.

### Lifecycle ordering and cleanup

The lifecycle contract is intentionally boring:

1. **Source resolution:** module, Hex/application, and bundled sources identify a trusted resident application inventory. Resolved Git and path sources identify an immutable source snapshot. A path with no Elixir source may use the deterministic JSON fallback.
2. **Artifact admission:** the complete module inventory establishes current-generation ownership before host loading. Path and resolved Git source compiles in a standalone disposable BEAM OS process with byte-only standard streams. Resident application sources are adopted rather than overwritten.
3. **Manifest:** Minga records the extension name, version, source type, commands, keybindings, modeline segments, and declared capabilities before `init/1` runs.
4. **Options:** declared options are validated and registered.
5. **Init:** `init/1` runs. If it returns `{:error, reason}` or raises, startup fails.
6. **Child start:** the child spec is normalized to `:temporary` and starts under the extension's local runtime supervisor. The Instance alone preserves and interprets the extension's declared `:permanent`, `:transient`, or `:temporary` restart policy.
7. **DSL registration:** declarative commands, keybindings, modeline segments, and runtime event handlers are registered with source `{:extension, name}`.

Stop, failed start, and reload all converge through the Instance's source-owned cleanup transition. Concurrent starts join one start and receive the same runtime PID. Concurrent stops finalize once, and a start that reaches the mailbox during stop waits for safe cleanup before starting one replacement. A cleanup failure retains retry state rather than allowing a new start to bypass unfinished work. Cleanup families are aggregated: a failure in one family is logged and returned, but later cleanup families still run. This prevents a bad command cleanup from leaving stale keymaps, themes, languages, tool recipes, or modeline segments behind.

Editor-owned finalization is asynchronous. The Instance casts effect cancellation, unload, and presentation cleanup requests to the Editor and waits for explicit acknowledgements without occupying the Editor mailbox. This ordering keeps config reload and effect-worker initiated reload paths from forming an Editor/Instance call cycle.

Runtime disable closes new source-owned work, invokes source-unload handlers with unload-only authority, removes dispatch-visible contributions, cancels or settles source-owned effects, stops the runtime subtree, runs source cleanup, and removes Editor-owned presentation state. Loaded modules remain resident. A later start in the same session may use only the exact artifact admitted for that extension in the current VM generation; installing, updating, or editing extension code reports that a Minga restart is required.

Isolated compiler artifacts, not source-syntax prediction, are the module inventory. Ordinary direct and nested modules, atom-targeted declarations, macro output, runtime-generated modules, and modules generated by spawned compiler processes are supported when their emitted artifacts are valid and conflict-free. Duplicate emissions are rejected before one output can overwrite another. Duplicate identities, malformed internal names, filename/metadata disagreement, incomplete or corrupt caches, and collisions with Minga, OTP applications, or another extension are rejected before loading.

Source files are opened as regular files with descriptor identity and size checks, copied into a private immutable snapshot, and then hashed and compiled from that same snapshot. Source count, per-file, and total-byte limits apply before subprocess launch. Fresh and cached BEAM directories are likewise copied through bounded regular-file descriptors before a separate standalone validator process structurally parses BEAM atom tables and compressed Attr/LitT ETF. Inflation is streaming and bounded, actual output must equal its declaration, and malformed or trailing terms are rejected. The host receives only bounded UTF-8 metadata, checks artifact count, per-artifact and total bytes and atoms, manifest bytes, and host atom headroom, and only then creates module atoms or loads code. Compressed manifests are not accepted.

This isolation protects the host VM's validation boundary; it is not a sandbox for extension authority. Extensions remain trusted code and compiler execution retains the OS user's filesystem and network authority. Review extension source accordingly.

Git updates stage the accepted checkout and report that restart is required. Development source edits follow the same rule; there is no same-VM hot-reload compiler path.

### Load Policies

By default, every extension loads eagerly at boot: compile, init, start child process, register contributions. This is correct for extensions that contribute first-paint UI (modeline segments, themes, dashboard widgets), but it means every installed extension adds to startup time, even ones the user rarely invokes.

The `load_policy` macro lets an extension declare when it should load. Minga registers lightweight stub commands and keybindings at boot without calling `init/1` or starting the child process. The first time a stub is triggered, the extension loads fully and the real handler takes over, all transparently within the same command dispatch.

```elixir
defmodule MingaTasks do
  use Minga.Extension

  # Load only when the user invokes :open_tasks
  load_policy {:on_command, [:open_tasks]}

  command :open_tasks, "Open task list",
    requires_buffer: false,
    execute: {MingaTasks.Commands, :open}

  keybind :normal, "SPC t t", :open_tasks, "Open tasks"

  @impl true
  def name, do: :minga_tasks
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

1. At boot, Minga admits the extension's isolated compiler artifact (via the validated compile cache, so this is fast for unchanged sources) and reads its schema callbacks (`__command_schema__/0`, `__keybind_schema__/0`, etc.).
2. For non-eager extensions, the Instance registers stub commands whose execute function triggers synchronous autoload through the same mailbox, then re-dispatches the command. Keybindings are registered normally because they reference command names.
3. `init/1` and `child_spec/1` are not called until the trigger fires.
4. Racing triggers join one Instance start and receive the same runtime. The stub is replaced with real handlers before the original command executes.
5. Deferred activation also uses the same Instance and checks that its captured declaration identity is still current. Stale deferred work does not activate a re-registered extension.

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

- Lazy extensions still admit and load their exact VM-generation artifact at boot. First activation never recompiles the current checkout; the savings come from skipping `init/1` and the child process tree.
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

### Runtime callback boundary

Commands, modeline segments, picker source callbacks, sidebar action MFAs, declared editor events, and extension-owned typed effect execution callbacks enter through one extension-only invocation contract. A callback that returns normally is different from a callback that could not run or failed while running. Minga reports exceptions, throws, exits, unavailable source code, and invalid domain returns before applying the adapter's documented fallback. Typed effects remain isolated in scheduler workers; callback containment becomes an explicit failed effect outcome rather than a worker crash.

That distinction matters most for ordered events. Declare one handler module and the families it accepts:

```elixir
defmodule MingaGitTools do
  use Minga.Extension

  editor_event_handler MingaGitTools.Events,
    [:buffer_saved, :editor_action, :source_unload],
    priority: 200
end
```

The handler implements `MingaEditor.Extension.EventHandler.handle_editor_event/2` and returns either `{:handled, state}` or `:not_matched`.

- `:editor_action` is first match. A successful `:not_matched` tries the next lower-priority handler. A failure stops dispatch, so a broken high-priority handler cannot accidentally hand the action to another extension.
- `:buffer_saved` fans out in priority order. Successful handlers thread their state forward. A later failure is reported, and remaining handlers still run from the last successful state.
- `:source_unload` runs only handlers owned by the source being stopped. It has the same state-preserving fan-out behavior and runs before registrations disappear.

These are the only public runtime event families. Worker results and process-down messages stay inside the effects and OTP owners that created them. Do not route arbitrary mailbox messages through a generic extension event wrapper.

An extension failure fallback may keep prior state, return an empty collection, or hide one malformed modeline segment, depending on the domain. It never means the callback declined. `:not_matched` is reserved for an event callback that actually ran and chose not to handle the event. Lifecycle schema callbacks and `init/1` remain load-time operations and do not use this runtime contract.

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

Disable and cleanup are source-owned. When an extension stops, fails, or is disabled, Minga removes only feature state owned by `{:extension, extension_name}` from the live workspace and saved workspace snapshots. State owned by other extensions, config, or built-in features remains intact. Config reload removes config-owned presentation when replacing config declarations; extension presentation follows the owning extension lifecycle rather than a competing reload path.

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

Editor command advice uses a state-to-state contract. Tool advice uses the same registration API but has an explicit result contract for `:around` and `:override` callbacks:

```elixir
Minga.Config.Advice.register(:around, :read_file, fn execute, state ->
  case execute.(state) do
    {:returned, next_state, {:ok, content}} ->
      {:returned, Map.put(next_state, :bytes_read, byte_size(content)), {:ok, content}}

    {:returned, next_state, result} ->
      {:returned, next_state, result}

    {:skipped, _next_state} = skipped ->
      skipped
  end
end)
```

The complete tool outcome is `{:returned, advice_state, result}` or `{:skipped, advice_state}`. A bare state map from tool `:around` or `:override` advice means skipped; it is never interpreted as a tool result. A skipped invocation returns `{:error, :no_result}` to the tool caller. The core always receives the arguments that passed approval and hook checks, even if before or around advice transforms its separate advice-state map.

Existing tool `:before` and `:after` callbacks do not need a signature change. They still receive and return only the advice-state map:

```elixir
Minga.Config.Advice.register(:before, :read_file, fn state ->
  Map.put(state, :started_at, System.monotonic_time())
end)

Minga.Config.Advice.register(:after, :read_file, fn state ->
  Map.put(state, :finished_at, System.monotonic_time())
end)
```

Tool-specific around callbacks that previously treated `execute.(state)` as a bare state map must pattern-match and return the tagged outcome as shown above. Editor command callbacks continue to use the original bare-map contract.

Advice callbacks are crash-isolated. Failed editor advice retains its existing behavior. Failed or invalid tool before/after advice preserves the prior advice state and tool result; failed or invalid tool around/override advice skips the invocation without retrying an already executed core.

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

Use a picker when an extension needs the user to choose from a list. Implement `MingaEditor.Extension.Picker.Source` and open it from an extension command. The editor handles filtering, keyboard and mouse input, and presentation on both frontends.

This picker opens one of the note files supplied by the command:

```elixir
defmodule MyExtension.NotesPicker do
  @behaviour MingaEditor.Extension.Picker.Source

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item

  @impl true
  def title, do: "Open note"

  @impl true
  def candidates(paths, :start) do
    items = Enum.map(paths, fn path -> %Item{id: path, label: Path.basename(path)} end)
    {:ok, items, :done}
  end

  @impl true
  def preview(%Item{id: path}, _paths), do: {:file, path}

  @impl true
  def on_select(state, %Item{id: path}, _paths), do: EditorAPI.open_file(state, path)
end
```

From a command callback, call `MingaEditor.Extension.Picker.open(state, MyExtension.NotesPicker, absolute_paths)`. The picker passes the original arguments to the source. Capture the path or repository at open time, not after the user selects an item.

`candidates/2` and `preview/2` run outside the editor process. For a long list, return `{:more, cursor, item}` instead of `:done`. The editor requests `{:continue, cursor}` only when the user activates that row. It keeps the existing results. Selection and alternative actions run after dismissal. See [`Picker.Source`](https://hexdocs.pm/minga_sdk/MingaEditor.Extension.Picker.Source.html) for preview, fallback, and the secondary actions (`actions/2`) the picker's act menu (`⌃.`) lists.

---

## Prompt

Use a text prompt when the user must enter a value, or a confirmation when you need an explicit Yes or No. The editor closes the prompt before calling the handler with the original arguments.

This text prompt jumps to a line in the file captured by the command, even if another buffer becomes active in the meantime:

```elixir
defmodule MyExtension.JumpPrompt do
  @behaviour MingaEditor.Extension.Prompt.Handler

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Prompt

  def open(state, path) do
    case Prompt.text(state, __MODULE__, path, label: "Go to line: ", default: "1") do
      {:ok, updated} -> updated
      {:error, _reason} -> EditorAPI.notice(state, "Could not open the line prompt")
    end
  end

  @impl true
  def on_submit(state, text, path) do
    case Integer.parse(text) do
      {line, ""} when line > 0 -> EditorAPI.navigate_to(state, path, line - 1)
      _ -> EditorAPI.notice(state, "Enter a positive line number")
    end
  end
end
```

For a Yes/No prompt, call `Prompt.confirm/4` and implement `on_confirm(state, decision, args)`. Only `:accepted` authorizes the operation. A No or Escape produces `:canceled`; unloading the extension dismisses the prompt without invoking the handler. Use `admission: :if_idle` when a background result should not replace an active modal.

## Repository operations

For repository operations that can block, propose a `MingaEditor.Extension.RepositoryJob` with an absolute repository root and immutable arguments. Return the proposal from the command or editor action. `run/2` performs the work in a supervised process. `on_result/4` updates the editor only while the same extension activation and project are current. The host owns the Git sidebar and rendered diff buffers; [`GitStatus`](https://hexdocs.pm/minga_sdk/MingaEditor.Extension.GitStatus.html) and [`GitDiff`](https://hexdocs.pm/minga_sdk/MingaEditor.Extension.GitDiff.html) provide their public operations.

A Git diff origin also identifies the comparison: `:unstaged` uses the index and working text, and `:staged` uses HEAD and the index. For an unmerged path, pass HEAD and worktree text as a `:conflict` preview. Do not stage or revert hunks from a conflict preview.

---

## Buffer Operations

Use `EditorAPI.active_buffer/1` to get the active buffer PID. It returns `nil` when there is no live buffer. Do not read fields from editor state. Read and write through `Minga.Buffer`:

```elixir
buf = MingaEditor.Extension.EditorAPI.active_buffer(state)

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

Ranges are inclusive, and a column past the end of its line means the line end. `apply_edits/3` is all or nothing: if any edit would leave the buffer as invalid UTF-8, for example two overlapping edits that split a character, it returns `{:error, {:edit_failed, index, :invalid_utf8}}` with `index` pointing into your list, and the buffer is unchanged.

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

Language support is owned by language packs. A pack is a normal extension module that lists language definition modules and registers their `%Minga.Language{}` structs with a source tag. That source tag is what makes disable safe: unloading the pack removes the whole language record, so the language name, file extensions, exact filenames, shebang mappings, devicon, grammar metadata, formatter, and LSP defaults disappear together.

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

This single call handles the full pipeline:

1. **Compiles** the grammar's `parser.c` (and optional `scanner.c`) into a platform-appropriate shared library (`.dylib` on macOS, `.so` on Linux) using the system C compiler (`$CC`, or `cc`/`gcc`/`clang`).
2. **Caches** the compiled library at `~/.local/share/minga/grammars/` (respects `$XDG_DATA_HOME`). Subsequent startups skip recompilation when the cache is newer than sources.
3. **Loads** the shared library into the parser Port via the `load_grammar` protocol message.
4. **Sends** highlight and injection queries to the parser.
5. **Registers** filetype mappings so `Minga.Language.detect_filetype/1` recognizes the new file extensions.
6. **Registers** the filetype-to-grammar mapping in `Minga.Language.Grammar` so buffers with the new filetype get syntax highlighting.

`Minga.Language.register/3` returns `{:error, reason}` for compilation or other synchronous setup failures. A successful `:ok` means the parser load request was accepted, not that every parser process has already applied it. Your `init/1` decides whether that should fail the extension or continue without highlighting.

The dynamic grammar registry is an ETS table (`read_concurrency: true`) initialized at application startup. Dynamic mappings take precedence over registered language definitions, so extensions can override bundled grammars when needed.

---

## Model routes

Your company runs an LLM gateway, or you already pay for a model subscription that has its own sign-in tool. You want that model in `/model` without giving up what Minga's agent does well: tool approvals, retries, compaction, changesets, and saved history. A model route is the seam for that. Your extension supplies model replies; Minga keeps running the turn.

### What a route does, and what it never does

A route answers one question: given these messages and tools, what does the model say next? It receives a `MingaAgent.InferenceRoute.Request` and streams back `MingaAgent.InferenceRoute.Event` values: text, thinking, complete tool calls, usage, and a finish reason. It never runs a tool. When the model asks for a tool, Minga executes it through its normal executor and approval flow, then sends the result back to your route in the next request. A denied tool reaches your route as an error tool result. This holds for every route, so trusting a route is trusting it with the conversation text, not with your machine.

The route contract is Minga's own. Every value a route sees or returns lives under `MingaAgent.InferenceRoute.*`, so your route keeps working when Minga changes the model library it uses internally.

### A complete example

This route forwards requests to a company proxy. It reads its token from the route credential Minga passes in, turns Minga's messages into the proxy's wire format, and turns the proxy's replies back into Minga events.

```elixir
defmodule CompanyProxy.Route do
  @behaviour MingaAgent.InferenceRoute

  alias MingaAgent.InferenceRoute.{Credential, Model, Request, Response, ToolCall, Usage}

  @impl true
  def models(_config) do
    {:ok, model} =
      Model.new(
        id: "fast",
        display_name: "Company Proxy (fast)",
        context_window: 128_000,
        max_output: 8_192,
        reasoning_levels: ["off", "low", "high"],
        tools?: true,
        images_in?: false,
        tool_result_images?: false,
        compaction: :native,
        usage: :tokens,
        cost: :subscription
      )

    [model]
  end

  @impl true
  def availability(_route_id, %Credential{env: %{"COMPANY_PROXY_TOKEN" => _token}}),
    do: {:ready, "company proxy"}

  def availability(_route_id, _credential),
    do:
      {:unavailable, :missing_token,
       "No proxy token. Add routes.company_proxy.env.COMPANY_PROXY_TOKEN to credentials.json."}

  @impl true
  def stream(%Request{} = request) do
    token = request.credential && request.credential.env["COMPANY_PROXY_TOKEN"]

    body = %{
      model: request.model.id,
      system: request.system,
      messages: Enum.map(request.messages, &CompanyProxy.Wire.message/1),
      tools: Enum.map(request.tools, &%{name: &1.name, description: &1.description, schema: &1.input_schema}),
      max_tokens: request.options.max_output_tokens,
      reasoning: request.options.reasoning
    }

    with {:ok, connection} <- CompanyProxy.Client.open(token, body) do
      events =
        connection
        |> CompanyProxy.Client.chunks()
        |> Stream.map(fn
          %{"type" => "text", "text" => text} -> {:text, text}
          %{"type" => "thinking", "text" => text} -> {:thinking, text}
          %{"type" => "tool", "id" => id, "name" => name, "input" => input} ->
            {:ok, call} = ToolCall.new(id: id, name: name, arguments: input)
            {:tool_call, call}
          %{"type" => "usage", "in" => input, "out" => output} ->
            {:ok, usage} = Usage.new(input_tokens: input, output_tokens: output)
            {:usage, usage}
          %{"type" => "done", "reason" => "tool_use"} -> {:finish, :tool_calls}
          %{"type" => "done"} -> {:finish, :stop}
          %{"type" => "error", "status" => status} -> {:finish, {:error, {:http, status}}}
        end)

      {:ok, %Response{events: events, cancel: fn -> CompanyProxy.Client.close(connection) end}}
    end
  end

  @impl true
  def classify_error({:http, 429}), do: {:rate_limited, "The company proxy is busy. Wait a moment, then try again."}
  def classify_error({:http, 401}), do: {:auth_failed, "The proxy token was rejected. Update routes.company_proxy.env in credentials.json."}
  def classify_error(_reason), do: {:provider_error, "The company proxy failed. Open *Messages* for details."}
end

defmodule CompanyProxy do
  use Minga.Extension

  @impl true
  def name, do: :company_proxy

  @impl true
  def description, do: "Company LLM proxy as a Minga model route"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    {:ok, reporter} =
      Minga.Extension.ModelRoutes.register(
        id: "company_proxy",
        module: CompanyProxy.Route,
        display_name: "Company Proxy"
      )

    {:ok, %{reporter: reporter}}
  end
end
```

After the extension loads, `/model` lists **Company Proxy (fast)** with the route's readiness text, context size, thinking levels, and tool support, all taken from the `Model` you declared. Users can also select it with `/model company_proxy:fast`.

### What a request contains

`Request.messages` holds `MingaAgent.InferenceRoute.Message` values with role `:user`, `:assistant`, or `:tool`, and content parts that are plain tagged tuples:

- `{:text, text}`
- `{:image, media_type, data}` with raw bytes
- `{:thinking, text, signature}`, where `signature` is nil unless your route supplied one
- `{:tool_call, %ToolCall{}}` on assistant messages, with decoded `arguments`
- `{:tool_result, tool_call_id, parts, is_error}` on tool messages; a tool the user denied arrives with `is_error: true`

The system prompt is in `Request.system`. `Request.tools` lists `ToolDeclaration` values with a JSON Schema `input_schema` that uses string keys. `Request.options` carries `max_output_tokens` and the selected `reasoning` level from your `Model.reasoning_levels`. Content your route cannot receive, such as video or file attachments, never reaches it: Minga rejects the request with a clear message instead.

### What a response contains

`stream/1` returns `{:ok, %Response{events: events, cancel: cancel}}`. `events` is a lazy enumerable that Minga consumes once. Emit `{:text, text}` and `{:thinking, text}` as they arrive, `{:tool_call, call}` once a call's arguments are final, `{:usage, usage}` when you know token counts, and finally `{:finish, reason}` with `:stop`, `:tool_calls`, `:length`, `:refusal`, or `{:error, term}`. Minga passes the `term` of an error finish to your `classify_error/1`. If the stream ends without a finish event, Minga treats it as `:stop`. An event that is not one of these shapes stops the turn with a clear "invalid response" error. `cancel` must stop the work behind the stream. Minga calls it exactly once whenever it stops reading before your events end: the user stops the turn, the process reading your events exits or crashes, or Minga ends the stream early because of an invalid event or a failure while reading. Minga does not call it after your events end, including when they end with `{:finish, {:error, term}}`. In the example above, that is what closes the proxy connection when the user presses Stop. If `cancel` raises, Minga logs the failure to `*Messages*` and carries on.

If enumerating your `events` raises, exits, or throws, Minga ends the turn instead of crashing. When the reply has not started, Minga passes `{:inference_route_failed, route_id, failure}` to your `classify_error/1` and shows its sentence; when a partial reply is already on screen, Minga keeps it and marks the stream as interrupted.

### Registration and ownership

`Minga.Extension.ModelRoutes.register/2` takes the route id, the module, and a display name, plus an optional `:config` keyword passed to `models/1`. Call it from `init/1`: Minga takes the owning extension from the call context, not from your arguments. Route ids use lowercase letters, digits, `_`, and `-`, and cannot reuse a built-in provider name. If another extension already owns the id, registration returns `{:error, {:duplicate_route_id, ...}}` and the first route keeps working. When your extension stops, its routes disappear from `/model`, and the next send on a removed route reports it as unavailable.

### Reporting status with a reporter

Minga calls `availability/2` off the editor process when the user opens `/model`, with a deadline. A route that raises or times out shows as unavailable with diagnostics in `*Messages*`. To push a change yourself, for example right after the user signs in, keep the `MingaAgent.InferenceRoute.Reporter` that `register/2` returned and call `Minga.Extension.ModelRoutes.report_status(reporter, {:ready, "me@example.com"})` from any process. A reporter from an earlier registration, or for a removed route, is rejected with `{:error, :stale_reporter}` or `{:error, :unknown_route}`.

An unavailable route cannot become the active model. Selecting it shows your remedy text and leaves the current model unchanged. The account label you report is part of the selection's identity, so switching accounts changes which saved selection matches.

### Models that change after registration

Your route's model list can depend on things outside Minga. The user installs your CLI, signs in, or upgrades a plan, and new models become available. You do not need to re-register. Every time Minga checks your route's availability, for example when the user opens `/model`, it calls `models/1` again with the `:config` you registered, in the same worker and under the same deadline as `availability/2`. If the new list is invalid or the call fails, Minga keeps the previous list and writes the reason to `*Messages*`. A saved selection whose model disappears restores as unavailable instead of falling back.

### A setup row in `/model`

A subscription route has states an API-key model does not: the CLI might be missing, or the user might be signed out. Declare a setup action and `/model` shows a row for your route while it is registered:

```elixir
Minga.Extension.ModelRoutes.register(
  id: "claude_subscription",
  module: ClaudeBridge.Route,
  display_name: "Claude (subscription)",
  short_name: "Claude",
  setup_action: [
    label: "Use Claude subscription (Claude Code)",
    description: "Sign in with the Claude Code CLI. Minga never sees your login."
  ]
)
```

The row shows your route's current readiness. Selecting it runs your `availability/2` check off the editor process and shows "Checking Claude…" while it runs. Minga uses `short_name` inside sentences like this one and `display_name` for picker rows and model labels; without a `short_name`, sentences use the display name. The result is your own text: `{:ready, account}` shows the account label, so put the plan in it if you know it ("me@example.com · Max plan"), and `{:unavailable, reason, remedy}` shows your remedy, so make it the exact command to run ("Not signed in. Run: claude auth login"). The row never asks for a secret.

### Reporting plan usage

Subscription plans have limit windows, such as five hours and seven days. When your route learns how much of a window is used, report it through the reporter:

```elixir
Minga.Extension.ModelRoutes.report_usage(reporter, [
  %{kind: "five_hour", utilization: 0.82, resets_at: ~U[2026-11-21 23:40:00Z], status: :warning},
  %{kind: "seven_day", utilization: 0.31, resets_at: nil, status: :allowed}
])
```

Each window has a `kind` (`"five_hour"` and `"seven_day"` read as 5h and 7d), `utilization` from 0 to 1, `resets_at` as a `DateTime` or nil, and `status`: `:allowed`, `:warning` as the limit approaches, or `:rejected` once requests are refused. Usage is kept separately from availability, so neither report erases the other. Report an empty list when you have no data; Minga then shows nothing rather than a guess.

Minga uses the busiest window to show usage on your model's row in `/model`, for example "82% of 5h limit · resets 3:40 PM". When a turn fails and your `classify_error/1` returns `:rate_limited` or `:usage_limit_reached` while a window is `:rejected`, Minga treats the failure as a usage limit: it does not retry, and the chat says "Your Claude usage limit is reached. It resets at 3:40 PM. Choose another model with /model to continue now." The reset is left out when the window has none, and it names the day when it is not today. Return `:usage_limit_reached` without a rejected window only when your route knows the plan refused the request; Minga then shows your own sentence. A plain `:rate_limited` with no rejected window keeps your sentence and reads as a transient rate limit. In both usage-limit cases the macOS app shows a "Choose another model" notification action that opens `/model` and keeps the draft. In the terminal, run `/model` to switch. Each report also publishes an `:inference_route_status_changed` event so editor chrome can update.

### Conversation identity

Every request carries `Request.conversation`, a `MingaAgent.InferenceRoute.ConversationRef`. For a normal turn, `purpose` is `:turn` and `session_id`, `epoch_id`, `conversation_revision`, and `request_id` come from Minga's session. `epoch_id` changes on branch, reset, or compaction, and the revision changes when the saved history changes. Tool follow-ups inside one turn keep the same `request_id`, epoch, and revision; tell them apart by the messages you receive. Use these values to decide whether you are continuing a conversation you already know or starting fresh. Minga does not try to guess that for you.

Compaction sends a request with `purpose: :summary` and no tools. Treat `:summary` and `:title` requests as isolated queries: do not continue or record a session from them. If you declare `compaction: :unsupported`, Minga refuses to compact for your route instead.

### Credentials

Minga passes a `MingaAgent.InferenceRoute.Credential` holding the `routes.<route_id>.env` map from `credentials.json` as `Request.credential` and as the second argument of `availability/2`. Core never interprets it and never logs its values. See [Configuration](CONFIGURATION.md#route-credentials) for the file format. If your route signs in through its own tool, keep that login in the tool; Minga never reads or copies another tool's login.

### Usage and cost

With `usage: :tokens`, the counts in your `{:usage, usage}` event appear in Minga's usage totals. The last usage event in a stream wins. With `cost: :subscription`, Minga shows no per-request dollar cost.

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

## Agent Session Observation (`Minga.Extension.AgentAPI`)

`Minga.Extension.AgentAPI` is the stable, read-only facade that extensions use to query agent session state. Extensions should not import `MingaAgent.Session` or `MingaAgent.SessionManager` directly; the facade shields them from internal refactors while providing a stable map-based contract.

All functions are safe to call with dead PIDs, stopped sessions, or when no session manager is running. They return empty results rather than crashing.

### Runtime callbacks and source-owned work

Use `editor_event_handler/3` for the retained callback families: `:buffer_saved`, `:editor_action`, and `:source_unload`. Buffer-save handlers run as an ordered fan-out. Editor actions stop at the first `{:handled, state}` and continue only after `:not_matched`. Source-unload handlers run only for the extension being disabled.

Dynamic extension callbacks cross `Minga.Extension.CallbackInvoker`. Exceptions, throws, exits, unavailable modules, and invalid return values become explicit callback failures and are reported without turning into a second callback protocol. Core callbacks execute directly and retain normal OTP crash behavior. Extension commands and editor handlers should return the documented state shape rather than rescuing framework failures themselves.

Slow picker, Git, and similar work must be represented as a typed `MingaEditor.Effect` request. `MingaEditor.EffectScheduler` owns worker supervision, resource ordering, cancellation, and result application. Tag requests with the extension source so disable can cancel them before presentation and callback registrations are removed. Do not spawn an untracked task and send a custom result message to the Editor.

### Listing sessions

`list_sessions/0` returns a summary for every registered agent session. Available sessions include their observed metadata:

```elixir
sessions = Minga.Extension.AgentAPI.list_sessions()
# => [%{id: "1", pid: #PID<0.1234.0>, status: :thinking, label: "refactor auth",
#       model: "claude-4", active_tool: "edit_file", created_at: ~U[2026-05-23 ...]}]
```

When a registered session cannot return metadata, its entry remains visible with a safe reason. Metadata-dependent fields are absent rather than invented:

```elixir
[%{id: "1", pid: #PID<0.1234.0>, availability: :unavailable,
   reason: :timeout | :unreachable | :invalid_details}]
```

Returns `[]` when no sessions are registered or the session manager is unavailable.

### Getting session details

`session_info/1` returns detailed info for a single session, including cost, token usage, turn count, and files touched.

```elixir
case Minga.Extension.AgentAPI.session_info(pid) do
  {:ok, info} ->
    IO.inspect(info.cost)
    IO.inspect(info.files_touched)
    # info keys: id, pid, status, label, model, active_tool, created_at,
    #            cost, input_tokens, output_tokens, turn_count, files_touched

  {:error, :not_found} ->
    IO.puts("Session not found or PID is dead")
end
```

### Subscribing to lifecycle and edit events

`subscribe/0` subscribes the calling process to agent lifecycle events, and `subscribe_edits/0` subscribes to buffer edit events in the standard `{:minga_event, topic, payload}` format:

```elixir
Minga.Extension.AgentAPI.subscribe()
Minga.Extension.AgentAPI.subscribe_edits()

receive do
  {:minga_event, :agent_session_stopped, %MingaAgent.SessionManager.SessionStoppedEvent{} = event} ->
    IO.inspect(event.session_id)

  {:minga_event, :buffer_changed, %Minga.Events.BufferChangedEvent{source: {:minga, task_id, step}} = event} ->
    IO.inspect({event.buffer, task_id, step})
end
```

An edit Minga makes during a task carries the author key `{:minga, task_id, step}` (see `Minga.Buffer.Author`): the task is the agent session, and the step is the tool call that made the edit. An agent edit made outside a task carries the legacy `{:agent, pid, call_id}` source.

- `topic` is an atom such as `:agent_session_stopped`, `:agent_hook`, or `:buffer_changed`.
- `payload` is a typed struct specific to the topic (see `Minga.Events` for the full list of payload structs).

---

## Compatibility Notes

The following removed Layer 2 delegates and deprecated theme keys were retired during core cleanups. Update existing extension or config code to use the canonical modules and keys:

- `MingaEditor.UI.Popup.Registry` has been removed. Use `Minga.Config.popup/2` for normal popup declarations, or `Minga.Popup.Registry` for direct registry operations.
- `MingaEditor.UI.Popup.Rule` has been removed. Use `Minga.Popup.Rule.new/2`, `%Minga.Popup.Rule{}`, or `Minga.Config.popup/2` for normal declarations.
- `MingaEditor.UI.Highlight.InjectionRange` has been removed. Construct injection ranges with `Minga.Language.Highlight.InjectionRange.new/3` or `%Minga.Language.Highlight.InjectionRange{}` directly.
- `MingaEditor.UI.Highlight.Grammar` has been removed. Use `Minga.Language.Grammar` for grammar registry initialization, runtime filetype registration, unregistering, filetype lookup, query lookup, query reading, and dynamic grammar paths (`Minga.Language.Grammar.query_path/1` replaces `highlight_query_path/1`).
- Theme override sections `:picker` and `:minibuffer` have been removed. Configure picker and minibuffer chrome through `:popup` colors instead.
- Theme fields `editor.tilde_fg`, `tree.modified_fg`, and `tree.git_conflict_fg` have been removed. Valid overrides for those deprecated keys are still parsed and ignored while invalid values still fail color validation; use live popup, tree, git, or gutter fields instead.

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
