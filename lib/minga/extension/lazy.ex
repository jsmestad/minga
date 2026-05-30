defmodule Minga.Extension.Lazy do
  @moduledoc """
  Lazy loading for extensions with non-eager load policies.

  Extensions that declare a load policy other than `:eager` are compiled
  at boot (via the compile cache, so this is fast for unchanged sources)
  but their `init/1` and child process are deferred. Instead, lightweight
  stub commands and keybindings are registered from the compiled module's
  schema callbacks. The first time a stub is triggered, the extension
  loads fully (init + child start) and the stub is replaced with the
  real handler, all synchronously within the command dispatch.

  This keeps startup cost proportional to the number of *eager*
  extensions, not the total installed count.
  """

  alias Minga.Command
  alias Minga.Extension.CompileCache
  alias Minga.Extension.Manifest
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  @typedoc "Result from registering stubs for a lazy extension."
  @type stub_result :: :ok | {:error, term()}

  @doc """
  Compiles a path/git extension, reads its schema, and registers stub
  commands and keybindings without calling init or starting a child.

  The extension's module is loaded into the VM (so schema callbacks are
  callable) but no runtime side effects run. The registry entry is
  updated to `:stub` status with the compiled module and manifest.
  """
  @spec register_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: stub_result()
  def register_stubs(supervisor, registry, name, entry, opts) do
    case compile_extension(entry) do
      {:ok, module} ->
        do_register_stubs(supervisor, registry, name, module, entry.source_type, opts,
          set_module: true
        )

      {:error, reason} ->
        log_stub_failure(name, reason, registry)
        {:error, reason}
    end
  end

  @doc """
  Compiles a module-sourced extension and registers stubs without init.

  For bundled extensions already on the code path, no compilation is
  needed beyond `Code.ensure_loaded/1`.
  """
  @spec register_module_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: stub_result()
  def register_module_stubs(supervisor, registry, name, entry, opts) do
    module = entry.module

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        do_register_stubs(supervisor, registry, name, module, entry.source_type, opts,
          set_module: false
        )

      {:error, reason} ->
        log_stub_failure(name, {:module_load_failed, reason}, registry)
        {:error, {:module_load_failed, reason}}
    end
  end

  @doc """
  Fully loads a previously-stubbed extension: runs init, starts its
  child process, and replaces stub commands/keybinds with real handlers.

  Called synchronously when a stub command or keybinding is first
  triggered. Uses the same lifecycle lock as `start_extension` to
  prevent races between concurrent stub triggers.

  Returns `{:ok, pid}` on success or `{:error, reason}` if the
  extension fails to load.
  """
  @spec autoload(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtSupervisor.start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  def autoload(supervisor, registry, name, opts) do
    with_autoload_lock(registry, name, fn ->
      case ExtRegistry.get(registry, name) do
        {:ok, %{status: :stub} = entry} ->
          do_autoload(supervisor, registry, name, entry, opts)

        {:ok, %{status: :running, pid: pid}} when is_pid(pid) ->
          {:ok, pid}

        {:ok, %{status: status}} ->
          {:error, {:unexpected_status, status}}

        :error ->
          {:error, :not_registered}
      end
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec do_register_stubs(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          Manifest.source_type(),
          ExtSupervisor.start_opts(),
          keyword()
        ) :: stub_result()
  defp do_register_stubs(supervisor, registry, name, module, source_type, opts, internal_opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    with :ok <- ExtSupervisor.validate_behaviour(module, name),
         {:ok, manifest} <- build_manifest(module, source_type) do
      registry_fields =
        if Keyword.get(internal_opts, :set_module, false) do
          [module: module, manifest: manifest, status: :stub]
        else
          [manifest: manifest, status: :stub]
        end

      ExtRegistry.update(registry, name, registry_fields)
      register_stub_commands(supervisor, registry, name, module, cmd_registry, opts)
      register_stub_keybinds(name, module, keymap)

      Minga.Log.info(
        :config,
        "Extension #{name} registered as stub (#{inspect(manifest.load_policy)})"
      )

      :ok
    else
      {:error, reason} ->
        log_stub_failure(name, reason, registry)
        {:error, reason}
    end
  end

  @spec log_stub_failure(atom(), term(), GenServer.server()) :: :ok
  defp log_stub_failure(name, reason, registry) do
    Minga.Log.warning(
      :config,
      "Extension #{name} stub registration failed: #{inspect(reason)}"
    )

    ExtRegistry.update(registry, name, status: :load_error, pid: nil, lifecycle_ref: nil)
    :ok
  end

  @spec do_autoload(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: {:ok, pid()} | {:error, term()}
  defp do_autoload(supervisor, registry, name, entry, opts) do
    cmd_registry = Keyword.get(opts, :command_registry, Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    Minga.Log.info(:config, "Extension #{name} autoloading on first use")

    cleanup_contributions(name, cmd_registry, keymap, opts)
    ExtRegistry.update(registry, name, status: :stopped)

    case ExtSupervisor.start_extension(supervisor, registry, name, entry, opts) do
      {:ok, pid} ->
        Minga.Log.info(:config, "Extension #{name} autoloaded successfully")
        {:ok, pid}

      {:error, reason} ->
        Minga.Log.warning(:config, "Extension #{name} autoload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec with_autoload_lock(GenServer.server(), atom(), (-> result)) :: result when result: var
  defp with_autoload_lock(registry, name, fun) when is_atom(name) and is_function(fun, 0) do
    resource_id = {ExtSupervisor, :lifecycle, canonical_registry_id(registry), name}
    requester_id = self()
    :global.trans({resource_id, requester_id}, fun, [node()], :infinity)
  end

  @spec canonical_registry_id(GenServer.server()) :: term()
  defp canonical_registry_id(registry) when is_pid(registry) do
    case Process.info(registry, :registered_name) do
      {:registered_name, reg_name} when is_atom(reg_name) -> {:local_name, reg_name}
      _other -> {:pid, registry}
    end
  end

  defp canonical_registry_id(registry) when is_atom(registry) do
    case Process.whereis(registry) do
      pid when is_pid(pid) -> canonical_registry_id(pid)
      nil -> {:local_name, registry}
    end
  end

  defp canonical_registry_id({:global, reg_name}), do: {:global_name, reg_name}
  defp canonical_registry_id({:via, module, reg_name}), do: {:via, module, reg_name}
  defp canonical_registry_id(registry), do: registry

  @spec cleanup_contributions(
          atom(),
          GenServer.server(),
          GenServer.server(),
          ExtSupervisor.start_opts()
        ) :: :ok
  defp cleanup_contributions(name, cmd_registry, keymap, opts) do
    source = {:extension, name}

    cleanup_opts =
      [command_registry: cmd_registry, keymap: keymap]
      |> Keyword.merge(Keyword.take(opts, [:callbacks]))

    case Minga.Extension.ContributionCleanup.unregister_source(source, cleanup_opts) do
      :ok -> :ok
      {:error, _failures} -> :ok
    end
  end

  @spec compile_extension(ExtRegistry.entry()) :: {:ok, module()} | {:error, term()}
  defp compile_extension(%{source_type: :path, path: path}) when is_binary(path) do
    compile_from_path(Path.expand(path))
  end

  defp compile_extension(%{source_type: :git, path: path}) when is_binary(path) do
    compile_from_path(Path.expand(path))
  end

  defp compile_extension(%{source_type: :git, path: nil}) do
    {:error, :clone_failed}
  end

  defp compile_extension(%{source_type: :module, module: module}) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      {:error, reason} -> {:error, {:module_load_failed, reason}}
    end
  end

  defp compile_extension(%{source_type: :hex}) do
    {:error, :hex_stub_not_supported}
  end

  @spec compile_from_path(String.t()) :: {:ok, module()} | {:error, term()}
  defp compile_from_path(expanded) do
    if File.dir?(expanded) do
      files =
        expanded
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.sort()

      compile_source_files(expanded, files)
    else
      {:error, "extension path does not exist: #{expanded}"}
    end
  end

  @spec compile_source_files(String.t(), [String.t()]) :: {:ok, module()} | {:error, term()}
  defp compile_source_files(_expanded, []), do: {:error, "no .ex files found"}

  defp compile_source_files(expanded, files) do
    case CompileCache.load_or_compile(expanded, files) do
      {:ok, %{modules: modules}} -> find_extension_module(modules)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec find_extension_module([module()]) :: {:ok, module()} | {:error, String.t()}
  defp find_extension_module(modules) do
    case Enum.find(modules, &ExtSupervisor.implements_extension?/1) do
      nil -> {:error, "no module implementing Minga.Extension behaviour found"}
      mod -> {:ok, mod}
    end
  end

  @spec build_manifest(module(), Manifest.source_type()) ::
          {:ok, Manifest.t()} | {:error, term()}
  defp build_manifest(module, source) do
    {:ok, Manifest.from_module(module, source)}
  rescue
    e -> {:error, "manifest introspection failed: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "manifest introspection failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  @spec register_stub_commands(
          GenServer.server(),
          GenServer.server(),
          atom(),
          module(),
          GenServer.server(),
          ExtSupervisor.start_opts()
        ) :: :ok
  defp register_stub_commands(supervisor, registry, name, module, cmd_registry, opts) do
    schema = command_schema(module)

    Enum.each(schema, fn {cmd_name, description, cmd_opts} ->
      requires_buffer = Keyword.get(cmd_opts, :requires_buffer, false)

      stub_cmd = %Command{
        name: cmd_name,
        description: description,
        requires_buffer: requires_buffer,
        execute: stub_execute_fn(supervisor, registry, name, cmd_name, cmd_registry, opts)
      }

      case Command.Registry.register_command(cmd_registry, {:extension, name}, stub_cmd) do
        :ok ->
          :ok

        {:error, reason} ->
          Minga.Log.warning(
            :config,
            "Extension #{name} stub command #{cmd_name} rejected: #{inspect(reason)}"
          )
      end
    end)
  end

  @spec stub_execute_fn(
          GenServer.server(),
          GenServer.server(),
          atom(),
          atom(),
          GenServer.server(),
          ExtSupervisor.start_opts()
        ) :: (term() -> term())
  defp stub_execute_fn(supervisor, registry, name, cmd_name, cmd_registry, opts) do
    fn state ->
      case autoload(supervisor, registry, name, opts) do
        {:ok, _pid} -> execute_autoloaded_command(cmd_registry, cmd_name, state)
        {:error, _reason} -> state
      end
    end
  end

  @spec execute_autoloaded_command(GenServer.server(), atom(), term()) :: term()
  defp execute_autoloaded_command(cmd_registry, cmd_name, state) do
    case Command.Registry.lookup(cmd_registry, cmd_name) do
      {:ok, cmd} -> cmd.execute.(state)
      :error -> state
    end
  end

  @spec register_stub_keybinds(atom(), module(), GenServer.server()) :: :ok
  defp register_stub_keybinds(name, module, keymap) do
    schema = keybind_schema(module)

    Enum.each(schema, fn {mode, key_str, command, description, bind_opts} ->
      source_opts = Keyword.put(bind_opts, :source, {:extension, name})

      case Minga.Keymap.Active.bind(keymap, mode, key_str, command, description, source_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Minga.Log.warning(
            :config,
            "Extension #{name} stub keybind #{inspect(key_str)} failed: #{reason}"
          )
      end
    end)
  end

  @spec command_schema(module()) :: [Minga.Extension.command_spec()]
  defp command_schema(module) do
    if function_exported?(module, :__command_schema__, 0),
      do: module.__command_schema__(),
      else: []
  end

  @spec keybind_schema(module()) :: [Minga.Extension.keybind_spec()]
  defp keybind_schema(module) do
    if function_exported?(module, :__keybind_schema__, 0),
      do: module.__keybind_schema__(),
      else: []
  end

  @doc """
  Resolves the effective load policy for an extension entry.

  If the entry has an explicit `load_policy` set from config (non-nil),
  that wins. Otherwise falls back to the module's declared
  `__load_policy__/0` if the module is loaded, then to `:eager`.
  """
  @spec effective_load_policy(ExtRegistry.entry()) :: Minga.Extension.load_policy()
  def effective_load_policy(%{load_policy: policy}) when is_atom(policy) and policy != nil,
    do: policy

  def effective_load_policy(%{load_policy: policy}) when is_tuple(policy), do: policy

  def effective_load_policy(%{module: module}) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__load_policy__, 0) do
      module.__load_policy__()
    else
      :eager
    end
  end

  def effective_load_policy(_entry), do: :eager

  @doc """
  Returns true if the given load policy requires eager loading at boot.
  """
  @spec eager?(Minga.Extension.load_policy()) :: boolean()
  def eager?(:eager), do: true
  def eager?(_policy), do: false

  @doc """
  Returns true if the given load policy is deferred (post-first-paint).
  """
  @spec deferred?(Minga.Extension.load_policy()) :: boolean()
  def deferred?(:deferred), do: true
  def deferred?(_policy), do: false

  @doc """
  Returns true if the load policy is trigger-based (on_command, on_filetype, on_key).
  """
  @spec trigger_based?(Minga.Extension.load_policy()) :: boolean()
  def trigger_based?({:on_command, _}), do: true
  def trigger_based?({:on_filetype, _}), do: true
  def trigger_based?({:on_key, _}), do: true
  def trigger_based?(_policy), do: false

  @deferred_load_delay_ms 100

  @doc """
  Schedules deferred extensions to load in the background after a short
  delay, allowing the editor to render the first frame first.
  """
  @spec schedule_deferred_loads(
          GenServer.server(),
          GenServer.server(),
          [{atom(), ExtRegistry.entry()}],
          ExtSupervisor.start_opts()
        ) :: :ok
  def schedule_deferred_loads(_supervisor, _registry, [], _opts), do: :ok

  def schedule_deferred_loads(supervisor, registry, deferred_entries, opts) do
    spawn(fn ->
      receive do
      after
        @deferred_load_delay_ms -> :ok
      end

      Enum.each(deferred_entries, fn {name, entry} ->
        start_deferred_extension(supervisor, registry, name, entry, opts)
      end)
    end)

    :ok
  end

  @spec start_deferred_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry(),
          ExtSupervisor.start_opts()
        ) :: :ok
  defp start_deferred_extension(supervisor, registry, name, entry, opts) do
    case ExtSupervisor.start_extension(supervisor, registry, name, entry, opts) do
      {:ok, _pid} ->
        Minga.Log.info(:config, "Extension #{name} deferred load complete")

      {:error, reason} ->
        Minga.Log.warning(
          :config,
          "Extension #{name} deferred load failed: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    e ->
      Minga.Log.warning(
        :config,
        "Extension #{name} deferred load crashed: #{Exception.message(e)}"
      )

      :ok
  end
end
