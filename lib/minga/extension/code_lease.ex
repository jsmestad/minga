defmodule Minga.Extension.CodeLease do
  @moduledoc """
  Tracks short-lived ownership of extension callback code.

  Existing long-lived agent integrations use `lease/4`. Runtime editor callbacks
  use source-aware admission: an active source admits only its declared module
  set, quiescing closes ordinary admission, and the returned token authorizes the
  source's final unload callbacks. Extension code remains resident for the VM
  generation; this service never purges code.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup

  @typedoc "Why the module is still callable."
  @type reason :: :provider | :tool | :hook | :mcp | :ui_action | :editor_event | atom()

  @typedoc "Opaque authority for callbacks that finalize a quiescing source."
  @type unload_token :: reference()

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

  @type source_status :: :active | {:quiescing, unload_token()} | :inactive
  @typep source_record :: %{status: source_status(), modules: MapSet.t(module())}

  @typep drain_waiter :: {pid(), reference()}
  @typep state :: %{
           leases: %{reference() => t()},
           owner_refs: %{pid() => MapSet.t(reference())},
           owner_monitors: %{pid() => reference()},
           monitor_owners: %{reference() => pid()},
           sources: %{ContributionCleanup.contribution_source() => source_record()},
           token_sources: %{unload_token() => ContributionCleanup.contribution_source()},
           drain_waiters: %{ContributionCleanup.contribution_source() => [drain_waiter()]}
         }

  @doc "Starts the code lease service."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Marks a source active with the exact callback modules it owns."
  @spec activate_source(ContributionCleanup.contribution_source(), [module()], keyword()) ::
          :ok | {:error, term()}
  def activate_source(source, modules, opts \\ []) when is_list(modules) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:activate_source, source, modules}, {:error, :not_started})
  end

  @doc "Closes ordinary callback admission and returns unload authority."
  @spec quiesce_source(ContributionCleanup.contribution_source(), keyword()) ::
          {:ok, unload_token()} | {:error, term()}
  def quiesce_source(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:quiesce_source, source}, {:error, :not_started})
  end

  @doc "Sends an event as soon as a source has no active callback leases."
  @spec notify_when_drained(
          ContributionCleanup.contribution_source(),
          pid(),
          reference(),
          keyword()
        ) :: :ok | {:error, term()}
  def notify_when_drained(source, recipient, ref, opts \\ [])
      when is_pid(recipient) and is_reference(ref) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:notify_when_drained, source, recipient, ref}, {:error, :not_started})
  end

  @doc "Marks a quiescing source inactive after unload callbacks finish."
  @spec complete_unload(unload_token(), keyword()) :: :ok | {:error, term()}
  def complete_unload(token, opts \\ []) when is_reference(token) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:complete_unload, token}, {:error, :not_started})
  end

  @doc "Reopens ordinary admission when source finalization is abandoned."
  @spec abort_unload(unload_token(), keyword()) :: :ok | {:error, term()}
  def abort_unload(token, opts \\ []) when is_reference(token) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:abort_unload, token}, {:error, :not_started})
  end

  @doc "Admits an ordinary runtime callback through the extension trust boundary."
  @spec admit_callback(
          ContributionCleanup.contribution_source(),
          module(),
          reason(),
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def admit_callback(source, module, reason, opts \\ [])
      when is_atom(module) and is_atom(reason) do
    admit({:ordinary, source}, module, reason, opts)
  end

  @doc "Admits a token-scoped callback while its extension source is quiescing."
  @spec admit_unload_callback(unload_token(), module(), reason(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def admit_unload_callback(token, module, reason, opts \\ [])
      when is_reference(token) and is_atom(module) and is_atom(reason) do
    admit({:unload, token}, module, reason, opts)
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

  @doc "Returns one source's admission status for lifecycle crash recovery."
  @spec source_status(ContributionCleanup.contribution_source(), keyword()) ::
          source_status() | :unknown
  def source_status(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:source_status, source}, :unknown)
  end

  @doc "Returns active leases matching a module, source, or both."
  @spec active_leases(keyword()) :: [summary()]
  def active_leases(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    source = Keyword.get(opts, :source, :_)
    module = Keyword.get(opts, :module, :_)
    safe_call(server, {:active_leases, source, module}, [])
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok,
     %{
       leases: %{},
       owner_refs: %{},
       owner_monitors: %{},
       monitor_owners: %{},
       sources: %{},
       token_sources: %{},
       drain_waiters: %{}
     }}
  end

  @impl true
  def handle_call({:activate_source, source, modules}, _from, state) do
    case validate_modules(modules) do
      {:ok, module_set} ->
        record = %{status: :active, modules: module_set}
        {:reply, :ok, %{state | sources: Map.put(state.sources, source, record)}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:quiesce_source, source}, _from, state) do
    case Map.get(state.sources, source) do
      %{status: :active} = record ->
        token = make_ref()
        record = %{record | status: {:quiescing, token}}

        {:reply, {:ok, token},
         %{
           state
           | sources: Map.put(state.sources, source, record),
             token_sources: Map.put(state.token_sources, token, source)
         }}

      %{status: {:quiescing, token}} ->
        {:reply, {:ok, token}, state}

      %{status: :inactive} ->
        {:reply, {:error, {:source_inactive, source}}, state}

      nil ->
        {:reply, {:error, {:source_not_active, source}}, state}
    end
  end

  def handle_call({:notify_when_drained, source, recipient, ref}, _from, state) do
    case matching_leases(state, source, :_) do
      [] ->
        send(recipient, {__MODULE__, :drained, source, ref})
        {:reply, :ok, state}

      [_lease | _rest] ->
        waiters =
          Map.update(state.drain_waiters, source, [{recipient, ref}], &[{recipient, ref} | &1])

        {:reply, :ok, %{state | drain_waiters: waiters}}
    end
  end

  def handle_call({:complete_unload, token}, _from, state) do
    transition_unload_token(state, token, :inactive)
  end

  def handle_call({:abort_unload, token}, _from, state) do
    transition_unload_token(state, token, :active)
  end

  def handle_call({:admit, {:ordinary, source}, module, owner, reason}, _from, state) do
    case ordinary_source(state, source, module) do
      :ok -> put_admitted_lease(state, source, module, owner, reason)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:admit, {:unload, token}, module, owner, reason}, _from, state) do
    case unload_source(state, token, module) do
      {:ok, source} -> put_admitted_lease(state, source, module, owner, reason)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:lease, source, module, owner, reason}, _from, state) do
    put_admitted_lease(state, source, module, owner, reason)
  end

  def handle_call({:release, id}, _from, state) do
    {:reply, :ok, state |> drop_lease(id) |> notify_drained_sources()}
  end

  def handle_call({:source_status, source}, _from, state) do
    status =
      case Map.get(state.sources, source) do
        %{status: source_status} -> source_status
        nil -> :unknown
      end

    {:reply, status, state}
  end

  def handle_call({:active_leases, source, module}, _from, state) do
    {:reply, matching_leases(state, source, module), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    case Map.get(state.monitor_owners, ref) do
      ^owner -> {:noreply, state |> drop_owner_leases(owner) |> notify_drained_sources()}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec admit({:ordinary, term()} | {:unload, unload_token()}, module(), reason(), keyword()) ::
          {:ok, t()} | {:error, term()}
  defp admit(scope, module, reason, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    owner = Keyword.get(opts, :owner, self())

    if is_pid(owner) do
      safe_call(server, {:admit, scope, module, owner, reason}, {:error, :not_started})
    else
      {:error, {:invalid_owner, owner}}
    end
  end

  @spec validate_modules([term()]) :: {:ok, MapSet.t(module())} | {:error, term()}
  defp validate_modules(modules) do
    invalid = Enum.reject(modules, &is_atom/1)

    case invalid do
      [] -> {:ok, MapSet.new(modules)}
      _ -> {:error, {:invalid_source_modules, invalid}}
    end
  end

  @spec transition_unload_token(state(), unload_token(), source_status()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp transition_unload_token(state, token, next_status) do
    case Map.pop(state.token_sources, token) do
      {nil, _tokens} ->
        {:reply, {:error, {:invalid_unload_token, token}}, state}

      {source, tokens} ->
        record = Map.fetch!(state.sources, source)
        record = %{record | status: next_status}
        sources = Map.put(state.sources, source, record)
        {:reply, :ok, %{state | sources: sources, token_sources: tokens}}
    end
  end

  @spec ordinary_source(state(), term(), module()) :: :ok | {:error, term()}
  defp ordinary_source(state, source, module) do
    case Map.get(state.sources, source) do
      %{status: :active, modules: modules} -> source_module_result(source, module, modules)
      %{status: {:quiescing, _token}} -> {:error, {:source_quiescing, source}}
      %{status: :inactive} -> {:error, {:source_inactive, source}}
      nil -> {:error, {:source_not_active, source}}
    end
  end

  @spec unload_source(state(), unload_token(), module()) ::
          {:ok, ContributionCleanup.contribution_source()} | {:error, term()}
  defp unload_source(state, token, module) do
    case Map.fetch(state.token_sources, token) do
      {:ok, source} -> unload_source_module(state, source, token, module)
      :error -> {:error, {:invalid_unload_token, token}}
    end
  end

  @spec unload_source_module(state(), term(), unload_token(), module()) ::
          {:ok, ContributionCleanup.contribution_source()} | {:error, term()}
  defp unload_source_module(state, source, token, module) do
    case Map.fetch!(state.sources, source) do
      %{status: {:quiescing, ^token}, modules: modules} ->
        case source_module_result(source, module, modules) do
          :ok -> {:ok, source}
          {:error, _reason} = error -> error
        end

      _record ->
        {:error, {:invalid_unload_token, token}}
    end
  end

  @spec source_module_result(term(), module(), MapSet.t(module())) :: :ok | {:error, term()}
  defp source_module_result(source, module, modules) do
    if MapSet.member?(modules, module) do
      :ok
    else
      {:error, {:module_not_owned, source, module}}
    end
  end

  @spec put_admitted_lease(state(), term(), module(), pid(), reason()) ::
          {:reply, {:ok, t()}, state()}
  defp put_admitted_lease(state, source, module, owner, reason) do
    lease = %__MODULE__{
      id: make_ref(),
      server: self(),
      source: source,
      module: module,
      owner: owner,
      reason: reason,
      started_at: System.monotonic_time()
    }

    {:reply, {:ok, lease}, put_lease(state, lease)}
  end

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

  @spec notify_drained_sources(state()) :: state()
  defp notify_drained_sources(state) do
    Enum.reduce(Map.keys(state.drain_waiters), state, &notify_drained_source/2)
  end

  @spec notify_drained_source(ContributionCleanup.contribution_source(), state()) :: state()
  defp notify_drained_source(source, current) do
    case matching_leases(current, source, :_) do
      [] -> notify_drain_waiters(current, source)
      [_lease | _rest] -> current
    end
  end

  @spec notify_drain_waiters(state(), ContributionCleanup.contribution_source()) :: state()
  defp notify_drain_waiters(current, source) do
    {waiters, remaining} = Map.pop(current.drain_waiters, source, [])

    Enum.each(waiters, fn {recipient, ref} ->
      send(recipient, {__MODULE__, :drained, source, ref})
    end)

    %{current | drain_waiters: remaining}
  end

  @spec matching_leases(state(), ContributionCleanup.contribution_source() | :_, module() | :_) ::
          [summary()]
  defp matching_leases(state, source, module) do
    state.leases
    |> Map.values()
    |> Enum.filter(&matches?(&1, source, module))
    |> Enum.map(&summarize/1)
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
