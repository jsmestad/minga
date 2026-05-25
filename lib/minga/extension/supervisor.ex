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

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Hex, as: ExtHex
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

    failures =
      ExtRegistry.all(registry)
      |> Enum.reduce([], fn {name, entry}, failures ->
        maybe_start_registered_extension(
          supervisor,
          registry,
          name,
          entry,
          failed_git_names,
          hex_install_failure,
          failures,
          opts
        )
      end)
      |> prepend_failure(hex_install_failure)
      |> Kernel.++(git_failures)

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
          start_opts()
        ) :: [start_failure()]
  defp maybe_start_registered_extension(
         _supervisor,
         _registry,
         name,
         %{source_type: :git, path: nil},
         failed_git_names,
         _hex_install_failure,
         failures,
         _opts
       ) do
    if MapSet.member?(failed_git_names, name) do
      failures
    else
      failures ++ [%{extension: name, reason: :clone_failed}]
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
         _opts
       )
       when is_map(hex_install_failure) do
    failures
  end

  defp maybe_start_registered_extension(
         supervisor,
         registry,
         name,
         entry,
         _failed_git_names,
         _hex_install_failure,
         failures,
         opts
       ) do
    case start_extension(supervisor, registry, name, entry, opts) do
      {:ok, _pid} ->
        failures

      {:error, reason} ->
        failures ++ [%{extension: name, reason: reason}]
    end
  end

  @doc """
  Stops all running extensions and purges their modules.

  Used by config reload to cleanly tear down before re-loading.
  """
  @type stop_failure :: %{extension: atom(), reason: term()}

  @spec stop_all() :: :ok | {:error, [stop_failure()]}
  @spec stop_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [stop_failure()]}
  def stop_all, do: stop_all(__MODULE__, ExtRegistry)

  def stop_all(supervisor, registry) do
    failures =
      ExtRegistry.all(registry)
      |> Enum.reduce([], fn {name, entry}, failures ->
        case stop_extension(supervisor, registry, name, entry) do
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
          slow_lifecycle_threshold_ms: non_neg_integer()
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
  def start_extension(supervisor, registry, name, entry, opts \\ [])

  def start_extension(supervisor, registry, name, %{source_type: :git} = entry, opts) do
    # Git extensions are resolved to a local path in resolve_git_extensions/1.
    # If the path was set, compile from there. Otherwise it failed to clone.
    if entry.path do
      start_from_path(supervisor, registry, name, entry, opts)
    else
      {:error, :clone_failed}
    end
  end

  def start_extension(supervisor, registry, name, %{source_type: :hex} = entry, opts) do
    # Hex extensions are loaded via Mix.install in start_all/2.
    # Find the module implementing the Extension behaviour from the
    # newly available code paths.
    find_and_start_hex_extension(supervisor, registry, name, entry, opts)
  end

  def start_extension(supervisor, registry, name, entry, opts) do
    start_from_path(supervisor, registry, name, entry, opts)
  end

  @spec start_from_path(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) ::
          {:ok, pid()} | {:error, term()}
  defp start_from_path(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

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
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
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
    ExtRegistry.update(registry, name, status: :load_error, pid: nil)

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
    case run_lifecycle_phase(name, :child_start, opts, fn ->
           start_extension_child(supervisor, module, config)
         end) do
      {:ok, pid} ->
        ExtRegistry.update(registry, name, module: module, status: :running, pid: pid)
        emit_restart_count(name, 0)

        start_child_restart_monitor(
          supervisor,
          registry,
          name,
          module,
          pid,
          cmd_registry,
          keymap,
          opts
        )

        Minga.Log.info(:config, "Extension #{name} started (#{module})")
        {:ok, pid}

      {:error, reason} ->
        msg = "Extension #{name} failed to start: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, module: module, status: :load_error, pid: nil)
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
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    entry = current_stop_entry(registry, name, entry)

    termination_result =
      run_lifecycle_phase(name, :stop, opts, fn ->
        terminate_extension_process(supervisor, entry)
      end)

    finalize_stopped_extension(registry, name, entry)

    cleanup_result = cleanup_extension_contributions(name, cmd_registry, keymap, opts)

    case {termination_result, cleanup_result} do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, failures}} ->
        {:error, {:cleanup_failed, failures}}

      {{:error, reason}, :ok} ->
        {:error, reason}

      {{:error, reason}, {:error, failures}} ->
        {:error, {:cleanup_failed, reason, failures}}
    end
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

  @spec record_extension_manifest(GenServer.server(), atom(), module(), Manifest.source_type()) ::
          :ok | {:error, term()}
  defp record_extension_manifest(registry, name, module, source) do
    manifest = Manifest.from_module(module, source)
    ExtRegistry.update(registry, name, manifest: manifest)
    :ok
  rescue
    e -> {:error, "manifest introspection failed: #{Exception.message(e)}"}
  end

  @spec run_lifecycle_phase(atom(), atom(), start_opts(), (-> result)) :: result when result: var
  defp run_lifecycle_phase(name, phase, opts, fun)
       when is_atom(name) and is_atom(phase) and is_function(fun, 0) do
    start_time = System.monotonic_time()

    result =
      Minga.Telemetry.span(
        [:minga, :extension, :lifecycle],
        %{extension: name, phase: phase},
        fun
      )

    duration = System.monotonic_time() - start_time
    maybe_log_slow_lifecycle_phase(name, phase, duration, opts)
    result
  end

  @spec maybe_log_slow_lifecycle_phase(atom(), atom(), integer(), start_opts()) :: :ok
  defp maybe_log_slow_lifecycle_phase(name, phase, duration, opts) do
    threshold_ms = Keyword.get(opts, :slow_lifecycle_threshold_ms, 50)
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

  @spec start_extension_child(GenServer.server(), module(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defp start_extension_child(supervisor, module, config) do
    child_spec = normalize_child_spec(module, config)
    DynamicSupervisor.start_child(supervisor, child_spec)
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

  @spec current_stop_entry(GenServer.server(), atom(), ExtRegistry.entry()) :: ExtRegistry.entry()
  defp current_stop_entry(registry, name, %{pid: requested_pid} = entry)
       when is_pid(requested_pid) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{pid: current_pid} = current_entry}
      when is_pid(current_pid) and current_pid != requested_pid ->
        current_entry

      _ ->
        entry
    end
  end

  defp current_stop_entry(_registry, _name, entry), do: entry

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
      {:ok, pid} when is_pid(pid) -> terminate_extension_child(supervisor, pid)
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :not_found}
    end
  end

  @spec start_child_restart_monitor(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          pid(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp start_child_restart_monitor(
         supervisor,
         registry,
         name,
         module,
         pid,
         cmd_registry,
         keymap,
         opts
       ) do
    spawn(fn ->
      monitor_child_restarts(
        supervisor,
        registry,
        name,
        module,
        pid,
        0,
        cmd_registry,
        keymap,
        opts
      )
    end)

    :ok
  end

  @spec monitor_child_restarts(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          pid(),
          non_neg_integer(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp monitor_child_restarts(
         supervisor,
         registry,
         name,
         module,
         pid,
         count,
         cmd_registry,
         keymap,
         opts
       ) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        handle_child_down(
          supervisor,
          registry,
          name,
          module,
          pid,
          reason,
          count,
          cmd_registry,
          keymap,
          opts
        )
    end
  end

  @spec handle_child_down(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          pid(),
          term(),
          non_neg_integer(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp handle_child_down(
         supervisor,
         registry,
         name,
         module,
         pid,
         reason,
         count,
         cmd_registry,
         keymap,
         opts
       ) do
    wait_for_restarted_child(
      supervisor,
      registry,
      name,
      module,
      pid,
      reason,
      count + 1,
      0,
      cmd_registry,
      keymap,
      opts
    )
  end

  @spec crash_reason?(term()) :: boolean()
  defp crash_reason?(:normal), do: false
  defp crash_reason?(:shutdown), do: false
  defp crash_reason?({:shutdown, _reason}), do: false
  defp crash_reason?(_reason), do: true

  @spec wait_for_restarted_child(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          pid(),
          term(),
          non_neg_integer(),
          non_neg_integer(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp wait_for_restarted_child(
         _supervisor,
         registry,
         name,
         module,
         observed_pid,
         reason,
         _count,
         5,
         cmd_registry,
         keymap,
         opts
       ) do
    reconcile_missing_restarted_child(
      registry,
      name,
      module,
      observed_pid,
      reason,
      cmd_registry,
      keymap,
      opts
    )
  end

  defp wait_for_restarted_child(
         supervisor,
         registry,
         name,
         module,
         observed_pid,
         reason,
         count,
         attempts,
         cmd_registry,
         keymap,
         opts
       ) do
    case extension_child_pid(supervisor, module) do
      {:ok, pid} when is_pid(pid) ->
        ExtRegistry.update(registry, name, pid: pid)
        emit_restart_count(name, count)

        monitor_child_restarts(
          supervisor,
          registry,
          name,
          module,
          pid,
          count,
          cmd_registry,
          keymap,
          opts
        )

      :not_found ->
        receive do
        after
          10 ->
            wait_for_restarted_child(
              supervisor,
              registry,
              name,
              module,
              observed_pid,
              reason,
              count,
              attempts + 1,
              cmd_registry,
              keymap,
              opts
            )
        end

      {:error, lookup_reason} ->
        mark_observed_child_lookup_failed(registry, name, observed_pid, lookup_reason)
    end
  end

  @spec reconcile_missing_restarted_child(
          GenServer.server(),
          atom(),
          module(),
          pid(),
          term(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp reconcile_missing_restarted_child(
         registry,
         name,
         module,
         observed_pid,
         reason,
         cmd_registry,
         keymap,
         opts
       ) do
    case crash_reason?(reason) do
      true ->
        mark_observed_child_crashed(registry, name, observed_pid)

      false ->
        Minga.Log.info(
          :config,
          "Extension #{name} exited without restart: #{inspect(reason)}"
        )

        finalize_observed_terminal_exit(
          registry,
          name,
          module,
          observed_pid,
          cmd_registry,
          keymap,
          opts
        )
    end
  end

  @spec mark_observed_child_lookup_failed(GenServer.server(), atom(), pid(), term()) :: :ok
  defp mark_observed_child_lookup_failed(registry, name, observed_pid, lookup_reason) do
    if registry_observes_child?(registry, name, observed_pid) do
      Minga.Log.warning(
        :config,
        "Extension #{name}: child lookup failed: #{inspect(lookup_reason)}"
      )

      ExtRegistry.update(registry, name, status: :crashed, pid: nil)
    else
      :ok
    end
  end

  @spec mark_observed_child_crashed(GenServer.server(), atom(), pid()) :: :ok
  defp mark_observed_child_crashed(registry, name, observed_pid) do
    if registry_observes_child?(registry, name, observed_pid) do
      ExtRegistry.update(registry, name, status: :crashed, pid: nil)
    else
      :ok
    end
  end

  @spec registry_observes_child?(GenServer.server(), atom(), pid()) :: boolean()
  defp registry_observes_child?(registry, name, observed_pid) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{pid: ^observed_pid}} -> true
      _ -> false
    end
  end

  @spec finalize_observed_terminal_exit(
          GenServer.server(),
          atom(),
          module(),
          pid(),
          GenServer.server(),
          GenServer.server(),
          start_opts()
        ) :: :ok
  defp finalize_observed_terminal_exit(
         registry,
         name,
         module,
         observed_pid,
         cmd_registry,
         keymap,
         opts
       ) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{pid: ^observed_pid} = entry} ->
        finalize_stopped_extension(registry, name, entry)
        cleanup_extension_contributions(name, cmd_registry, keymap, opts)
        :ok

      :error ->
        finalize_stopped_extension(registry, name, %{module: module})
        cleanup_extension_contributions(name, cmd_registry, keymap, opts)
        :ok

      _replacement_or_stopped ->
        :ok
    end
  end

  @spec extension_child_pid(GenServer.server(), module()) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp extension_child_pid(supervisor, module) do
    child =
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {:undefined, pid, _type, [^module]} when is_pid(pid) -> {:ok, pid}
        _child -> nil
      end)

    child || :not_found
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
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
        [%{extension: name, reason: reason} | failures]
    end
  end

  defp resolve_git_extension(_registry, _name, _entry, failures), do: failures

  @spec find_and_start_hex_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp find_and_start_hex_extension(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    package_atom = String.to_atom(entry.hex.package)

    with :ok <-
           run_lifecycle_phase(name, :load, opts, fn ->
             ensure_hex_application_started(package_atom)
           end),
         {:ok, module} <- find_extension_module(package_atom),
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
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
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
        compile_and_find_extension(files)
    end
  end

  @spec compile_and_find_extension([String.t()]) :: {:ok, module()} | {:error, String.t()}
  defp compile_and_find_extension(files) do
    {result, diagnostics} = compile_quietly(files)
    log_diagnostics(diagnostics)
    result
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      {:error, "compile error: #{Exception.message(e)}"}

    e ->
      {:error, "error: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "error: #{inspect(kind)} #{inspect(reason)}"}
  end

  # Compiles extension files using ParallelCompiler so cross-module references resolve.
  # Diagnostics go through Code.with_diagnostics, not global :standard_error mutation.
  @spec compile_quietly([String.t()]) :: {{:ok, module()} | {:error, String.t()}, [map()]}
  defp compile_quietly(files) do
    Code.with_diagnostics(fn -> parallel_compile_and_find(files) end)
  end

  @spec parallel_compile_and_find([String.t()]) :: {:ok, module()} | {:error, String.t()}
  defp parallel_compile_and_find(files) do
    case Kernel.ParallelCompiler.compile(files, return_diagnostics: true) do
      {:ok, modules, _diag_map} ->
        find_extension_in_compiled(modules)

      {:error, _errors, _diag_map} ->
        {:error, "extension compilation failed (see *Messages*)"}
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

  @spec finalize_stopped_extension(GenServer.server(), atom(), ExtRegistry.entry()) :: :ok
  defp finalize_stopped_extension(registry, name, entry) do
    if entry.module do
      :code.purge(entry.module)
      :code.delete(entry.module)
    end

    ExtRegistry.update(registry, name, status: :stopped, pid: nil, module: nil)
    :ok
  end

  @spec mark_hex_entries_load_error(GenServer.server()) :: :ok
  defp mark_hex_entries_load_error(registry) do
    for {name, entry} <- ExtRegistry.all(registry), entry.source_type == :hex do
      ExtRegistry.update(registry, name, status: :load_error, pid: nil)
    end

    :ok
  end

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
