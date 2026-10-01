defmodule MingaAgent.ArtifactStores do
  @moduledoc "Stateless lazy access to record-scoped retained-artifact stores."

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStores.Runtime
  alias MingaAgent.ArtifactStores.Copy
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output

  @doc "Returns the process names, root, and policy owned by the production artifact subtree."
  @spec default_runtime() :: Runtime.t()
  def default_runtime do
    {:ok, runtime} =
      Runtime.new(
        root: MingaAgent.Config.artifact_root(),
        quota: MingaAgent.ArtifactQuota,
        registry: MingaAgent.ArtifactStores.Registry,
        store_supervisor: MingaAgent.ArtifactStores.StoreSupervisor,
        limits: MingaAgent.Config.artifact_limits()
      )

    runtime
  end

  @doc "Returns the unique record store, starting it lazily after quota admission when absent."
  @spec ensure_record(String.t(), Runtime.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_record(record_id, runtime \\ default_runtime())

  def ensure_record(record_id, %Runtime{} = runtime)
      when is_binary(record_id) and byte_size(record_id) > 0 do
    case lookup(runtime.registry, record_id) do
      {:ok, store} -> {:ok, store}
      :error -> start_record(record_id, runtime)
    end
  end

  def ensure_record(_record_id, %Runtime{}), do: {:error, :invalid_record_id}

  @doc """
  Copies retained output into another record and rewrites every foreign token.

  The copy ID must be stable for retries of the same fork operation.
  """
  @spec copy_output(String.t(), String.t(), Output.t(), String.t(), Runtime.t()) ::
          {:ok, Output.t()} | {:error, term()}
  def copy_output(source_record, target_record, output, copy_id, runtime \\ default_runtime())

  def copy_output(record, record, %Output{} = output, copy_id, %Runtime{})
      when is_binary(record) and byte_size(record) > 0 and is_binary(copy_id) and
             byte_size(copy_id) > 0,
      do: {:ok, output}

  def copy_output(source_record, target_record, %Output{} = output, copy_id, %Runtime{} = runtime)
      when is_binary(source_record) and byte_size(source_record) > 0 and
             is_binary(target_record) and byte_size(target_record) > 0 and
             is_binary(copy_id) and byte_size(copy_id) > 0 do
    with {:ok, source} <- ensure_record(source_record, runtime),
         {:ok, target} <- ensure_record(target_record, runtime) do
      Copy.output(source, target, output, copy_id)
    end
  end

  def copy_output(_source_record, _target_record, _output, _copy_id, %Runtime{}),
    do: {:error, :invalid_artifact_copy}

  @doc "Explicitly deletes one durable record and its quota row; missing records are already deleted."
  @spec delete_record(String.t(), Runtime.t()) :: :ok | {:error, term()}
  def delete_record(record_id, runtime \\ default_runtime())

  def delete_record(record_id, %Runtime{} = runtime)
      when is_binary(record_id) and byte_size(record_id) > 0 do
    namespace = Reference.namespace(record_id)

    case lookup(runtime.registry, record_id) do
      {:ok, store} -> delete_running_record(store)
      :error -> delete_stopped_record(record_id, namespace, runtime)
    end
  end

  def delete_record(_record_id, %Runtime{}), do: {:error, :invalid_record_id}

  @spec delete_stopped_record(String.t(), String.t(), Runtime.t()) :: :ok | {:error, term()}
  defp delete_stopped_record(record_id, namespace, runtime) do
    case ArtifactQuota.namespace_registered?(runtime.quota, runtime.root, namespace) do
      {:ok, false} -> :ok
      {:ok, true} -> delete_started_record(record_id, runtime)
      {:error, _reason} = error -> error
    end
  end

  @spec delete_started_record(String.t(), Runtime.t()) :: :ok | {:error, term()}
  defp delete_started_record(record_id, runtime) do
    case ensure_record(record_id, runtime) do
      {:ok, store} -> delete_running_record(store)
      {:error, _reason} = error -> error
    end
  end

  @spec delete_running_record(pid()) :: :ok | {:error, term()}
  defp delete_running_record(store) do
    monitor = Process.monitor(store)

    case ArtifactStore.delete_record(store) do
      :ok ->
        receive do
          {:DOWN, ^monitor, :process, ^store, _reason} -> :ok
        end

      {:error, _reason} = error ->
        Process.demonitor(monitor, [:flush])
        error
    end
  end

  @spec start_record(String.t(), Runtime.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  defp start_record(record_id, runtime) do
    name = {:via, Registry, {runtime.registry, record_id}}

    child =
      Supervisor.child_spec(
        {ArtifactStore,
         root: runtime.root,
         quota: runtime.quota,
         session_id: record_id,
         limits: runtime.limits,
         name: name},
        restart: :transient
      )

    case DynamicSupervisor.start_child(runtime.store_supervisor, child) do
      {:ok, store} -> {:ok, store}
      {:error, {:already_started, store}} -> {:ok, store}
      {:error, :already_present} -> lookup_after_start(runtime.registry, record_id)
      {:error, _reason} = error -> error
    end
  end

  @spec lookup_after_start(atom(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp lookup_after_start(registry, record_id) do
    case lookup(registry, record_id) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :record_start_race}
    end
  end

  @spec lookup(atom(), String.t()) :: {:ok, pid()} | :error
  defp lookup(registry, record_id) do
    case Registry.whereis_name({registry, record_id}) do
      store when is_pid(store) -> {:ok, store}
      :undefined -> :error
    end
  end
end
