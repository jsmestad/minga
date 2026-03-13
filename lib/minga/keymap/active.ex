defmodule Minga.Keymap.Active do
  @moduledoc """
  Mutable keymap store backed by ETS for lock-free reads.

  Holds the active leader trie, per-mode binding overrides, filetype-scoped
  bindings, and per-scope overrides. Initialized from `Minga.Keymap.Defaults`
  on startup, then mutated by user config via `bind/4` and `bind/5`.

  Backed by ETS with `read_concurrency: true` so keystroke processing reads
  bindings without a GenServer round-trip. The GenServer exists only to own
  the ETS table lifecycle. Writes go directly to ETS (no serialization
  needed since binds only happen during config evaluation, which is
  single-threaded).

  ## Binding modes

  User bindings can target any vim mode:

  * `:normal` — leader sequences (SPC ...) and single-key overrides
  * `:insert` — single-key or multi-key sequences in insert mode
  * `:visual` — bindings active in visual mode
  * `:operator_pending` — bindings active in operator-pending mode
  * `:command` — bindings active in command mode

  ## Filetype-scoped bindings

  Bindings scoped to a filetype appear under the `SPC m` leader prefix. Pass
  `filetype: :elixir` to `bind/5` to register a binding that only activates
  when the active buffer's filetype matches.

  ## Per-scope overrides

  Bindings scoped to a keymap scope (`:agent`, `:file_tree`) override the
  defaults declared in the scope module. Pass a `{scope, vim_state}` tuple
  as the mode to target a specific scope.
  """

  use GenServer

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope

  @typedoc """
  Per-scope, per-vim-state binding overrides from user config.

  Outer key is the scope name, inner key is the vim state.
  """
  @type scope_overrides :: %{Scope.scope_name() => %{Scope.vim_state() => Bindings.node_t()}}

  @typedoc "Per-filetype binding tries for SPC m."
  @type filetype_tries :: %{atom() => Bindings.node_t()}

  @typedoc "Per-mode binding tries for insert, visual, operator_pending, command."
  @type mode_tries :: %{atom() => Bindings.node_t()}

  # ETS keys
  @leader_trie_key :leader_trie
  @normal_overrides_key :normal_overrides
  @scope_overrides_key :scope_overrides
  @filetype_tries_key :filetype_tries
  @mode_tries_key :mode_tries

  # ── GenServer (table lifecycle only) ────────────────────────────────────────

  @doc "Starts the keymap store and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl GenServer
  def init(name) do
    table = :ets.new(table_name(name), [:set, :public, :named_table, read_concurrency: true])
    seed_defaults(table)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:table_name, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  # ── Client API (reads go directly to ETS) ───────────────────────────────────

  @doc """
  Returns the current leader trie (defaults + user overrides).
  """
  @spec leader_trie() :: Bindings.node_t()
  @spec leader_trie(GenServer.server()) :: Bindings.node_t()
  def leader_trie, do: leader_trie(__MODULE__)

  def leader_trie(server) do
    ets_get(server, @leader_trie_key, Defaults.leader_trie())
  end

  @doc """
  Returns normal-mode binding overrides as a map.

  These are merged on top of `Defaults.normal_bindings()` at lookup time.
  """
  @spec normal_overrides() :: %{Bindings.key() => {atom(), String.t()}}
  @spec normal_overrides(GenServer.server()) :: %{Bindings.key() => {atom(), String.t()}}
  def normal_overrides, do: normal_overrides(__MODULE__)
  def normal_overrides(server), do: ets_get(server, @normal_overrides_key, %{})

  @doc """
  Returns the merged normal-mode bindings (defaults + user overrides).
  """
  @spec normal_bindings() :: %{Bindings.key() => {atom(), String.t()}}
  @spec normal_bindings(GenServer.server()) :: %{Bindings.key() => {atom(), String.t()}}
  def normal_bindings, do: normal_bindings(__MODULE__)

  def normal_bindings(server) do
    overrides = normal_overrides(server)
    Map.merge(Defaults.normal_bindings(), overrides)
  end

  @doc """
  Returns the binding trie for a specific mode (insert, visual, etc.).

  Returns an empty trie if no user bindings have been defined for that mode.
  """
  @spec mode_trie(atom()) :: Bindings.node_t()
  @spec mode_trie(GenServer.server(), atom()) :: Bindings.node_t()
  def mode_trie(mode), do: mode_trie(__MODULE__, mode)

  def mode_trie(server, mode) when is_atom(mode) do
    tries = ets_get(server, @mode_tries_key, %{})
    Map.get(tries, mode, Bindings.new())
  end

  @doc """
  Returns the filetype-scoped binding trie for SPC m.

  Returns an empty trie if no bindings have been defined for the filetype.
  """
  @spec filetype_trie(atom()) :: Bindings.node_t()
  @spec filetype_trie(GenServer.server(), atom()) :: Bindings.node_t()
  def filetype_trie(filetype), do: filetype_trie(__MODULE__, filetype)

  def filetype_trie(server, filetype) when is_atom(filetype) do
    tries = ets_get(server, @filetype_tries_key, %{})
    Map.get(tries, filetype, Bindings.new())
  end

  @doc """
  Returns scope-specific binding overrides from user config.
  """
  @spec scope_overrides() :: scope_overrides()
  @spec scope_overrides(GenServer.server()) :: scope_overrides()
  def scope_overrides, do: scope_overrides(__MODULE__)
  def scope_overrides(server), do: ets_get(server, @scope_overrides_key, %{})

  @doc """
  Returns the override trie for a specific scope and vim state.

  Returns an empty trie if no user overrides exist for that combination.
  """
  @spec scope_trie(Scope.scope_name(), Scope.vim_state()) :: Bindings.node_t()
  @spec scope_trie(GenServer.server(), Scope.scope_name(), Scope.vim_state()) ::
          Bindings.node_t()
  def scope_trie(scope, vim_state), do: scope_trie(__MODULE__, scope, vim_state)

  def scope_trie(server, scope, vim_state) do
    server
    |> ets_get(@scope_overrides_key, %{})
    |> Map.get(scope, %{})
    |> Map.get(vim_state, Bindings.new())
  end

  # ── Bind API ────────────────────────────────────────────────────────────────

  @doc """
  Binds a key sequence to a command in the given mode.

  For normal mode, leader sequences (starting with `SPC`) are added to
  the leader trie. Single-key bindings override defaults. For other modes
  (insert, visual, operator_pending, command), bindings are stored in
  per-mode tries.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      bind(:normal, "SPC g s", :git_status, "Git status")
      bind(:normal, "Q", :replay_macro_q, "Replay macro q")
      bind(:insert, "C-j", :next_line, "Next line")
      bind(:visual, "SPC x", :custom_delete, "Custom delete")
  """
  @spec bind(atom() | {atom(), atom()}, String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  @spec bind(GenServer.server(), atom() | {atom(), atom()}, String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  def bind(mode, key_str, command, description),
    do: bind(__MODULE__, mode, key_str, command, description)

  def bind(server, mode, key_str, command, description)
      when is_binary(key_str) and is_atom(command) and is_binary(description) do
    case KeyParser.parse(key_str) do
      {:ok, keys} ->
        do_bind(server, mode, keys, command, description)

      {:error, reason} ->
        Minga.Log.warning(:config, "Invalid key binding #{inspect(key_str)}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Binds a key sequence to a command with options.

  Supports the `filetype:` option for filetype-scoped bindings under SPC m.

  ## Examples

      bind(:normal, "SPC m t", :mix_test, "Run tests", filetype: :elixir)
      bind(:normal, "SPC m p", :markdown_preview, "Preview", filetype: :markdown)
  """
  @spec bind(atom(), String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  @spec bind(GenServer.server(), atom(), String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def bind(mode, key_str, command, description, opts),
    do: bind(__MODULE__, mode, key_str, command, description, opts)

  def bind(server, mode, key_str, command, description, opts)
      when is_atom(mode) and is_binary(key_str) and is_atom(command) and is_binary(description) and
             is_list(opts) do
    filetype = Keyword.get(opts, :filetype)

    if filetype do
      bind_filetype(server, filetype, key_str, command, description)
    else
      bind(server, mode, key_str, command, description)
    end
  end

  @doc """
  Resets all bindings to defaults (removes user overrides).
  """
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    table = table_name(server)
    :ets.delete_all_objects(table)
    seed_defaults(table)
    :ok
  end

  # ── Private: ETS helpers ────────────────────────────────────────────────────

  @spec table_name(GenServer.server()) :: atom()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)

  @spec ets_get(GenServer.server(), atom(), term()) :: term()
  defp ets_get(server, key, default) do
    table = table_name(server)

    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @spec ets_update(GenServer.server(), atom(), term(), (term() -> term())) :: :ok
  defp ets_update(server, key, default, fun) do
    table = table_name(server)
    current = ets_get(server, key, default)
    :ets.insert(table, {key, fun.(current)})
    :ok
  end

  @spec seed_defaults(:ets.table()) :: true
  defp seed_defaults(table) do
    :ets.insert(table, [
      {@leader_trie_key, Defaults.leader_trie()},
      {@normal_overrides_key, %{}},
      {@scope_overrides_key, %{}},
      {@filetype_tries_key, %{}},
      {@mode_tries_key, %{}}
    ])
  end

  # ── Private: bind dispatch ──────────────────────────────────────────────────

  @spec do_bind(
          GenServer.server(),
          atom() | {atom(), atom()},
          [Bindings.key()],
          atom(),
          String.t()
        ) ::
          :ok | {:error, String.t()}

  # Normal mode: leader sequences (SPC + more keys)
  defp do_bind(server, :normal, [{32, 0} | rest], command, description) when rest != [] do
    ets_update(server, @leader_trie_key, Defaults.leader_trie(), fn trie ->
      Bindings.bind(trie, rest, command, description)
    end)
  end

  # Normal mode: single-key binding
  defp do_bind(server, :normal, [single_key], command, description) do
    ets_update(server, @normal_overrides_key, %{}, fn overrides ->
      Map.put(overrides, single_key, {command, description})
    end)
  end

  # Normal mode: unsupported multi-key (not SPC-prefixed)
  defp do_bind(_server, :normal, keys, _command, _description) do
    Minga.Log.warning(:config, "Unsupported key sequence for normal mode: #{inspect(keys)}")
    {:error, "unsupported key sequence for normal mode"}
  end

  # Insert, visual, operator_pending, command modes: store in per-mode tries
  defp do_bind(server, mode, keys, command, description)
       when mode in [:insert, :visual, :operator_pending, :command] do
    ets_update(server, @mode_tries_key, %{}, fn tries ->
      trie = Map.get(tries, mode, Bindings.new())
      updated = Bindings.bind(trie, keys, command, description)
      Map.put(tries, mode, updated)
    end)
  end

  # Scope-specific bindings: {scope, vim_state} tuple
  defp do_bind(server, {scope, vim_state}, keys, command, description)
       when is_atom(scope) and is_atom(vim_state) do
    ets_update(server, @scope_overrides_key, %{}, fn overrides ->
      scope_map = Map.get(overrides, scope, %{})
      trie = Map.get(scope_map, vim_state, Bindings.new())
      updated = Bindings.bind(trie, keys, command, description)
      new_scope_map = Map.put(scope_map, vim_state, updated)
      Map.put(overrides, scope, new_scope_map)
    end)
  end

  defp do_bind(_server, mode, _keys, _command, _description) do
    Minga.Log.warning(:config, "Keybinding for mode #{inspect(mode)} not yet supported")
    {:error, "keybinding for mode #{inspect(mode)} not yet supported"}
  end

  # ── Private: filetype bind ─────────────────────────────────────────────────

  @spec bind_filetype(GenServer.server(), atom(), String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  defp bind_filetype(server, filetype, key_str, command, description) do
    case KeyParser.parse(key_str) do
      {:ok, keys} ->
        sub_keys = strip_spc_m_prefix(keys)

        ets_update(server, @filetype_tries_key, %{}, fn tries ->
          trie = Map.get(tries, filetype, Bindings.new())
          updated = Bindings.bind(trie, sub_keys, command, description)
          Map.put(tries, filetype, updated)
        end)

      {:error, reason} ->
        Minga.Log.warning(:config, "Invalid key binding #{inspect(key_str)}: #{reason}")
        {:error, reason}
    end
  end

  # Strip "SPC m" prefix from key sequences so filetype tries store only
  # the sub-keys. If the sequence doesn't start with SPC m, store as-is.
  @spec strip_spc_m_prefix([Bindings.key()]) :: [Bindings.key()]
  defp strip_spc_m_prefix([{32, 0}, {?m, 0} | rest]) when rest != [], do: rest
  defp strip_spc_m_prefix(keys), do: keys
end
