# Keymap Scopes

Keymap scopes determine which keybindings are active based on the type of view you're in. They replace the old approach of having per-view handlers in the focus stack, giving you a single, uniform system for all keybindings.

If you're coming from **Emacs**, keymap scopes are Minga's equivalent of major modes. A keymap scope is set per-view and determines which keys do what, just like `python-mode` or `magit-status-mode` provide buffer-type-specific keymaps. If you're coming from **Vim**, think buffer-local keymaps. If you're from **VS Code**, think keybinding contexts (the `when` clauses in `keybindings.json`).

## Built-in scopes

Minga ships three scopes:

| Scope | Active when | Purpose |
|-------|-------------|---------|
| `:editor` | Editing files (default) | All normal vim editing. No scope-specific bindings; the full mode system (normal, insert, visual, etc.) handles everything. |
| `:agent` | Full-screen agentic view (`SPC a t`) | Agent chat navigation, fold/collapse, copy, search, panel management. See [Agentic Keymap](AGENTIC-KEYMAP.md). |
| `:file_tree` | File tree panel is focused | Tree-specific keys (Enter, h/l, H, r). Unmatched keys delegate to vim motions for navigation. |

## How resolution works

When you press a key, Minga resolves it through layers in priority order:

1. **Modal overlays** (picker, completion, conflict prompt) intercept all keys when active. These are truly modal and sit above the scope system.
2. **Scope-specific bindings** for the active scope and vim state. For example, in the agent scope's normal mode, `j` is bound to `:agent_scroll_down`.
3. **Shared scope bindings** that apply regardless of vim state within the scope (e.g., a key that works the same in both normal and insert mode).
4. **Global bindings** (leader sequences via SPC, Ctrl+S, Ctrl+Q). These work in every scope.
5. **Mode FSM fallback** for the `:editor` scope. The existing vim mode system (motions, operators, text objects) handles everything the scope doesn't claim.

For the `:file_tree` scope, keys that don't match any scope binding also fall through to the mode FSM with the tree buffer swapped in as the active buffer. This gives you full vim navigation (j/k, gg/G, Ctrl-d/u, etc.) in the file tree for free.

### Agent side panel

The agent side panel (`SPC a a`) lives in the `:editor` scope. When visible, the `Input.Scoped` handler intercepts keys for the panel:

- **Input focused**: all keys go to the chat input field, using the same bindings as the agentic view's insert mode.
- **Navigation mode**: panel-specific keys (q to close, i to focus input, ESC to close) are handled directly. Everything else delegates to the mode FSM with the agent buffer, giving you full vim navigation of chat content.

This means leader sequences (`SPC f f`, `SPC b b`, etc.) work from inside the side panel just like anywhere else.

## Leader sequences (SPC) always work

Leader sequences pass through to the mode FSM regardless of which scope is active. In every scope:

- **SPC** opens the which-key popup (when input is not focused)
- All leader sequences (`SPC f f`, `SPC b b`, `SPC w v`, etc.) work identically
- The which-key popup shows the same leader key tree

The only exception: when the agent input field is focused (insert mode), SPC types a space character. Press ESC first to return to normal mode, then use SPC for leader keys.

## Scope lifecycle

Each scope module can define `on_enter/1` and `on_exit/1` callbacks for setup and teardown when the scope becomes active or deactivates. Currently these are identity functions (no-ops), but they're available for future use.

## Customizing bindings

You can override or extend scope-specific bindings in your `config.exs` using the standard `bind` function. Phase 1 supports global and leader key overrides. Phase 2 ([#215](https://github.com/jsmestad/minga/issues/215)) will add per-scope, per-vim-state, and per-filetype customization.

```elixir
use Minga.Config

# Global leader key bindings (work in all scopes)
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC g b", :git_blame, "Git blame"

# Phase 2 will add:
# bind :agent, :normal, "s", :agent_session_switcher, "Session switcher"
# bind :file_tree, :normal, "d", :tree_delete, "Delete file"
```

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

Bindings are declared as trie data (using `Minga.Keymap.Bindings`) and resolved through `Minga.Keymap.Scope.resolve_key/4`. The `context` parameter in `keymap/2` is a keyword list that phase 1 passes as `[]`. Phase 2 will pass `[filetype: :elixir]` so the editor scope can return filetype-specific bindings.

The `Input.Scoped` handler sits in the focus stack and routes keys through the appropriate scope based on `state.keymap_scope`. It also handles sub-states within a scope (search input, mention completion, tool approval, diff review) before trie lookup. The focus stack is now:

```
ConflictPrompt → Scoped → Picker → Completion → GlobalBindings → ModeFSM
```

Only truly modal overlays remain as separate handlers. All view-type-specific keybindings are unified under the scope system.

## Relationship to future work

- **Phase 2** ([#215](https://github.com/jsmestad/minga/issues/215)): Adds filetype-scoped `SPC m` bindings and per-vim-state user customization. The `Keymap.Active` store already has a `scope_overrides` map ready for this.
- **Minor modes** ([#216](https://github.com/jsmestad/minga/issues/216)): Toggleable keymap layers (like Emacs minor modes) can be added on top of scopes without restructuring anything. The resolution order will gain a new layer between user overrides and scope bindings.

## Key files

| File | Purpose |
|------|---------|
| `lib/minga/keymap/scope.ex` | Behaviour definition and resolution logic |
| `lib/minga/keymap/scope/editor.ex` | Editor scope (pass-through to mode system) |
| `lib/minga/keymap/scope/agent.ex` | Agent scope (trie-based bindings) |
| `lib/minga/keymap/scope/file_tree.ex` | File tree scope (trie-based bindings) |
| `lib/minga/input/scoped.ex` | Focus stack handler that routes through scopes |
| `lib/minga/keymap/active.ex` | Runtime keymap store (includes scope_overrides) |
