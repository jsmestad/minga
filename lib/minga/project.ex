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
  * `rebuilding?` — true while a background Task is rebuilding the file cache

  ## File cache

  The cached file list lives in GenServer state (not ETS). Only one consumer
  (the picker, running inside the Editor process) reads it at a time, so a
  GenServer is simpler and sufficient. Cache rebuilds run in a supervised
  `Task` to keep the GenServer responsive during the shell-out to `fd` or
  `git ls-files`.
  """

  use GenServer

  alias Minga.Project.Detector

  require Logger

  @enforce_keys []
  defstruct current_root: nil,
            project_type: nil,
            cached_files: [],
            known_projects: [],
            rebuilding?: false,
            rebuild_ref: nil

  @typedoc "Project GenServer state."
  @type t :: %__MODULE__{
          current_root: String.t() | nil,
          project_type: Detector.project_type() | nil,
          cached_files: [String.t()],
          known_projects: [String.t()],
          rebuilding?: boolean(),
          rebuild_ref: reference() | nil
        }

  @known_projects_file "known-projects"

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

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(_opts) do
    known = load_known_projects()
    {:ok, %__MODULE__{known_projects: known}}
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

  @impl true
  @spec handle_cast(term(), t()) :: {:noreply, t()}
  def handle_cast({:detect_and_set, file_path}, state) do
    case Detector.detect(file_path) do
      {:ok, root, type} ->
        if root == state.current_root do
          {:noreply, state}
        else
          state =
            state
            |> set_project(root, type)
            |> add_to_known(root)
            |> start_rebuild()

          {:noreply, state}
        end

      :none ->
        {:noreply, state}
    end
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
      Logger.warning("Project.switch: directory not found: #{expanded}")
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
      Logger.warning("Project.add: directory not found: #{expanded}")
      {:noreply, state}
    end
  end

  def handle_cast({:remove, root_path}, state) do
    expanded = Path.expand(root_path)
    new_known = Enum.reject(state.known_projects, &(&1 == expanded))
    persist_known_projects(new_known)
    {:noreply, %{state | known_projects: new_known}}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({ref, {:rebuild_done, root, files}}, %{rebuild_ref: ref} = state)
      when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    if root == state.current_root do
      {:noreply, %{state | cached_files: files, rebuilding?: false, rebuild_ref: nil}}
    else
      # Root changed while rebuild was in progress; discard stale result
      {:noreply, %{state | rebuilding?: false, rebuild_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rebuild_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("Project file cache rebuild failed: #{inspect(reason)}")
    end

    {:noreply, %{state | rebuilding?: false, rebuild_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

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
      persist_known_projects(new_known)
      %{state | known_projects: new_known}
    end
  end

  @spec start_rebuild(t()) :: t()
  defp start_rebuild(%{current_root: nil} = state), do: state

  defp start_rebuild(state) do
    root = state.current_root

    task =
      Task.async(fn ->
        case Minga.FileFind.list_files(root) do
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
      Logger.warning("Failed to persist known projects: #{Exception.message(e)}")
      :ok
  end
end
