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

  ## Update checks

  `check_updates/1` snapshots every installed tool with its recipe, replies `:ok`, and runs the registry lookups outside the Manager mailbox. The lookups run under a task supervisor that the Manager starts and links in `init/1`, so they stop when the Manager stops. At most four lookups run at once; the rest wait in a queue. Each lookup has its own timeout (`:update_check_timeout`, 15 seconds by default). Killing a lookup does not stop a subprocess it started, so each installer backend also bounds its own request to `Minga.Tool.Installer.latest_version_timeout_seconds/0`, which is shorter.

  One check is active at a time. A new `check_updates/1`, `cancel_update_check/1`, or the exit of the process that requested the check cancels it, kills its lookups, and broadcasts `:tool_update_check_cancelled`.

  A lookup result is accepted only if the tool's installation and recipe are still the ones that were snapshotted. A result for a tool that was installed, reinstalled, uninstalled, or given a new recipe during the check is discarded. Install, uninstall, and update also drop the tool's cached update. Accepted updates are stored in the ETS table, so `cached_updates/1`, `available_update/2`, and `tool_status_list/1` read them without waiting for a check.

  The Editor starts a check when a tool picker opens and refreshes the tool picker when the check completes.

  ## Events

  - `:tool_install_started` — `%{name: atom()}`
  - `:tool_install_progress` — `%{name: atom(), stage: atom(), message: String.t()}`
  - `:tool_install_complete` — `%{name: atom(), version: String.t()}`
  - `:tool_install_failed` — `%{name: atom(), reason: term()}`
  - `:tool_uninstall_complete` — `%{name: atom()}`
  - `:tool_update_check_started`: `%{generation: pos_integer(), count: non_neg_integer()}`
  - `:tool_update_check_complete`: `%{generation: pos_integer(), updates: [update_result()], errors: [update_error()]}`
  - `:tool_update_check_cancelled`: `%{generation: pos_integer(), reason: cancel_reason()}`
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
  @type cancel_reason :: :cancelled | :superseded | :requester_down

  @typedoc "Process name or pid of a Manager."
  @type server :: GenServer.server()

  @typedoc "Name of the ETS table that a Manager owns."
  @type table :: atom()

  @typedoc "A cached update, valid only while the installation and recipe are unchanged."
  @type cached_update :: %{installation: Installation.t(), recipe: Recipe.t(), latest: String.t()}

  @typedoc "One in-flight update lookup."
  @type update_task :: %{
          name: atom(),
          recipe: Recipe.t(),
          installation: Installation.t(),
          pid: pid(),
          timer: reference()
        }

  defmodule State do
    @moduledoc false

    @enforce_keys [:table, :tools_dir, :events, :update_supervisor, :update_timeout]
    defstruct [
      :table,
      :tools_dir,
      :events,
      :update_supervisor,
      :update_timeout,
      installing: MapSet.new(),
      failed: %{},
      task_refs: %{},
      # Update check orchestration
      update_gen: 0,
      update_requester: nil,
      update_tasks: %{},
      update_queue: [],
      update_results: [],
      update_errors: []
    ]

    @type t :: %__MODULE__{
            table: Minga.Tool.Manager.table(),
            tools_dir: String.t(),
            events: Minga.Events.registry(),
            update_supervisor: pid(),
            update_timeout: pos_integer(),
            installing: MapSet.t(atom()),
            failed: %{atom() => String.t()},
            task_refs: %{reference() => atom()},
            update_gen: non_neg_integer(),
            update_requester: {pid(), reference()} | nil,
            update_tasks: %{reference() => Minga.Tool.Manager.update_task()},
            update_queue: [{Minga.Tool.Recipe.t(), Minga.Tool.Installation.t()}],
            update_results: [{atom(), Minga.Tool.Manager.cached_update()}],
            update_errors: [Minga.Tool.Manager.update_error()]
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
  @spec installed?(atom(), table()) :: boolean()
  def installed?(name, table \\ @table) when is_atom(name) do
    get_installation(name, table) != nil
  end

  @doc "Returns the installation info for a tool, or nil."
  @spec get_installation(atom(), table()) :: Installation.t() | nil
  def get_installation(name, table \\ @table) when is_atom(name) do
    case :ets.lookup(table, name) do
      [{^name, %Installation{} = inst}] -> inst
      _ -> nil
    end
  end

  @doc "Returns all installed tools."
  @spec all_installed(table()) :: [Installation.t()]
  def all_installed(table \\ @table) do
    for {_name, %Installation{} = inst} <- :ets.tab2list(table), do: inst
  end

  @doc "Returns the set of tools currently being installed."
  @spec installing(server()) :: MapSet.t(atom())
  def installing(server \\ __MODULE__) do
    GenServer.call(server, :installing)
  end

  @doc "Installs a tool by name. Returns immediately; install runs async."
  @spec install(atom(), server()) ::
          :ok | {:error, :already_installed | :unknown_tool | :already_installing}
  def install(name, server \\ __MODULE__) when is_atom(name) do
    GenServer.call(server, {:install, name})
  end

  @doc "Uninstalls a tool by name."
  @spec uninstall(atom(), server()) :: :ok | {:error, :not_installed | :unknown_tool}
  def uninstall(name, server \\ __MODULE__) when is_atom(name) do
    GenServer.call(server, {:uninstall, name})
  end

  @doc "Updates a tool to its latest version. Uninstalls then reinstalls."
  @spec update(atom(), server()) :: :ok | {:error, term()}
  def update(name, server \\ __MODULE__) when is_atom(name) do
    GenServer.call(server, {:update, name})
  end

  @doc """
  Returns the status of every known tool (installed, installing, not_installed,
  update_available, failed) along with version and error info.

  Returns a list of maps suitable for UI rendering:
  `%{recipe: Recipe.t(), status: tool_status(), installed_version: String.t() | nil, error_reason: String.t() | nil}`
  """
  @spec tool_status_list(server()) :: [
          %{
            recipe: Recipe.t(),
            status: tool_status(),
            installed_version: String.t() | nil,
            error_reason: String.t() | nil
          }
        ]
  def tool_status_list(server \\ __MODULE__) do
    GenServer.call(server, :tool_status_list)
  end

  @doc """
  Starts an asynchronous update check for all installed tools.

  Returns `:ok` after the lookups are scheduled; it never waits for a registry. The calling process owns the check: if it exits, the check is cancelled. A new call cancels any in-flight check. Results are broadcast as `:tool_update_check_complete` and cached for `cached_updates/1`.
  """
  @spec check_updates(server()) :: :ok
  def check_updates(server \\ __MODULE__) do
    GenServer.call(server, :check_updates)
  end

  @doc "Returns the cached updates that still match the current installation and recipe."
  @spec cached_updates(table()) :: [update_result()]
  def cached_updates(table \\ @table) do
    for {{:update, name}, entry} <- :ets.match_object(table, {{:update, :_}, :_}),
        current_update?(table, name, entry),
        do: {name, entry.installation.version, entry.latest}
  end

  @doc "Returns `{installed_version, latest_version}` when a valid cached update exists for the tool."
  @spec available_update(atom(), table()) :: {String.t(), String.t()} | nil
  def available_update(name, table \\ @table) when is_atom(name) do
    case :ets.lookup(table, {:update, name}) do
      [{_key, entry}] ->
        if current_update?(table, name, entry),
          do: {entry.installation.version, entry.latest},
          else: nil

      [] ->
        nil
    end
  end

  @doc "Cancels any in-flight update check. Already-cached results are preserved."
  @spec cancel_update_check(server()) :: :ok
  def cancel_update_check(server \\ __MODULE__) do
    GenServer.call(server, :cancel_update_check)
  end

  @doc "Returns true while an update check is in progress."
  @spec update_check_active?(server()) :: boolean()
  def update_check_active?(server \\ __MODULE__) do
    GenServer.call(server, :update_check_active?)
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @doc """
  Starts the Manager.

  Options:
  - `:name`: process name, defaults to `#{inspect(__MODULE__)}`
  - `:table`: ETS table name, defaults to `#{inspect(@table)}`
  - `:tools_dir`: tools directory, defaults to `tools_dir/0`
  - `:events_registry`: event bus registry, defaults to `Minga.Events.default_registry/0`
  - `:update_check_timeout`: per-tool update lookup timeout in milliseconds
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.get(opts, :table, @table), [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    dir = Keyword.get(opts, :tools_dir, tools_dir())
    File.mkdir_p!(Path.join(dir, "bin"))

    # Scan existing installations on startup
    scan_installed(table, dir)

    # Linked, so update lookups stop when the Manager stops.
    {:ok, update_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %State{
       table: table,
       tools_dir: dir,
       events: Keyword.get(opts, :events_registry, Minga.Events.default_registry()),
       update_supervisor: update_supervisor,
       update_timeout: Keyword.get(opts, :update_check_timeout, @default_update_check_timeout)
     }}
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
        case do_uninstall(recipe, state) do
          :ok ->
            :ets.delete(state.table, name)
            state = forget_update(state, name)
            broadcast(state, :tool_uninstall_complete, %{name: name})
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
          do_uninstall(recipe, state)
          :ets.delete(state.table, name)
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

  def handle_call(:check_updates, {requester, _tag}, state) do
    state = begin_update_check(state, requester)
    {:reply, :ok, state}
  end

  def handle_call(:cancel_update_check, _from, state) do
    state = cancel_in_flight_updates(state, :cancelled)
    {:reply, :ok, state}
  end

  def handle_call(:update_check_active?, _from, state) do
    {:reply, update_check_running?(state), state}
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

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{update_requester: {_, ref}} = state
      ) do
    {:noreply, cancel_in_flight_updates(state, :requester_down)}
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

  def handle_info({:update_check_timeout, ref}, state) do
    case Map.pop(state.update_tasks, ref) do
      {nil, _tasks} ->
        # Stale timer: the lookup already finished or its check was cancelled.
        {:noreply, state}

      {task, tasks} ->
        Process.demonitor(ref, [:flush])
        Process.exit(task.pid, :kill)
        Minga.Log.warning(:editor, "[Tool.Manager] Update check timed out: #{task.name}")

        state = %{
          state
          | update_tasks: tasks,
            update_errors: [{task.name, "timeout"} | state.update_errors]
        }

        {:noreply, advance_update_check(state)}
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
              record_installation(recipe, version, state)
              broadcast(state, :tool_install_complete, %{name: name, version: version})
              log_message(state, "Tool installed: #{recipe.label} v#{version}")
              %{state | failed: Map.delete(state.failed, name)}

            {:error, reason} ->
              reason_str = format_error_reason(reason)
              broadcast(state, :tool_install_failed, %{name: name, reason: reason})
              log_message(state, "Tool install failed: #{name} - #{reason_str}")
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
        broadcast(state, :tool_install_failed, %{name: name, reason: reason})
        log_message(state, "Tool install crashed: #{name} - #{reason_str}")
        {:noreply, state}
    end
  end

  # ── Update check orchestration ─────────────────────────────────────────────

  @spec begin_update_check(State.t(), pid()) :: State.t()
  defp begin_update_check(state, requester) do
    state = cancel_in_flight_updates(state, :superseded)
    gen = state.update_gen + 1

    snapshots =
      for inst <- all_installed(state.table),
          recipe = RecipeRegistry.get(inst.name),
          recipe != nil,
          do: {recipe, inst}

    state = %{
      state
      | update_gen: gen,
        update_requester: {requester, Process.monitor(requester)},
        update_queue: snapshots
    }

    broadcast(state, :tool_update_check_started, %{generation: gen, count: length(snapshots)})
    advance_update_check(state)
  end

  # Starts queued lookups up to the concurrency limit, or finishes the check when nothing is left.
  @spec advance_update_check(State.t()) :: State.t()
  defp advance_update_check(%State{update_queue: [], update_tasks: tasks} = state)
       when map_size(tasks) == 0,
       do: finalize_update_check(state)

  defp advance_update_check(
         %State{update_queue: [{recipe, inst} | rest], update_tasks: tasks} = state
       )
       when map_size(tasks) < @max_update_concurrency do
    %{state | update_queue: rest}
    |> start_update_task(recipe, inst)
    |> advance_update_check()
  end

  defp advance_update_check(state), do: state

  @spec start_update_task(State.t(), Recipe.t(), Installation.t()) :: State.t()
  defp start_update_task(state, recipe, installation) do
    installer = Installer.for_method(recipe.method)

    task =
      Task.Supervisor.async_nolink(state.update_supervisor, fn ->
        installer.latest_version(recipe)
      end)

    timer = Process.send_after(self(), {:update_check_timeout, task.ref}, state.update_timeout)

    entry = %{
      name: recipe.name,
      recipe: recipe,
      installation: installation,
      pid: task.pid,
      timer: timer
    }

    %{state | update_tasks: Map.put(state.update_tasks, task.ref, entry)}
  end

  @spec handle_update_check_result(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_update_check_result(ref, result, state) do
    {task, tasks} = Map.pop!(state.update_tasks, ref)
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(task.timer)

    state =
      %{state | update_tasks: tasks}
      |> record_update_outcome(task, result)
      |> advance_update_check()

    {:noreply, state}
  end

  @spec record_update_outcome(State.t(), update_task(), term()) :: State.t()
  defp record_update_outcome(state, task, {:ok, latest}) when is_binary(latest) do
    entry = %{installation: task.installation, recipe: task.recipe, latest: latest}

    cond do
      not current_update?(state.table, task.name, entry) ->
        Minga.Log.debug(:editor, "[Tool.Manager] Discarded stale update check: #{task.name}")
        state

      latest == task.installation.version ->
        state

      true ->
        %{state | update_results: [{task.name, entry} | state.update_results]}
    end
  end

  defp record_update_outcome(state, task, {:error, reason}) do
    reason_str = format_error_reason(reason)
    Minga.Log.warning(:editor, "[Tool.Manager] Update check failed: #{task.name} - #{reason_str}")
    %{state | update_errors: [{task.name, reason_str} | state.update_errors]}
  end

  defp record_update_outcome(state, task, other) do
    record_update_outcome(state, task, {:error, {:unexpected_result, other}})
  end

  @spec handle_update_check_down(reference(), term(), State.t()) :: {:noreply, State.t()}
  defp handle_update_check_down(ref, reason, state) do
    {task, tasks} = Map.pop!(state.update_tasks, ref)
    Process.cancel_timer(task.timer)
    reason_str = format_error_reason(reason)

    Minga.Log.warning(
      :editor,
      "[Tool.Manager] Update check crashed: #{task.name} - #{reason_str}"
    )

    state = %{
      state
      | update_tasks: tasks,
        update_errors: [{task.name, reason_str} | state.update_errors]
    }

    {:noreply, advance_update_check(state)}
  end

  @spec finalize_update_check(State.t()) :: State.t()
  defp finalize_update_check(state) do
    :ets.match_delete(state.table, {{:update, :_}, :_})

    for {name, entry} <- state.update_results,
        do: :ets.insert(state.table, {{:update, name}, entry})

    results =
      state.update_results
      |> Enum.map(fn {name, entry} -> {name, entry.installation.version, entry.latest} end)
      |> Enum.sort()

    errors = Enum.sort(state.update_errors)

    broadcast(state, :tool_update_check_complete, %{
      generation: state.update_gen,
      updates: results,
      errors: errors
    })

    log_message(state, completion_message(length(results), length(errors)))
    clear_update_check(state)
  end

  @spec completion_message(non_neg_integer(), non_neg_integer()) :: String.t()
  defp completion_message(count, 0), do: "Update check complete: #{count} update(s) available"

  defp completion_message(count, error_count),
    do: "Update check complete: #{count} update(s) available, #{error_count} check(s) failed"

  @spec cancel_in_flight_updates(State.t(), cancel_reason()) :: State.t()
  defp cancel_in_flight_updates(state, reason) do
    if update_check_running?(state) do
      for {ref, task} <- state.update_tasks do
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(task.timer)
        Process.exit(task.pid, :kill)
      end

      broadcast(state, :tool_update_check_cancelled, %{
        generation: state.update_gen,
        reason: reason
      })
    end

    clear_update_check(state)
  end

  @spec clear_update_check(State.t()) :: State.t()
  defp clear_update_check(state) do
    case state.update_requester do
      {_pid, ref} -> Process.demonitor(ref, [:flush])
      nil -> true
    end

    %{
      state
      | update_requester: nil,
        update_tasks: %{},
        update_queue: [],
        update_results: [],
        update_errors: []
    }
  end

  @spec update_check_running?(State.t()) :: boolean()
  defp update_check_running?(state), do: state.update_tasks != %{} or state.update_queue != []

  # Drops a tool's cached and pending update after its installation changes.
  @spec forget_update(State.t(), atom()) :: State.t()
  defp forget_update(state, name) do
    :ets.delete(state.table, {:update, name})
    %{state | update_results: List.keydelete(state.update_results, name, 0)}
  end

  @spec current_update?(table(), atom(), cached_update()) :: boolean()
  defp current_update?(table, name, entry) do
    get_installation(name, table) == entry.installation and
      RecipeRegistry.get(name) == entry.recipe
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec tool_status(atom(), State.t()) :: {tool_status(), String.t() | nil, String.t() | nil}
  defp tool_status(name, state) do
    cond do
      MapSet.member?(state.installing, name) -> {:installing, nil, nil}
      Map.has_key?(state.failed, name) -> {:failed, nil, Map.fetch!(state.failed, name)}
      true -> installed_status(name, state.table)
    end
  end

  @spec installed_status(atom(), table()) :: {tool_status(), String.t() | nil, String.t() | nil}
  defp installed_status(name, table) do
    case get_installation(name, table) do
      nil -> {:not_installed, nil, nil}
      %Installation{version: version} -> {installed_kind(name, table), version, nil}
    end
  end

  @spec installed_kind(atom(), table()) :: :installed | :update_available
  defp installed_kind(name, table) do
    if available_update(name, table), do: :update_available, else: :installed
  end

  @spec validate_install(atom(), State.t()) :: {:ok, Recipe.t()} | {:error, atom()}
  defp validate_install(name, state) do
    if MapSet.member?(state.installing, name) do
      {:error, :already_installing}
    else
      validate_recipe_and_status(name, state.table)
    end
  end

  @spec validate_recipe_and_status(atom(), table()) :: {:ok, Recipe.t()} | {:error, atom()}
  defp validate_recipe_and_status(name, table) do
    case RecipeRegistry.get(name) do
      nil -> {:error, :unknown_tool}
      # Allow retry of failed installs
      recipe -> if installed?(name, table), do: {:error, :already_installed}, else: {:ok, recipe}
    end
  end

  @spec start_install_task(Recipe.t(), State.t()) :: State.t()
  defp start_install_task(recipe, state) do
    name = recipe.name
    broadcast(state, :tool_install_started, %{name: name})
    log_message(state, "Installing #{recipe.label}...")

    dest_dir = Path.join(state.tools_dir, Atom.to_string(name))
    bin = Path.join(state.tools_dir, "bin")
    installer = Installer.for_method(recipe.method)
    events = state.events

    progress_fn = fn stage, message ->
      Minga.Events.broadcast(
        :tool_install_progress,
        %{name: name, stage: stage, message: message},
        events
      )

      :ok
    end

    task =
      Task.Supervisor.async_nolink(Minga.Eval.TaskSupervisor, fn ->
        case installer.install(recipe, dest_dir, progress_fn) do
          {:ok, version} ->
            # Create symlinks into tools/bin/
            create_symlinks(recipe, dest_dir, bin)
            {:ok, version, recipe}

          {:error, reason} ->
            # Clean up partial install
            File.rm_rf(dest_dir)
            {:error, reason}
        end
      end)

    state = forget_update(state, name)

    %{
      state
      | installing: MapSet.put(state.installing, name),
        failed: Map.delete(state.failed, name),
        task_refs: Map.put(state.task_refs, task.ref, name)
    }
  end

  @spec do_uninstall(Recipe.t(), State.t()) :: :ok | {:error, term()}
  defp do_uninstall(recipe, state) do
    dest_dir = Path.join(state.tools_dir, Atom.to_string(recipe.name))
    bin = Path.join(state.tools_dir, "bin")

    # Remove symlinks first
    for cmd <- recipe.provides do
      link_path = Path.join(bin, cmd)
      File.rm(link_path)
    end

    installer = Installer.for_method(recipe.method)
    installer.uninstall(recipe, dest_dir)
  end

  @spec record_installation(Recipe.t(), String.t(), State.t()) :: :ok
  defp record_installation(recipe, version, state) do
    dest_dir = Path.join(state.tools_dir, Atom.to_string(recipe.name))

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
    :ets.insert(state.table, {recipe.name, installation})
    :ok
  end

  @spec create_symlinks(Recipe.t(), String.t(), String.t()) :: :ok
  defp create_symlinks(recipe, dest_dir, bin) do
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

  @spec scan_installed(table(), String.t()) :: :ok
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

  @spec load_receipt(table(), String.t(), String.t()) :: :ok
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

  # Sort order for tool list display: pending and failed first, then installed tools, then the rest.
  @spec status_order(tool_status()) :: non_neg_integer()
  defp status_order(:installing), do: 0
  defp status_order(:failed), do: 0
  defp status_order(:update_available), do: 1
  defp status_order(:installed), do: 1
  defp status_order(:not_installed), do: 2

  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason, limit: 200)

  @spec broadcast(State.t(), atom(), map()) :: :ok
  defp broadcast(state, topic, payload) do
    Minga.Events.broadcast(topic, payload, state.events)
  end

  @spec log_message(State.t(), String.t()) :: :ok
  defp log_message(state, text) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: text, level: :info},
      state.events
    )

    :ok
  end
end
