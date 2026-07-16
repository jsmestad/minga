defmodule Minga.Extension.Lazy do
  @moduledoc "Lazy/deferred activation helpers routed through stable extension Instances."

  alias Minga.Extension.DeferredBatchCompleteEvent
  alias Minga.Extension.Instance
  alias Minga.Extension.Instance.Source
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Log

  @typedoc "Result from registering lazy stubs."
  @type stub_result :: :ok | {:error, term()}

  @doc "Registers path/Git/Hex stubs through the extension Instance."
  @spec register_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: stub_result()
  def register_stubs(supervisor, registry, name, entry, opts) do
    ExtSupervisor.register_lazy_extension(supervisor, registry, name, entry, opts)
  end

  @doc "Registers module-source stubs through the same extension Instance."
  @spec register_module_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: stub_result()
  def register_module_stubs(supervisor, registry, name, entry, opts) do
    register_stubs(supervisor, registry, name, entry, opts)
  end

  @doc "Activates the captured lazy declaration through its stable mailbox."
  @spec autoload(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtSupervisor.start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  def autoload(supervisor, _registry, name, opts) do
    registry =
      Keyword.get(
        opts,
        :instance_registry,
        InstanceRegistry.registry_for_root(root_supervisor(supervisor))
      )

    case InstanceRegistry.whereis(registry, :instance, name) do
      pid when is_pid(pid) -> safe_start(name, InstanceRegistry.via(registry, :instance, name))
      nil -> {:error, :not_registered}
    end
  end

  @doc "Returns the effective policy already present on a declaration."
  @spec effective_load_policy(ExtRegistry.entry()) :: Minga.Extension.load_policy()
  def effective_load_policy(%{load_policy: nil, module: module}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__load_policy__, 0) do
      module.__load_policy__()
    else
      :eager
    end
  end

  def effective_load_policy(%{load_policy: nil}), do: :eager
  def effective_load_policy(%{load_policy: policy}), do: policy
  def effective_load_policy(_entry), do: :eager

  @doc "Discovers policy through the single source preparation path."
  @spec discover_load_policy(atom(), ExtRegistry.entry(), ExtSupervisor.start_opts()) ::
          {:ok, Minga.Extension.load_policy(), module()} | {:error, term()}
  def discover_load_policy(name, entry, opts) do
    with {:ok, policy, artifact} <- Source.discover_load_policy(name, entry, opts) do
      {:ok, entry.load_policy || policy, artifact.module}
    end
  end

  @doc "Returns true for eager policy."
  @spec eager?(Minga.Extension.load_policy()) :: boolean()
  def eager?(:eager), do: true
  def eager?(_policy), do: false

  @doc "Returns true for deferred policy."
  @spec deferred?(Minga.Extension.load_policy()) :: boolean()
  def deferred?(:deferred), do: true
  def deferred?(_policy), do: false

  @doc "Returns true for trigger-based policy."
  @spec trigger_based?(Minga.Extension.load_policy()) :: boolean()
  def trigger_based?({tag, _trigger}) when tag in [:on_command, :on_filetype, :on_key], do: true
  def trigger_based?(_policy), do: false

  @deferred_load_delay_ms 100

  @doc "Schedules captured Instance identities after first-paint delay."
  @spec schedule_deferred_loads([{GenServer.server(), atom(), ExtRegistry.entry()}]) :: :ok
  def schedule_deferred_loads([]), do: :ok

  def schedule_deferred_loads(instances) do
    schedule_deferred_batch(instances, [], length(instances))
  end

  @doc "Registers declarations and schedules their deferred Instance activations."
  @spec schedule_deferred_loads(
          GenServer.server(),
          GenServer.server(),
          [{atom(), ExtRegistry.entry()}],
          ExtSupervisor.start_opts()
        ) :: :ok
  def schedule_deferred_loads(supervisor, registry, entries, opts) do
    {instances, failures} =
      Enum.reduce(entries, {[], []}, fn {name, entry}, {instances, failures} ->
        case ExtSupervisor.register_lazy_extension(supervisor, registry, name, entry, opts) do
          :ok ->
            instance_registry =
              Keyword.get(
                opts,
                :instance_registry,
                InstanceRegistry.registry_for_root(root_supervisor(supervisor))
              )

            instance = {InstanceRegistry.via(instance_registry, :instance, name), name, entry}
            {[instance | instances], failures}

          {:error, reason} ->
            failure = %{extension: name, reason: reason}

            Log.warning(
              :config,
              "Extension #{name} deferred stub registration failed: #{inspect(reason)}"
            )

            {instances, [failure | failures]}
        end
      end)

    schedule_deferred_batch(Enum.reverse(instances), Enum.reverse(failures), length(entries))
  end

  @spec schedule_deferred_batch(
          [{GenServer.server(), atom(), ExtRegistry.entry()}],
          [DeferredBatchCompleteEvent.failure()],
          non_neg_integer()
        ) :: :ok
  defp schedule_deferred_batch(instances, registration_failures, total_count) do
    {:ok, _pid} =
      Task.start(fn ->
        receive do
        after
          @deferred_load_delay_ms -> :ok
        end

        failures =
          instances
          |> Enum.reduce(
            Enum.reverse(registration_failures),
            &start_deferred_instance/2
          )
          |> Enum.reverse()

        event = DeferredBatchCompleteEvent.new(total_count, failures)
        Minga.Events.broadcast(:extension_deferred_batch_complete, event)
      end)

    :ok
  end

  @spec start_deferred_instance(
          {GenServer.server(), atom(), ExtRegistry.entry()},
          [DeferredBatchCompleteEvent.failure()]
        ) :: [DeferredBatchCompleteEvent.failure()]
  defp start_deferred_instance({instance, name, declaration}, failures) do
    case safe_start_deferred(instance, declaration) do
      {:ok, _pid} ->
        Log.info(:config, "Extension #{name} deferred load complete")
        failures

      {:error, reason} ->
        Log.warning(:config, "Extension #{name} deferred load failed: #{inspect(reason)}")
        [%{extension: name, reason: reason} | failures]
    end
  end

  @spec safe_start(atom(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  defp safe_start(name, instance) do
    case call_instance(instance, &Instance.start/1) do
      {:authority_call_exit, reason} ->
        failure = {:authority_call_exit, name, reason}
        Log.warning(:config, "Extension #{name} lazy activation failed: #{inspect(failure)}")
        {:error, failure}

      result ->
        result
    end
  end

  @spec safe_start_deferred(GenServer.server(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  defp safe_start_deferred(instance, declaration) do
    case call_instance(instance, fn current -> Instance.start_deferred(current, declaration) end) do
      {:authority_call_exit, reason} -> {:error, {:instance_call_exit, reason}}
      result -> result
    end
  end

  @spec call_instance(GenServer.server(), (GenServer.server() -> result)) ::
          result | {:authority_call_exit, term()}
        when result: var
  defp call_instance(instance, fun) do
    fun.(instance)
  catch
    :exit, reason -> {:authority_call_exit, reason}
  end

  @spec root_supervisor(GenServer.server()) :: GenServer.server()
  defp root_supervisor(ExtSupervisor), do: Minga.Extension.RootSupervisor
  defp root_supervisor(supervisor), do: supervisor
end
