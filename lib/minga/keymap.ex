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

  ## Server-aware API

  Every binding-lookup and runtime-rebinding function takes an optional
  `server` argument. When omitted, calls go to the singleton process
  registered under the `default_server/0` name. Pass an explicit server
  (pid or registered name) to target an isolated instance, e.g. per-test
  fixtures or future per-tab keymaps.
  """

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.Scope

  @typedoc "Supported editor modes."
  @type mode :: :normal | :insert | :visual | :command

  @typedoc "Reference to a Keymap.Active GenServer (registered name or pid)."
  @type server :: GenServer.server()

  # Single source of truth for the default registered Keymap.Active. Other
  # modules should call `default_server/0` rather than referencing `Active`
  # directly so future renames or alternate defaults stay localized here.
  @default_server Active

  @doc "Returns the registered name of the default keymap server."
  @spec default_server() :: server()
  def default_server, do: @default_server

  # ── Binding lookup ─────────────────────────────────────────────────

  @doc "Returns the merged leader trie (defaults + user overrides)."
  @spec leader_trie(server()) :: Bindings.node_t()
  defdelegate leader_trie(server \\ @default_server), to: Active

  @doc "Returns the merged normal-mode single-key bindings."
  @spec normal_bindings(server()) :: %{Bindings.key() => {atom(), String.t()}}
  defdelegate normal_bindings(server \\ @default_server), to: Active

  @doc "Returns the mode-specific trie for the given mode."
  @spec mode_trie(server(), atom()) :: Bindings.node_t()
  def mode_trie(server \\ @default_server, mode), do: Active.mode_trie(server, mode)

  @doc "Returns the filetype-scoped trie (SPC m bindings)."
  @spec filetype_trie(server(), atom()) :: Bindings.node_t()
  def filetype_trie(server \\ @default_server, filetype),
    do: Active.filetype_trie(server, filetype)

  @doc "Returns the scope-specific trie for a given scope and vim state."
  @spec scope_trie(server(), Scope.scope_name(), Scope.vim_state()) :: Bindings.node_t()
  def scope_trie(server \\ @default_server, scope, vim_state),
    do: Active.scope_trie(server, scope, vim_state)

  @doc """
  Resolves a key press against a mode's merged bindings.

  Checks mode-specific trie first, then normal overrides.
  Returns `{:command, atom()}` when a command is found, or `:not_found`.
  """
  @spec resolve_binding(server(), atom(), atom() | nil, Bindings.key()) ::
          {:command, atom()} | :not_found
  def resolve_binding(server \\ @default_server, mode, filetype, key),
    do: Active.resolve_mode_binding(server, mode, filetype, key)

  # ── Key resolution (scoped dispatch) ───────────────────────────────

  @doc """
  Resolves a key press within a scope (e.g., `:editor`, `:agent`, `:file_tree`).

  Checks scope-specific bindings first, then falls through to the
  scope's fallback chain. Returns `Scope.resolve_result()`:
  `{:command, atom()}`, `{:prefix, Bindings.node_t()}`, or `:not_found`.
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
  def bind(mode, key_str, command, description),
    do: Active.bind(@default_server, mode, key_str, command, description, [])

  @doc "Binds a key sequence with options (e.g., `filetype:`)."
  @spec bind(atom() | {atom(), atom()}, String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def bind(mode, key_str, command, description, opts) when is_list(opts),
    do: Active.bind(@default_server, mode, key_str, command, description, opts)

  @doc "Binds a key sequence on an explicit keymap server."
  @spec bind(server(), atom() | {atom(), atom()}, String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  defdelegate bind(server, mode, key_str, command, description, opts), to: Active

  @doc "Removes a key binding from a mode."
  @spec unbind(server(), atom(), String.t()) :: :ok | {:error, String.t()}
  def unbind(server \\ @default_server, mode, key_str),
    do: Active.unbind(server, mode, key_str)

  @doc "Resets all bindings to defaults (discards user overrides)."
  @spec reset(server()) :: :ok
  defdelegate reset(server \\ @default_server), to: Active

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
