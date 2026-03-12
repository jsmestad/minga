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

  Compiles each extension from its declared path, validates the behaviour,
  and starts its child_spec. Errors are logged and stored in the registry
  as `:load_error` status without affecting other extensions.
  """
  @spec start_all() :: :ok
  @spec start_all(GenServer.server(), GenServer.server()) :: :ok
  def start_all, do: start_all(__MODULE__, ExtRegistry)

  def start_all(supervisor, registry) do
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

  Compiles the module from path, validates the behaviour, calls `init/1`,
  and starts the child_spec under this supervisor.
  """
  @spec start_extension(GenServer.server(), GenServer.server(), atom(), ExtRegistry.entry()) ::
          {:ok, pid()} | {:error, term()}
  def start_extension(supervisor, registry, name, entry) do
    with {:ok, module} <- compile_extension(entry.path),
         :ok <- validate_behaviour(module, name),
         {:ok, _state} <- call_init(module, entry.config) do
      child_spec = module.child_spec(entry.config)

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
    else
      {:error, reason} ->
        msg = "Extension #{name} load error: #{inspect(reason)}"
        Minga.Log.warning(:config, msg)
        ExtRegistry.update(registry, name, status: :load_error, pid: nil)
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
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      {:error, "compile error: #{Exception.message(e)}"}

    e ->
      {:error, "error: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "error: #{inspect(kind)} #{inspect(reason)}"}
  end

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
