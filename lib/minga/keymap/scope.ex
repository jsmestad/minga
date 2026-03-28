defmodule Minga.Keymap.Scope do
  @moduledoc """
  Behaviour and resolution logic for buffer-type-specific keybindings.

  A keymap scope determines which keybindings are active based on the type of
  view the user is interacting with. Think of scopes as Neovim's which-key
  groups: flat, explicit declarations of what keys do in a given context.

  ## Design rules

  The keymap follows Neovim's flat model, not Emacs's composed hierarchy.
  See AGENTS.md § "Keymap Architecture" for the full rationale. Three rules:

  1. **Keymap is the single authority.** If a key resolves through a scope
     trie, the command runs. Commands never re-check context internally.
     Don't bind a command in a scope where it shouldn't run.

  2. **Scopes are flat.** No implicit inheritance or minor-mode stacking.
     Shared bindings come in through bulk registration helpers that merge
     named binding groups at compile time. See #1278.

  3. **Derived scope.** The active scope should follow from what's on screen,
     not from a manually managed field. (Target architecture; today
     `workspace.keymap_scope` is still a field.)

  ## Built-in scopes

  * `:editor` — normal text editing (default)
  * `:agent` — agent chat view (Board zoom or side panel)
  * `:file_tree` — file tree panel
  * `:git_status` — git status panel

  ## Resolution layers

  Each scope module implements this behaviour and declares its own keybindings
  as trie data. Keymap resolution walks layers in priority order:

  1. User overrides for the active scope + vim state
  2. Vim-state-specific bindings from the scope module
  3. Shared bindings that apply across all vim states for the scope
  4. `:not_found` (caller decides what to do: self-insert, passthrough, etc.)

  Global bindings (leader sequences, Ctrl+S) and the Mode FSM fallback are
  handled by the caller, not by this module.

  ## Context parameter

  The `keymap/2` callback receives a `context` keyword list. Phase 1 always
  passes `[]`. Phase 2 (#215) will pass `[filetype: :elixir]` so the editor
  scope can return filetype-specific bindings. Agent and file_tree scopes
  ignore context.
  """

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings

  @typedoc "Extra context for scope keymap resolution (e.g., filetype)."
  @type context :: keyword()

  @typedoc "A scope name atom."
  @type scope_name :: :editor | :agent | :file_tree | :git_status

  @typedoc "Vim state relevant to scope resolution."
  @type vim_state :: :normal | :insert | :input_normal | :cua

  @typedoc "A single help binding: `{key_string, description}`."
  @type help_binding :: {String.t(), String.t()}

  @typedoc "A group of help bindings with a category label."
  @type help_group :: {String.t(), [help_binding()]}

  @typedoc """
  Result of resolving a key through the scope system.

  * `{:command, atom()}` — execute this named command
  * `{:prefix, Bindings.node_t()}` — key is a prefix; more keys needed
  * `:not_found` — scope has no binding for this key
  """
  @type resolve_result ::
          {:command, atom()}
          | {:prefix, Bindings.node_t()}
          | :not_found

  # ── Behaviour callbacks ────────────────────────────────────────────────────

  @doc "Returns the atom name of this scope (e.g., `:agent`)."
  @callback name() :: scope_name()

  @doc "Returns a human-readable name for display (e.g., \"Agent\")."
  @callback display_name() :: String.t()

  @doc """
  Returns the keybinding trie for a specific vim state.

  The `context` parameter is a keyword list that phase 1 passes as `[]`.
  Phase 2 will pass `[filetype: :elixir]` for filetype-specific bindings.
  """
  @callback keymap(vim_state(), context()) :: Bindings.node_t()

  @doc """
  Returns bindings that apply regardless of vim state.

  These are checked after vim-state-specific bindings but before global
  bindings. Useful for keys like Ctrl+C (abort) that work the same in
  both normal and insert mode within a scope.
  """
  @callback shared_keymap() :: Bindings.node_t()

  @doc """
  Returns categorized help groups for the `?` help overlay.

  Each group is a `{category_label, [{key_string, description}]}` tuple.
  The `focus` parameter lets scopes return different help content depending
  on the current UI context (e.g., `:chat` vs `:file_viewer` in the agent
  scope).

  Return `[]` to indicate no help overlay is available for this scope.
  """
  @callback help_groups(focus :: atom()) :: [help_group()]

  @doc "Called when this scope becomes active. Initialize scope-specific state."
  @callback on_enter(state :: term()) :: term()

  @doc "Called when this scope is deactivated. Clean up scope-specific state."
  @callback on_exit(state :: term()) :: term()

  # ── Registry ───────────────────────────────────────────────────────────────

  @scope_modules %{
    editor: Minga.Keymap.Scope.Editor,
    agent: Minga.Keymap.Scope.Agent,
    file_tree: Minga.Keymap.Scope.FileTree,
    git_status: Minga.Keymap.Scope.GitStatus
  }

  @doc "Returns the scope module for a given scope name."
  @spec module_for(scope_name()) :: module() | nil
  def module_for(name) when is_atom(name), do: Map.get(@scope_modules, name)

  @doc "Returns all registered scope names."
  @spec all_scopes() :: [scope_name()]
  def all_scopes, do: Map.keys(@scope_modules)

  # ── Help ────────────────────────────────────────────────────────────────────

  @doc """
  Returns help groups for the given scope and focus context.

  Delegates to the scope module's `help_groups/1` callback.
  Returns `[]` if the scope is not found.
  """
  @spec help_groups(scope_name(), atom()) :: [help_group()]
  def help_groups(scope_name, focus \\ :default) do
    case module_for(scope_name) do
      nil -> []
      mod -> mod.help_groups(focus)
    end
  end

  # ── Resolution ─────────────────────────────────────────────────────────────

  @doc """
  Resolves a key through the scope's keybinding layers.

  Walks layers in priority order:
  1. User overrides for the scope + vim state (from `Keymap.Active`)
  2. Vim-state-specific bindings for the active scope
  3. Shared bindings for the active scope
  4. Returns `:not_found` if no scope binding matches

  Global bindings (leader sequences, Ctrl+S) and Mode.process fallback are
  handled by the caller, not by this function.
  """
  @spec resolve_key(scope_name(), vim_state(), Bindings.key(), context()) :: resolve_result()
  def resolve_key(scope_name, vim_state, key, context \\ []) do
    case module_for(scope_name) do
      nil -> :not_found
      mod -> resolve_through_layers(mod, scope_name, vim_state, key, context)
    end
  end

  @spec resolve_through_layers(module(), scope_name(), vim_state(), Bindings.key(), context()) ::
          resolve_result()
  defp resolve_through_layers(mod, scope_name, vim_state, key, context) do
    tries = [
      # Layer 0: user overrides for this scope + vim state
      user_scope_trie(scope_name, vim_state),
      # Layer 1: vim-state-specific bindings from the scope module
      mod.keymap(vim_state, context),
      # Layer 2: shared bindings (cross vim-state)
      mod.shared_keymap()
    ]

    Enum.find_value(tries, :not_found, fn trie ->
      case Bindings.lookup(trie, key) do
        :not_found -> nil
        result -> result
      end
    end)
  end

  @spec user_scope_trie(scope_name(), vim_state()) :: Bindings.node_t()
  defp user_scope_trie(scope_name, vim_state) do
    KeymapActive.scope_trie(scope_name, vim_state)
  catch
    :exit, _ -> Bindings.new()
  end

  @doc """
  Resolves a key against a specific trie node (for multi-key sequences).

  Used when continuing a prefix sequence within a scope. The caller tracks
  which trie node to continue from.
  """
  @spec resolve_key_in_node(Bindings.node_t(), Bindings.key()) :: resolve_result()
  def resolve_key_in_node(node, key) do
    Bindings.lookup(node, key)
  end
end
