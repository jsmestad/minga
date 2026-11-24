# Keymap Scopes

In Minga, what a key does depends on what is on screen. `y` copies text in a file, copies a code block in the agent view, and confirms a discard in the Git status list. `q` records a macro in a file and closes the file tree. You never switch these meanings yourself: the focused view decides, and leader keys (`SPC`) mean the same thing everywhere you are not typing text. A keymap scope is the name for one such set of meanings, and this guide explains how Minga picks the scope and resolves a key inside it.

This is the guide to how it works. If you want to know what a key does, read the [Key reference](AGENTIC-KEYMAP.md), which lists the keys Minga ships by where you are. Come back here when you want to rebind a key in one kind of view, add a scope from an extension, or understand why a key did not reach the command you expected.

Scopes determine which trie bindings are active based on the type of view you're in. They work inside the shell's ordered input-handler chain, alongside dedicated handlers for overlays, sub-states, navigation, mouse input, and editing-model fallback.

If you're coming from **Emacs**, keymap scopes are Minga's equivalent of major modes. A keymap scope is set per-view and determines which keys do what, just like `python-mode` or `magit-status-mode` provide buffer-type-specific keymaps. If you're coming from **Vim**, think buffer-local keymaps. If you're from **VS Code**, think keybinding contexts (the `when` clauses in `keybindings.json`).

## Built-in scopes

Minga ships these scopes:

