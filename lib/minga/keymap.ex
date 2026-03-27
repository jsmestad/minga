defmodule Minga.Keymap do
  @moduledoc """
  Keymap domain facade.

  Manages key bindings across editor modes, scopes, and filetypes.
  Internally backed by a trie data structure (`Keymap.Bindings`) for
  prefix-matching key sequences, and an ETS-backed GenServer
  (`Keymap.Active`) for live binding state that merges defaults with
  user overrides.

  External callers use this facade for binding lookups, key resolution,
  and runtime rebinding. The `Keymap.Bindings` trie type appears in
  specs across mode dispatch and input handling code.
  """

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.Scope

  @typedoc "Supported editor modes."
  @type mode :: :normal | :insert | :visual | :command

  # ── Binding lookup ─────────────────────────────────────────────────

  @doc "Returns the merged leader trie (defaults + user overrides)."
  @spec leader_trie() :: Bindings.node_t()
  defdelegate leader_trie, to: Active

  @doc "Returns the merged normal-mode single-key bindings."
  @spec normal_bindings() :: %{Bindings.key() => {atom(), String.t()}}
  defdelegate normal_bindings, to: Active

  @doc "Returns the mode-specific trie for the given mode."
  @spec mode_trie(atom()) :: Bindings.node_t()
  defdelegate mode_trie(mode), to: Active

  @doc "Returns the filetype-scoped trie (SPC m bindings)."
  @spec filetype_trie(atom()) :: Bindings.node_t()
  defdelegate filetype_trie(filetype), to: Active

  @doc "Returns the scope-specific trie for a given scope and vim state."
  @spec scope_trie(Scope.scope_name(), Scope.vim_state()) :: Bindings.node_t()
  defdelegate scope_trie(scope, vim_state), to: Active

  @doc """
  Resolves a single key press against a mode's merged bindings.

  Checks mode-specific trie first, then normal overrides. Returns
  `{:command, name, desc}`, `{:prefix, node}`, or `:unbound`.
  """
  @spec resolve_binding(atom(), atom() | nil, Bindings.key()) ::
          {:command, atom()} | :not_found
  defdelegate resolve_binding(mode, filetype, key), to: Active, as: :resolve_mode_binding

  # ── Key resolution (scoped dispatch) ───────────────────────────────

  @doc """
  Resolves a key press within a scope (e.g., `:editor`, `:agent`, `:file_tree`).

  Checks scope-specific bindings first, then falls through to the
  scope's fallback chain. Returns `{:command, name, desc}`,
  `{:prefix, node}`, or `:unbound`.
  """
  @spec resolve_scoped_key(Scope.scope_name(), Scope.vim_state(), Bindings.key(), keyword()) ::
          Scope.resolve_result()
  defdelegate resolve_scoped_key(scope, vim_state, key, context \\ []),
    to: Scope,
    as: :resolve_key

  # ── Runtime rebinding ──────────────────────────────────────────────

  @doc "Binds a key sequence to a command in the given mode."
  @spec bind(atom() | {atom(), atom()}, String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  defdelegate bind(mode, key_str, command, description), to: Active

  @doc "Binds a key sequence with options (e.g., `filetype:`)."
  @spec bind(atom() | {atom(), atom()}, String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  defdelegate bind(mode, key_str, command, description, opts), to: Active

  @doc "Removes a key binding from a mode."
  @spec unbind(atom(), String.t()) :: :ok | {:error, String.t()}
  defdelegate unbind(mode, key_str), to: Active

  @doc "Resets all bindings to defaults (discards user overrides)."
  @spec reset() :: :ok
  defdelegate reset, to: Active

  # ── Default bindings ───────────────────────────────────────────────

  @doc "Returns the default leader trie (before user overrides)."
  @spec default_leader_trie() :: Bindings.node_t()
  defdelegate default_leader_trie, to: Defaults, as: :leader_trie

  @doc "Returns all default bindings as a flat list."
  @spec default_bindings() :: [{[Bindings.key()], atom(), String.t()}]
  defdelegate default_bindings, to: Defaults, as: :all_bindings

  @doc "Returns the default normal-mode single-key bindings."
  @spec default_normal_bindings() :: %{Bindings.key() => {atom(), String.t()}}
  defdelegate default_normal_bindings, to: Defaults, as: :normal_bindings
end
