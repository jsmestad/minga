defmodule Minga.Extension.CodeLease do
  @moduledoc """
  Tracks short-lived leases for extension callback modules.

  Extension reload and disable may purge path, git, and generated plugin modules. Agent-facing callbacks can outlive the extension process that registered them, so callers lease the callback module while a provider, tool worker, hook, MCP config builder, or UI action may still call it. Purge paths consult this service and reject unsafe unloads with a clear error instead of racing `:code.purge/1` against active work.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup

  @typedoc "Why the module is still callable."
  @type reason :: :provider | :tool | :hook | :mcp | :ui_action | atom()

  @typedoc "A process-owned extension code lease."
  @enforce_keys [:id, :server, :source, :module, :owner, :reason, :started_at]
  defstruct [:id, :server, :source, :module, :owner, :reason, :started_at]

  @type t :: %__MODULE__{
          id: reference(),
          server: GenServer.server(),
          source: ContributionCleanup.contribution_source(),
          module: module(),
          owner: pid(),
          reason: reason(),
          started_at: integer()
        }

  @typedoc "Public lease summary safe to include in errors and logs."
  @type summary :: %{
          source: ContributionCleanup.contribution_source(),
          module: module(),
          owner: pid(),
          reason: reason()
        }

  @typep state :: %{
           leases: %{reference() => t()},
           owner_refs: %{pid() => MapSet.t(reference())},
           owner_monitors: %{pid() => reference()},
           monitor_owners: %{reference() => pid()}
         }

  @doc "Starts the code lease service."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Leases an extension callback module for the owner process."
  @spec lease(ContributionCleanup.contribution_source(), module(), reason(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def lease(source, module, reason, opts \\ [])
      when is_atom(module) and is_atom(reason) do
    server = Keyword.get(opts, :server, __MODULE__)
    owner = Keyword.get(opts, :owner, self())

    if is_pid(owner) do
      safe_call(server, {:lease, source, module, owner, reason}, {:error, :not_started})
    else
      {:error, {:invalid_owner, owner}}
    end
  end

  @doc "Releases a previously acquired lease."
  @spec release(t() | reference(), keyword()) :: :ok
  def release(lease_or_ref, opts \\ [])

  def release(%__MODULE__{server: server, id: id}, _opts) do
    safe_call(server, {:release, id}, :ok)
  end

  def release(id, opts) when is_reference(id) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:release, id}, :ok)
  end

  @doc "Returns active leases matching a module, source, or both."
  @spec active_leases(keyword()) :: [summary()]
  def active_leases(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    source = Keyword.get(opts, :source, :_)
    module = Keyword.get(opts, :module, :_)
    safe_call(server, {:active_leases, source, module}, [])
  end

  @doc "Returns `:ok` when a module can be purged safely."
  @spec ensure_purge_allowed(ContributionCleanup.contribution_source() | nil, module(), keyword()) ::
          :ok | {:error, term()}
  def ensure_purge_allowed(source, module, opts \\ []) when is_atom(module) do
    server = Keyword.get(opts, :server, __MODULE__)

    safe_call(
      server,
      {:ensure_purge_allowed, source, module},
      {:error, {:lease_service_unavailable, server}}
    )
  end

  @doc "Purges and deletes a module atomically with the lease check."
  @spec purge_module(ContributionCleanup.contribution_source() | nil, module(), keyword()) ::
          :ok | {:error, term()}
  def purge_module(source, module, opts \\ []) when is_atom(module) do
    server = Keyword.get(opts, :server, __MODULE__)

    safe_call(
      server,
      {:purge_module, source, module},
      {:error, {:lease_service_unavailable, server}}
    )
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok, %{leases: %{}, owner_refs: %{}, owner_monitors: %{}, monitor_owners: %{}}}
  end

  @impl true
  def handle_call({:lease, source, module, owner, reason}, _from, state) do
    id = make_ref()
    server = self()

    lease = %__MODULE__{
      id: id,
      server: server,
      source: source,
      module: module,
      owner: owner,
      reason: reason,
      started_at: System.monotonic_time()
    }

    state = put_lease(state, lease)
    {:reply, {:ok, lease}, state}
  end

  def handle_call({:release, id}, _from, state) do
    {:reply, :ok, drop_lease(state, id)}
  end

  def handle_call({:active_leases, source, module}, _from, state) do
    {:reply, matching_leases(state, source, module), state}
  end

  def handle_call({:ensure_purge_allowed, _source, module}, _from, state) do
    {:reply, purge_allowed_reply(state, module), state}
  end

  def handle_call({:purge_module, _source, module}, _from, state) do
    case purge_allowed_reply(state, module) do
      :ok ->
        :code.purge(module)
        :code.delete(module)
        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    case Map.get(state.monitor_owners, ref) do
      ^owner -> {:noreply, drop_owner_leases(state, owner)}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec put_lease(state(), t()) :: state()
  defp put_lease(state, %__MODULE__{id: id, owner: owner} = lease) do
    {owner_monitors, monitor_owners} = ensure_owner_monitor(state, owner)
    owner_refs = Map.update(state.owner_refs, owner, MapSet.new([id]), &MapSet.put(&1, id))

    %{
      state
      | leases: Map.put(state.leases, id, lease),
        owner_refs: owner_refs,
        owner_monitors: owner_monitors,
        monitor_owners: monitor_owners
    }
  end

  @spec ensure_owner_monitor(state(), pid()) :: {%{pid() => reference()}, %{reference() => pid()}}
  defp ensure_owner_monitor(%{owner_monitors: monitors, monitor_owners: owners}, owner) do
    case Map.fetch(monitors, owner) do
      {:ok, _ref} -> {monitors, owners}
      :error -> put_owner_monitor(monitors, owners, owner)
    end
  end

  @spec put_owner_monitor(%{pid() => reference()}, %{reference() => pid()}, pid()) ::
          {%{pid() => reference()}, %{reference() => pid()}}
  defp put_owner_monitor(monitors, owners, owner) do
    ref = Process.monitor(owner)
    {Map.put(monitors, owner, ref), Map.put(owners, ref, owner)}
  end

  @spec drop_lease(state(), reference()) :: state()
  defp drop_lease(state, id) do
    case Map.pop(state.leases, id) do
      {%__MODULE__{owner: owner}, leases} -> drop_owner_ref(%{state | leases: leases}, owner, id)
      {nil, _leases} -> state
    end
  end

  @spec drop_owner_ref(state(), pid(), reference()) :: state()
  defp drop_owner_ref(state, owner, id) do
    refs = state.owner_refs |> Map.get(owner, MapSet.new()) |> MapSet.delete(id)

    if MapSet.size(refs) == 0 do
      demonitor_owner(%{state | owner_refs: Map.delete(state.owner_refs, owner)}, owner)
    else
      %{state | owner_refs: Map.put(state.owner_refs, owner, refs)}
    end
  end

  @spec drop_owner_leases(state(), pid()) :: state()
  defp drop_owner_leases(state, owner) do
    refs = Map.get(state.owner_refs, owner, MapSet.new())
    leases = Map.drop(state.leases, MapSet.to_list(refs))

    state
    |> Map.put(:leases, leases)
    |> Map.put(:owner_refs, Map.delete(state.owner_refs, owner))
    |> demonitor_owner(owner)
  end

  @spec demonitor_owner(state(), pid()) :: state()
  defp demonitor_owner(state, owner) do
    case Map.pop(state.owner_monitors, owner) do
      {ref, owner_monitors} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | owner_monitors: owner_monitors,
            monitor_owners: Map.delete(state.monitor_owners, ref)
        }

      {nil, _owner_monitors} ->
        state
    end
  end

  @spec matching_leases(state(), ContributionCleanup.contribution_source() | :_, module() | :_) ::
          [summary()]
  defp matching_leases(state, source, module) do
    state.leases
    |> Map.values()
    |> Enum.filter(&matches?(&1, source, module))
    |> Enum.map(&summarize/1)
  end

  @spec purge_allowed_reply(state(), module()) :: :ok | {:error, {:leased_modules, [summary()]}}
  defp purge_allowed_reply(state, module) do
    case matching_leases(state, :_, module) do
      [] -> :ok
      leases -> {:error, {:leased_modules, leases}}
    end
  end

  @spec matches?(t(), ContributionCleanup.contribution_source() | :_, module() | :_) :: boolean()
  defp matches?(%__MODULE__{} = lease, source, module) do
    source_matches?(lease.source, source) and module_matches?(lease.module, module)
  end

  @spec source_matches?(
          ContributionCleanup.contribution_source(),
          ContributionCleanup.contribution_source() | :_
        ) :: boolean()
  defp source_matches?(_lease_source, :_), do: true
  defp source_matches?(lease_source, source), do: lease_source == source

  @spec module_matches?(module(), module() | :_) :: boolean()
  defp module_matches?(_lease_module, :_), do: true
  defp module_matches?(lease_module, module), do: lease_module == module

  @spec summarize(t()) :: summary()
  defp summarize(%__MODULE__{} = lease) do
    %{source: lease.source, module: lease.module, owner: lease.owner, reason: lease.reason}
  end

  @spec safe_call(GenServer.server(), term(), result) :: result when result: var
  defp safe_call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> fallback
  end
end
