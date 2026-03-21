defmodule Minga.Tool.Manager do
  @moduledoc """
  GenServer that manages tool installations.

  Owns an ETS table of installed tools, scans the tools directory on init,
  and handles install/uninstall as async tasks under `Eval.TaskSupervisor`.
  Broadcasts events via `Events` for UI progress updates.

  ## Directory structure

      ~/.local/share/minga/tools/
      ├── bin/                          # Symlinks to actual binaries
      │   ├── pyright-langserver → ../pyright/node_modules/.bin/pyright-langserver
      │   └── gopls → ../gopls/bin/gopls
      ├── pyright/
      │   ├── receipt.json
      │   └── node_modules/...
      └── gopls/
          ├── receipt.json
          └── bin/gopls

  ## Events

  - `:tool_install_started` — `%{name: atom()}`
  - `:tool_install_progress` — `%{name: atom(), stage: atom(), message: String.t()}`
  - `:tool_install_complete` — `%{name: atom(), version: String.t()}`
  - `:tool_install_failed` — `%{name: atom(), reason: term()}`
  - `:tool_uninstall_complete` — `%{name: atom()}`
  """

  use GenServer

  alias Minga.Tool.{Installation, Installer, Recipe}
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @table __MODULE__
  @tools_dir_name "tools"

  @type tool_status :: :installed | :installing | :not_installed | :update_available | :failed

  defmodule State do
    @moduledoc false

    @enforce_keys [:table]
    defstruct [
      :table,
      installing: MapSet.new(),
      failed: %{},
      task_refs: %{}
    ]

    @type t :: %__MODULE__{
            table: :ets.tid(),
            installing: MapSet.t(atom()),
            failed: %{atom() => String.t()},
            task_refs: %{reference() => atom()}
          }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Returns the base tools directory path."
  @spec tools_dir() :: String.t()
  def tools_dir do
    data_dir = System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
    Path.join([data_dir, "minga", @tools_dir_name])
  end

  @doc "Returns the tools/bin directory path (for PATH prepending)."
  @spec bin_dir() :: String.t()
  def bin_dir, do: Path.join(tools_dir(), "bin")

  @doc "Returns true if a tool is installed."
  @spec installed?(atom()) :: boolean()
  def installed?(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, %Installation{}}] -> true
      _ -> false
    end
  end

  @doc "Returns the installation info for a tool, or nil."
  @spec get_installation(atom()) :: Installation.t() | nil
  def get_installation(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, %Installation{} = inst}] -> inst
      _ -> nil
    end
  end

  @doc "Returns all installed tools."
  @spec all_installed() :: [Installation.t()]
  def all_installed do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, inst} -> inst end)
    |> Enum.filter(&match?(%Installation{}, &1))
  end

  @doc "Returns the set of tools currently being installed."
  @spec installing() :: MapSet.t(atom())
  def installing do
    GenServer.call(__MODULE__, :installing)
  end

  @doc "Installs a tool by name. Returns immediately; install runs async."
  @spec install(atom()) ::
          :ok | {:error, :already_installed | :unknown_tool | :already_installing}
  def install(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:install, name})
  end

  @doc "Uninstalls a tool by name."
  @spec uninstall(atom()) :: :ok | {:error, :not_installed | :unknown_tool}
  def uninstall(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:uninstall, name})
  end

  @doc "Updates a tool to its latest version. Uninstalls then reinstalls."
  @spec update(atom()) :: :ok | {:error, term()}
  def update(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:update, name})
  end

  @doc """
  Returns the status of every known tool (installed, installing, not_installed,
  update_available, failed) along with version and error info.

  Returns a list of maps suitable for UI rendering:
  `%{recipe: Recipe.t(), status: tool_status(), installed_version: String.t() | nil, error_reason: String.t() | nil}`
  """
  @spec tool_status_list() :: [
          %{
            recipe: Recipe.t(),
            status: tool_status(),
            installed_version: String.t() | nil,
            error_reason: String.t() | nil
          }
        ]
  def tool_status_list do
    GenServer.call(__MODULE__, :tool_status_list)
  end

  @doc "Checks for updates across all installed tools. Returns a list of updatable tools."
  @spec check_updates() :: [{atom(), String.t(), String.t()}]
  def check_updates do
    GenServer.call(__MODULE__, :check_updates, 30_000)
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    dir = tools_dir()
    File.mkdir_p!(Path.join(dir, "bin"))

    # Scan existing installations on startup
    scan_installed(table, dir)

    {:ok, %State{table: table}}
  end

  @impl true
  def handle_call(:installing, _from, state) do
    {:reply, state.installing, state}
  end

  def handle_call({:install, name}, _from, state) do
    case validate_install(name, state) do
      {:ok, recipe} ->
        state = start_install_task(recipe, state)
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:uninstall, name}, _from, state) do
    case RecipeRegistry.get(name) do
      nil ->
        {:reply, {:error, :unknown_tool}, state}

      recipe ->
        case do_uninstall(recipe) do
          :ok ->
            :ets.delete(@table, name)
            broadcast(:tool_uninstall_complete, %{name: name})
            {:reply, :ok, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:update, name}, _from, state) do
    if MapSet.member?(state.installing, name) do
      {:reply, {:error, :already_installing}, state}
    else
      case RecipeRegistry.get(name) do
        nil ->
          {:reply, {:error, :unknown_tool}, state}

        recipe ->
          # Uninstall first, then start install task
          do_uninstall(recipe)
          :ets.delete(@table, name)
          state = start_install_task(recipe, state)
          {:reply, :ok, state}
      end
    end
  end

  def handle_call(:tool_status_list, _from, state) do
    recipes = RecipeRegistry.all()

    statuses =
      Enum.map(recipes, fn recipe ->
        {status, version, error_reason} = tool_status(recipe.name, state)

        %{
          recipe: recipe,
          status: status,
          installed_version: version,
          error_reason: error_reason
        }
      end)
      |> Enum.sort_by(fn %{recipe: r} -> {status_sort_order(r.name, state), r.label} end)

    {:reply, statuses, state}
  end

  def handle_call(:check_updates, _from, state) do
    updates =
      all_installed()
      |> Enum.map(&check_tool_update/1)
      |> Enum.reject(&is_nil/1)

    {:reply, updates, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed
    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {name, task_refs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | task_refs: task_refs, installing: MapSet.delete(state.installing, name)}

        state =
          case result do
            {:ok, version, recipe} ->
              record_installation(recipe, version)
              broadcast(:tool_install_complete, %{name: name, version: version})
              log_message("Tool installed: #{recipe.label} v#{version}")
              %{state | failed: Map.delete(state.failed, name)}

            {:error, reason} ->
              reason_str = format_error_reason(reason)
              broadcast(:tool_install_failed, %{name: name, reason: reason})
              log_message("Tool install failed: #{name} - #{reason_str}")
              %{state | failed: Map.put(state.failed, name, reason_str)}
          end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when reason != :normal do
    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {name, task_refs} ->
        reason_str = format_error_reason(reason)
        state = %{state | task_refs: task_refs, installing: MapSet.delete(state.installing, name)}
        state = %{state | failed: Map.put(state.failed, name, reason_str)}
        broadcast(:tool_install_failed, %{name: name, reason: reason})
        log_message("Tool install crashed: #{name} - #{reason_str}")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec check_tool_update(Installation.t()) :: {atom(), String.t(), String.t()} | nil
  defp check_tool_update(inst) do
    with %Recipe{} = recipe <- RecipeRegistry.get(inst.name),
         installer = Installer.for_method(recipe.method),
         {:ok, latest} when latest != inst.version <- installer.latest_version(recipe) do
      {inst.name, inst.version, latest}
    else
      _ -> nil
    end
  end

  @spec tool_status(atom(), map()) :: {tool_status(), String.t() | nil, String.t() | nil}
  defp tool_status(name, state) do
    tool_status_for(name, state.installing, state.failed)
  end

  @spec tool_status_for(atom(), MapSet.t(), %{atom() => String.t()}) ::
          {tool_status(), String.t() | nil, String.t() | nil}
  defp tool_status_for(name, installing, failed) do
    if MapSet.member?(installing, name) do
      {:installing, nil, nil}
    else
      case Map.get(failed, name) do
        nil -> installed_status(name)
        reason -> {:failed, nil, reason}
      end
    end
  end

  @spec installed_status(atom()) :: {tool_status(), String.t() | nil, String.t() | nil}
  defp installed_status(name) do
    case get_installation(name) do
      %Installation{version: version} -> {:installed, version, nil}
      nil -> {:not_installed, nil, nil}
    end
  end

  @spec validate_install(atom(), map()) :: {:ok, Recipe.t()} | {:error, atom()}
  defp validate_install(name, state) do
    if MapSet.member?(state.installing, name) do
      {:error, :already_installing}
    else
      validate_recipe_and_status(name)
    end
  end

  @spec validate_recipe_and_status(atom()) :: {:ok, Recipe.t()} | {:error, atom()}
  defp validate_recipe_and_status(name) do
    case RecipeRegistry.get(name) do
      nil -> {:error, :unknown_tool}
      # Allow retry of failed installs
      recipe -> if installed?(name), do: {:error, :already_installed}, else: {:ok, recipe}
    end
  end

  @spec start_install_task(Recipe.t(), map()) :: map()
  defp start_install_task(recipe, state) do
    name = recipe.name
    broadcast(:tool_install_started, %{name: name})
    log_message("Installing #{recipe.label}...")

    dest_dir = Path.join(tools_dir(), Atom.to_string(name))
    installer = Installer.for_method(recipe.method)

    progress_fn = fn stage, message ->
      broadcast(:tool_install_progress, %{name: name, stage: stage, message: message})
      :ok
    end

    task =
      Task.Supervisor.async_nolink(Minga.Eval.TaskSupervisor, fn ->
        case installer.install(recipe, dest_dir, progress_fn) do
          {:ok, version} ->
            # Create symlinks into tools/bin/
            create_symlinks(recipe, dest_dir)
            {:ok, version, recipe}

          {:error, reason} ->
            # Clean up partial install
            File.rm_rf(dest_dir)
            {:error, reason}
        end
      end)

    %{
      state
      | installing: MapSet.put(state.installing, name),
        failed: Map.delete(state.failed, name),
        task_refs: Map.put(state.task_refs, task.ref, name)
    }
  end

  @spec do_uninstall(Recipe.t()) :: :ok | {:error, term()}
  defp do_uninstall(recipe) do
    dest_dir = Path.join(tools_dir(), Atom.to_string(recipe.name))
    bin = bin_dir()

    # Remove symlinks first
    for cmd <- recipe.provides do
      link_path = Path.join(bin, cmd)
      File.rm(link_path)
    end

    # Remove the tool directory
    installer = Installer.for_method(recipe.method)
    installer.uninstall(recipe, dest_dir)
  end

  @spec record_installation(Recipe.t(), String.t()) :: :ok
  defp record_installation(recipe, version) do
    dest_dir = Path.join(tools_dir(), Atom.to_string(recipe.name))

    installation = %Installation{
      name: recipe.name,
      version: version,
      installed_at: DateTime.utc_now(),
      method: recipe.method,
      path: dest_dir
    }

    # Write receipt.json
    receipt_path = Path.join(dest_dir, "receipt.json")
    File.mkdir_p!(dest_dir)
    receipt_json = Jason.encode!(Installation.to_receipt(installation), pretty: true)
    File.write!(receipt_path, receipt_json)

    # Update ETS cache
    :ets.insert(@table, {recipe.name, installation})
    :ok
  end

  @spec create_symlinks(Recipe.t(), String.t()) :: :ok
  defp create_symlinks(recipe, dest_dir) do
    bin = bin_dir()
    File.mkdir_p!(bin)

    for cmd <- recipe.provides do
      target = find_binary(recipe, dest_dir, cmd)
      link_path = Path.join(bin, cmd)

      if target do
        # Remove existing symlink if present
        File.rm(link_path)
        File.ln_s!(target, link_path)
      end
    end

    :ok
  end

  @spec find_binary(Recipe.t(), String.t(), String.t()) :: String.t() | nil
  defp find_binary(%Recipe{method: :npm}, dest_dir, cmd) do
    path = Path.join([dest_dir, "node_modules", ".bin", cmd])
    if File.exists?(path), do: path, else: nil
  end

  defp find_binary(%Recipe{method: :pip}, dest_dir, cmd) do
    path = Path.join([dest_dir, "venv", "bin", cmd])
    if File.exists?(path), do: path, else: nil
  end

  defp find_binary(_recipe, dest_dir, cmd) do
    # For cargo, go, github_release: binary is in dest_dir/bin/
    path = Path.join([dest_dir, "bin", cmd])

    if File.exists?(path) do
      path
    else
      # Some tools extract to a nested directory; search recursively
      case System.cmd("find", [dest_dir, "-name", cmd, "-type", "f", "-perm", "+111"],
             stderr_to_stdout: true
           ) do
        {result, 0} ->
          result |> String.trim() |> String.split("\n") |> List.first()

        _ ->
          nil
      end
    end
  end

  @spec scan_installed(:ets.tid(), String.t()) :: :ok
  defp scan_installed(table, tools_dir) do
    case File.ls(tools_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "bin"))
        |> Enum.each(&load_receipt(table, tools_dir, &1))

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(:editor, "[Tool.Manager] Failed to scan tools dir: #{inspect(reason)}")
        :ok
    end
  end

  @spec load_receipt(:ets.tid(), String.t(), String.t()) :: :ok
  defp load_receipt(table, tools_dir, entry) do
    receipt_path = Path.join([tools_dir, entry, "receipt.json"])

    with {:ok, content} <- File.read(receipt_path),
         {:ok, receipt} <- Jason.decode(content),
         {:ok, installation} <- Installation.from_receipt(receipt) do
      :ets.insert(table, {installation.name, installation})
    else
      {:error, :enoent} ->
        :ok

      _ ->
        Minga.Log.warning(:editor, "[Tool.Manager] Invalid or missing receipt: #{receipt_path}")
    end

    :ok
  end

  @spec status_sort_order(atom(), map()) :: non_neg_integer()
  defp status_sort_order(name, state) do
    {status, _, _} = tool_status(name, state)
    status_order(status)
  end

  # Sort order for tool list display. :update_available will sort as :installed
  # once check_updates is wired into tool_status_list (ticket #743).
  @spec status_order(tool_status()) :: non_neg_integer()
  defp status_order(:installing), do: 0
  defp status_order(:failed), do: 0
  defp status_order(:installed), do: 1
  defp status_order(:not_installed), do: 2

  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason, limit: 200)

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(topic, payload) do
    unless is_nil(Process.whereis(Minga.EventBus)) do
      Registry.dispatch(Minga.EventBus, topic, &notify_subscribers(&1, topic, payload))
    end

    :ok
  end

  @spec notify_subscribers([{pid(), term()}], atom(), map()) :: :ok
  defp notify_subscribers(entries, topic, payload) do
    for {pid, _value} <- entries, do: send(pid, {:minga_event, topic, payload})
    :ok
  end

  @spec log_message(String.t()) :: :ok
  defp log_message(text) do
    if Process.whereis(Minga.Editor) do
      Minga.Editor.log_to_messages(text)
    end

    :ok
  end
end
