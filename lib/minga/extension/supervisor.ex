defmodule Minga.Extension.Supervisor do
  @moduledoc """
  Public extension lifecycle facade.

  Per-extension ordering and policy live exclusively in `Extension.Instance`.
  This module retains bulk Git/Hex prerequisites, declaration reconciliation,
  iteration/error aggregation, pending-restart queries, and list projection.
  """

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Hex, as: ExtHex
  alias Minga.Extension.Instance
  alias Minga.Extension.Instance.Contributions
  alias Minga.Extension.Instance.Source
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Lazy
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RootSupervisor
  alias Minga.Log

  @type start_failure :: %{extension: atom(), reason: term()}
  @type stop_failure :: %{extension: atom(), reason: term()}

  @typedoc "Injected lifecycle collaborators."
  @type start_opts :: [
          command_registry: GenServer.server(),
          keymap: GenServer.server(),
          callbacks: %{atom() => function()},
          code_lease: GenServer.server(),
          callback_registry: atom(),
          artifact_admission: GenServer.server(),
          runtime_application: atom(),
          runtime_owned_modules: [module()],
          instance_registry: atom(),
          slow_lifecycle_threshold_ms: non_neg_integer(),
          transition_timeout_ms: pos_integer(),
          callback_timeout_ms: pos_integer(),
          runtime_query_timeout_ms: pos_integer(),
          drain_timeout_ms: pos_integer()
        ]

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, RootSupervisor)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @doc "Starts an isolated root supervisor for tests and embedded callers."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, RootSupervisor)

    instance_registry =
      Keyword.get(opts, :instance_registry, InstanceRegistry.registry_for_root(name))

    case Process.whereis(instance_registry) do
      nil ->
        {:ok, _pid} = InstanceRegistry.start_link(name: instance_registry)

      _pid ->
        :ok
    end

    RootSupervisor.start_link(Keyword.put(opts, :name, name))
  end

  @doc "Starts all declared extensions after bulk source prerequisites."
  @spec start_all() :: :ok | {:error, [start_failure()]}
  @spec start_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [start_failure()]}
  @spec start_all(GenServer.server(), GenServer.server(), start_opts()) ::
          :ok | {:error, [start_failure()]}
  def start_all, do: start_all(__MODULE__, ExtRegistry, [])
  def start_all(supervisor, registry), do: start_all(supervisor, registry, [])

  def start_all(supervisor, registry, opts) do
    reconciliation_failures = reconcile_declarations(supervisor, registry, opts)
    authority_failures = ensure_declared_authorities(supervisor, registry, opts)

    hex_failure = install_hex(registry)
    git_failures = resolve_git_extensions(registry)
    prerequisite_failures = git_failures ++ List.wrap(hex_failure)

    routing_failures =
      route_prerequisite_failures(
        supervisor,
        registry,
        prerequisite_failures,
        hex_failure,
        opts
      )

    failed_names = MapSet.new(Enum.map(prerequisite_failures, & &1.extension))

    initial_failures =
      reconciliation_failures ++
        authority_failures ++ prerequisite_failures ++ routing_failures

    {reversed_failures, deferred} =
      registry
      |> ExtRegistry.all()
      |> Enum.reduce({Enum.reverse(initial_failures), []}, fn {name, entry},
                                                              {failures, deferred} ->
        if failed_prerequisite?(name, entry, failed_names, hex_failure) or
             Enum.any?(authority_failures, &(&1.extension == name)) do
          {failures, deferred}
        else
          start_by_policy(supervisor, registry, name, entry, opts, failures, deferred)
        end
      end)

    Lazy.schedule_deferred_loads(deferred)

    case Enum.reverse(reversed_failures) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc "Stops all declared extension authorities, aggregating failures."
  @spec stop_all() :: :ok | {:error, [stop_failure()]}
  @spec stop_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [stop_failure()]}
  @spec stop_all(GenServer.server(), GenServer.server(), start_opts()) ::
          :ok | {:error, [stop_failure()]}
  def stop_all, do: stop_all(__MODULE__, ExtRegistry, [])
  def stop_all(supervisor, registry), do: stop_all(supervisor, registry, [])

  def stop_all(supervisor, registry, opts) do
    failures =
      registry
      |> ExtRegistry.all()
      |> Enum.reduce([], fn {name, entry}, failures ->
        case stop_extension(supervisor, registry, name, entry, opts) do
          :ok -> failures
          {:error, reason} -> [%{extension: name, reason: reason} | failures]
        end
      end)
      |> Enum.reverse()

    case failures do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc "Starts one extension through its stable authority and returns the runtime PID."
  @spec start_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  @spec start_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  def start_extension(supervisor, registry, name, entry, opts \\ []) do
    call_declared_instance(supervisor, registry, name, entry, opts, fn instance ->
      start_instance(name, instance)
    end)
  end

  @spec start_instance(atom(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  defp start_instance(name, instance),
    do: safe_instance_call(name, fn -> Instance.start(instance) end)

  @doc "Registers one lazy declaration and its activation stubs through its stable authority."
  @spec register_lazy_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  def register_lazy_extension(supervisor, registry, name, entry, opts \\ []) do
    call_declared_instance(supervisor, registry, name, entry, opts, &Instance.stub/1)
  end

  @doc "Starts a captured deferred declaration through the same Instance."
  @spec start_deferred_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok
  def start_deferred_extension(supervisor, _registry, name, entry, opts \\ []) do
    supervisor
    |> call_existing_instance(name, opts, fn instance ->
      Instance.start_deferred(instance, entry)
    end)
    |> start_deferred_instance(name)
  end

  @spec start_deferred_instance(:absent | {:ok, pid()} | {:error, term()}, atom()) :: :ok
  defp start_deferred_instance(:absent, name) do
    Log.warning(:config, "Extension #{name} deferred load skipped: authority unavailable")
    :ok
  end

  defp start_deferred_instance(result, name), do: handle_deferred_start(result, name)

  @spec handle_deferred_start({:ok, pid()} | {:error, term()}, atom()) :: :ok
  defp handle_deferred_start({:ok, _pid}, _name), do: :ok

  defp handle_deferred_start({:error, reason}, name) do
    Log.warning(:config, "Extension #{name} deferred load failed: #{inspect(reason)}")
    :ok
  end

  @doc "Stops one extension authority. Stop is idempotent."
  @spec stop_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          :ok | {:error, term()}
  @spec stop_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  def stop_extension(supervisor, registry, name, entry, opts \\ []) do
    supervisor
    |> call_existing_instance(name, opts, fn instance -> Instance.stop(instance, opts) end)
    |> stop_existing_instance(supervisor, registry, name, entry, opts)
  end

  @spec stop_existing_instance(
          :ok | :absent | {:error, term()},
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  defp stop_existing_instance(:ok, _supervisor, _registry, _name, _entry, _opts), do: :ok

  defp stop_existing_instance(:absent, supervisor, registry, name, entry, opts) do
    case ExtRegistry.get(registry, name) do
      :error -> :ok
      {:ok, _declaration} -> stop_declared_instance(supervisor, registry, name, entry, opts)
    end
  end

  defp stop_existing_instance(
         {:error, reason},
         _supervisor,
         _registry,
         _name,
         _entry,
         _opts
       ),
       do: {:error, reason}

  @spec stop_declared_instance(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  defp stop_declared_instance(supervisor, registry, name, entry, opts) do
    call_declared_instance(supervisor, registry, name, entry, opts, fn instance ->
      Instance.stop(instance, opts)
    end)
  end

  @doc "Reports path/Git sources changed since current-generation admission."
  @spec pending_artifact_restarts(GenServer.server(), start_opts()) :: [atom()]
  def pending_artifact_restarts(registry, opts \\ []) do
    for {name, entry} <- ExtRegistry.all(registry),
        Source.pending_restart?(name, entry, opts),
        do: name
  end

  @doc "Returns compatible `{name, version, status}` list projection."
  @spec list_extensions() :: [{atom(), String.t(), Minga.Extension.extension_status()}]
  @spec list_extensions(GenServer.server()) ::
          [{atom(), String.t(), Minga.Extension.extension_status()}]
  def list_extensions(registry \\ ExtRegistry) do
    for {name, entry} <- ExtRegistry.all(registry) do
      {name, version(entry.module), entry.status}
    end
  end

  @doc "Returns whether a module exports the required extension callbacks."
  @spec implements_extension?(module()) :: boolean()
  def implements_extension?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      function_exported?(module, :description, 0) and
      function_exported?(module, :version, 0) and
      function_exported?(module, :init, 1)
  end

  @doc "Validates that an extension module exports every required callback."
  @spec validate_behaviour(module(), atom()) :: :ok | {:error, String.t()}
  def validate_behaviour(module, name) do
    missing =
      Enum.reject([:name, :description, :version, :init], fn
        :init -> function_exported?(module, :init, 1)
        function -> function_exported?(module, function, 0)
      end)

    case missing do
      [] -> :ok
      functions -> {:error, "extension #{name} missing callbacks: #{inspect(functions)}"}
    end
  end

  @doc "Registers and validates an extension module's declared options."
  @spec register_and_validate_options(atom(), module(), keyword()) :: :ok | {:error, term()}
  defdelegate register_and_validate_options(name, module, config),
    to: Contributions,
    as: :register_options

  @doc "Removes command, keymap, and callback contributions owned by an extension."
  @spec cleanup_extension_contributions(
          atom(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) ::
          :ok | {:error, [map()]}
  def cleanup_extension_contributions(name, command_registry, keymap, opts) do
    Contributions.cleanup(
      name,
      opts
      |> Keyword.put(:command_registry, command_registry)
      |> Keyword.put(:keymap, keymap)
    )
  end

  @spec start_by_policy(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts(),
          [start_failure()],
          [{GenServer.server(), atom(), ExtRegistry.entry()}]
        ) :: {[start_failure()], [{GenServer.server(), atom(), ExtRegistry.entry()}]}
  defp start_by_policy(supervisor, registry, name, entry, opts, failures, deferred) do
    result =
      call_declared_instance(supervisor, registry, name, entry, opts, fn instance ->
        with {:ok, policy} <- Instance.load_policy(instance) do
          apply_policy(policy, instance, name, entry)
        end
      end)

    collect_policy_result(result, name, entry, failures, deferred)
  end

  @spec apply_policy(
          Minga.Extension.load_policy(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry()
        ) :: {:ok, pid()} | :ok | {:deferred, GenServer.server()} | {:error, term()}
  defp apply_policy(:eager, instance, name, _entry), do: start_instance(name, instance)
  defp apply_policy(:deferred, instance, _name, _entry), do: {:deferred, instance}

  defp apply_policy({tag, _trigger}, instance, _name, _entry)
       when tag in [:on_command, :on_filetype, :on_key],
       do: Instance.stub(instance)

  defp apply_policy(invalid, instance, name, entry) do
    Log.warning(:config, "Invalid load_policy #{inspect(invalid)}, falling back to :eager")
    apply_policy(:eager, instance, name, entry)
  end

  @spec collect_policy_result(
          {:ok, pid()} | :ok | {:deferred, GenServer.server()} | {:error, term()},
          atom(),
          ExtRegistry.entry(),
          [start_failure()],
          [{GenServer.server(), atom(), ExtRegistry.entry()}]
        ) :: {[start_failure()], [{GenServer.server(), atom(), ExtRegistry.entry()}]}
  defp collect_policy_result({:ok, _pid}, _name, _entry, failures, deferred),
    do: {failures, deferred}

  defp collect_policy_result(:ok, _name, _entry, failures, deferred), do: {failures, deferred}

  defp collect_policy_result({:deferred, instance}, name, entry, failures, deferred),
    do: {failures, [{instance, name, entry} | deferred]}

  defp collect_policy_result({:error, reason}, name, _entry, failures, deferred),
    do: {[%{extension: name, reason: reason} | failures], deferred}

  @spec locate_instance(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: {:ok, GenServer.server()} | {:error, term()}
  defp locate_instance(supervisor, registry, name, entry, opts) do
    root = root_supervisor(supervisor)
    instance_registry = instance_registry(supervisor, opts)

    RootSupervisor.ensure_root(
      root,
      name,
      entry,
      registry,
      Keyword.put(opts, :instance_registry, instance_registry)
    )
  end

  @spec existing_instance(GenServer.server(), atom(), start_opts()) ::
          {:ok, GenServer.server()} | :absent | {:error, term()}
  defp existing_instance(supervisor, name, opts) do
    root = root_supervisor(supervisor)
    registry = instance_registry(supervisor, opts)
    RootSupervisor.existing_authority(root, name, instance_registry: registry)
  end

  @spec reconcile_declarations(GenServer.server(), GenServer.server(), start_opts()) ::
          [start_failure()]
  defp reconcile_declarations(supervisor, registry, opts) do
    root = root_supervisor(supervisor)
    names = registry |> ExtRegistry.all() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    registry_name = instance_registry(supervisor, opts)
    root_opts = Keyword.put(opts, :instance_registry, registry_name)

    root
    |> RootSupervisor.names(root_opts)
    |> Enum.reduce([], fn name, failures ->
      reconcile_declaration(root, root_opts, name, MapSet.member?(names, name), failures)
    end)
    |> Enum.reverse()
  end

  @spec reconcile_declaration(
          GenServer.server(),
          keyword(),
          atom(),
          boolean(),
          [start_failure()]
        ) :: [start_failure()]
  defp reconcile_declaration(_root, _root_opts, _name, true, failures), do: failures

  defp reconcile_declaration(root, root_opts, name, false, failures) do
    case RootSupervisor.terminate_root(root, name, root_opts) do
      :ok ->
        failures

      {:error, reason} ->
        [%{extension: name, reason: {:terminate_root_failed, reason}} | failures]
    end
  end

  @spec root_supervisor(GenServer.server()) :: GenServer.server()
  defp root_supervisor(__MODULE__), do: RootSupervisor
  defp root_supervisor(supervisor), do: supervisor

  @spec instance_registry(GenServer.server(), start_opts()) :: atom()
  defp instance_registry(supervisor, opts) do
    Keyword.get(
      opts,
      :instance_registry,
      InstanceRegistry.registry_for_root(root_supervisor(supervisor))
    )
  end

  @spec ensure_declared_authorities(GenServer.server(), GenServer.server(), start_opts()) ::
          [start_failure()]
  defp ensure_declared_authorities(supervisor, registry, opts) do
    registry
    |> ExtRegistry.all()
    |> Enum.reduce([], fn {name, entry}, failures ->
      ensure_declared_authority(supervisor, registry, name, entry, opts, failures)
    end)
    |> Enum.reverse()
  end

  @spec ensure_declared_authority(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts(),
          [start_failure()]
        ) :: [start_failure()]
  defp ensure_declared_authority(supervisor, registry, name, entry, opts, failures) do
    supervisor
    |> call_declared_instance(registry, name, entry, opts, fn _instance -> :ok end)
    |> collect_authority_failure(name, failures)
  end

  @spec collect_authority_failure(:ok | {:error, term()}, atom(), [start_failure()]) ::
          [start_failure()]
  defp collect_authority_failure(:ok, _name, failures), do: failures

  defp collect_authority_failure({:error, reason}, name, failures),
    do: [%{extension: name, reason: reason} | failures]

  @spec route_prerequisite_failures(
          GenServer.server(),
          GenServer.server(),
          [start_failure()],
          start_failure() | nil,
          start_opts()
        ) :: [start_failure()]
  defp route_prerequisite_failures(supervisor, registry, failures, hex_failure, opts) do
    failed_by_name = Map.new(failures, &{&1.extension, &1.reason})

    registry
    |> ExtRegistry.all()
    |> Enum.reduce([], fn {name, entry}, routing_failures ->
      reason = prerequisite_reason(name, entry, failed_by_name, hex_failure)
      collect_routing_failure(supervisor, name, reason, opts, routing_failures)
    end)
    |> Enum.reverse()
  end

  @spec collect_routing_failure(
          GenServer.server(),
          atom(),
          term() | nil,
          start_opts(),
          [start_failure()]
        ) :: [start_failure()]
  defp collect_routing_failure(_supervisor, _name, nil, _opts, failures), do: failures

  defp collect_routing_failure(supervisor, name, reason, opts, failures) do
    case route_prerequisite_failure(supervisor, name, reason, opts) do
      :ok -> failures
      {:error, route_reason} -> [%{extension: name, reason: route_reason} | failures]
    end
  end

  @spec route_prerequisite_failure(GenServer.server(), atom(), term(), start_opts()) ::
          :ok | {:error, term()}
  defp route_prerequisite_failure(supervisor, name, reason, opts) do
    supervisor
    |> call_existing_instance(name, opts, fn instance ->
      {:instance_result, Instance.fail_start(instance, reason)}
    end)
    |> route_existing_prerequisite_failure(name, reason)
  end

  @spec route_existing_prerequisite_failure(
          {:instance_result, term()} | :absent | {:error, term()},
          atom(),
          term()
        ) :: :ok | {:error, term()}
  defp route_existing_prerequisite_failure({:instance_result, result}, _name, reason),
    do: prerequisite_rollback_result(result, reason)

  defp route_existing_prerequisite_failure(:absent, name, _reason),
    do: {:error, {:authority_unavailable, name, :absent}}

  defp route_existing_prerequisite_failure({:error, authority_reason}, name, _reason),
    do: {:error, {:authority_unavailable, name, authority_reason}}

  @spec prerequisite_rollback_result(term(), term()) :: :ok | {:error, term()}
  defp prerequisite_rollback_result({:error, reason}, reason), do: :ok

  defp prerequisite_rollback_result({:error, rollback_reason}, reason),
    do: {:error, {:prerequisite_rollback_failed, reason, rollback_reason}}

  defp prerequisite_rollback_result(other, reason),
    do: {:error, {:prerequisite_rollback_unexpected, reason, other}}

  @spec prerequisite_reason(atom(), ExtRegistry.entry(), map(), start_failure() | nil) ::
          term() | nil
  defp prerequisite_reason(_name, %{source_type: :hex}, _failed, %{reason: reason}), do: reason
  defp prerequisite_reason(name, _entry, failed, _hex_failure), do: Map.get(failed, name)

  @spec install_hex(GenServer.server()) :: start_failure() | nil
  defp install_hex(registry) do
    case ExtHex.install_all(registry) do
      :ok ->
        nil

      {:error, reason} ->
        Log.warning(:config, inspect(reason))
        %{extension: :hex_install, reason: reason}
    end
  end

  @spec resolve_git_extensions(GenServer.server()) :: [start_failure()]
  defp resolve_git_extensions(registry) do
    registry
    |> ExtRegistry.all()
    |> Enum.reduce([], &resolve_git_extension(registry, &1, &2))
    |> Enum.reverse()
  end

  @spec resolve_git_extension(
          GenServer.server(),
          {atom(), ExtRegistry.entry()},
          [start_failure()]
        ) :: [start_failure()]
  defp resolve_git_extension(registry, {name, %{source_type: :git} = entry}, failures) do
    name
    |> ExtGit.ensure_cloned(entry.git)
    |> update_resolved_git(registry, name, failures)
  end

  defp resolve_git_extension(_registry, {_name, _entry}, failures), do: failures

  @spec update_resolved_git(
          {:ok, String.t()} | {:error, term()},
          GenServer.server(),
          atom(),
          [start_failure()]
        ) :: [start_failure()]
  defp update_resolved_git({:ok, path}, registry, name, failures) do
    case ExtRegistry.update(registry, name, path: path) do
      :ok -> failures
      {:error, reason} -> [%{extension: name, reason: reason} | failures]
    end
  end

  defp update_resolved_git({:error, reason}, _registry, name, failures) do
    Log.warning(:config, "Extension #{name}: #{reason}")
    [%{extension: name, reason: reason} | failures]
  end

  @spec failed_prerequisite?(atom(), ExtRegistry.entry(), MapSet.t(atom()), start_failure() | nil) ::
          boolean()
  defp failed_prerequisite?(_name, %{source_type: :hex}, _failed, nil), do: false
  defp failed_prerequisite?(_name, %{source_type: :hex}, _failed, _hex_failure), do: true
  defp failed_prerequisite?(name, _entry, failed, _hex_failure), do: MapSet.member?(failed, name)

  @spec call_declared_instance(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts(),
          (GenServer.server() -> result)
        ) :: result | {:error, term()}
        when result: var
  defp call_declared_instance(supervisor, registry, name, entry, opts, fun) do
    with {:ok, instance} <- locate_instance(supervisor, registry, name, entry, opts),
         :ok <-
           safe_instance_call(name, fn ->
             Instance.declare(instance, entry, registry, opts)
           end) do
      safe_instance_call(name, fn -> fun.(instance) end)
    end
  end

  @spec call_existing_instance(
          GenServer.server(),
          atom(),
          start_opts(),
          (GenServer.server() -> result)
        ) :: result | :absent | {:error, term()}
        when result: var
  defp call_existing_instance(supervisor, name, opts, fun) do
    with {:ok, instance} <- existing_instance(supervisor, name, opts) do
      safe_instance_call(name, fn -> fun.(instance) end)
    end
  end

  @spec safe_instance_call(atom(), (-> result)) :: result | {:error, term()} when result: var
  defp safe_instance_call(name, fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:authority_unavailable, name, reason}}
  end

  @spec version(module() | nil) :: String.t()
  defp version(nil), do: "unknown"

  defp version(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module.version()
    else
      "unknown"
    end
  rescue
    error ->
      Log.warning(:config, "Extension version() failed: #{Exception.message(error)}")
      "unknown"
  end

  defp version(_module), do: "unknown"
end
