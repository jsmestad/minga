defmodule Minga.Keymap.Active do
  @moduledoc """
  Mutable keymap store backed by an Agent.

  Holds the active leader trie, per-mode binding overrides, filetype-scoped
  bindings, and per-scope overrides. Initialized from `Minga.Keymap.Defaults`
  on startup, then mutated by user config via `bind/4` and `bind/5`.

  The store is the single source of truth for keybindings at runtime. Mode
  handlers read from here instead of `Defaults` directly, so user overrides
  take effect immediately.

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

  use Agent

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope

  require Logger

  @typedoc """
  Per-scope, per-vim-state binding overrides from user config.

  Outer key is the scope name, inner key is the vim state.
  """
  @type scope_overrides :: %{Scope.scope_name() => %{Scope.vim_state() => Bindings.node_t()}}

  @typedoc "Per-filetype binding tries for SPC m."
  @type filetype_tries :: %{atom() => Bindings.node_t()}

  @typedoc "Per-mode binding tries for insert, visual, operator_pending, command."
  @type mode_tries :: %{atom() => Bindings.node_t()}

  @typedoc "Store state."
  @type state :: %{
          leader_trie: Bindings.node_t(),
          normal_overrides: %{Bindings.key() => {atom(), String.t()}},
          scope_overrides: scope_overrides(),
          filetype_tries: filetype_tries(),
          mode_tries: mode_tries()
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the keymap store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)

    Agent.start_link(
      fn -> initial_state() end,
      name: name
    )
  end

  @spec initial_state() :: state()
  defp initial_state do
    %{
      leader_trie: Defaults.leader_trie(),
      normal_overrides: %{},
      scope_overrides: %{},
      filetype_tries: %{},
      mode_tries: %{}
    }
  end

  @doc """
  Returns the current leader trie (defaults + user overrides).
  """
  @spec leader_trie() :: Bindings.node_t()
  @spec leader_trie(GenServer.server()) :: Bindings.node_t()
  def leader_trie, do: leader_trie(__MODULE__)
  def leader_trie(server), do: Agent.get(server, & &1.leader_trie)

  @doc """
  Returns normal-mode binding overrides as a map.

  These are merged on top of `Defaults.normal_bindings()` at lookup time.
  """
  @spec normal_overrides() :: %{Bindings.key() => {atom(), String.t()}}
  @spec normal_overrides(GenServer.server()) :: %{Bindings.key() => {atom(), String.t()}}
  def normal_overrides, do: normal_overrides(__MODULE__)
  def normal_overrides(server), do: Agent.get(server, & &1.normal_overrides)

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
    Agent.get(server, fn state ->
      Map.get(state.mode_tries, mode, Bindings.new())
    end)
  end

  @doc """
  Returns the filetype-scoped binding trie for SPC m.

  Returns an empty trie if no bindings have been defined for the filetype.
  """
  @spec filetype_trie(atom()) :: Bindings.node_t()
  @spec filetype_trie(GenServer.server(), atom()) :: Bindings.node_t()
  def filetype_trie(filetype), do: filetype_trie(__MODULE__, filetype)

  def filetype_trie(server, filetype) when is_atom(filetype) do
    Agent.get(server, fn state ->
      Map.get(state.filetype_tries, filetype, Bindings.new())
    end)
  end

  @doc """
  Returns scope-specific binding overrides from user config.
  """
  @spec scope_overrides() :: scope_overrides()
  @spec scope_overrides(GenServer.server()) :: scope_overrides()
  def scope_overrides, do: scope_overrides(__MODULE__)
  def scope_overrides(server), do: Agent.get(server, & &1.scope_overrides)

  @doc """
  Returns the override trie for a specific scope and vim state.

  Returns an empty trie if no user overrides exist for that combination.
  """
  @spec scope_trie(Scope.scope_name(), Scope.vim_state()) :: Bindings.node_t()
  @spec scope_trie(GenServer.server(), Scope.scope_name(), Scope.vim_state()) ::
          Bindings.node_t()
  def scope_trie(scope, vim_state), do: scope_trie(__MODULE__, scope, vim_state)

  def scope_trie(server, scope, vim_state) do
    Agent.get(server, fn state ->
      state.scope_overrides
      |> Map.get(scope, %{})
      |> Map.get(vim_state, Bindings.new())
    end)
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
        Logger.warning("Invalid key binding #{inspect(key_str)}: #{reason}")
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
    Agent.update(server, fn _ -> initial_state() end)
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
    Agent.update(server, fn %{leader_trie: trie} = state ->
      %{state | leader_trie: Bindings.bind(trie, rest, command, description)}
    end)
  end

  # Normal mode: single-key binding
  defp do_bind(server, :normal, [single_key], command, description) do
    Agent.update(server, fn %{normal_overrides: overrides} = state ->
      %{state | normal_overrides: Map.put(overrides, single_key, {command, description})}
    end)
  end

  # Normal mode: unsupported multi-key (not SPC-prefixed)
  defp do_bind(_server, :normal, keys, _command, _description) do
    Logger.warning("Unsupported key sequence for normal mode: #{inspect(keys)}")
    {:error, "unsupported key sequence for normal mode"}
  end

  # Insert, visual, operator_pending, command modes: store in per-mode tries
  defp do_bind(server, mode, keys, command, description)
       when mode in [:insert, :visual, :operator_pending, :command] do
    Agent.update(server, fn %{mode_tries: tries} = state ->
      trie = Map.get(tries, mode, Bindings.new())
      updated = Bindings.bind(trie, keys, command, description)
      %{state | mode_tries: Map.put(tries, mode, updated)}
    end)
  end

  # Scope-specific bindings: {scope, vim_state} tuple
  defp do_bind(server, {scope, vim_state}, keys, command, description)
       when is_atom(scope) and is_atom(vim_state) do
    Agent.update(server, fn %{scope_overrides: overrides} = state ->
      scope_map = Map.get(overrides, scope, %{})
      trie = Map.get(scope_map, vim_state, Bindings.new())
      updated = Bindings.bind(trie, keys, command, description)
      new_scope_map = Map.put(scope_map, vim_state, updated)
      %{state | scope_overrides: Map.put(overrides, scope, new_scope_map)}
    end)
  end

  defp do_bind(_server, mode, _keys, _command, _description) do
    Logger.warning("Keybinding for mode #{inspect(mode)} not yet supported")
    {:error, "keybinding for mode #{inspect(mode)} not yet supported"}
  end

  # ── Private: filetype bind ─────────────────────────────────────────────────

  @spec bind_filetype(GenServer.server(), atom(), String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  defp bind_filetype(server, filetype, key_str, command, description) do
    case KeyParser.parse(key_str) do
      {:ok, keys} ->
        # Strip the SPC m prefix if present (user writes "SPC m t" but we
        # store just the sub-keys under the filetype trie)
        sub_keys = strip_spc_m_prefix(keys)

        Agent.update(server, fn %{filetype_tries: tries} = state ->
          trie = Map.get(tries, filetype, Bindings.new())
          updated = Bindings.bind(trie, sub_keys, command, description)
          %{state | filetype_tries: Map.put(tries, filetype, updated)}
        end)

      {:error, reason} ->
        Logger.warning("Invalid key binding #{inspect(key_str)}: #{reason}")
        {:error, reason}
    end
  end

  # Strip "SPC m" prefix from key sequences so filetype tries store only
  # the sub-keys. If the sequence doesn't start with SPC m, store as-is.
  @spec strip_spc_m_prefix([Bindings.key()]) :: [Bindings.key()]
  defp strip_spc_m_prefix([{32, 0}, {?m, 0} | rest]) when rest != [], do: rest
  defp strip_spc_m_prefix(keys), do: keys
end
