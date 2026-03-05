defmodule Minga.Keymap.Active do
  @moduledoc """
  Mutable keymap store backed by an Agent.

  Holds the active leader trie and normal-mode binding overrides. Initialized
  from `Minga.Keymap.Defaults` on startup, then mutated by user config via
  `bind/4`.

  The store is the single source of truth for keybindings at runtime. Mode
  handlers read from here instead of `Defaults` directly, so user overrides
  take effect immediately.
  """

  use Agent

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.KeyParser

  require Logger

  @typedoc "Store state: leader trie + normal binding overrides."
  @type state :: %{
          leader_trie: Bindings.node_t(),
          normal_overrides: %{Bindings.key() => {atom(), String.t()}}
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the keymap store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        %{
          leader_trie: Defaults.leader_trie(),
          normal_overrides: %{}
        }
      end,
      name: name
    )
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
  Binds a key sequence to a command.

  For leader sequences (starting with `SPC`), inserts into the leader trie.
  For single-key normal-mode bindings, adds to the normal overrides map.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Examples

      Minga.Keymap.Active.bind(:normal, "SPC g s", :git_status, "Git status")
      Minga.Keymap.Active.bind(:normal, "Q", :replay_macro_q, "Replay macro q")
  """
  @spec bind(atom(), String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  @spec bind(GenServer.server(), atom(), String.t(), atom(), String.t()) ::
          :ok | {:error, String.t()}
  def bind(mode, key_str, command, description),
    do: bind(__MODULE__, mode, key_str, command, description)

  def bind(server, mode, key_str, command, description)
      when is_atom(mode) and is_binary(key_str) and is_atom(command) and is_binary(description) do
    case KeyParser.parse(key_str) do
      {:ok, keys} ->
        do_bind(server, mode, keys, command, description)

      {:error, reason} ->
        Logger.warning("Invalid key binding #{inspect(key_str)}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Resets all bindings to defaults (removes user overrides).
  """
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    Agent.update(server, fn _ ->
      %{
        leader_trie: Defaults.leader_trie(),
        normal_overrides: %{}
      }
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec do_bind(GenServer.server(), atom(), [Bindings.key()], atom(), String.t()) :: :ok
  defp do_bind(server, :normal, [{32, 0} | rest], command, description) when rest != [] do
    # Leader sequence: SPC + more keys → insert into leader trie
    Agent.update(server, fn %{leader_trie: trie} = state ->
      %{state | leader_trie: Bindings.bind(trie, rest, command, description)}
    end)
  end

  defp do_bind(server, :normal, [single_key], command, description) do
    # Single normal-mode key binding
    Agent.update(server, fn %{normal_overrides: overrides} = state ->
      %{state | normal_overrides: Map.put(overrides, single_key, {command, description})}
    end)
  end

  defp do_bind(_server, :normal, keys, _command, _description) do
    Logger.warning("Unsupported key sequence for normal mode: #{inspect(keys)}")
    {:error, "unsupported key sequence for normal mode"}
  end

  defp do_bind(_server, mode, _keys, _command, _description) do
    Logger.warning("Keybinding for mode #{inspect(mode)} not yet supported")
    {:error, "keybinding for mode #{inspect(mode)} not yet supported"}
  end
end
