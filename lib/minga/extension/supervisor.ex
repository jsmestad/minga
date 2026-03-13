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
  @spec start_all() :: :ok
  @spec start_all(GenServer.server(), GenServer.server()) :: :ok
  def start_all, do: start_all(__MODULE__, ExtRegistry)

  def start_all(supervisor, registry) do
    # Step 1: Install hex extensions (single Mix.install call)
    case ExtHex.install_all(registry) do
      :ok -> :ok
      {:error, msg} -> Minga.Log.warning(:config, msg)
    end

    # Step 2: Resolve git extensions to local paths
    resolve_git_extensions(registry)

    # Step 3: Start all extensions
    for {name, entry} <- ExtRegistry.all(registry) do
      start_extension(supervisor, registry, name, entry)
    end

    :ok
  end

  @doc """
  Stops all running extensions and purges their modules.

  Used by config reload to cleanly tear down before re-loading.
  """
  @spec stop_all() :: :ok
  @spec stop_all(GenServer.server(), GenServer.server()) :: :ok
  def stop_all, do: stop_all(__MODULE__, ExtRegistry)

  def stop_all(supervisor, registry) do
    for {name, entry} <- ExtRegistry.all(registry) do
      stop_extension(supervisor, registry, name, entry)
    end

    :ok
  end

  @doc """
  Starts a single extension by name.

  For path extensions, compiles the module from the local directory.
  Git and hex extensions must be resolved to a local path or loaded
  via Mix.install before calling this function.
  """
  @spec start_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  def start_extension(supervisor, registry, name, %{source_type: :git} = entry) do
    # Git extensions are resolved to a local path in resolve_git_extensions/1.
    # If the path was set, compile from there. Otherwise it failed to clone.
    if entry.path do
      start_from_path(supervisor, registry, name, entry)
    else
      {:error, :clone_failed}
    end
  end

  def start_extension(supervisor, registry, name, %{source_type: :hex} = entry) do
    # Hex extensions are loaded via Mix.install in start_all/2.
    # Find the module implementing the Extension behaviour from the
    # newly available code paths.
    find_and_start_hex_extension(supervisor, registry, name, entry)
  end

  def start_extension(supervisor, registry, name, entry) do
    start_from_path(supervisor, registry, name, entry)
  end

  @spec start_from_path(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  defp start_from_path(supervisor, registry, name, entry) do
    with {:ok, module} <- compile_extension(entry.path),
         :ok <- validate_behaviour(module, name),
         {:ok, _state} <- call_init(module, entry.config) do
      start_child(supervisor, registry, name, module, entry.config)
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
        {:error, reason}
    end
  end

  @spec start_child(GenServer.server(), GenServer.server(), atom(), module(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defp start_child(supervisor, registry, name, module, config) do
    child_spec = module.child_spec(config)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        ExtRegistry.update(registry, name, module: module, status: :running, pid: pid)
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
  @spec stop_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) :: :ok
  def stop_extension(supervisor, registry, name, entry) do
    if is_pid(entry.pid) and Process.alive?(entry.pid) do
      DynamicSupervisor.terminate_child(supervisor, entry.pid)
    end

    if entry.module do
      :code.purge(entry.module)
      :code.delete(entry.module)
    end

    ExtRegistry.update(registry, name, status: :stopped, pid: nil, module: nil)
    :ok
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
            _ -> "unknown"
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

  @spec resolve_git_extensions(GenServer.server()) :: :ok
  defp resolve_git_extensions(registry) do
    for {name, entry} <- ExtRegistry.all(registry), entry.source_type == :git do
      case ExtGit.ensure_cloned(name, entry.git) do
        {:ok, local_path} ->
          ExtRegistry.update(registry, name, path: local_path)

        {:error, reason} ->
          Minga.Log.warning(:config, "Extension #{name}: #{reason}")
          ExtRegistry.update(registry, name, status: :load_error)
      end
    end

    :ok
  end

  @spec find_and_start_hex_extension(
          GenServer.server(),
          GenServer.server(),
          atom(),
          ExtRegistry.entry()
        ) :: {:ok, pid()} | {:error, term()}
  defp find_and_start_hex_extension(supervisor, registry, name, entry) do
    package_atom = String.to_atom(entry.hex.package)

    case Application.ensure_all_started(package_atom) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    # Search loaded modules for one implementing the Extension behaviour.
    # The convention is the package name maps to a module like MingaSnippets.
    with {:ok, module} <- find_extension_module(package_atom),
         :ok <- validate_behaviour(module, name),
         {:ok, _state} <- call_init(module, entry.config) do
      start_child(supervisor, registry, name, module, entry.config)
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
        {:error, reason}
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
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        modules =
          Enum.flat_map(files, fn file ->
            file
            |> Code.compile_file()
            |> Enum.map(&elem(&1, 0))
          end)

        case Enum.find(modules, &implements_extension?/1) do
          nil ->
            {:error, "no module implementing Minga.Extension behaviour found"}

          mod ->
            {:ok, mod}
        end
      end)

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

      # All extension compile diagnostics go to debug level. Warnings about
      # undefined Minga modules are expected (extensions compile standalone
      # without Minga in scope) and would clutter the terminal during startup
      # if logged at warning level.
      case severity do
        :error ->
          Minga.Log.warning(:editor, "[ext:error] #{short_file}:#{pos_str}: #{message}")

        _ ->
          Minga.Log.debug(:editor, "[ext] #{short_file}:#{pos_str}: #{message}")
      end
    end

    :ok
  end

  @spec format_position(term()) :: String.t()
  defp format_position({line, col}) when is_integer(line) and is_integer(col), do: "#{line}:#{col}"
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