| Scope | Active when | Purpose |
|-------|-------------|---------|
| `:editor` | Editing files (default) | All normal vim editing. No scope-specific bindings; the full mode system (normal, insert, visual, etc.) handles everything. |
| `:agent` | The agent view (`SPC a a`) | Agent chat navigation, fold/collapse, copy, search, panel management. The [Key reference](AGENTIC-KEYMAP.md#in-the-agent-view) lists its keys. |
| `:file_tree` | File tree panel is focused | Tree-specific keys (Enter, h/l, H, r). Unmatched keys delegate to vim motions for navigation. |
| `:git_status` | Git status panel is focused | Staging, committing and navigation keys for the panel. The panel itself comes from the optional GitExtended extension. |
| `:picker` | A picker is open (find file, project search, the buffer switcher) | `⌃J` / `⌃K` and the arrows move, `↩` opens, `esc` closes, `Tab` completes, `PageUp` / `PageDown` page, `⌃.` opens the act menu on the highlighted row, and `⌃V` opens the highlighted buffer in a split from the buffer switcher. Every other key edits the query. |
| `:prompt` | A minibuffer prompt or the `:` command line has focus | `↩` runs, `esc` cancels, `Tab` completes; `⌃J` / `⌃K` move through the command line's completions. Every other key edits the text. |

### Live prompts

Pickers and prompts are live prompts: typing always edits the query, so their scopes bind only the established list conventions from the [key design](design/keys.md). The readline keys are text editing, not bindings: `⌃A` and `⌃E` move to the start and end of the line, `⌃H` deletes a character, `⌃W` the word before the cursor, `⌃U` everything before it, and `⌃K` everything after it in a prompt without a list. Both scopes declare their keys only in the `:insert` vim state, because a prompt always takes text and the CUA profile never applies to one.

`MingaEditor.PickerUI` and `MingaEditor.PromptUI` resolve keys through these scopes, so a user override such as `bind {:picker, :insert}, "C-n", :picker_next, "Next"` works there. On macOS the native picker query field forwards only the picker conventions (`⌃J`, `⌃K`, `⌃V`, `⌃.`) and keeps other control keys for itself, so an override on another chord reaches the BEAM only from the terminal frontend. The `:` command line is a pure mode and reads the default `:prompt` trie directly, so overrides do not reach it.

## How resolution works

When you press a key, the active shell runs an ordered handler chain. Modal overlays run first. Dedicated surface and sub-state handlers can then consume input before `Input.Scoped`. If the key reaches `Input.Scoped`, scope bindings resolve in this order:

1. **User scope overrides** for the active scope and vim state. These are bindings you define in `config.exs` targeting a specific scope.
2. **Scope-specific bindings** from the scope module for the active vim state.
3. **Shared scope bindings** that apply regardless of vim state within the scope.

If no scope binding matches, later surface handlers run. These include agent navigation, global bindings, bottom-panel input, and agent mouse handling. The editing-model fallback runs last. For the `:editor` scope, that fallback is the Vim or CUA mode system. For `:file_tree`, unmatched keys reach the mode fallback with the tree buffer active, which provides Vim navigation such as j/k, gg/G, and Ctrl-d/u.

### The agent view and its composer

`SPC a a` runs `:toggle_agentic_view`. It switches to the agent view and activates the `:agent` scope, or returns to the editor context it recorded when you left. It has no other meaning. `SPC a v` (`:toggle_agent_split`) runs the same toggle today.

Agent scope bindings are trie data in `Minga.Keymap.Scope.Agent`, with one trie per state: `:normal` for chat navigation, `:insert` and `:input_normal` for the composer, and `:cua` for the desktop shortcut profile. The scope adds keys from context, so `y`, `x`, `Y` and `X` decide changes only while a Diff Review has focus, and `r` runs a failed start's remedy only while one is offered.

Several handlers run before `Input.Scoped` reaches that trie:

- **Tool approval and @-mention completion** are separate handlers, so `y` on a pending approval never reaches the copy binding. Diff review is not a handler: its keys are context bindings in the agent trie, as described above.
- **`MingaEditor.Input.AgentPanel`** owns the composer. While the composer is focused in Insert mode, or with desktop shortcuts, it resolves the `:insert` or `:cua` bindings and applies text input, in the agent view and in any layout that shows an agent chat pane beside a file. In Normal, Visual and operator-pending states only Tab and a failed start's remedy key resolve first; every other key goes through the standard mode FSM against the prompt buffer, which is why Vim motions and operators edit a draft and why `q` records a macro there.

Scrolling keys (`j`, `k`, `G`, `⌃D`, `⌃U`) are deliberately not in the agent trie. They pass through to `MingaEditor.Input.AgentNav`, which updates the transcript's scroll state. The `?` help overlay content comes from `Scope.Agent.help_groups/1`.

### Why the agent view repurposes Vim keys

The conversation is a read-only special buffer, and it follows the Doom Emacs and Evil convention for those: motions stay, and editing keys that have no meaning in a read-only buffer become contextual actions. Magit does the same (`s` stages, `q` closes, `Tab` toggles a section), and so does org-agenda.

1. **Vim motions stay.** `j`/`k`, `gg`/`G`, `⌃D`/`⌃U`, `/`, `n`/`N` work as a Vim user expects.
2. **Editing keys are repurposed.** `i`/`a` focus the composer (the parallel to entering Insert mode), `y` copies structured content, and `q`/`esc` return to the editor context for the same workspace.
3. **Standard prefixes carry multi-key sequences.** `z` for collapse, `]`/`[` for next and previous, `g` for go-to. A prefix the agent trie claims never falls through to the mode FSM, so every sub-binding under `g`, `z`, `]` and `[` is declared in the scope.
4. **Pending input owns the keyboard.** Once a leader sequence, an operator, or the describe-key prompt (`SPC h k`) is pending, every key goes to it, so `SPC h k` followed by `q` describes `q` instead of closing the chat. The same holds while the command line, search, or eval prompt is open. Tool approval and diff review keys do not act while a command line or key sequence owns the key, so `:x` never rejects a hunk.
5. **Nothing leaks to the file behind the chat.** From chat navigation and the file viewer, only `SPC`, `:`, `/`, `n` and `N` enter the mode FSM. Every other unbound key stops in `AgentNav`. It never edits, or moves focus to, the file buffer behind the chat. In the CUA profile the same rule ignores an undo or paste chord that arrives as a key. On macOS, ⌘S, ⌘Z, ⌘X, ⌘C and ⌘V are menu commands, not keys, so the rule does not filter them and they act on the active buffer as they do from any other surface.

Keys with a standard Vim meaning that the agent view does not use are reserved, not free: `h`/`l`, the word motions, `f`/`F`/`t`/`T`, `H`/`M`/`L`, the editing operators `d`/`c`, and `p`/`P`. They do nothing in the conversation today, and they will not be given unrelated meanings.

## Leader sequences (SPC) always work

Leader sequences pass through to the mode FSM regardless of which scope is active. In every scope:

- **SPC** opens the which-key popup (when input is not focused)
- All leader sequences (`SPC f f`, `SPC b b`, `SPC w v`, etc.) work identically
- The which-key popup shows the same leader key tree

The exceptions are places where Space is text. In the agent composer's insert mode, SPC types a space; press ESC first to return to normal mode, then use SPC for leader keys. Pickers and prompts take every printable key as text.

## Filetype-scoped bindings (SPC m)

The `SPC m` prefix is reserved for filetype-specific leader bindings. When you press `SPC m`, the which-key popup shows bindings specific to the current buffer's filetype.

Define filetype bindings in your `config.exs`:

```elixir
use Minga.Config

# Option 1: keymap block (recommended for multiple bindings)
keymap :elixir do
  bind :normal, "SPC m t", :mix_test, "Run tests"
  bind :normal, "SPC m f", :mix_format, "Format with mix"
  bind :normal, "SPC m r", :iex_run, "Run in IEx"
end

keymap :markdown do
  bind :normal, "SPC m p", :markdown_preview, "Preview"
end

# Option 2: explicit filetype option (one-off bindings)
bind :normal, "SPC m t", :go_test, "Run go test", filetype: :go
```

Different filetypes can use the same sub-key. `SPC m t` runs `mix test` in an Elixir buffer but `go test` in a Go buffer.

## Customizing bindings

### Per-mode bindings

You can bind keys in any vim mode, not just normal:

```elixir
use Minga.Config

# Normal mode (leader and single-key)
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "Q", :replay_last_macro, "Replay last macro"

# Insert mode
bind :insert, "C-j", :next_line, "Next line"
bind :insert, "C-k", :prev_line, "Previous line"

# Visual mode
bind :visual, "C-x", :custom_cut, "Custom cut"

# Operator-pending mode
bind :operator_pending, "C-a", :select_all, "Select all"

# Command mode
bind :command, "C-p", :history_prev, "Previous history entry"
```

### Per-scope bindings

Override or extend scope-specific bindings:

```elixir
use Minga.Config

# Override agent scope keys
bind {:agent, :normal}, "y", :my_custom_yank, "Custom yank"
bind {:agent, :normal}, "~", :toggle_debug, "Toggle debug"

# Override file tree scope keys
bind {:file_tree, :normal}, "d", :tree_delete, "Delete file"
```

### Resolution order

When resolving a key, Minga checks these sources in order:

1. **User filetype** bindings (for `SPC m` prefix)
2. **User scope overrides** (for scope-specific keys)
3. **User per-mode overrides** (for mode-specific keys)
4. **Built-in scope defaults**
5. **Built-in mode defaults**

The first match wins. This means your config always takes priority over built-in defaults.

## Scope lifecycle

Each scope module can define `on_enter/1` and `on_exit/1` callbacks for setup and teardown when the scope becomes active or deactivates. Currently these are identity functions (no-ops), but they're available for future use.

## Architecture

Each scope is a module implementing the `Minga.Keymap.Scope` behaviour:

```elixir
@callback name() :: scope_name()
@callback display_name() :: String.t()
@callback keymap(vim_state(), context()) :: Bindings.node_t()
@callback shared_keymap() :: Bindings.node_t()
@callback help_groups(focus :: atom()) :: [help_group()]
@callback on_enter(state) :: state
@callback on_exit(state) :: state

# Optional
@callback included_groups() :: [atom() | {atom(), keyword()}]
@callback modal?() :: boolean()
```

`vim_state()` is `:normal | :insert | :input_normal | :cua`. `use Minga.Keymap.Scope.Builder` supplies `name/0`, `display_name/0` and `modal?/0` from its options. `included_groups/0` names the shared binding groups a scope merges in (`Minga.Keymap.SharedGroups`), which is how the same arrow-key navigation or newline keys reach several scopes without one scope inheriting from another.

Bindings are declared as trie data (using `Minga.Keymap.Bindings`) and resolved through `Minga.Keymap.Scope.resolve_key/4`. The `context` parameter in `keymap/2` carries facts about the focused surface that change the trie, such as `agent_diff_review`, `agent_start_remedy`, `picker_split` and `prompt_list`.

The `Input.Scoped` handler sits in the shell's surface handler list and routes remaining scope-owned keys through the appropriate scope based on `state.keymap_scope`. The full shell handler order is broader than the scope system: overlay handlers run first, dedicated surface and sub-state handlers such as mention completion, tool approval, agent panel, sidebar, popup, and CUA space-leader may consume input before `Input.Scoped`, then later surface handlers such as agent navigation, global bindings, bottom panel, agent mouse, and the editing-model fallback run after it.

```
Overlay handlers → earlier surface/sub-state handlers → Input.Scoped → later surface handlers → editing-model fallback
```

Scope trie bindings are unified under the scope system. Dedicated modal, sub-state, navigation, mouse, and fallback handlers remain separate shell-provided handlers.

## Relationship to future work

- **Minor modes** ([#216](https://github.com/jsmestad/minga/issues/216)): Toggleable keymap layers (like Emacs minor modes) can be added on top of scopes without restructuring anything. The resolution order will gain a new layer between user overrides and scope bindings.

## Key files

| File | Purpose |
|------|---------|
| `lib/minga/keymap/scope.ex` | Behaviour definition and resolution logic |
| `lib/minga/keymap/scope/editor.ex` | Editor scope (pass-through to mode system) |
| `lib/minga/keymap/scope/agent.ex` | Agent scope (trie-based bindings) |
| `lib/minga/keymap/scope/file_tree.ex` | File tree scope (trie-based bindings) |
| `lib/minga/keymap/scope/git_status.ex` | Git status scope (trie-based bindings) |
| `lib/minga/keymap/scope/picker.ex`, `scope/prompt.ex` | Picker and prompt scopes, built from `lib/minga/keymap/prompt_keys.ex` |
| `lib/minga/keymap/scope/builder.ex` | `use` macro that supplies the boilerplate callbacks and merges shared groups |
| `lib/minga/keymap/shared_groups.ex` | Named binding groups that several scopes include |
| `lib/minga/keymap/defaults.ex`, `normal_prefixes.ex` | Leader keys and the `g`, `z`, `]`, `[` sequences of Normal mode |
| `lib/minga_editor/input/agent_panel.ex`, `agent_nav.ex` | Composer input and conversation scrolling |
| `lib/minga_editor/input/scoped.ex` | Surface handler that routes through scopes |
| `lib/minga/keymap/active.ex` | Runtime keymap store (overrides, filetype, scope) |

## Keeping the key reference in step

The [Key reference](AGENTIC-KEYMAP.md) is written by hand from the files above. The pull request that ships, moves or removes a key updates that page in the same change, and the [design keymap](design/keys.md) stays the place for keys that are planned but not built.
