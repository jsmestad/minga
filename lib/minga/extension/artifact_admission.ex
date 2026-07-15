defmodule Minga.Extension.ArtifactAdmission do
  @moduledoc """
  Serialized VM-generation authority for extension module provenance.

  Claims remain pending through code loading and are identified by an
  unforgeable attempt token. Equivalent callers wait for commit or receive the
  next ownership token after abort; no caller can release another attempt's
  claim. Committed provenance is persisted by `ArtifactGenerationState`, so an
  admission-service restart never reopens an empty generation under loaded code.
  """

  use GenServer

  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.ArtifactInventory
  alias Minga.Extension.ContributionCleanup

  @max_modules_per_source 128

  @type fingerprint :: binary()

  @type claim :: %{
          source: ContributionCleanup.contribution_source(),
          fingerprint: fingerprint(),
          source_fingerprint: fingerprint(),
          modules: [module()],
          load_modules: [module()],
          adopted_modules: [module()],
          acquired?: boolean(),
          attempt_token: reference() | nil
        }

  @type collision ::
          {:source_artifact_changed, ContributionCleanup.contribution_source()}
          | {:generation_failed, term()}
          | {:generation_sealed, ContributionCleanup.contribution_source()}
          | {:module_owned_by_source, module(), ContributionCleanup.contribution_source(),
             ContributionCleanup.contribution_source()}
          | {:module_conflicts_with_host, module()}
          | {:invalid_module_set, term()}
          | {:invalid_trusted_application, term()}
          | {:module_not_in_trusted_application, module(), atom()}

  @typep waiter :: %{from: GenServer.from(), pid: pid(), monitor: reference()}
  @typep pending_phase :: :claimed | :loading
  @typep pending_attempt :: %{
           token: reference(),
           owner: pid(),
           owner_monitor: reference(),
           phase: pending_phase(),
           waiters: [waiter()]
         }
  @typep source_status :: :committed | :failed | {:pending, pending_attempt()}

  @typep source_record :: %{
           fingerprint: fingerprint(),
           source_fingerprint: fingerprint(),
           modules: [module()],
           load_modules: [module()],
           adopted_modules: [module()],
           status: source_status()
         }

  @typep state :: %{
           sources: %{ContributionCleanup.contribution_source() => source_record()},
           module_sources: %{module() => ContributionCleanup.contribution_source()},
           sealed?: boolean(),
           failed?: boolean(),
           state_owner: GenServer.server()
         }

  @doc "Starts the VM-generation artifact admission authority."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Atomically begins admission for every module in one validated inventory."
  @spec claim_inventory(
          ContributionCleanup.contribution_source(),
          ArtifactInventory.t(),
          keyword()
        ) :: {:ok, claim()} | {:error, collision() | term()}
  def claim_inventory(source, %ArtifactInventory{} = inventory, opts \\ []) do
    modules = Enum.map(inventory.artifacts, & &1.module)
    source_fingerprint = Keyword.get(opts, :source_fingerprint, inventory.fingerprint)

    claim_source_modules(
      source,
      modules,
      inventory.fingerprint,
      Keyword.put(opts, :source_fingerprint, source_fingerprint)
    )
  end

  @doc "Atomically begins a deterministic generated or application module-set attempt."
  @spec claim_source_modules(
          ContributionCleanup.contribution_source(),
          [module()],
          fingerprint(),
          keyword()
        ) :: {:ok, claim()} | {:error, collision() | term()}
  def claim_source_modules(source, modules, fingerprint, opts \\ [])
      when is_list(modules) and is_binary(fingerprint) do
    source_fingerprint = Keyword.get(opts, :source_fingerprint, fingerprint)

    if valid_module_set?(modules, fingerprint, source_fingerprint) do
      server = Keyword.get(opts, :server, __MODULE__)
      trusted_application = Keyword.get(opts, :trusted_application)

      safe_call(
        server,
        {:claim_source_modules, source, Enum.sort(Enum.uniq(modules)), fingerprint,
         source_fingerprint, trusted_application},
        {:error, {:artifact_admission_unavailable, server}},
        :infinity
      )
    else
      {:error, {:invalid_module_set, modules}}
    end
  end

  @doc "Marks the exact pending attempt as able to have loaded code."
  @spec mark_loading(claim(), keyword()) :: :ok | {:error, term()}
  def mark_loading(claim, opts \\ [])

  def mark_loading(%{source: source, acquired?: false}, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:mark_loading, source, nil}, {:error, :artifact_admission_unavailable})
  end

  def mark_loading(%{source: source, attempt_token: token}, opts) when is_reference(token) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:mark_loading, source, token}, {:error, :artifact_admission_unavailable})
  end

  @doc "Commits the exact pending attempt after all modules load successfully."
  @spec commit_attempt(claim(), keyword()) :: :ok | {:error, term()}
  def commit_attempt(claim, opts \\ [])

  def commit_attempt(%{source: source, acquired?: false}, opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    safe_call(
      server,
      {:commit_attempt, source, nil},
      {:error, {:artifact_admission_unavailable, server}}
    )
  end

  def commit_attempt(%{source: source, attempt_token: token}, opts) when is_reference(token) do
    server = Keyword.get(opts, :server, __MODULE__)

    safe_call(
      server,
      {:commit_attempt, source, token},
      {:error, {:artifact_admission_unavailable, server}}
    )
  end

  @doc "Aborts only the exact pending attempt and transfers ownership to a waiting caller."
  @spec abort_attempt(claim(), keyword()) :: :ok | {:error, term()}
  def abort_attempt(claim, opts \\ [])

  def abort_attempt(%{source: source, acquired?: false}, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:abort_attempt, source, nil}, :ok)
  end

  def abort_attempt(%{source: source, attempt_token: token}, opts) when is_reference(token) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:abort_attempt, source, token}, :ok)
  end

  @doc "Seals this VM generation against first-time source admission."
  @spec seal(keyword()) :: :ok | {:error, term()}
  def seal(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, :seal_generation, {:error, {:artifact_admission_unavailable, server}})
  end

  @doc "Returns the exact committed module set admitted for a source."
  @spec source_modules(ContributionCleanup.contribution_source(), keyword()) ::
          {:ok, [module()]} | :error
  def source_modules(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:source_modules, source}, :error)
  end

  @doc "Returns the immutable source snapshot fingerprint admitted for a source."
  @spec source_fingerprint(ContributionCleanup.contribution_source(), keyword()) ::
          {:ok, fingerprint()} | :error
  def source_fingerprint(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    safe_call(server, {:source_fingerprint, source}, :error)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    with {:ok, owner} <- state_owner(opts),
         {:ok, stored} <- ArtifactGenerationState.fetch(owner),
         {:ok, state} <- rehydrate(stored, owner) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()} | {:noreply, state()}
  def handle_call(
        {:claim_source_modules, source, _modules, _fingerprint, _source_fingerprint,
         _trusted_application},
        _from,
        %{failed?: true} = state
      ) do
    {:reply, {:error, {:generation_failed, source}}, state}
  end

  def handle_call(
        {:claim_source_modules, source, modules, fingerprint, source_fingerprint,
         trusted_application},
        from,
        state
      ) do
    case Map.fetch(state.sources, source) do
      {:ok, record} ->
        existing_claim(state, from, source, modules, fingerprint, source_fingerprint, record)

      :error when state.sealed? ->
        {:reply, {:error, {:generation_sealed, source}}, state}

      :error ->
        begin_claim(
          state,
          from,
          source,
          modules,
          fingerprint,
          source_fingerprint,
          trusted_application
        )
    end
  end

  def handle_call({operation, source, _token}, _from, %{failed?: true} = state)
      when operation in [:mark_loading, :commit_attempt, :abort_attempt] do
    {:reply, {:error, {:generation_failed, source}}, state}
  end

  def handle_call({:mark_loading, _source, nil}, _from, state), do: {:reply, :ok, state}

  def handle_call({:mark_loading, source, token}, _from, state) do
    case Map.fetch(state.sources, source) do
      {:ok, %{status: {:pending, %{token: ^token} = pending}} = record} ->
        loading = %{pending | phase: :loading}
        {:reply, :ok, put_record(state, source, %{record | status: {:pending, loading}})}

      _other ->
        {:reply, {:error, :invalid_attempt}, state}
    end
  end

  def handle_call({:commit_attempt, source, token}, _from, state) do
    case Map.fetch(state.sources, source) do
      {:ok, %{status: {:pending, %{token: ^token} = pending}} = record} ->
        commit_pending(state, source, record, pending)

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:abort_attempt, source, token}, _from, state) do
    case Map.fetch(state.sources, source) do
      {:ok, %{status: {:pending, %{token: ^token} = pending}} = record} ->
        abort_pending(state, source, record, pending)

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:seal_generation, _from, %{failed?: true} = state) do
    {:reply, {:error, :artifact_generation_failed}, state}
  end

  def handle_call(:seal_generation, _from, state) do
    {:reply, :ok, persist!(%{state | sealed?: true})}
  end

  def handle_call({:source_modules, source}, _from, state) do
    reply =
      case Map.fetch(state.sources, source) do
        {:ok, %{status: status, modules: modules}} when status in [:committed, :failed] ->
          {:ok, modules}

        _other ->
          :error
      end

    {:reply, reply, state}
  end

  def handle_call({:source_fingerprint, source}, _from, state) do
    reply =
      case Map.fetch(state.sources, source) do
        {:ok, %{status: status, source_fingerprint: fingerprint}}
        when status in [:committed, :failed] ->
          {:ok, fingerprint}

        _other ->
          :error
      end

    {:reply, reply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case pending_monitor(state, ref, pid) do
      {:owner, source, record, %{phase: :claimed} = pending} ->
        {:noreply, transfer_or_release(state, source, record, pending.waiters)}

      {:owner, _source, _record, %{phase: :loading}} ->
        {:noreply, fail_generation(state)}

      {:waiter, source, record, pending} ->
        waiters = Enum.reject(pending.waiters, &(&1.monitor == ref))
        next_pending = %{pending | waiters: waiters}
        next_record = %{record | status: {:pending, next_pending}}
        {:noreply, put_record(state, source, next_record)}

      :unknown ->
        _ = reason
        {:noreply, state}
    end
  end

  @spec valid_module_set?([term()], binary(), binary()) :: boolean()
  defp valid_module_set?(modules, fingerprint, source_fingerprint) do
    modules != [] and length(modules) <= @max_modules_per_source and
      Enum.all?(modules, &is_atom/1) and byte_size(fingerprint) == 32 and
      is_binary(source_fingerprint) and byte_size(source_fingerprint) == 32
  end

  @spec existing_claim(
          state(),
          GenServer.from(),
          ContributionCleanup.contribution_source(),
          [module()],
          fingerprint(),
          fingerprint(),
          source_record()
        ) :: {:reply, term(), state()} | {:noreply, state()}
  defp existing_claim(
         state,
         from,
         source,
         modules,
         _fingerprint,
         source_fingerprint,
         %{
           source_fingerprint: source_fingerprint,
           modules: modules,
           status: {:pending, pending_attempt}
         } = record
       ) do
    waiter = monitor_waiter(from)
    pending_attempt = %{pending_attempt | waiters: Enum.concat(pending_attempt.waiters, [waiter])}
    pending = %{record | status: {:pending, pending_attempt}}
    {:noreply, put_record(state, source, pending)}
  end

  defp existing_claim(
         state,
         _from,
         source,
         modules,
         _fingerprint,
         source_fingerprint,
         %{
           source_fingerprint: source_fingerprint,
           modules: modules,
           status: :committed
         } = record
       ) do
    {:reply, {:ok, claim_from_record(source, record, false)}, state}
  end

  defp existing_claim(state, _from, source, _modules, _fingerprint, _source_fingerprint, _record),
    do: {:reply, {:error, {:source_artifact_changed, source}}, state}

  @spec begin_claim(
          state(),
          GenServer.from(),
          term(),
          [module()],
          binary(),
          binary(),
          atom() | nil
        ) :: {:reply, term(), state()}
  defp begin_claim(
         state,
         from,
         source,
         modules,
         fingerprint,
         source_fingerprint,
         trusted_application
       ) do
    case build_source_record(
           state,
           from,
           source,
           modules,
           fingerprint,
           source_fingerprint,
           trusted_application
         ) do
      {:ok, record} ->
        sources = Map.put(state.sources, source, record)

        module_sources =
          Enum.reduce(record.load_modules, state.module_sources, &Map.put(&2, &1, source))

        next_state = persist!(%{state | sources: sources, module_sources: module_sources})
        {:reply, {:ok, claim_from_record(source, record, true)}, next_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @spec build_source_record(
          state(),
          GenServer.from(),
          term(),
          [module()],
          binary(),
          binary(),
          atom() | nil
        ) :: {:ok, source_record()} | {:error, collision()}
  defp build_source_record(
         state,
         from,
         source,
         modules,
         fingerprint,
         source_fingerprint,
         trusted_application
       ) do
    with {:ok, trusted_modules} <- trusted_modules(trusted_application),
         :ok <- validate_module_collisions(state, source, modules, trusted_modules) do
      {adopted_modules, load_modules} =
        Enum.split_with(modules, &MapSet.member?(trusted_modules, &1))

      owner = elem(from, 0)

      {:ok,
       %{
         fingerprint: fingerprint,
         source_fingerprint: source_fingerprint,
         modules: modules,
         load_modules: load_modules,
         adopted_modules: adopted_modules,
         status:
           {:pending,
            %{
              token: make_ref(),
              owner: owner,
              owner_monitor: Process.monitor(owner),
              phase: :claimed,
              waiters: []
            }}
       }}
    end
  end

  @spec trusted_modules(atom() | nil) :: {:ok, MapSet.t(module())} | {:error, collision()}
  defp trusted_modules(nil), do: {:ok, MapSet.new()}

  defp trusted_modules(application) when is_atom(application) do
    case :application.get_key(application, :modules) do
      {:ok, modules} -> {:ok, MapSet.new(modules)}
      :undefined -> {:error, {:invalid_trusted_application, application}}
    end
  end

  defp trusted_modules(application), do: {:error, {:invalid_trusted_application, application}}

  @spec validate_module_collisions(state(), term(), [module()], MapSet.t(module())) ::
          :ok | {:error, collision()}
  defp validate_module_collisions(state, source, modules, trusted_modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case module_collision(state, source, module, trusted_modules) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec module_collision(state(), term(), module(), MapSet.t(module())) ::
          :ok | {:error, collision()}
  defp module_collision(state, source, module, trusted_modules) do
    case Map.get(state.module_sources, module) do
      nil -> host_collision(module, trusted_modules)
      ^source -> :ok
      owner -> {:error, {:module_owned_by_source, module, owner, source}}
    end
  end

  @spec host_collision(module(), MapSet.t(module())) :: :ok | {:error, collision()}
  defp host_collision(module, trusted_modules) do
    if MapSet.member?(trusted_modules, module) do
      :ok
    else
      case :code.which(module) do
        :non_existing -> :ok
        _path -> {:error, {:module_conflicts_with_host, module}}
      end
    end
  end

  @spec claim_from_record(term(), source_record(), boolean()) :: claim()
  defp claim_from_record(source, record, acquired?) do
    token = if acquired?, do: pending_token(record.status), else: nil

    %{
      source: source,
      fingerprint: record.fingerprint,
      source_fingerprint: record.source_fingerprint,
      modules: record.modules,
      load_modules: record.load_modules,
      adopted_modules: record.adopted_modules,
      acquired?: acquired?,
      attempt_token: token
    }
  end

  @spec pending_token(:committed | {:pending, pending_attempt()}) :: reference() | nil
  defp pending_token({:pending, pending}), do: pending.token
  defp pending_token(:committed), do: nil

  @spec monitor_waiter(GenServer.from()) :: waiter()
  defp monitor_waiter(from) do
    pid = elem(from, 0)
    %{from: from, pid: pid, monitor: Process.monitor(pid)}
  end

  @spec pending_monitor(state(), reference(), pid()) ::
          {:owner, term(), source_record(), pending_attempt()}
          | {:waiter, term(), source_record(), pending_attempt()}
          | :unknown
  defp pending_monitor(state, ref, pid) do
    Enum.find_value(state.sources, :unknown, fn {source, record} ->
      monitor_in_record(source, record, ref, pid)
    end)
  end

  @spec monitor_in_record(term(), source_record(), reference(), pid()) ::
          {:owner, term(), source_record(), pending_attempt()}
          | {:waiter, term(), source_record(), pending_attempt()}
          | false
  defp monitor_in_record(source, %{status: {:pending, pending}} = record, ref, pid) do
    monitor_in_pending(source, record, pending, ref, pid)
  end

  defp monitor_in_record(_source, %{status: status}, _ref, _pid)
       when status in [:committed, :failed],
       do: false

  @spec monitor_in_pending(term(), source_record(), pending_attempt(), reference(), pid()) ::
          {:owner, term(), source_record(), pending_attempt()}
          | {:waiter, term(), source_record(), pending_attempt()}
          | false
  defp monitor_in_pending(source, record, %{owner: pid, owner_monitor: ref} = pending, ref, pid),
    do: {:owner, source, record, pending}

  defp monitor_in_pending(source, record, pending, ref, pid) do
    if Enum.any?(pending.waiters, &(&1.pid == pid and &1.monitor == ref)),
      do: {:waiter, source, record, pending},
      else: false
  end

  @spec commit_pending(state(), term(), source_record(), pending_attempt()) ::
          {:reply, term(), state()}
  defp commit_pending(state, source, record, pending) do
    if owner_died_after_loading?(pending) do
      failed = fail_generation(state)
      {:reply, {:error, {:generation_failed, source}}, failed}
    else
      demonitor_pending(pending)
      committed = %{record | status: :committed}
      next_state = put_record(state, source, committed)

      Enum.each(pending.waiters, fn waiter ->
        GenServer.reply(waiter.from, {:ok, claim_from_record(source, committed, false)})
      end)

      {:reply, :ok, next_state}
    end
  end

  @spec abort_pending(state(), term(), source_record(), pending_attempt()) ::
          {:reply, term(), state()}
  defp abort_pending(state, source, record, pending) do
    if owner_died_after_loading?(pending) do
      failed = fail_generation(state)
      {:reply, {:error, {:generation_failed, source}}, failed}
    else
      Process.demonitor(pending.owner_monitor, [:flush])
      {:reply, :ok, transfer_or_release(state, source, record, pending.waiters)}
    end
  end

  @spec owner_died_after_loading?(pending_attempt()) :: boolean()
  defp owner_died_after_loading?(%{phase: :loading, owner: owner}),
    do: not Process.alive?(owner)

  defp owner_died_after_loading?(%{phase: :claimed}), do: false

  @spec fail_generation(state()) :: state()
  defp fail_generation(state) do
    {sources, waiters} =
      Enum.reduce(state.sources, {%{}, []}, fn {source, record}, {sources, waiters} ->
        case record.status do
          {:pending, pending} ->
            demonitor_pending(pending)

            pending_waiters =
              Enum.reduce(pending.waiters, waiters, fn waiter, acc ->
                [{source, waiter} | acc]
              end)

            {Map.put(sources, source, %{record | status: :failed}), pending_waiters}

          status when status in [:committed, :failed] ->
            {Map.put(sources, source, record), waiters}
        end
      end)

    failed = persist!(%{state | sources: sources, failed?: true})

    Enum.each(waiters, fn {source, waiter} ->
      GenServer.reply(waiter.from, {:error, {:generation_failed, source}})
    end)

    failed
  end

  @spec transfer_or_release(state(), term(), source_record(), [waiter()]) :: state()
  defp transfer_or_release(state, source, record, waiters) do
    case next_live_waiter(waiters) do
      {:ok, next, rest} ->
        Process.demonitor(next.monitor, [:flush])
        owner_monitor = Process.monitor(next.pid)

        pending = %{
          token: make_ref(),
          owner: next.pid,
          owner_monitor: owner_monitor,
          phase: :claimed,
          waiters: rest
        }

        next_record = %{record | status: {:pending, pending}}
        next_state = put_record(state, source, next_record)
        GenServer.reply(next.from, {:ok, claim_from_record(source, next_record, true)})
        next_state

      :none ->
        sources = Map.delete(state.sources, source)
        module_sources = Map.drop(state.module_sources, record.load_modules)
        persist!(%{state | sources: sources, module_sources: module_sources})
    end
  end

  @spec next_live_waiter([waiter()]) :: {:ok, waiter(), [waiter()]} | :none
  defp next_live_waiter([]), do: :none

  defp next_live_waiter([waiter | rest]) do
    if Process.alive?(waiter.pid) do
      {:ok, waiter, rest}
    else
      Process.demonitor(waiter.monitor, [:flush])
      next_live_waiter(rest)
    end
  end

  @spec demonitor_pending(pending_attempt()) :: :ok
  defp demonitor_pending(pending) do
    Process.demonitor(pending.owner_monitor, [:flush])
    Enum.each(pending.waiters, &Process.demonitor(&1.monitor, [:flush]))
    :ok
  end

  @spec put_record(state(), term(), source_record()) :: state()
  defp put_record(state, source, record),
    do: persist!(%{state | sources: Map.put(state.sources, source, record)})

  @spec persist!(state()) :: state()
  defp persist!(state) do
    persisted = Map.delete(state, :state_owner)

    case ArtifactGenerationState.store(state.state_owner, persisted) do
      :ok -> state
      {:error, reason} -> exit({:artifact_generation_state_unavailable, reason})
    end
  end

  @spec state_owner(keyword()) :: {:ok, GenServer.server()} | {:error, term()}
  defp state_owner(opts) do
    default_owner =
      if Keyword.get(opts, :name, __MODULE__) == nil, do: nil, else: ArtifactGenerationState

    case Keyword.get(opts, :state_owner, default_owner) do
      nil ->
        start_private_owner()

      owner ->
        case ArtifactGenerationState.fetch(owner) do
          {:ok, _state} -> {:ok, owner}
          {:error, reason} -> {:error, {:artifact_generation_state_unavailable, reason}}
        end
    end
  end

  @spec start_private_owner() :: {:ok, pid()} | {:error, term()}
  defp start_private_owner do
    ArtifactGenerationState.start_link(name: nil, fatal_on_loss: false)
  end

  @spec rehydrate(map() | nil, GenServer.server()) :: {:ok, state()} | {:error, term()}
  defp rehydrate(nil, owner) do
    state = %{
      sources: %{},
      module_sources: %{},
      sealed?: false,
      failed?: false,
      state_owner: owner
    }

    :ok = ArtifactGenerationState.store(owner, Map.delete(state, :state_owner))
    {:ok, state}
  end

  defp rehydrate(stored, owner) when is_map(stored) do
    sources = Map.get(stored, :sources, %{})
    interrupted? = pending_sources?(sources)
    failed? = Map.get(stored, :failed?, false) or interrupted?

    state = %{
      sources: if(interrupted?, do: invalidate_pending_sources(sources), else: sources),
      module_sources: Map.get(stored, :module_sources, %{}),
      sealed?: Map.get(stored, :sealed?, false),
      failed?: failed?,
      state_owner: owner
    }

    persist_rehydrated_state(state, interrupted?)
  end

  @spec persist_rehydrated_state(state(), boolean()) :: {:ok, state()} | {:error, term()}
  defp persist_rehydrated_state(state, false), do: {:ok, state}

  defp persist_rehydrated_state(state, true) do
    case ArtifactGenerationState.store(state.state_owner, Map.delete(state, :state_owner)) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:artifact_generation_state_unavailable, reason}}
    end
  end

  @spec pending_sources?(map()) :: boolean()
  defp pending_sources?(sources) do
    Enum.any?(sources, fn {_source, record} ->
      match?({:pending, _pending}, record.status)
    end)
  end

  @spec invalidate_pending_sources(map()) :: map()
  defp invalidate_pending_sources(sources) do
    Map.new(sources, fn
      {source, %{status: {:pending, _pending}} = record} ->
        {source, %{record | status: :failed}}

      entry ->
        entry
    end)
  end

  @spec safe_call(GenServer.server(), term(), result, timeout()) :: result when result: var
  defp safe_call(server, message, fallback, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> fallback
  end
end
