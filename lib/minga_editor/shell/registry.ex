defmodule MingaEditor.Shell.Registry do
  @moduledoc """
  Serialized source-owned registry for workspace shells.

  One GenServer validates every duplicate decision, source-owned removal, generation assignment, and cleanup transition. It publishes the complete validated snapshot through one `persistent_term` key so input and render hot paths never observe separately updated module and source metadata.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Registry.Snapshot

  @type shell_id :: atom()
  @type source :: ContributionCleanup.contribution_source()
  @type register_attrs :: keyword() | map()
  @type server :: GenServer.server()
  @type register_error ::
          Snapshot.register_error()
          | {:missing_default, term()}
          | {:invalid_entry, term()}
          | :source_required
          | :not_owner
  @type snapshot :: Snapshot.t()

  @state_key {__MODULE__, :state}

  @doc "Starts the sole shell-registry publisher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, snapshot()}
  def init(_opts) do
    :ok = ContributionCleanup.register(:shells, &__MODULE__.unregister_source/1)

    state =
      Snapshot.new()
      |> seed_builtin_snapshot()
      |> publish()

    {:ok, state}
  end

  @doc "Registers the built-in shell contributions. Safe to call more than once."
  @spec seed_builtin() :: :ok
  def seed_builtin, do: GenServer.call(__MODULE__, :seed_builtin)

  @doc "Registers a shell contribution."
  @spec register(source(), register_attrs()) :: :ok | {:error, register_error()}
  def register(source, attrs) do
    attrs = attrs |> Map.new() |> Map.put(:source, source)

    case Entry.new(attrs) do
      {:ok, entry} -> GenServer.call(__MODULE__, {:register, entry})
      {:error, reason} -> {:error, {:invalid_entry, reason}}
    end
  end

  @doc "Unregisters a shell by id. Built-in shells are preserved and extension shells require their source."
  @spec unregister(shell_id()) :: :ok | {:error, :builtin_shell | :source_required}
  def unregister(id) when is_atom(id) do
    case get(id) do
      %Entry{source: :builtin} -> {:error, :builtin_shell}
      %Entry{} -> {:error, :source_required}
      nil -> :ok
    end
  end

  @doc "Unregisters a shell owned by the given source."
  @spec unregister(source(), shell_id()) :: :ok | {:error, :builtin_shell | :not_owner}
  def unregister(:builtin, _id), do: {:error, :builtin_shell}

  def unregister(source, id) when is_atom(id) do
    GenServer.call(__MODULE__, {:unregister, source, id})
  end

  @doc "Unregisters all shells owned by a source as one publication."
  @spec unregister_source(source()) :: :ok
  def unregister_source(:builtin), do: :ok
  def unregister_source(source), do: GenServer.call(__MODULE__, {:unregister_source, source})

  @doc "Returns one coherent registry publication."
  @spec snapshot() :: snapshot()
  def snapshot, do: :persistent_term.get(@state_key, Snapshot.new())

  @doc "Returns registered shells in deterministic display order."
  @spec list() :: [Entry.t()]
  def list, do: snapshot().ordered

  @doc "Returns a shell entry by id."
  @spec get(shell_id()) :: Entry.t() | nil
  def get(id) when is_atom(id), do: Map.get(snapshot().entries, id)

  @doc "Resolves an id or implementation module from one coherent snapshot."
  @spec resolve(shell_id() | module()) :: Entry.t() | nil
  def resolve(id_or_module) when is_atom(id_or_module) do
    snapshot() |> Snapshot.resolve(id_or_module)
  end

  @doc "Returns the default shell entry, falling back to Traditional when the registry is empty."
  @spec default() :: Entry.t()
  def default do
    current = snapshot()
    Map.get(current.entries, current.default_id) || builtin_traditional_entry()
  end

  @doc "Returns the registered module for an id, or nil."
  @spec module_for(shell_id()) :: module() | nil
  def module_for(id) when is_atom(id) do
    case get(id) do
      %Entry{module: module} -> module
      nil -> nil
    end
  end

  @doc "Returns the shell id registered for a module, or nil."
  @spec id_for_module(module()) :: shell_id() | nil
  def id_for_module(module) when is_atom(module) do
    case snapshot() |> Snapshot.entry_for_module(module) do
      %Entry{id: id} -> id
      nil -> nil
    end
  end

  @doc "Returns true when the id is currently registered."
  @spec available?(shell_id()) :: boolean()
  def available?(id) when is_atom(id), do: get(id) != nil

  @doc "Returns true when the shell supports a capability atom."
  @spec supports?(shell_id(), atom()) :: boolean()
  def supports?(id, capability) when is_atom(id) and is_atom(capability) do
    case get(id) do
      %Entry{capabilities: capabilities} -> capability in capabilities
      nil -> false
    end
  end

  @doc "Resets registry state. Intended for tests that need isolated registry setup."
  @spec reset_for_test([Entry.t()]) :: :ok
  def reset_for_test(entries \\ []) when is_list(entries) do
    GenServer.call(__MODULE__, {:reset_for_test, entries})
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), snapshot()) ::
          {:reply, :ok | {:error, register_error()}, snapshot()}
  def handle_call(:seed_builtin, _from, state) do
    state = state |> seed_builtin_snapshot() |> publish()
    {:reply, :ok, state}
  end

  def handle_call({:register, %Entry{} = entry}, _from, state) do
    case Snapshot.register(state, entry) do
      {:ok, updated} -> {:reply, :ok, publish(updated)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, source, id}, _from, state) do
    case Snapshot.unregister(state, source, id) do
      {:ok, updated, true} -> {:reply, :ok, publish(updated)}
      {:ok, _unchanged, false} -> {:reply, :ok, state}
      {:error, :not_owner} -> {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:unregister_source, source}, _from, state) do
    case Snapshot.unregister_source(state, source) do
      {updated, true} -> {:reply, :ok, publish(updated)}
      {_unchanged, false} -> {:reply, :ok, state}
    end
  end

  def handle_call({:reset_for_test, entries}, _from, _state) do
    state = entries |> Snapshot.from_entries() |> publish()
    {:reply, :ok, state}
  end

  @spec seed_builtin_snapshot(snapshot()) :: snapshot()
  defp seed_builtin_snapshot(snapshot) do
    case Snapshot.put_builtin(snapshot, builtin_traditional_entry()) do
      {:ok, updated} -> updated
      {:error, reason} -> raise "failed to seed built-in shell: #{inspect(reason)}"
    end
  end

  @spec publish(snapshot()) :: snapshot()
  defp publish(snapshot) do
    published = Snapshot.advance(snapshot)
    :persistent_term.put(@state_key, published)
    published
  end

  @spec builtin_traditional_entry() :: Entry.t()
  defp builtin_traditional_entry do
    Entry.builtin!(
      :traditional,
      MingaEditor.Shell.Traditional,
      "Traditional",
      "Tab-based editor with file tree, modeline, picker, and agent panel.",
      true
    )
  end
end
