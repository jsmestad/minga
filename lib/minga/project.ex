defmodule Minga.Project do
  @moduledoc """
  Project awareness GenServer, modeled after Emacs projectile.

  Tracks the current project root, caches the file list, and persists a
  known-projects list to `~/.config/minga/known-projects` so that `SPC p p`
  works across editor sessions.

  ## State

  * `current_root` — the active project root (detected from the first opened file)
  * `project_type` — the type of project (`:git`, `:mix`, `:cargo`, etc.)
  * `cached_files` — the file list for the current project (populated by a background Task)
  * `known_projects` — list of all project roots the user has visited, persisted to disk
  * `recent_files` — per-project list of recently opened files, most recent first, persisted to disk
  * `command_frecency` — command execution timestamps used to rank the empty command palette
  * `rebuilding?` — true while a background Task is rebuilding the file cache

  ## File cache

  The cached file list lives in GenServer state (not ETS). Only one consumer
  (the picker, running inside the Editor process) reads it at a time, so a
  GenServer is simpler and sufficient. Cache rebuilds run in a supervised
  `Task` to keep the GenServer responsive during the shell-out to `fd` or
  `git ls-files`.
  """

  use GenServer

  alias Minga.Command
  alias Minga.Config
  alias Minga.Project.Detector

  defstruct current_root: nil,
            project_type: nil,
            cached_files: [],
            known_projects: [],
            recent_files: %{},
            frecency_events: %{},
            command_frecency: %{},
            rebuilding?: false,
            rebuild_ref: nil,
            events_registry: Minga.Events.default_registry()

  @typedoc "Per-project recent files map: project root => list of relative paths (most recent first)."
  @type recent_files_map :: %{String.t() => [String.t()]}

  @typedoc "Per-file access event history (most recent first, unix seconds)."
  @type file_accesses_map :: %{String.t() => [non_neg_integer()]}

  @typedoc "Per-project frecency map: project root => %{relative_path => access_timestamps}."
  @type frecency_events_map :: %{String.t() => file_accesses_map()}

  @typedoc "Per-command execution event history (most recent first, unix seconds)."
  @type command_frecency_map :: %{atom() => [non_neg_integer()]}

  @typedoc "Project GenServer state."
  @type t :: %__MODULE__{
          current_root: String.t() | nil,
          project_type: Detector.project_type() | nil,
          cached_files: [String.t()],
          known_projects: [String.t()],
          recent_files: recent_files_map(),
          frecency_events: frecency_events_map(),
          command_frecency: command_frecency_map(),
          rebuilding?: boolean(),
          rebuild_ref: reference() | nil,
          events_registry: Minga.Events.registry()
        }

  @known_projects_file "known-projects"
  @recent_files_file "recent-files"
  @frecency_file "frecency"
  @command_frecency_file "command-frecency"
  @frecency_events_per_file_limit 10
  @command_frecency_events_limit 20

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the project GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Detects the project root for a file and sets it as the current project.

  Automatically adds the detected root to the known-projects list and triggers
  a background cache rebuild. No-op if detection finds no project markers.
  """
  @spec detect_and_set(GenServer.server(), String.t()) :: :ok
  def detect_and_set(server \\ __MODULE__, file_path) when is_binary(file_path) do
    GenServer.cast(server, {:detect_and_set, file_path})
  end

  @doc "Returns the current project root, or nil if none is detected."
  @spec root(GenServer.server()) :: String.t() | nil
  def root(server \\ __MODULE__) do
    GenServer.call(server, :root)
  end

  @doc """
  Returns the current project root, falling back to `File.cwd!()`.

  Safe to call even when the Project GenServer is not running (e.g., during
  early startup or in tests): catches `:exit` from the GenServer call and
  falls back to the working directory.
  """
  @spec resolve_root() :: String.t()
  def resolve_root do
    case root() do
      nil -> File.cwd!()
      r -> r
    end
  catch
    :exit, _ -> File.cwd!()
  end

  @doc "Returns the cached file list for the current project."
  @spec files(GenServer.server()) :: [String.t()]
  def files(server \\ __MODULE__) do
    GenServer.call(server, :files)
  end

  @doc "Returns the list of known project roots."
  @spec known_projects(GenServer.server()) :: [String.t()]
  def known_projects(server \\ __MODULE__) do
    GenServer.call(server, :known_projects)
  end

  @doc "Switches to a known project root, triggering a cache rebuild."
  @spec switch(GenServer.server(), String.t()) :: :ok
  def switch(server \\ __MODULE__, root_path) when is_binary(root_path) do
    GenServer.cast(server, {:switch, root_path})
  end

  @doc "Invalidates the file cache and triggers a rebuild."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  end

  @doc "Adds a directory as a known project."
  @spec add(GenServer.server(), String.t()) :: :ok
  def add(server \\ __MODULE__, root_path) when is_binary(root_path) do
    GenServer.cast(server, {:add, root_path})
  end

  @doc "Removes a project from the known-projects list."
  @spec remove(GenServer.server(), String.t()) :: :ok
  def remove(server \\ __MODULE__, root_path) when is_binary(root_path) do
    GenServer.cast(server, {:remove, root_path})
  end

  @doc """
  Records a file as recently opened in the current project.

  The file path should be absolute. It is stored relative to the project root.
  Most recent files appear first. Duplicates are moved to the front.
  No-op if no project root is set or the file is outside the current project.
  """
  @spec record_file(GenServer.server(), String.t()) :: :ok
  def record_file(server \\ __MODULE__, file_path) when is_binary(file_path) do
    GenServer.cast(server, {:record_file, file_path})
  end

  @doc "Returns the list of recently opened files for the current project (relative paths, most recent first)."
  @spec recent_files(GenServer.server()) :: [String.t()]
  def recent_files(server \\ __MODULE__) do
    GenServer.call(server, :recent_files)
  end

  @doc "Returns frecency scores for files in the current project (relative path => score)."
  @spec frecency_scores(GenServer.server()) :: %{String.t() => non_neg_integer()}
  def frecency_scores(server \\ __MODULE__) do
    GenServer.call(server, :frecency_scores)
  end

  @doc "Records a command execution for command palette frecency ranking."
  @spec record_command(GenServer.server(), atom()) :: :ok
  def record_command(server \\ __MODULE__, command_name)

  def record_command(__MODULE__, command_name) when is_atom(command_name) do
    case Process.whereis(__MODULE__) do
      nil ->
        Minga.Log.warning(
          :editor,
          "Command frecency not recorded, Project unavailable: #{command_name}"
        )

        :ok

      _pid ->
        GenServer.cast(__MODULE__, {:record_command, command_name})
    end
  end

  def record_command(server, command_name) when is_atom(command_name) do
    GenServer.cast(server, {:record_command, command_name})
  end

  @doc "Returns frecency scores for command palette commands (command name => score)."
  @spec command_frecency_scores(GenServer.server()) :: %{atom() => non_neg_integer()}
  def command_frecency_scores(server \\ __MODULE__) do
    GenServer.call(server, :command_frecency_scores)
  end

  @doc "Scores a file's access timestamps using frecency decay buckets."
  @spec score_accesses([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  def score_accesses(timestamps, now_unix) when is_list(timestamps) and is_integer(now_unix) do
    Enum.reduce(timestamps, 0, fn ts, score -> score + bucket_points(now_unix - ts) end)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    # Subscribe to buffer-open events so we detect projects and record
    # recent files automatically, without the Editor wiring it up.
    # Tests pass subscribe: false to avoid cross-test event contamination.
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    unless Keyword.get(opts, :subscribe) == false do
      Minga.Events.subscribe(:buffer_opened, events_registry)
    end

    known = if persist_known_projects?(), do: load_known_projects(), else: []
    recent = if persist_recent_files?(), do: load_recent_files(), else: %{}
    frecency = if persist_recent_files?(), do: load_frecency_events(), else: %{}
    command_frecency = load_command_frecency()

    {:ok,
     %__MODULE__{
       known_projects: known,
       recent_files: recent,
       frecency_events: frecency,
       command_frecency: command_frecency,
       events_registry: events_registry
     }}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()}
  def handle_call(:root, _from, state) do
    {:reply, state.current_root, state}
  end

  def handle_call(:files, _from, state) do
    {:reply, state.cached_files, state}
  end

  def handle_call(:known_projects, _from, state) do
    {:reply, state.known_projects, state}
  end

  def handle_call(:recent_files, _from, %{current_root: nil} = state) do
    {:reply, [], state}
  end

  def handle_call(:recent_files, _from, state) do
    files = Map.get(state.recent_files, state.current_root, [])
    {:reply, files, state}
  end

  def handle_call(:frecency_scores, _from, %{current_root: nil} = state) do
    {:reply, %{}, state}
  end

  def handle_call(:frecency_scores, _from, state) do
    root = state.current_root
    now_unix = System.system_time(:second)

    scores =
      state.frecency_events
      |> Map.get(root, %{})
      |> Map.new(fn {rel_path, timestamps} ->
        {rel_path, score_accesses(timestamps, now_unix)}
      end)

    {:reply, scores, state}
  end

  def handle_call(:command_frecency_scores, _from, state) do
    now_unix = System.system_time(:second)

    scores =
      Map.new(state.command_frecency, fn {command_name, timestamps} ->
        {command_name, score_accesses(timestamps, now_unix)}
      end)

    {:reply, scores, state}
  end

  @impl true
  @spec handle_cast(term(), t()) :: {:noreply, t()}
  def handle_cast({:detect_and_set, file_path}, state) do
    {:noreply, do_detect_and_set(state, file_path)}
  end

  def handle_cast({:switch, root_path}, state) do
    expanded = Path.expand(root_path)

    if File.dir?(expanded) do
      state =
        state
        |> set_project(expanded, nil)
        |> add_to_known(expanded)
        |> start_rebuild()

      {:noreply, state}
    else
      Minga.Log.warning(:editor, "Project.switch: directory not found: #{expanded}")
      {:noreply, state}
    end
  end

  def handle_cast(:invalidate, state) do
    state = %{state | cached_files: []} |> start_rebuild()
    {:noreply, state}
  end

  def handle_cast({:add, root_path}, state) do
    expanded = Path.expand(root_path)

    if File.dir?(expanded) do
      state = add_to_known(state, expanded)
      {:noreply, state}
    else
      Minga.Log.warning(:editor, "Project.add: directory not found: #{expanded}")
      {:noreply, state}
    end
  end

  def handle_cast({:record_file, _file_path}, %{current_root: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:record_file, file_path}, state) do
    {:noreply, do_record_file(state, file_path)}
  end

  def handle_cast({:record_command, command_name}, state) do
    {:noreply, do_record_command(state, command_name)}
  end

  def handle_cast({:remove, root_path}, state) do
    expanded = Path.expand(root_path)
    new_known = Enum.reject(state.known_projects, &(&1 == expanded))
    if persist_known_projects?(), do: persist_known_projects(new_known)
    {:noreply, %{state | known_projects: new_known}}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({ref, {:rebuild_done, root, files}}, %{rebuild_ref: ref} = state)
      when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    if root == state.current_root do
      Minga.Events.broadcast(
        :project_rebuilt,
        %Minga.Events.ProjectRebuiltEvent{root: root},
        state.events_registry
      )

      {:noreply, %{state | cached_files: files, rebuilding?: false, rebuild_ref: nil}}
    else
      # Root changed while rebuild was in progress; discard stale result
      {:noreply, %{state | rebuilding?: false, rebuild_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rebuild_ref: ref} = state) do
    if reason != :normal do
      Minga.Log.warning(:editor, "Project file cache rebuild failed: #{inspect(reason)}")
    end

    {:noreply, %{state | rebuilding?: false, rebuild_ref: nil}}
  end

  def handle_info({:minga_event, :buffer_opened, %Minga.Events.BufferEvent{path: path}}, state) do
    state = do_detect_and_set(state, path)
    state = do_record_file(state, path)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec do_detect_and_set(t(), String.t()) :: t()
  defp do_detect_and_set(state, file_path) do
    case Detector.detect(file_path) do
      {:ok, root, type} ->
        if root == state.current_root do
          state
        else
          state
          |> set_project(root, type)
          |> add_to_known(root)
          |> start_rebuild()
        end

      :none ->
        state
    end
  end

  @spec do_record_file(t(), String.t()) :: t()
  defp do_record_file(%{current_root: nil} = state, _file_path), do: state

  defp do_record_file(state, file_path) do
    expanded = Path.expand(file_path)
    root = state.current_root

    case make_relative(expanded, root) do
      nil ->
        state

      rel_path ->
        limit = recent_files_limit()
        existing = Map.get(state.recent_files, root, [])
        updated = [rel_path | Enum.reject(existing, &(&1 == rel_path))]
        updated = Enum.take(updated, limit)
        new_recent = Map.put(state.recent_files, root, updated)

        now_unix = System.system_time(:second)

        new_frecency =
          state.frecency_events
          |> Map.get(root, %{})
          |> Map.update(rel_path, [now_unix], fn timestamps ->
            [now_unix | timestamps] |> Enum.take(@frecency_events_per_file_limit)
          end)
          |> then(&Map.put(state.frecency_events, root, &1))

        state = %{state | recent_files: new_recent, frecency_events: new_frecency}

        if persist_recent_files?() do
          persist_recent_files(new_recent)
          persist_frecency_events(new_frecency)
        end

        state
    end
  end

  @spec do_record_command(t(), atom()) :: t()
  defp do_record_command(state, command_name) when is_atom(command_name) do
    now_unix = System.system_time(:second)

    command_frecency =
      Map.update(state.command_frecency, command_name, [now_unix], fn timestamps ->
        [now_unix | timestamps] |> Enum.take(@command_frecency_events_limit)
      end)

    state = %{state | command_frecency: command_frecency}
    persist_command_frecency(command_frecency)
    state
  end

  @spec set_project(t(), String.t(), Detector.project_type() | nil) :: t()
  defp set_project(state, root, type) do
    %{state | current_root: root, project_type: type, cached_files: []}
  end

  @spec add_to_known(t(), String.t()) :: t()
  defp add_to_known(state, root) do
    if root in state.known_projects do
      state
    else
      new_known = [root | state.known_projects]
      if persist_known_projects?(), do: persist_known_projects(new_known)
      %{state | known_projects: new_known}
    end
  end

  @spec start_rebuild(t()) :: t()
  defp start_rebuild(%{current_root: nil} = state), do: state

  defp start_rebuild(state) do
    root = state.current_root

    task =
      Task.async(fn ->
        case Minga.Project.list_files(root) do
          {:ok, files} -> {:rebuild_done, root, files}
          {:error, _msg} -> {:rebuild_done, root, []}
        end
      end)

    %{state | rebuilding?: true, rebuild_ref: task.ref}
  end

  # ── Persistence ─────────────────────────────────────────────────────────────

  @spec known_projects_path() :: String.t()
  defp known_projects_path do
    config_dir = Path.expand("~/.config/minga")
    Path.join(config_dir, @known_projects_file)
  end

  @spec load_known_projects() :: [String.t()]
  defp load_known_projects do
    path = known_projects_path()

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  @spec make_relative(String.t(), String.t()) :: String.t() | nil
  defp make_relative(abs_path, root) do
    root_prefix = root <> "/"

    if String.starts_with?(abs_path, root_prefix) do
      String.replace_prefix(abs_path, root_prefix, "")
    else
      nil
    end
  end

  @spec recent_files_limit() :: pos_integer()
  defp recent_files_limit do
    Config.get(:recent_files_limit)
  end

  @spec persist_known_projects?() :: boolean()
  defp persist_known_projects? do
    Config.get(:persist_known_projects)
  end

  @spec persist_recent_files?() :: boolean()
  defp persist_recent_files? do
    Config.get(:persist_recent_files)
  end

  @spec persist_known_projects([String.t()]) :: :ok
  defp persist_known_projects(projects) do
    path = known_projects_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    content = Enum.join(projects, "\n") <> "\n"
    File.write!(path, content)
    :ok
  rescue
    e ->
      Minga.Log.warning(:editor, "Failed to persist known projects: #{Exception.message(e)}")
      :ok
  end

  # ── Recent files persistence ────────────────────────────────────────────────
  # Format: one line per entry, tab-separated: root\trelative_path
  # Most recent entries first. Loaded into a map keyed by root.

  @spec recent_files_path() :: String.t()
  defp recent_files_path do
    config_dir = Path.expand("~/.config/minga")
    Path.join(config_dir, @recent_files_file)
  end

  @spec load_recent_files() :: recent_files_map()
  defp load_recent_files do
    path = recent_files_path()

    case File.read(path) do
      {:ok, content} -> parse_recent_files(content)
      {:error, _} -> %{}
    end
  end

  @spec parse_recent_files(String.t()) :: recent_files_map()
  defp parse_recent_files(content) do
    # Build lists with prepend (O(1)), then reverse to restore file order.
    reversed =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "\t", parts: 2) do
          [root, rel_path] ->
            Map.update(acc, root, [rel_path], fn existing -> [rel_path | existing] end)

          _ ->
            acc
        end
      end)

    Map.new(reversed, fn {root, files} -> {root, Enum.reverse(files)} end)
  end

  @spec persist_recent_files(recent_files_map()) :: :ok
  defp persist_recent_files(recent_map) do
    path = recent_files_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    lines =
      Enum.flat_map(recent_map, fn {root, files} ->
        Enum.map(files, fn rel -> "#{root}\t#{rel}" end)
      end)

    content = Enum.join(lines, "\n") <> "\n"
    File.write!(path, content)
    :ok
  rescue
    e ->
      Minga.Log.warning(:editor, "Failed to persist recent files: #{Exception.message(e)}")
      :ok
  end

  @spec frecency_path() :: String.t()
  defp frecency_path do
    config_dir = Path.expand("~/.config/minga")
    Path.join(config_dir, @frecency_file)
  end

  @spec load_frecency_events() :: frecency_events_map()
  defp load_frecency_events do
    path = frecency_path()

    case File.read(path) do
      {:ok, content} -> parse_frecency_events(content)
      {:error, _} -> %{}
    end
  end

  @spec parse_frecency_events(String.t()) :: frecency_events_map()
  defp parse_frecency_events(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_frecency_line(line) do
        {:ok, root, rel_path, timestamp} -> update_frecency_event(acc, root, rel_path, timestamp)
        :error -> acc
      end
    end)
  end

  @spec parse_frecency_line(String.t()) ::
          {:ok, String.t(), String.t(), non_neg_integer()} | :error
  defp parse_frecency_line(line) do
    case String.split(line, "\t", parts: 3) do
      [root, rel_path, ts] -> parse_frecency_timestamp(root, rel_path, ts)
      _ -> :error
    end
  end

  @spec parse_frecency_timestamp(String.t(), String.t(), String.t()) ::
          {:ok, String.t(), String.t(), non_neg_integer()} | :error
  defp parse_frecency_timestamp(root, rel_path, ts) do
    case Integer.parse(ts) do
      {timestamp, ""} when timestamp >= 0 -> {:ok, root, rel_path, timestamp}
      _ -> :error
    end
  end

  @spec update_frecency_event(frecency_events_map(), String.t(), String.t(), non_neg_integer()) ::
          frecency_events_map()
  defp update_frecency_event(events, root, rel_path, timestamp) do
    root_map = Map.get(events, root, %{})

    updated_root_map =
      Map.update(root_map, rel_path, [timestamp], fn timestamps ->
        timestamps
        |> Kernel.++([timestamp])
        |> Enum.take(@frecency_events_per_file_limit)
      end)

    Map.put(events, root, updated_root_map)
  end

  @spec persist_frecency_events(frecency_events_map()) :: :ok
  defp persist_frecency_events(frecency_events) do
    path = frecency_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    content = frecency_lines(frecency_events) |> Enum.join("\n") |> Kernel.<>("\n")
    File.write!(path, content)
    :ok
  rescue
    e ->
      Minga.Log.warning(:editor, "Failed to persist frecency data: #{Exception.message(e)}")
      :ok
  end

  @spec frecency_lines(frecency_events_map()) :: [String.t()]
  defp frecency_lines(frecency_events) do
    Enum.flat_map(frecency_events, fn {root, file_accesses} ->
      file_accesses_to_lines(root, file_accesses)
    end)
  end

  @spec file_accesses_to_lines(String.t(), file_accesses_map()) :: [String.t()]
  defp file_accesses_to_lines(root, file_accesses) do
    Enum.flat_map(file_accesses, fn {rel_path, timestamps} ->
      Enum.map(timestamps, fn ts -> "#{root}\t#{rel_path}\t#{ts}" end)
    end)
  end

  # ── Command frecency persistence ───────────────────────────────────────────

  @spec command_frecency_path() :: String.t()
  defp command_frecency_path do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
    Path.join([config_dir, "minga", @command_frecency_file])
  end

  @spec load_command_frecency() :: command_frecency_map()
  defp load_command_frecency do
    path = command_frecency_path()

    case read_persisted_file(path, "command frecency") do
      {:ok, content} -> parse_command_frecency(content)
      :missing -> %{}
      {:error, _reason} -> %{}
    end
  end

  @spec read_persisted_file(String.t(), String.t()) ::
          {:ok, String.t()} | :missing | {:error, term()}
  defp read_persisted_file(path, label) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        Minga.Log.warning(:editor, "Failed to read #{label} from #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec parse_command_frecency(String.t()) :: command_frecency_map()
  defp parse_command_frecency(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, line_number}, acc ->
      case parse_command_frecency_line(line) do
        {:ok, command_name, timestamp} ->
          update_command_frecency(acc, command_name, timestamp)

        {:error, reason} ->
          Minga.Log.warning(
            :editor,
            "Skipping invalid command frecency line #{line_number}: #{line} (#{reason})"
          )

          acc
      end
    end)
  end

  @spec parse_command_frecency_line(String.t()) ::
          {:ok, atom(), non_neg_integer()} | {:error, atom()}
  defp parse_command_frecency_line(line) do
    case String.split(line, "\t", parts: 2) do
      [command_name, ts] ->
        with {:ok, command_atom} <- parse_command_frecency_command_name(command_name),
             {:ok, timestamp} <- parse_command_frecency_timestamp(ts),
             :ok <- validate_command_frecency_command(command_atom) do
          {:ok, command_atom, timestamp}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  @spec parse_command_frecency_command_name(String.t()) :: {:ok, atom()} | {:error, atom()}
  defp parse_command_frecency_command_name(command_name) do
    {:ok, String.to_existing_atom(command_name)}
  rescue
    ArgumentError -> {:error, :unknown_command_name}
  end

  @spec parse_command_frecency_timestamp(String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  defp parse_command_frecency_timestamp(ts) do
    case Integer.parse(ts) do
      {timestamp, ""} when timestamp >= 0 -> {:ok, timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  @spec validate_command_frecency_command(atom()) :: :ok | {:error, atom()}
  defp validate_command_frecency_command(command_name) do
    case Process.whereis(Minga.Command.Registry) do
      nil ->
        {:error, :command_registry_unavailable}

      _pid ->
        case Command.lookup(command_name) do
          {:ok, _cmd} -> :ok
          :error -> {:error, :stale_command}
        end
    end
  catch
    :exit, _ -> {:error, :command_registry_unavailable}
  end

  @spec update_command_frecency(command_frecency_map(), atom(), non_neg_integer()) ::
          command_frecency_map()
  defp update_command_frecency(events, command_name, timestamp) do
    Map.update(events, command_name, [timestamp], fn timestamps ->
      (timestamps ++ [timestamp]) |> Enum.take(@command_frecency_events_limit)
    end)
  end

  @spec persist_command_frecency(command_frecency_map()) :: :ok
  defp persist_command_frecency(command_frecency) do
    path = command_frecency_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    content = command_frecency_lines(command_frecency) |> Enum.join("\n") |> Kernel.<>("\n")
    File.write!(path, content)
    :ok
  rescue
    e ->
      Minga.Log.warning(
        :editor,
        "Failed to persist command frecency data: #{Exception.message(e)}"
      )

      :ok
  end

  @spec command_frecency_lines(command_frecency_map()) :: [String.t()]
  defp command_frecency_lines(command_frecency) do
    Enum.flat_map(command_frecency, fn {command_name, timestamps} ->
      Enum.map(timestamps, fn ts -> "#{command_name}\t#{ts}" end)
    end)
  end

  @spec bucket_points(integer()) :: non_neg_integer()
  defp bucket_points(age_seconds) when age_seconds <= 4 * 60 * 60, do: 100
  defp bucket_points(age_seconds) when age_seconds <= 24 * 60 * 60, do: 80
  defp bucket_points(age_seconds) when age_seconds <= 7 * 24 * 60 * 60, do: 60
  defp bucket_points(age_seconds) when age_seconds <= 30 * 24 * 60 * 60, do: 40
  defp bucket_points(_age_seconds), do: 20

  # ── Domain delegates ──────────────────────────────────────────────────────

  @doc "Lists all files in the given directory, respecting .gitignore."
  @spec list_files(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defdelegate list_files(root), to: Minga.Project.FileFind

  @doc "Finds alternate files (test <> implementation) for the given file."
  @spec alternate_candidates(String.t(), atom(), String.t()) :: [String.t()]
  defdelegate alternate_candidates(file_path, filetype, project_root),
    to: Minga.Project.AlternateFile,
    as: :candidates

  @doc "Detects the test runner for a project."
  @spec detect_test_runner(atom(), String.t()) ::
          {:ok, Minga.Project.TestRunner.Runner.t()} | :none
  defdelegate detect_test_runner(filetype, project_root),
    to: Minga.Project.TestRunner,
    as: :detect

  @doc "Generates a command to run all tests."
  @spec test_all_command(Minga.Project.TestRunner.Runner.t()) :: String.t()
  defdelegate test_all_command(runner), to: Minga.Project.TestRunner, as: :all_command

  @doc "Generates a command to run tests in a file."
  @spec test_file_command(Minga.Project.TestRunner.Runner.t(), String.t()) :: String.t() | nil
  defdelegate test_file_command(runner, path), to: Minga.Project.TestRunner, as: :file_command

  @doc "Generates a command to run test at cursor position."
  @spec test_at_point_command(Minga.Project.TestRunner.Runner.t(), String.t(), pos_integer()) ::
          String.t() | nil
  defdelegate test_at_point_command(runner, path, line),
    to: Minga.Project.TestRunner,
    as: :at_point_command
end
