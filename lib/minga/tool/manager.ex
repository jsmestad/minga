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
  - `:tool_update_check_started` — `%{count: non_neg_integer()}`
  - `:tool_update_check_complete` — `%{updates: [update_result()], errors: [update_error()]}`
  """

  use GenServer

  alias Minga.Tool.{Installation, Installer, Recipe}
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @table __MODULE__
  @tools_dir_name "tools"
  @max_update_concurrency 4
  @default_update_check_timeout 15_000

  @type tool_status :: :installed | :installing | :not_installed | :update_available | :failed
  @type update_result :: {atom(), String.t(), String.t()}
  @type update_error :: {atom(), String.t()}

  defmodule State do
    @moduledoc false

    @enforce_keys [:table]
    defstruct [
      :table,
      installing: MapSet.new(),
      failed: %{},
      task_refs: %{},
      # Update check orchestration
      update_gen: 0,
      update_tasks: %{},
      update_timers: %{},
      update_queue: [],
      update_results: [],
      update_errors: [],
      cached_updates: []
    ]

    @type t :: %__MODULE__{
            table: :ets.tid(),
            installing: MapSet.t(atom()),
            failed: %{atom() => String.t()},
            task_refs: %{reference() => atom()},
            update_gen: non_neg_integer(),
            update_tasks: %{reference() => {atom(), String.t(), non_neg_integer(), pid()}},
            update_timers: %{reference() => reference()},
            update_queue: [{Minga.Tool.Recipe.t(), String.t()}],
            update_results: [Minga.Tool.Manager.update_result()],
            update_errors: [Minga.Tool.Manager.update_error()],
            cached_updates: [Minga.Tool.Manager.update_result()]
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

  @doc """
  Starts an asynchronous update check for all installed tools.

  Returns `:ok` immediately. At most #{@max_update_concurrency} checks run
  concurrently; the rest queue. Each check has a per-tool timeout. A new
  call cancels any in-flight check. Results are broadcast as
  `:tool_update_check_complete` and cached for `cached_updates/0`.
  """
  @spec check_updates() :: :ok
  def check_updates do
    GenServer.call(__MODULE__, :check_updates)
  end

  @doc "Returns cached results from the last completed update check."
  @spec cached_updates() :: [update_result()]
  def cached_updates do
    GenServer.call(__MODULE__, :cached_updates)
  end

  @doc "Cancels any in-flight update check. Already-cached results are preserved."
  @spec cancel_update_check() :: :ok
  def cancel_update_check do
    GenServer.call(__MODULE__, :cancel_update_check)
  end

  @doc "Returns true while an update check is in progress."
  @spec update_check_active?() :: boolean()
  def update_check_active? do
    GenServer.call(__MODULE__, :update_check_active?)
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
      |> Enum.sort_by(fn row -> {status_order(row.status), row.recipe.label} end)

    {:reply, statuses, state}
  end

  def handle_call(:check_updates, _from, state) do
    state = begin_update_check(state)
    {:reply, :ok, state}
  end

  def handle_call(:cached_updates, _from, state) do
    {:reply, state.cached_updates, state}
  end

  def handle_call(:cancel_update_check, _from, state) do
    state = cancel_in_flight_updates(state)
    {:reply, :ok, state}
  end

  def handle_call(:update_check_active?, _from, state) do
    active? = state.update_tasks != %{} or state.update_queue != []
    {:reply, active?, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.task_refs, ref) ->
        handle_install_complete(ref, result, state)

      Map.has_key?(state.update_tasks, ref) ->
        handle_update_check_result(ref, result, state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when reason != :normal do
    cond do
      Map.has_key?(state.task_refs, ref) ->
        handle_install_down(ref, reason, state)

      Map.has_key?(state.update_tasks, ref) ->
        handle_update_check_down(ref, reason, state)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:update_check_timeout, ref, gen}, state) do
    case Map.get(state.update_tasks, ref) do
      {name, _version, ^gen, pid} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        state = remove_update_task(state, ref)
        state = %{state | update_errors: [{name, "timeout"} | state.update_errors]}
        Minga.Log.warning(:editor, "[Tool.Manager] Update check timed out: #{name}")
        state = maybe_advance_update_check(state)
        {:noreply, state}

      _ ->
        # Stale timer (task already completed or generation changed)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Install task handling ──────────────────────────────────────────────────

  @spec handle_install_complete(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_install_complete(ref, result, state) do
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

  @spec handle_install_down(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_install_down(ref, reason, state) do
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

  # ── Update check orchestration ─────────────────────────────────────────────

  @spec begin_update_check(State.t()) :: State.t()
  defp begin_update_check(state) do
    state = cancel_in_flight_updates(state)
    gen = state.update_gen + 1
    installed = all_installed()

    snapshots =
      for inst <- installed,
          recipe = RecipeRegistry.get(inst.name),
          recipe != nil,
          do: {recipe, inst.version}

    state = %{state | update_gen: gen, update_results: [], update_errors: []}
    broadcast(:tool_update_check_started, %{count: length(snapshots)})

    if snapshots == [] do
      finalize_update_check(state)
    else
      dispatch_update_batch(snapshots, gen, state)
    end
  end

  @spec dispatch_update_batch([{Recipe.t(), String.t()}], non_neg_integer(), State.t()) ::
          State.t()
  defp dispatch_update_batch(snapshots, gen, state) do
    {batch, queue} = Enum.split(snapshots, @max_update_concurrency)
    state = %{state | update_queue: queue}

    Enum.reduce(batch, state, fn {recipe, version}, acc ->
      start_single_update_task(recipe, version, gen, acc)
    end)
  end

  @spec start_single_update_task(Recipe.t(), String.t(), non_neg_integer(), State.t()) ::
          State.t()
  defp start_single_update_task(recipe, installed_version, gen, state) do
    task =
      Task.Supervisor.async_nolink(Minga.Eval.TaskSupervisor, fn ->
        installer = Installer.for_method(recipe.method)

        case installer.latest_version(recipe) do
          {:ok, latest} -> {:ok, recipe.name, installed_version, latest}
          {:error, reason} -> {:error, recipe.name, reason}
        end
      end)

    timeout = update_check_timeout()
    timer_ref = Process.send_after(self(), {:update_check_timeout, task.ref, gen}, timeout)

    %{
      state
      | update_tasks:
          Map.put(state.update_tasks, task.ref, {recipe.name, installed_version, gen, task.pid}),
        update_timers: Map.put(state.update_timers, task.ref, timer_ref)
    }
  end

  @spec handle_update_check_result(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_update_check_result(ref, result, state) do
    case Map.get(state.update_tasks, ref) do
      nil ->
        {:noreply, state}

      {_name, _version, gen, _pid} when gen != state.update_gen ->
        # Stale result from a previous generation; discard
        Process.demonitor(ref, [:flush])
        state = remove_update_task(state, ref)
        {:noreply, state}

      {name, _version, _gen, _pid} ->
        Process.demonitor(ref, [:flush])
        state = remove_update_task(state, ref)

        state =
          case result do
            {:ok, ^name, installed, latest} when latest != installed ->
              %{state | update_results: [{name, installed, latest} | state.update_results]}

            {:ok, _, _, _} ->
              # Same version, no update needed
              state

            {:error, err_name, reason} ->
              reason_str = format_error_reason(reason)

              Minga.Log.warning(
                :editor,
                "[Tool.Manager] Update check failed: #{err_name} - #{reason_str}"
              )

              %{state | update_errors: [{err_name, reason_str} | state.update_errors]}
          end

        state = maybe_advance_update_check(state)
        {:noreply, state}
    end
  end

  @spec handle_update_check_down(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_update_check_down(ref, reason, state) do
    case Map.get(state.update_tasks, ref) do
      nil ->
        {:noreply, state}

      {_name, _version, gen, _pid} when gen != state.update_gen ->
        state = remove_update_task(state, ref)
        {:noreply, state}

      {name, _version, _gen, _pid} ->
        state = remove_update_task(state, ref)
        reason_str = format_error_reason(reason)
        state = %{state | update_errors: [{name, reason_str} | state.update_errors]}
        Minga.Log.warning(:editor, "[Tool.Manager] Update check crashed: #{name} - #{reason_str}")
        state = maybe_advance_update_check(state)
        {:noreply, state}
    end
  end

  @spec maybe_advance_update_check(State.t()) :: State.t()
  defp maybe_advance_update_check(state) do
    case state.update_queue do
      [] when map_size(state.update_tasks) == 0 ->
        finalize_update_check(state)

      [{recipe, version} | rest] ->
        state = %{state | update_queue: rest}
        start_single_update_task(recipe, version, state.update_gen, state)

      _ ->
        # Queue empty but tasks still in flight; wait for them
        state
    end
  end

  @spec finalize_update_check(State.t()) :: State.t()
  defp finalize_update_check(state) do
    results = Enum.reverse(state.update_results)
    errors = Enum.reverse(state.update_errors)
    broadcast(:tool_update_check_complete, %{updates: results, errors: errors})

    count = length(results)
    error_count = length(errors)

    if error_count > 0 do
      log_message(
        "Update check complete: #{count} update(s) available, #{error_count} check(s) failed"
      )
    else
      log_message("Update check complete: #{count} update(s) available")
    end

    %{state | cached_updates: results, update_results: [], update_errors: []}
  end

  @spec cancel_in_flight_updates(State.t()) :: State.t()
  defp cancel_in_flight_updates(state) do
    for {ref, {_name, _version, _gen, pid}} <- state.update_tasks do
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
    end

    for {_ref, timer} <- state.update_timers do
      Process.cancel_timer(timer)
    end

    %{
      state
      | update_tasks: %{},
        update_timers: %{},
        update_queue: [],
        update_results: [],
        update_errors: []
    }
  end

  @spec remove_update_task(State.t(), reference()) :: State.t()
  defp remove_update_task(state, ref) do
    case Map.get(state.update_timers, ref) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end

    %{
      state
      | update_tasks: Map.delete(state.update_tasks, ref),
        update_timers: Map.delete(state.update_timers, ref)
    }
  end

  @spec update_check_timeout() :: non_neg_integer()
  defp update_check_timeout do
    Application.get_env(:minga, :update_check_timeout, @default_update_check_timeout)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec tool_status(atom(), State.t()) :: {tool_status(), String.t() | nil, String.t() | nil}
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

  @spec validate_install(atom(), State.t()) :: {:ok, Recipe.t()} | {:error, atom()}
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

  @spec start_install_task(Recipe.t(), State.t()) :: State.t()
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
    receipt_json = Installation.to_receipt(installation) |> :json.format()
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
         {:ok, receipt} <- JSON.decode(content),
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
    Minga.Events.broadcast(topic, payload, Minga.Events.default_registry())
  end

  @spec log_message(String.t()) :: :ok
  defp log_message(text) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: text, level: :info},
      Minga.Events.default_registry()
    )

    :ok
  end
end
