defmodule Minga.Extension.Supervisor do
  @moduledoc """
  DynamicSupervisor managing extension process trees.

  Each extension gets its own child under this supervisor. If an extension
  crashes, only that extension restarts. The editor and other extensions
  are unaffected.

  ## Lifecycle

  1. Config eval registers extensions in `Extension.Registry`
  2. `start_all/0` reads the registry and starts each extension
  3. `stop_all/0` terminates all running extensions (used by reload)
  """

  use DynamicSupervisor

  alias Minga.Extension.CompileCache
  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Hex, as: ExtHex
  alias Minga.Extension.Lazy
  alias Minga.Extension.Manifest
  alias Minga.Extension.Registry, as: ExtRegistry

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the extension supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts all extensions declared in the registry.

  Processes extensions in order:
  1. Install all hex extensions via a single Mix.install/2 call
  2. Clone/checkout all git extensions to local cache
  3. Compile and start all extensions (path, git, hex)

  Errors at any stage are logged to *Messages* and stored in the
  registry as `:load_error` without affecting other extensions.
  """
  @type start_failure :: %{extension: atom(), reason: term()}

  @spec start_all() :: :ok | {:error, [start_failure()]}
  @spec start_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [start_failure()]}
  @spec start_all(GenServer.server(), GenServer.server(), start_opts()) ::
          :ok | {:error, [start_failure()]}
  def start_all, do: start_all(__MODULE__, ExtRegistry)

  def start_all(supervisor, registry), do: start_all(supervisor, registry, [])

  def start_all(supervisor, registry, opts) do
    hex_install_failure =
      case ExtHex.install_all(registry) do
        :ok ->
          nil

        {:error, reason} ->
          Minga.Log.warning(:config, reason)
          mark_hex_entries_load_error(registry)
          %{extension: :hex_install, reason: reason}
      end

    git_failures = resolve_git_extensions(registry)
    failed_git_names = MapSet.new(Enum.map(git_failures, & &1.extension))

    {failures, deferred_entries} =
      ExtRegistry.all(registry)
      |> Enum.reduce({[], []}, fn {name, entry}, {failures, deferred} ->
        maybe_start_registered_extension(
          supervisor,
          registry,
          name,
          entry,
          failed_git_names,
          hex_install_failure,
          failures,
          deferred,
          opts
        )
      end)

    failures =
      failures
      |> prepend_failure(hex_install_failure)
      |> Kernel.++(git_failures)

    Lazy.schedule_deferred_loads(supervisor, registry, deferred_entries, opts)

    case failures do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @spec maybe_start_registered_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          MapSet.t(atom()),
          start_failure() | nil,
          [start_failure()],
          [{atom(), ExtRegistry.entry()}],
          start_opts()
        ) :: {[start_failure()], [{atom(), ExtRegistry.entry()}]}
  defp maybe_start_registered_extension(
         _supervisor,
         _registry,
         name,
         %{source_type: :git, path: nil},
         failed_git_names,
         _hex_install_failure,
         failures,
         deferred,
         _opts
       ) do
    if MapSet.member?(failed_git_names, name) do
      {failures, deferred}
    else
      {failures ++ [%{extension: name, reason: :clone_failed}], deferred}
    end
  end

  defp maybe_start_registered_extension(
         _supervisor,
         _registry,
         _name,
         %{source_type: :hex},
         _failed_git_names,
         hex_install_failure,
         failures,
         deferred,
         _opts
       )
       when is_map(hex_install_failure) do
    {failures, deferred}
  end

  defp maybe_start_registered_extension(
         supervisor,
         registry,
         name,
         entry,
         _failed_git_names,
         _hex_install_failure,
         failures,
         deferred,
         opts
       ) do
    load_policy = Lazy.effective_load_policy(entry)

    case load_policy do
      :eager ->
        case start_extension(supervisor, registry, name, entry, opts) do
          {:ok, _pid} -> {failures, deferred}
          {:error, reason} -> {failures ++ [%{extension: name, reason: reason}], deferred}
        end

      :deferred ->
        {failures, [{name, entry} | deferred]}

      trigger when is_tuple(trigger) ->
        case register_lazy_stubs(supervisor, registry, name, entry, opts) do
          :ok -> {failures, deferred}
          {:error, reason} -> {failures ++ [%{extension: name, reason: reason}], deferred}
        end
    end
  end

  @spec register_lazy_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  defp register_lazy_stubs(supervisor, registry, name, %{source_type: :module} = entry, opts) do
    Lazy.register_module_stubs(supervisor, registry, name, entry, opts)
  end

  defp register_lazy_stubs(supervisor, registry, name, entry, opts) do
    Lazy.register_stubs(supervisor, registry, name, entry, opts)
  end

  @doc """
  Stops all running extensions and purges their modules.

  Used by config reload to cleanly tear down before re-loading.
  """
  @type stop_failure :: %{extension: atom(), reason: term()}

  @spec stop_all() :: :ok | {:error, [stop_failure()]}
  @spec stop_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [stop_failure()]}
  @spec stop_all(GenServer.server(), GenServer.server(), start_opts()) ::
          :ok | {:error, [stop_failure()]}
  def stop_all, do: stop_all(__MODULE__, ExtRegistry)

  def stop_all(supervisor, registry), do: stop_all(supervisor, registry, [])

  def stop_all(supervisor, registry, opts) do
    failures =
      ExtRegistry.all(registry)
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

  @doc """
  Starts a single extension by name.

  For path extensions, compiles the module from the local directory.
  Git and hex extensions must be resolved to a local path or loaded
  via Mix.install before calling this function.
  """
  @typedoc """
  Options for extension start/stop that inject collaborator dependencies.

  * `:command_registry` — the `Minga.Command.Registry` server to register
    commands with (default: `Minga.Command.Registry`)
  * `:keymap` — the `Minga.Keymap.Active` server to register keybindings
    with (default: `Minga.Keymap.Active`)
  * `:callbacks` — cleanup callbacks map, injected for test isolation
    (default: reads from `ContributionCleanup` persistent_term)
  """
  @type start_opts :: [
          command_registry: GenServer.server(),
          keymap: GenServer.server(),
          callbacks: %{atom() => Minga.Extension.ContributionCleanup.cleanup_fun()},
          slow_lifecycle_threshold_ms: non_neg_integer(),
          test_hooks: map()
        ]

  @spec start_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  @spec start_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) ::
          {:ok, pid()} | {:error, term()}
  def start_extension(supervisor, registry, name, _entry, opts \\ []) do
    with_lifecycle_lock(registry, name, fn ->
      case current_start_entry(supervisor, registry, name) do
        {:ok, {:running, pid}} ->
          {:ok, pid}

        {:ok, entry} ->
          start_current_entry_locked(supervisor, registry, name, entry, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec start_current_entry_locked(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp start_current_entry_locked(
         _supervisor,
         registry,
         name,
         %{source_type: :git, path: nil},
         _opts
       ) do
    # Git extensions are resolved to a local path in resolve_git_extensions/1.
    # If the current registry entry has no path, the clone failed.
    mark_start_load_error(registry, name)
    {:error, :clone_failed}
  end

  defp start_current_entry_locked(supervisor, registry, name, %{source_type: :hex} = entry, opts) do
    # Hex extensions are loaded via Mix.install in start_all/2.
    # Find the module implementing the Extension behaviour from the newly available code paths.
    find_and_start_hex_extension_locked(supervisor, registry, name, entry, opts)
  end

  defp start_current_entry_locked(
         supervisor,
         registry,
         name,
         %{source_type: :module} = entry,
         opts
       ) do
    start_from_module_locked(supervisor, registry, name, entry, opts)
  end

  defp start_current_entry_locked(supervisor, registry, name, entry, opts) do
    start_from_path_locked(supervisor, registry, name, entry, opts)
  end

  @spec start_from_module_locked(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) ::
          {:ok, pid()} | {:error, term()}
  defp start_from_module_locked(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    module = entry.module
    mark_start_attempt(registry, name)

    with {:module, ^module} <- Code.ensure_loaded(module),
         :ok <- validate_behaviour(module, name),
         :ok <- record_extension_manifest(registry, name, module, entry.source_type),
         :ok <- register_and_validate_options(name, module, entry.config),
         {:ok, _state} <-
           run_lifecycle_phase(name, :init, opts, fn -> call_init(module, entry.config) end) do
      finalize_extension_start(
        start_loaded_extension(
          supervisor,
          registry,
          name,
          module,
          entry.config,
          cmd_registry,
          keymap,
          opts
        ),
        registry,
        name,
        cmd_registry,
        keymap,
        opts
      )
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
        wrap_start_failure(name, reason, cmd_registry, keymap, opts)
    end
  end

  @spec start_from_path_locked(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) ::
          {:ok, pid()} | {:error, term()}
  defp start_from_path_locked(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    mark_start_attempt(registry, name)
    purge_recompilable_module(entry)

    with {:ok, module} <-
           run_lifecycle_phase(name, :load, opts, fn -> compile_extension(entry.path) end),
         :ok <- validate_behaviour(module, name),
         :ok <- record_extension_manifest(registry, name, module, entry.source_type),
         :ok <- register_and_validate_options(name, module, entry.config),
         {:ok, _state} <-
           run_lifecycle_phase(name, :init, opts, fn -> call_init(module, entry.config) end) do
      finalize_extension_start(
        start_loaded_extension(
          supervisor,
          registry,
          name,
          module,
          entry.config,
          cmd_registry,
          keymap,
          opts
        ),
        registry,
        name,
        cmd_registry,
        keymap,
        opts
      )
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
        wrap_start_failure(name, reason, cmd_registry, keymap, opts)
    end
  end

  @spec start_loaded_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          keyword(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp start_loaded_extension(
         supervisor,
         registry,
         name,
         module,
         config,
         cmd_registry,
         keymap,
         opts
       ) do
    case register_extension_modeline_segments(module, name) do
      :ok ->
        start_child_then_register_dsl(
          supervisor,
          registry,
          name,
          module,
          config,
          cmd_registry,
          keymap,
          opts
        )

      {:error, _reason} = error ->
        error
    end
  end

  @spec start_child_then_register_dsl(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          keyword(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp start_child_then_register_dsl(
         supervisor,
         registry,
         name,
         module,
         config,
         cmd_registry,
         keymap,
         opts
       ) do
    case start_child(supervisor, registry, name, module, config, cmd_registry, keymap, opts) do
      {:ok, pid} ->
        register_dsl_for_started_child(supervisor, pid, module, name, cmd_registry, keymap)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec register_dsl_for_started_child(
          GenServer.server(),
          pid(),
          module(),
          atom(),
          GenServer.server(),
          GenServer.server()
        ) :: {:ok, pid()} | {:error, term()}
  defp register_dsl_for_started_child(supervisor, pid, module, name, cmd_registry, keymap) do
    with :ok <- register_extension_commands(module, name, cmd_registry),
         :ok <- register_extension_keybinds(module, name, keymap) do
      {:ok, pid}
    else
      {:error, reason} -> handle_dsl_registration_failure(supervisor, pid, reason)
    end
  end

  @spec handle_dsl_registration_failure(GenServer.server(), pid(), term()) :: {:error, term()}
  defp handle_dsl_registration_failure(supervisor, pid, reason) do
    case terminate_extension_child(supervisor, pid) do
      :ok ->
        {:error, reason}

      {:error, termination_reason} ->
        {:error, {:registration_cleanup_failed, reason, termination_reason}}
    end
  end

  @spec terminate_extension_child(GenServer.server(), pid()) :: :ok | {:error, term()}
  defp terminate_extension_child(supervisor, pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Minga.Log.warning(
          :config,
          "Extension child #{inspect(pid)} termination failed: #{inspect(reason)}"
        )

        error
    end
  catch
    :exit, reason ->
      Minga.Log.warning(
        :config,
        "Extension child #{inspect(pid)} termination exited: #{inspect(reason)}"
      )

      {:error, {:exit, reason}}
  end

  @spec finalize_extension_start(
          {:ok, pid()} | {:error, term()},
          GenServer.server(),
          atom(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp finalize_extension_start({:ok, pid}, _registry, _name, _cmd_registry, _keymap, _opts),
    do: {:ok, pid}

  defp finalize_extension_start({:error, reason}, registry, name, cmd_registry, keymap, opts) do
    cleanup_result = cleanup_extension_contributions(name, cmd_registry, keymap, opts)
    msg = "Extension #{name} load error: #{inspect(reason)}"
    Minga.Log.warning(:config, msg)
    ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)

    case cleanup_result do
      :ok -> {:error, reason}
      {:error, failures} -> {:error, {:cleanup_failed, reason, failures}}
    end
  end

  @spec start_child(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          keyword(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) ::
          {:ok, pid()} | {:error, term()}
  defp start_child(supervisor, registry, name, module, config, cmd_registry, keymap, opts) do
    lifecycle_ref = make_ref()
    ExtRegistry.update(registry, name, lifecycle_ref: lifecycle_ref)

    case run_lifecycle_phase(name, :child_start, opts, fn ->
           start_extension_child(supervisor, module, config)
         end) do
      {:ok, {pid, restart}} ->
        ExtRegistry.update(
          registry,
          name,
          module: module,
          status: :running,
          pid: pid,
          lifecycle_ref: lifecycle_ref
        )

        emit_restart_count(name, 0)

        start_child_restart_monitor(
          %{
            supervisor: supervisor,
            registry: registry,
            name: name,
            module: module,
            lifecycle_ref: lifecycle_ref,
            cmd_registry: cmd_registry,
            keymap: keymap,
            restart: restart,
            opts: opts
          },
          pid
        )

        Minga.Log.info(:config, "Extension #{name} started (#{module})")
        {:ok, pid}

      {:error, reason} ->
        msg = "Extension #{name} failed to start: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)

        ExtRegistry.update(
          registry,
          name,
          module: module,
          status: :load_error,
          pid: nil,
          lifecycle_ref: nil
        )

        {:error, reason}
    end
  end

  @doc """
  Stops a single extension, terminates its process, and purges the module.
  """
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
    with_lifecycle_lock(registry, name, fn ->
      case current_stop_entry(registry, name, entry) do
        {:ok, current_entry} ->
          stop_current_extension(supervisor, registry, name, current_entry, opts)

        :stale ->
          :ok

        :not_registered ->
          :ok
      end
    end)
  end

  @spec stop_current_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: :ok | {:error, term()}
  defp stop_current_extension(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    ExtRegistry.update(registry, name, lifecycle_ref: nil)

    termination_result =
      run_lifecycle_phase(name, :stop, opts, fn ->
        terminate_extension_process(supervisor, entry)
      end)

    cleanup_result = cleanup_extension_contributions(name, cmd_registry, keymap, opts)
    finalize_explicit_stop_result(termination_result, cleanup_result, registry, name, entry)
  end

  @doc """
  Returns a summary of all extensions: `[{name, version, status}]`.
  """
  @spec list_extensions() :: [{atom(), String.t(), Minga.Extension.extension_status()}]
  @spec list_extensions(GenServer.server()) :: [
          {atom(), String.t(), Minga.Extension.extension_status()}
        ]
  def list_extensions, do: list_extensions(ExtRegistry)

  def list_extensions(registry) do
    for {name, entry} <- ExtRegistry.all(registry) do
      version =
        if entry.module && Code.ensure_loaded?(entry.module) do
          try do
            entry.module.version()
          rescue
            e ->
              Minga.Log.warning(
                :config,
                "Extension #{name} version() failed: #{Exception.message(e)}"
              )

              "unknown"
          end
        else
          "unknown"
        end

      {name, version, entry.status}
    end
  end

  # ── Supervisor Callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec mark_start_attempt(GenServer.server(), atom()) :: :ok
  defp mark_start_attempt(registry, name) do
    ExtRegistry.update(registry, name, manifest: nil)
  end

  @spec mark_start_load_error(GenServer.server(), atom()) :: :ok
  defp mark_start_load_error(registry, name) do
    ExtRegistry.update(registry, name,
      status: :load_error,
      pid: nil,
      lifecycle_ref: nil,
      manifest: nil
    )
  end

  @spec record_extension_manifest(GenServer.server(), atom(), module(), Manifest.source_type()) ::
          :ok | {:error, term()}
  defp record_extension_manifest(registry, name, module, source) do
    case safe_record_extension_manifest(module, source) do
      {:ok, manifest} ->
        ExtRegistry.update(registry, name, manifest: manifest)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec safe_record_extension_manifest(module(), Manifest.source_type()) ::
          {:ok, Manifest.t()} | {:error, term()}
  defp safe_record_extension_manifest(module, source) do
    {:ok, Manifest.from_module(module, source)}
  rescue
    e -> {:error, "manifest introspection failed: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "manifest introspection failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  @spec run_lifecycle_phase(atom(), atom(), start_opts(), (-> result)) :: result when result: var
  defp run_lifecycle_phase(name, phase, opts, fun)
       when is_atom(name) and is_atom(phase) and is_function(fun, 0) do
    handler_id = attach_slow_lifecycle_handler(name, phase, opts)

    try do
      Minga.Telemetry.span(
        [:minga, :extension, :lifecycle],
        %{extension: name, phase: phase},
        fun
      )
    after
      detach_slow_lifecycle_handler(handler_id)
    end
  end

  @spec with_lifecycle_lock(GenServer.server(), atom(), (-> result)) :: result when result: var
  defp with_lifecycle_lock(registry, name, fun) when is_atom(name) and is_function(fun, 0) do
    # The resource id identifies the extension lifecycle stream to serialize.
    # The requester id identifies this caller for :global.trans/4 reentrancy bookkeeping.
    # Restricting nodes to [node()] keeps the lock local to this editor VM.
    resource_id = {__MODULE__, :lifecycle, canonical_registry_id(registry), name}
    requester_id = self()

    :global.trans({resource_id, requester_id}, fun, [node()], :infinity)
  end

  @spec canonical_registry_id(GenServer.server()) :: term()
  defp canonical_registry_id(registry) when is_pid(registry) do
    case Process.info(registry, :registered_name) do
      {:registered_name, name} when is_atom(name) -> {:local_name, name}
      _other -> {:pid, registry}
    end
  end

  defp canonical_registry_id(registry) when is_atom(registry) do
    case Process.whereis(registry) do
      pid when is_pid(pid) -> canonical_registry_id(pid)
      nil -> {:local_name, registry}
    end
  end

  defp canonical_registry_id({:global, name}), do: {:global_name, name}
  defp canonical_registry_id({:via, module, name}), do: {:via, module, name}
  defp canonical_registry_id(registry), do: registry

  @spec current_start_entry(GenServer.server(), GenServer.server(), atom()) ::
          {:ok, ExtRegistry.entry() | {:running, pid()}} | {:error, term()}
  defp current_start_entry(supervisor, registry, name) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{status: :running, pid: pid} = entry} when is_pid(pid) ->
        current_running_or_restartable_entry(supervisor, registry, name, pid, entry)

      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error, :not_registered}
    end
  end

  @spec current_running_or_restartable_entry(
          GenServer.server(),
          GenServer.server(),
          atom(),
          pid(),
          ExtRegistry.entry()
        ) :: {:ok, {:running, pid()} | ExtRegistry.entry()} | {:error, term()}
  defp current_running_or_restartable_entry(supervisor, registry, name, pid, entry) do
    case extension_child_pid_by_pid(supervisor, pid) do
      {:ok, ^pid} ->
        {:ok, {:running, pid}}

      :not_found ->
        reconcile_dead_running_entry(supervisor, registry, name, entry)

      {:error, reason} ->
        Minga.Log.warning(
          :config,
          "Extension #{name} running child validation failed: #{inspect(reason)}"
        )

        mark_start_load_error(registry, name)
        {:error, {:restart_lookup_failed, reason}}
    end
  end

  @spec reconcile_dead_running_entry(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry()
        ) ::
          {:ok, {:running, pid()} | ExtRegistry.entry()} | {:error, term()}
  defp reconcile_dead_running_entry(supervisor, registry, name, %{module: module} = entry)
       when is_atom(module) and not is_nil(module) do
    case extension_child_pid(supervisor, module) do
      {:ok, pid} ->
        ExtRegistry.update(registry, name, pid: pid)
        {:ok, {:running, pid}}

      :not_found ->
        {:ok, entry}

      {:error, reason} ->
        Minga.Log.warning(
          :config,
          "Extension #{name} restart reconciliation failed: #{inspect(reason)}"
        )

        mark_start_load_error(registry, name)
        {:error, {:restart_lookup_failed, reason}}
    end
  end

  defp reconcile_dead_running_entry(_supervisor, _registry, _name, entry), do: {:ok, entry}

  @spec current_stop_entry(GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, ExtRegistry.entry()} | :stale | :not_registered
  defp current_stop_entry(registry, name, requested_entry) do
    case ExtRegistry.get(registry, name) do
      {:ok, current_entry} -> current_stop_entry_for_request(requested_entry, current_entry)
      :error -> :not_registered
    end
  end

  @spec current_stop_entry_for_request(ExtRegistry.entry(), ExtRegistry.entry()) ::
          {:ok, ExtRegistry.entry()} | :stale
  defp current_stop_entry_for_request(
         %{status: :running, lifecycle_ref: requested_ref},
         %{status: :running, lifecycle_ref: requested_ref} = current_entry
       )
       when is_reference(requested_ref),
       do: {:ok, current_entry}

  defp current_stop_entry_for_request(
         %{status: :running, pid: requested_pid, lifecycle_ref: nil},
         %{status: :running, pid: requested_pid, lifecycle_ref: nil} = current_entry
       )
       when is_pid(requested_pid),
       do: {:ok, current_entry}

  defp current_stop_entry_for_request(
         %{status: :running, pid: nil, module: requested_module, lifecycle_ref: nil},
         %{status: :running, pid: nil, module: requested_module, lifecycle_ref: nil} =
           current_entry
       )
       when is_atom(requested_module) and not is_nil(requested_module),
       do: {:ok, current_entry}

  defp current_stop_entry_for_request(
         %{status: requested_status, pid: nil, lifecycle_ref: nil},
         %{status: requested_status, pid: nil, lifecycle_ref: nil} = current_entry
       )
       when requested_status != :running,
       do: {:ok, current_entry}

  defp current_stop_entry_for_request(_requested_entry, _current_entry), do: :stale

  @spec attach_slow_lifecycle_handler(atom(), atom(), start_opts()) :: term()
  defp attach_slow_lifecycle_handler(name, phase, opts) do
    threshold_ms = Keyword.get(opts, :slow_lifecycle_threshold_ms, 50)
    handler_id = {__MODULE__, :slow_lifecycle, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:minga, :extension, :lifecycle, :stop],
      &__MODULE__.handle_slow_lifecycle_event/4,
      %{extension: name, phase: phase, threshold_ms: threshold_ms}
    )

    handler_id
  end

  @spec detach_slow_lifecycle_handler(term()) :: :ok
  defp detach_slow_lifecycle_handler(handler_id) do
    :telemetry.detach(handler_id)
    :ok
  end

  @doc false
  @spec handle_slow_lifecycle_event([atom()], map(), map(), map()) :: :ok
  def handle_slow_lifecycle_event(
        _event,
        %{duration: duration},
        %{extension: extension, phase: phase},
        %{extension: extension, phase: phase, threshold_ms: threshold_ms}
      ) do
    maybe_log_slow_lifecycle_phase(extension, phase, duration, threshold_ms)
  end

  def handle_slow_lifecycle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec maybe_log_slow_lifecycle_phase(atom(), atom(), integer(), non_neg_integer()) :: :ok
  defp maybe_log_slow_lifecycle_phase(name, phase, duration, threshold_ms) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case duration_ms >= threshold_ms do
      true ->
        Minga.Log.warning(
          :config,
          "Extension #{name} lifecycle phase #{phase} took #{duration_ms}ms"
        )

      false ->
        :ok
    end
  end

  @spec emit_restart_count(atom(), non_neg_integer()) :: :ok
  defp emit_restart_count(name, count) do
    Minga.Telemetry.execute(
      [:minga, :extension, :lifecycle, :crash_restart_count],
      %{count: count},
      %{extension: name, phase: :crash_restart_count}
    )
  end

  @spec run_test_hook(start_opts(), atom()) :: :ok
  defp run_test_hook(opts, hook_name) do
    case Keyword.get(opts, :test_hooks, %{}) do
      %{^hook_name => hook} when is_function(hook, 0) -> hook.()
      _ -> :ok
    end
  end

  @spec start_extension_child(GenServer.server(), module(), keyword()) ::
          {:ok, {pid(), child_restart()}} | {:error, term()}
  defp start_extension_child(supervisor, module, config) do
    child_spec = normalize_child_spec(module, config)
    restart = Map.get(child_spec, :restart, :permanent)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, {pid, restart}}
      {:error, _reason} = error -> error
    end
  rescue
    e -> {:error, {:child_spec_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:child_spec_failed, {kind, reason}}}
  end

  @spec normalize_child_spec(module(), keyword()) :: Supervisor.child_spec()
  defp normalize_child_spec(module, config) do
    module.child_spec(config)
    |> Supervisor.child_spec([])
    |> Map.put(:modules, [module])
  end

  @spec terminate_extension_process(GenServer.server(), ExtRegistry.entry()) ::
          :ok | {:error, term()}
  defp terminate_extension_process(supervisor, %{pid: pid} = entry) when is_pid(pid) do
    case terminate_extension_child(supervisor, pid) do
      {:error, :not_found} -> terminate_extension_process_by_module(supervisor, entry.module)
      result -> result
    end
  end

  defp terminate_extension_process(supervisor, %{module: module, status: :running})
       when is_atom(module) and not is_nil(module) do
    terminate_extension_process_by_module(supervisor, module)
  end

  defp terminate_extension_process(_supervisor, _entry), do: :ok

  @spec terminate_extension_process_by_module(GenServer.server(), module() | nil) ::
          :ok | {:error, term()}
  defp terminate_extension_process_by_module(_supervisor, nil), do: {:error, :not_found}

  defp terminate_extension_process_by_module(supervisor, module) do
    case extension_child_pid(supervisor, module) do
      {:ok, pid} -> terminate_extension_child(supervisor, pid)
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @typep child_restart :: :permanent | :transient | :temporary

  @typep restart_monitor :: %{
           supervisor: GenServer.server(),
           registry: GenServer.server(),
           name: atom(),
           module: module(),
           lifecycle_ref: reference(),
           cmd_registry: GenServer.server(),
           keymap: GenServer.server(),
           restart: child_restart(),
           opts: start_opts()
         }

  @spec start_child_restart_monitor(restart_monitor(), pid()) :: :ok
  defp start_child_restart_monitor(monitor, pid) do
    spawn(fn -> monitor_child_restarts(monitor, pid, 0) end)

    :ok
  end

  @spec monitor_child_restarts(restart_monitor(), pid(), non_neg_integer()) :: :ok
  defp monitor_child_restarts(monitor, pid, count) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> handle_child_down(monitor, pid, reason, count)
    end
  end

  @spec handle_child_down(restart_monitor(), pid(), term(), non_neg_integer()) :: :ok
  defp handle_child_down(monitor, pid, reason, count) do
    wait_for_restarted_child(monitor, pid, reason, count + 1, 0)
  end

  @spec lifecycle_monitor_active?(GenServer.server(), atom(), reference()) :: boolean()
  defp lifecycle_monitor_active?(registry, name, lifecycle_ref) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{lifecycle_ref: ^lifecycle_ref, status: :running}} -> true
      _ -> false
    end
  end

  @spec crash_reason?(term()) :: boolean()
  defp crash_reason?(:normal), do: false
  defp crash_reason?(:shutdown), do: false
  defp crash_reason?({:shutdown, _reason}), do: false
  defp crash_reason?(_reason), do: true

  @spec wait_for_restarted_child(
          restart_monitor(),
          pid(),
          term(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok
  defp wait_for_restarted_child(monitor, excluded_pid, reason, count, attempts) do
    case lifecycle_monitor_active?(monitor.registry, monitor.name, monitor.lifecycle_ref) do
      true -> wait_for_active_monitor_child(monitor, excluded_pid, reason, count, attempts)
      false -> :ok
    end
  end

  @spec wait_for_active_monitor_child(
          restart_monitor(),
          pid(),
          term(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  defp wait_for_active_monitor_child(monitor, excluded_pid, reason, count, attempts) do
    case extension_child_pid(monitor.supervisor, monitor.module, excluded_pid) do
      {:ok, pid} ->
        handle_restarted_child(monitor, pid, count)

      :not_found ->
        wait_for_missing_restarted_child(monitor, excluded_pid, reason, count, attempts)

      {:error, lookup_reason} ->
        Minga.Log.warning(
          :config,
          "Extension #{monitor.name} restart reconciliation failed: #{inspect(lookup_reason)}"
        )

        finalize_terminal_child_exit(monitor, reason)
    end
  end

  @spec wait_for_missing_restarted_child(
          restart_monitor(),
          pid(),
          term(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  defp wait_for_missing_restarted_child(monitor, excluded_pid, reason, count, attempts) do
    case restart_terminal_exit?(monitor.restart, reason) do
      true ->
        finalize_terminal_child_exit(monitor, reason)

      false ->
        if attempts >= restart_reconcile_attempt_limit() do
          Minga.Log.warning(
            :config,
            "Extension #{monitor.name} restart reconciliation timed out after #{attempts} attempt(s)"
          )

          finalize_terminal_child_exit(monitor, reason)
        else
          receive do
          after
            10 -> wait_for_restarted_child(monitor, excluded_pid, reason, count, attempts + 1)
          end
        end
    end
  end

  @spec finalize_terminal_child_exit(restart_monitor(), term()) :: :ok
  defp finalize_terminal_child_exit(monitor, reason) do
    run_test_hook(monitor.opts, :before_terminal_child_exit)

    mark_terminal_child_exit(
      monitor.registry,
      monitor.name,
      monitor.lifecycle_ref,
      monitor.cmd_registry,
      monitor.keymap,
      monitor.opts,
      reason
    )
  end

  @spec restart_terminal_exit?(child_restart(), term()) :: boolean()
  defp restart_terminal_exit?(:temporary, _reason), do: true
  defp restart_terminal_exit?(:transient, reason), do: not crash_reason?(reason)
  defp restart_terminal_exit?(:permanent, _reason), do: false

  @restart_reconcile_attempt_limit 50
  @spec restart_reconcile_attempt_limit() :: non_neg_integer()
  defp restart_reconcile_attempt_limit, do: @restart_reconcile_attempt_limit

  @spec handle_restarted_child(restart_monitor(), pid(), non_neg_integer()) :: :ok
  defp handle_restarted_child(monitor, pid, count) do
    run_test_hook(monitor.opts, :before_restart_reconcile)

    case reconcile_restarted_child(monitor, pid, count) do
      :monitor -> monitor_child_restarts(monitor, pid, count)
      :stale -> :ok
    end
  end

  @spec reconcile_restarted_child(restart_monitor(), pid(), non_neg_integer()) ::
          :monitor | :stale
  defp reconcile_restarted_child(monitor, pid, count) do
    with_lifecycle_lock(monitor.registry, monitor.name, fn ->
      case lifecycle_monitor_active?(monitor.registry, monitor.name, monitor.lifecycle_ref) do
        true ->
          ExtRegistry.update(monitor.registry, monitor.name, pid: pid)
          emit_restart_count(monitor.name, count)
          :monitor

        false ->
          :stale
      end
    end)
  end

  @spec mark_terminal_child_exit(
          GenServer.server(),
          atom(),
          reference(),
          GenServer.server(),
          GenServer.server(),
          start_opts(),
          term()
        ) :: :ok
  defp mark_terminal_child_exit(registry, name, lifecycle_ref, cmd_registry, keymap, opts, reason) do
    with_lifecycle_lock(registry, name, fn ->
      case crash_reason?(reason) do
        true ->
          mark_crashed_without_replacement(registry, name, lifecycle_ref)

        false ->
          mark_stopped_without_replacement(
            registry,
            name,
            lifecycle_ref,
            cmd_registry,
            keymap,
            opts
          )
      end
    end)
  end

  @spec mark_crashed_without_replacement(GenServer.server(), atom(), reference()) :: :ok
  defp mark_crashed_without_replacement(registry, name, lifecycle_ref) do
    if lifecycle_monitor_active?(registry, name, lifecycle_ref) do
      ExtRegistry.update(registry, name, status: :crashed, pid: nil, lifecycle_ref: nil)
    end

    :ok
  end

  @spec mark_stopped_without_replacement(
          GenServer.server(),
          atom(),
          reference(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp mark_stopped_without_replacement(registry, name, lifecycle_ref, cmd_registry, keymap, opts) do
    finalize_stopped_lifecycle_exit(registry, name, lifecycle_ref, cmd_registry, keymap, opts)
    :ok
  end

  @spec finalize_stopped_lifecycle_exit(
          GenServer.server(),
          atom(),
          reference(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp finalize_stopped_lifecycle_exit(registry, name, lifecycle_ref, cmd_registry, keymap, opts) do
    if lifecycle_monitor_active?(registry, name, lifecycle_ref) do
      case ExtRegistry.get(registry, name) do
        {:ok, entry} ->
          cleanup_result = cleanup_extension_contributions(name, cmd_registry, keymap, opts)

          finalize_terminal_cleanup_result(
            cleanup_result,
            registry,
            name,
            lifecycle_ref,
            entry
          )

        :error ->
          :ok
      end
    end

    :ok
  end

  @spec finalize_terminal_cleanup_result(
          :ok | {:error, [map()]},
          GenServer.server(),
          atom(),
          reference(),
          ExtRegistry.entry()
        ) :: :ok
  defp finalize_terminal_cleanup_result(:ok, registry, name, lifecycle_ref, entry) do
    if lifecycle_monitor_active?(registry, name, lifecycle_ref) do
      finalize_stopped_extension(registry, name, entry)
    end

    :ok
  end

  defp finalize_terminal_cleanup_result(
         {:error, _failures},
         registry,
         name,
         lifecycle_ref,
         _entry
       ) do
    if lifecycle_monitor_active?(registry, name, lifecycle_ref) do
      ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
    end

    :ok
  end

  @spec extension_child_pid_by_pid(GenServer.server(), pid()) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp extension_child_pid_by_pid(supervisor, target_pid) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:not_found, fn
      {_id, ^target_pid, _type, _modules} -> {:ok, target_pid}
      _child -> false
    end)
  catch
    :exit, reason -> {:error, {:which_children_failed, reason}}
  end

  @spec extension_child_pid(GenServer.server(), module()) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp extension_child_pid(supervisor, module), do: extension_child_pid(supervisor, module, nil)

  @spec extension_child_pid(GenServer.server(), module(), pid() | nil) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp extension_child_pid(supervisor, module, excluded_pid) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:not_found, fn
      {:undefined, pid, _type, [^module]} when is_pid(pid) and pid != excluded_pid -> {:ok, pid}
      _child -> false
    end)
  catch
    :exit, reason -> {:error, {:which_children_failed, reason}}
  end

  @spec resolve_git_extensions(GenServer.server()) :: [start_failure()]
  defp resolve_git_extensions(registry) do
    ExtRegistry.all(registry)
    |> Enum.reduce([], fn {name, entry}, failures ->
      resolve_git_extension(registry, name, entry, failures)
    end)
    |> Enum.reverse()
  end

  @spec resolve_git_extension(GenServer.server(), atom(), ExtRegistry.entry(), [start_failure()]) ::
          [start_failure()]
  defp resolve_git_extension(registry, name, %{source_type: :git} = entry, failures) do
    case ExtGit.ensure_cloned(name, entry.git) do
      {:ok, local_path} ->
        ExtRegistry.update(registry, name, path: local_path)
        failures

      {:error, reason} ->
        Minga.Log.warning(:config, "Extension #{name}: #{reason}")
        mark_start_load_error(registry, name)
        [%{extension: name, reason: reason} | failures]
    end
  end

  defp resolve_git_extension(_registry, _name, _entry, failures), do: failures

  @spec find_and_start_hex_extension_locked(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp find_and_start_hex_extension_locked(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    mark_start_attempt(registry, name)

    with {:ok, app_atom} <- hex_application_name(name, entry.hex),
         :ok <-
           run_lifecycle_phase(name, :load, opts, fn ->
             ensure_hex_application_started(app_atom)
           end),
         {:ok, module} <- find_extension_module(app_atom),
         :ok <- validate_behaviour(module, name),
         :ok <- record_extension_manifest(registry, name, module, entry.source_type),
         :ok <- register_and_validate_options(name, module, entry.config),
         {:ok, _state} <-
           run_lifecycle_phase(name, :init, opts, fn -> call_init(module, entry.config) end) do
      finalize_extension_start(
        start_loaded_extension(
          supervisor,
          registry,
          name,
          module,
          entry.config,
          cmd_registry,
          keymap,
          opts
        ),
        registry,
        name,
        cmd_registry,
        keymap,
        opts
      )
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
        wrap_start_failure(name, reason, cmd_registry, keymap, opts)
    end
  end

  @spec find_extension_module(atom()) :: {:ok, module()} | {:error, String.t()}
  defp find_extension_module(package_atom) do
    # Try the application's modules for one implementing Minga.Extension
    case :application.get_key(package_atom, :modules) do
      {:ok, modules} ->
        case Enum.find(modules, &implements_extension?/1) do
          nil -> {:error, "no module implementing Minga.Extension found in #{package_atom}"}
          mod -> {:ok, mod}
        end

      :undefined ->
        {:error, "application #{package_atom} not found after Mix.install"}
    end
  end

  @spec purge_recompilable_module(ExtRegistry.entry()) :: :ok
  defp purge_recompilable_module(%{source_type: source_type, module: module})
       when source_type in [:path, :git] and is_atom(module) and module != nil do
    :code.purge(module)
    :code.delete(module)
    :ok
  end

  defp purge_recompilable_module(_entry), do: :ok

  @spec compile_extension(String.t()) :: {:ok, module()} | {:error, String.t()}
  defp compile_extension(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      compile_extension_files(expanded)
    else
      {:error, "extension path does not exist: #{expanded}"}
    end
  end

  @spec compile_extension_files(String.t()) :: {:ok, module()} | {:error, String.t()}
  defp compile_extension_files(expanded) do
    files =
      expanded
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()

    case files do
      [] ->
        {:error, "no .ex files found in #{expanded}"}

      _ ->
        # The compile cache loads precompiled beams on a hit and recompiles
        # (writing fresh beams) on a miss, so editing extension source still
        # hot-reloads via a changed content hash.
        case CompileCache.load_or_compile(expanded, files) do
          {:ok, %{modules: modules, diagnostics: diagnostics}} ->
            log_diagnostics(diagnostics)
            find_extension_in_compiled(modules)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec find_extension_in_compiled([module()]) :: {:ok, module()} | {:error, String.t()}
  defp find_extension_in_compiled(modules) do
    case Enum.find(modules, &implements_extension?/1) do
      nil -> {:error, "no module implementing Minga.Extension behaviour found"}
      mod -> {:ok, mod}
    end
  end

  @spec log_diagnostics([map()]) :: :ok
  defp log_diagnostics([]), do: :ok

  defp log_diagnostics(diagnostics) do
    for diag <- diagnostics do
      file = Map.get(diag, :file, "unknown")
      position = Map.get(diag, :position, nil)
      message = Map.get(diag, :message, "")
      severity = Map.get(diag, :severity, :warning)
      short_file = Path.basename(file)
      pos_str = format_position(position)

      case severity do
        :error ->
          Minga.Log.warning(:editor, "[ext:error] #{short_file}:#{pos_str}: #{message}")

        :warning ->
          Minga.Log.warning(:editor, "[ext] #{short_file}:#{pos_str}: #{message}")

        _ ->
          Minga.Log.debug(:editor, "[ext] #{short_file}:#{pos_str}: #{message}")
      end
    end

    :ok
  end

  @spec format_position(term()) :: String.t()
  defp format_position({line, col}) when is_integer(line) and is_integer(col),
    do: "#{line}:#{col}"

  defp format_position(line) when is_integer(line), do: "#{line}"
  defp format_position(_), do: "?"

  @spec implements_extension?(module()) :: boolean()
  defp implements_extension?(module) do
    Code.ensure_loaded?(module) &&
      function_exported?(module, :name, 0) &&
      function_exported?(module, :description, 0) &&
      function_exported?(module, :version, 0) &&
      function_exported?(module, :init, 1)
  end

  @spec validate_behaviour(module(), atom()) :: :ok | {:error, String.t()}
  defp validate_behaviour(module, name) do
    missing =
      [:name, :description, :version, :init]
      |> Enum.reject(fn
        :init -> function_exported?(module, :init, 1)
        fun -> function_exported?(module, fun, 0)
      end)

    case missing do
      [] -> :ok
      funs -> {:error, "extension #{name} missing callbacks: #{inspect(funs)}"}
    end
  end

  @spec cleanup_extension_contributions(
          atom(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) ::
          :ok | {:error, [map()]}
  defp cleanup_extension_contributions(name, cmd_registry, keymap, opts) do
    source = {:extension, name}

    cleanup_opts =
      [command_registry: cmd_registry, keymap: keymap]
      |> Keyword.merge(Keyword.take(opts, [:callbacks]))

    case run_lifecycle_phase(name, :cleanup, opts, fn ->
           Minga.Extension.ContributionCleanup.unregister_source(source, cleanup_opts)
         end) do
      :ok ->
        :ok

      {:error, failures} = error ->
        Minga.Log.warning(
          :config,
          "Extension #{name} contribution cleanup failed: #{format_cleanup_failures(failures)}"
        )

        error
    end
  end

  @spec wrap_start_failure(atom(), term(), GenServer.server(), GenServer.server(), start_opts()) ::
          {:error, term()}
  defp wrap_start_failure(name, reason, cmd_registry, keymap, opts) do
    case cleanup_extension_contributions(name, cmd_registry, keymap, opts) do
      :ok -> {:error, reason}
      {:error, failures} -> {:error, {:cleanup_failed, reason, failures}}
    end
  end

  @spec finalize_explicit_stop_result(
          :ok | {:error, term()},
          :ok | {:error, [map()]},
          GenServer.server(),
          atom(),
          ExtRegistry.entry()
        ) :: :ok | {:error, term()}
  defp finalize_explicit_stop_result(:ok, :ok, registry, name, entry) do
    finalize_stopped_extension(registry, name, entry)
  end

  defp finalize_explicit_stop_result(:ok, {:error, failures}, registry, name, _entry) do
    ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
    {:error, {:cleanup_failed, failures}}
  end

  defp finalize_explicit_stop_result({:error, reason}, :ok, registry, name, entry) do
    finalize_stopped_extension(registry, name, entry)
    {:error, reason}
  end

  defp finalize_explicit_stop_result({:error, reason}, {:error, failures}, registry, name, _entry) do
    ExtRegistry.update(registry, name, status: :load_error, lifecycle_ref: nil)
    {:error, {:cleanup_failed, reason, failures}}
  end

  @spec finalize_stopped_extension(GenServer.server(), atom(), ExtRegistry.entry()) :: :ok
  defp finalize_stopped_extension(registry, name, entry) do
    if entry.source_type != :module and entry.module do
      :code.purge(entry.module)
      :code.delete(entry.module)
    end

    update_fields = [status: :stopped, pid: nil, lifecycle_ref: nil]

    update_fields =
      if entry.source_type == :module do
        update_fields
      else
        [{:module, nil} | update_fields]
      end

    ExtRegistry.update(registry, name, update_fields)

    :ok
  end

  @spec mark_hex_entries_load_error(GenServer.server()) :: :ok
  defp mark_hex_entries_load_error(registry) do
    for {name, entry} <- ExtRegistry.all(registry), entry.source_type == :hex do
      mark_start_load_error(registry, name)
    end

    :ok
  end

  @spec hex_application_name(atom(), Minga.Extension.Entry.hex_opts()) ::
          {:ok, atom()} | {:error, term()}
  defp hex_application_name(_name, %{app: app}) when is_atom(app) and app != nil, do: {:ok, app}
  defp hex_application_name(name, %{app: nil}), do: {:ok, name}

  @spec ensure_hex_application_started(atom()) :: :ok | {:error, term()}
  defp ensure_hex_application_started(package_atom) do
    case Application.ensure_all_started(package_atom) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:hex_application_start_failed, package_atom, reason}}
    end
  end

  @spec prepend_failure([start_failure()], start_failure() | nil) :: [start_failure()]
  defp prepend_failure(failures, nil), do: failures
  defp prepend_failure(failures, failure), do: [failure | failures]

  @spec format_cleanup_failures([map()]) :: String.t()
  defp format_cleanup_failures(failures) do
    Enum.map_join(failures, "; ", &format_cleanup_failure/1)
  end

  @spec format_cleanup_failure(map()) :: String.t()
  defp format_cleanup_failure(%{family: family, source: source, reason: reason}) do
    "#{inspect(family)} source=#{inspect(source)} reason=#{inspect(reason)}"
  end

  @spec register_extension_commands(module(), atom(), GenServer.server()) ::
          :ok | {:error, term()}
  defp register_extension_commands(module, ext_name, cmd_registry) do
    schema = command_schema(module)

    case register_extension_command_schema(schema, ext_name, cmd_registry) do
      :ok ->
        log_registered_commands(ext_name, schema)
        :ok

      {:error, _reason} = error ->
        error
    end
  rescue
    e ->
      Minga.Log.warning(
        :config,
        "Extension #{ext_name} command registration failed: #{Exception.message(e)}"
      )

      {:error, {:command_registration_failed, Exception.message(e)}}
  end

  @spec register_extension_command_schema(
          [Minga.Extension.command_spec()],
          atom(),
          GenServer.server()
        ) :: :ok | {:error, term()}
  defp register_extension_command_schema(schema, ext_name, cmd_registry) do
    Enum.reduce_while(schema, :ok, fn spec, :ok ->
      case register_extension_command_spec(spec, ext_name, cmd_registry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec command_schema(module()) :: [Minga.Extension.command_spec()]
  defp command_schema(module) do
    case function_exported?(module, :__command_schema__, 0) do
      true -> module.__command_schema__()
      false -> []
    end
  end

  @spec register_extension_command_spec(
          Minga.Extension.command_spec(),
          atom(),
          GenServer.server()
        ) :: :ok | {:error, term()}
  defp register_extension_command_spec(spec, ext_name, cmd_registry) do
    case Minga.Command.Registry.register_command(
           cmd_registry,
           {:extension, ext_name},
           build_command_from_spec(spec)
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Minga.Log.warning(:config, "Extension #{ext_name} command rejected: #{inspect(reason)}")
        error
    end
  end

  @spec log_registered_commands(atom(), [Minga.Extension.command_spec()]) :: :ok
  defp log_registered_commands(_ext_name, []), do: :ok

  defp log_registered_commands(ext_name, schema) do
    Minga.Log.debug(:config, "Extension #{ext_name}: registered #{length(schema)} commands")
  end

  @spec build_command_from_spec(Minga.Extension.command_spec()) :: Minga.Command.t()
  defp build_command_from_spec({name, description, opts}) do
    {mod, fun} = Keyword.fetch!(opts, :execute)
    requires_buffer = Keyword.get(opts, :requires_buffer, false)

    %Minga.Command{
      name: name,
      description: description,
      execute: fn state -> apply(mod, fun, [state]) end,
      requires_buffer: requires_buffer
    }
  end

  @spec register_extension_modeline_segments(module(), atom()) :: :ok | {:error, term()}
  defp register_extension_modeline_segments(module, ext_name) do
    case function_exported?(module, :__modeline_segment_schema__, 0) do
      true ->
        register_extension_modeline_segment_schema(module.__modeline_segment_schema__(), ext_name)

      false ->
        :ok
    end
  rescue
    e ->
      reason = {:modeline_segment_registration_failed, Exception.message(e)}

      Minga.Log.warning(
        :config,
        "Extension #{ext_name} modeline segment registration failed: #{Exception.message(e)}"
      )

      {:error, reason}
  end

  @spec register_extension_modeline_segment_schema(
          [Minga.Extension.modeline_segment_spec()],
          atom()
        ) :: :ok | {:error, term()}
  defp register_extension_modeline_segment_schema(schema, ext_name) do
    Enum.reduce_while(schema, :ok, fn spec, :ok ->
      case register_extension_modeline_segment(spec, ext_name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec register_extension_modeline_segment(Minga.Extension.modeline_segment_spec(), atom()) ::
          :ok | {:error, term()}
  defp register_extension_modeline_segment({name, opts, {mod, fun}}, ext_name) do
    case Minga.Config.ModelineSegments.register(
           name,
           opts,
           fn ctx -> apply(mod, fun, [ctx]) end,
           {:extension, ext_name}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        msg = Minga.Config.ModelineSegments.register_error_message(name, reason)
        Minga.Log.warning(:config, "Extension #{ext_name} modeline segment rejected: #{msg}")
        {:error, {:modeline_segment_rejected, name, reason}}
    end
  end

  @spec register_extension_keybinds(module(), atom(), GenServer.server()) ::
          :ok | {:error, term()}
  defp register_extension_keybinds(module, ext_name, keymap) do
    case function_exported?(module, :__keybind_schema__, 0) do
      true -> register_extension_keybind_schema(module.__keybind_schema__(), ext_name, keymap)
      false -> :ok
    end
  rescue
    e ->
      Minga.Log.warning(
        :config,
        "Extension #{ext_name} keybind registration failed: #{Exception.message(e)}"
      )

      {:error, {:keybind_registration_failed, :schema, Exception.message(e)}}
  end

  @spec register_extension_keybind_schema(
          [Minga.Extension.keybind_spec()],
          atom(),
          GenServer.server()
        ) :: :ok | {:error, term()}
  defp register_extension_keybind_schema(schema, ext_name, keymap) do
    Enum.reduce_while(schema, :ok, fn spec, :ok ->
      case bind_keybind_spec(spec, ext_name, keymap) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec bind_keybind_spec(Minga.Extension.keybind_spec(), atom(), GenServer.server()) ::
          :ok | {:error, term()}
  defp bind_keybind_spec({mode, key_str, command, description, opts}, ext_name, keymap) do
    source_opts = Keyword.put(opts, :source, {:extension, ext_name})

    case Minga.Keymap.Active.bind(keymap, mode, key_str, command, description, source_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :config,
          "Extension #{ext_name}: keybind #{inspect(key_str)} failed: #{reason}"
        )

        {:error, {:keybind_registration_failed, key_str, reason}}
    end
  end

  @spec register_and_validate_options(atom(), module(), keyword()) ::
          :ok | {:error, String.t()}
  defp register_and_validate_options(name, module, config) do
    if function_exported?(module, :__option_schema__, 0) do
      schema = module.__option_schema__()
      Minga.Config.register_extension_schema(name, schema, config)
    else
      :ok
    end
  rescue
    e ->
      {:error, "__option_schema__/0 crashed: #{Exception.message(e)}"}
  end

  @spec call_init(module(), keyword()) :: {:ok, term()} | {:error, term()}
  defp call_init(module, config) do
    case module.init(config) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, "init failed: #{inspect(reason)}"}
      other -> {:error, "init returned unexpected value: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "init crashed: #{Exception.message(e)}"}
  end
end
