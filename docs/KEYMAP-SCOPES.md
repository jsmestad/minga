# Keymap Scopes

Keymap scopes determine which trie bindings are active based on the type of view you're in. They work inside the shell's ordered input-handler chain, alongside dedicated handlers for overlays, sub-states, navigation, mouse input, and editing-model fallback.

If you're coming from **Emacs**, keymap scopes are Minga's equivalent of major modes. A keymap scope is set per-view and determines which keys do what, just like `python-mode` or `magit-status-mode` provide buffer-type-specific keymaps. If you're coming from **Vim**, think buffer-local keymaps. If you're from **VS Code**, think keybinding contexts (the `when` clauses in `keybindings.json`).

## Built-in scopes

Minga ships three scopes:

| Scope | Active when | Purpose |
|-------|-------------|---------|
| `:editor` | Editing files (default) | All normal vim editing. No scope-specific bindings; the full mode system (normal, insert, visual, etc.) handles everything. |
| `:agent` | Full-screen agentic view (`SPC a t`) | Agent chat navigation, fold/collapse, copy, search, panel management. See [Agentic Keymap](AGENTIC-KEYMAP.md). |
| `:file_tree` | File tree panel is focused | Tree-specific keys (Enter, h/l, H, r). Unmatched keys delegate to vim motions for navigation. |

## How resolution works

When you press a key, the active shell runs an ordered handler chain. Modal overlays run first. Dedicated surface and sub-state handlers can then consume input before `Input.Scoped`. If the key reaches `Input.Scoped`, scope bindings resolve in this order:

1. **User scope overrides** for the active scope and vim state. These are bindings you define in `config.exs` targeting a specific scope.
2. **Scope-specific bindings** from the scope module for the active vim state.
3. **Shared scope bindings** that apply regardless of vim state within the scope.

If no scope binding matches, later surface handlers run. These include agent navigation, global bindings, bottom-panel input, and agent mouse handling. The editing-model fallback runs last. For the `:editor` scope, that fallback is the Vim or CUA mode system. For `:file_tree`, unmatched keys reach the mode fallback with the tree buffer active, which provides Vim navigation such as j/k, gg/G, and Ctrl-d/u.

### Agent side panel

The agent side panel (`SPC a a`) lives in the `:editor` scope. `MingaEditor.Input.AgentPanel` runs before `Input.Scoped` and owns focused prompt input plus panel navigation:

- **Input focused**: the panel handler resolves the agent prompt bindings and applies text input.
- **Navigation mode**: the panel handler consumes panel actions such as closing or focusing the prompt, and delegates or passes through other keys to the remaining handler chain.

Leader sequences such as `SPC f f` and `SPC b b` continue through the normal chain when the panel does not consume them.

## Leader sequences (SPC) always work

Leader sequences pass through to the mode FSM regardless of which scope is active. In every scope:

- **SPC** opens the which-key popup (when input is not focused)
- All leader sequences (`SPC f f`, `SPC b b`, `SPC w v`, etc.) work identically
- The which-key popup shows the same leader key tree

The only exception: when the agent input field is focused (insert mode), SPC types a space character. Press ESC first to return to normal mode, then use SPC for leader keys.

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
@callback name() :: :editor | :agent | :file_tree
@callback display_name() :: String.t()
@callback keymap(vim_state, context) :: Bindings.node_t()
@callback shared_keymap() :: Bindings.node_t()
@callback help_groups(focus :: atom()) :: [help_group()]
@callback on_enter(state) :: state
@callback on_exit(state) :: state
```

Bindings are declared as trie data (using `Minga.Keymap.Bindings`) and resolved through `Minga.Keymap.Scope.resolve_key/4`. The `context` parameter in `keymap/2` is reserved for future filetype parameterization of scope bindings.

The `Input.Scoped` handler sits in the shell's surface handler list and routes remaining scope-owned keys through the appropriate scope based on `state.keymap_scope`. The full shell handler order is broader than the scope system: overlay handlers run first, dedicated surface and sub-state handlers such as mention completion, tool approval, diff review, agent panel, sidebar, popup, and CUA space-leader may consume input before `Input.Scoped`, then later surface handlers such as agent navigation, global bindings, bottom panel, agent mouse, and the editing-model fallback run after it.

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
| `lib/minga_editor/input/scoped.ex` | Surface handler that routes through scopes |
| `lib/minga/keymap/active.ex` | Runtime keymap store (overrides, filetype, scope) |
