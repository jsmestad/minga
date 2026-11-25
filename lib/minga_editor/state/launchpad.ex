defmodule MingaEditor.State.Launchpad do
  @moduledoc """
  State for the project home, `*home*` (#4056): the resting view Minga opens on when there is nothing to restore.

  The home describes where you are. In a project it shows the project's name, path and git state, the files you opened recently in it, Minga's tasks and the next actions. In a folder without project markers it says so in one line and offers the file tree first. Outside any project it lists recent projects.

  Filesystem, git and project data are snapshotted once when the home is entered, so the render builder stays pure and frame builds never touch the filesystem. Minga's tasks are live: callers pass the current task ids to the focus functions, and the builder reads them from the frame.

  This module owns focus movement; activation semantics live in `MingaEditor.Commands.Launchpad` so both frontends behave identically.
  """

  alias Minga.Project.Detector

  @max_rows 9

  @typedoc "Where the home was opened: a marked project, a plain folder used as the root, or no root at all."
  @type place :: :project | :folder | :outside

  @typedoc "Git state for the project header, from the cached repository status."
  @type git :: %{branch: String.t(), changed: non_neg_integer()}

  @type t :: %__MODULE__{
          place: place(),
          root: String.t() | nil,
          git: git() | nil,
          recents: [String.t()],
          projects: [String.t()],
          focused_id: String.t() | nil,
          pending_g?: boolean(),
          waiting: MapSet.t(String.t())
        }

  defstruct place: :outside,
            root: nil,
            git: nil,
            recents: [],
            projects: [],
            focused_id: nil,
            pending_g?: false,
            waiting: MapSet.new()

  @doc """
  Builds the home by snapshotting project, git and recent data.

  Options: `:project_root` (nil outside a project). Tests can override every read: `:place`, `:recents` (paths relative to the root), `:projects` (roots) and `:git`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    root = Keyword.get(opts, :project_root)
    place = Keyword.get_lazy(opts, :place, fn -> place_of(root) end)
    recents = Keyword.get_lazy(opts, :recents, fn -> recents_of(place) end)
    projects = Keyword.get_lazy(opts, :projects, fn -> projects_of(place) end)

    home = %__MODULE__{
      place: place,
      root: root,
      git: Keyword.get_lazy(opts, :git, fn -> git_of(place, root) end),
      recents: Enum.take(recents, @max_rows),
      projects: Enum.take(projects, @max_rows)
    }

    %{home | focused_id: List.first(item_ids(home, []))}
  end

  @doc """
  Ordered focusable item ids: recent files or recent projects, then Minga's tasks, then the next actions.

  In a folder that is not a project the file tree action comes first among the actions, because there is nothing recent to go back to.
  """
  @spec item_ids(t(), [String.t()]) :: [String.t()]
  def item_ids(%__MODULE__{} = home, task_ids) do
    rows(home) ++ task_ids ++ Enum.map(actions(home), &action_id/1)
  end

  @doc "The next actions for this home, as `{command, label}` in display order."
  @spec actions(t()) :: [{atom(), String.t()}]
  def actions(%__MODULE__{place: :project}) do
    [
      {:project_find_file, "Find a file"},
      {:agent_new_session, "New task"},
      {:toggle_file_tree, "File tree"},
      {:project_switch, "Switch project"}
    ]
  end

  def actions(%__MODULE__{place: :folder}) do
    [
      {:toggle_file_tree, "File tree"},
      {:project_find_file, "Find a file"},
      {:project_add, "Remember as a project"},
      {:agent_new_session, "New task"}
    ]
  end

  def actions(%__MODULE__{place: :outside}) do
    [
      {:project_switch, "Switch project"},
      {:find_file, "Find a file"},
      {:project_add, "Add a project"}
    ]
  end

  @doc "The item id for a next action."
  @spec action_id({atom(), String.t()} | atom()) :: String.t()
  def action_id({command, _label}), do: action_id(command)
  def action_id(command) when is_atom(command), do: "action-" <> Atom.to_string(command)

  @doc "The command a next-action id runs, or nil for an id that is not one of this home's actions."
  @spec action_command(t(), String.t()) :: atom() | nil
  def action_command(%__MODULE__{} = home, id) do
    Enum.find_value(actions(home), fn {command, _label} ->
      if action_id(command) == id, do: command
    end)
  end

  @doc "The item id for the recent file at 1-based position `i`."
  @spec recent_id(pos_integer()) :: String.t()
  def recent_id(i) when is_integer(i) and i > 0, do: "recent-#{i}"

  @doc "The item id for the recent project at 1-based position `i`."
  @spec project_id(pos_integer()) :: String.t()
  def project_id(i) when is_integer(i) and i > 0, do: "project-#{i}"

  @doc "The item id for a Minga task, by its workspace id."
  @spec task_id(non_neg_integer()) :: String.t()
  def task_id(workspace_id) when is_integer(workspace_id), do: "task-#{workspace_id}"

  @doc "The item id the number key `n` opens: a recent file in a project or folder, a recent project outside one."
  @spec numbered_id(t(), pos_integer()) :: String.t() | nil
  def numbered_id(%__MODULE__{place: :outside, projects: projects}, n),
    do: if(Enum.at(projects, n - 1), do: project_id(n))

  def numbered_id(%__MODULE__{recents: recents}, n),
    do: if(Enum.at(recents, n - 1), do: recent_id(n))

  @doc "The absolute path of a recent file id, or nil."
  @spec recent_path(t(), String.t()) :: String.t() | nil
  def recent_path(%__MODULE__{recents: recents, root: root}, "recent-" <> idx) do
    with {i, ""} when i > 0 <- Integer.parse(idx),
         path when is_binary(path) <- Enum.at(recents, i - 1) do
      if root, do: Path.expand(path, root), else: path
    else
      _other -> nil
    end
  end

  def recent_path(%__MODULE__{}, _id), do: nil

  @doc "The root of a recent project id, or nil."
  @spec project_root(t(), String.t()) :: String.t() | nil
  def project_root(%__MODULE__{projects: projects}, "project-" <> idx) do
    case Integer.parse(idx) do
      {i, ""} when i > 0 -> Enum.at(projects, i - 1)
      _other -> nil
    end
  end

  def project_root(%__MODULE__{}, _id), do: nil

  @doc "The workspace id of a task item id, or nil."
  @spec task_workspace(String.t()) :: non_neg_integer() | nil
  def task_workspace("task-" <> id) do
    case Integer.parse(id) do
      {i, ""} -> i
      _other -> nil
    end
  end

  def task_workspace(_id), do: nil

  @doc """
  Marks the recent projects with unsaved text waiting in swap files (`Minga.Session.recoverable_projects/1`), so the home says where text can be recovered.

  Roots are compared as canonical paths, the way session files are keyed.
  """
  @spec mark_waiting(t(), [%{root: String.t() | nil, files: pos_integer()}]) :: t()
  def mark_waiting(%__MODULE__{projects: projects} = home, waiting) do
    roots =
      for %{root: root} when is_binary(root) <- waiting, into: MapSet.new(), do: canonical(root)

    %{
      home
      | waiting: projects |> Enum.filter(&MapSet.member?(roots, canonical(&1))) |> MapSet.new()
    }
  end

  @doc "True when a recent project has unsaved text waiting."
  @spec waiting?(t(), String.t()) :: boolean()
  def waiting?(%__MODULE__{waiting: waiting}, root), do: MapSet.member?(waiting, root)

  @spec canonical(String.t()) :: String.t()
  defp canonical(root) do
    case Minga.Project.Root.canonical_path(root) do
      {:ok, path} -> path
      _error -> Path.expand(root)
    end
  end

  @doc """
  Takes a repository's new status for the header, when the home's root is inside that repository.

  `Git.Repo` publishes status on `:git_status_changed`; the home starts without it when the repository was not tracked yet.
  """
  @spec accept_git(t(), Minga.Events.GitStatusEvent.t()) :: t()
  def accept_git(%__MODULE__{root: root} = home, %Minga.Events.GitStatusEvent{} = event)
      when is_binary(root) and is_binary(event.branch) do
    if root == event.git_root or String.starts_with?(root, event.git_root <> "/"),
      do: %{home | git: %{branch: event.branch, changed: length(event.entries)}},
      else: home
  end

  def accept_git(%__MODULE__{} = home, _event), do: home

  @typedoc "A task the home lists: the Agent workspace that shows it, and the task as `MingaEditor.Agent.Tasks` knows it."
  @type task :: {workspace_id :: pos_integer(), MingaEditor.Agent.Tasks.Entry.t()}

  @doc """
  Minga's tasks the home lists, from the shared task model (`MingaEditor.Agent.Tasks.tree/1`) in its order: each top-level task whose session an Agent workspace shows.

  On a project's home, only that project's tasks (and tasks of workspaces tied to no project); outside a project, every task. A task no workspace shows cannot be opened from the home, so it is left out.
  """
  @spec tasks(MingaEditor.Agent.Tasks.t(), MingaEditor.State.TabBar.t() | nil, t()) :: [task()]
  def tasks(_tasks, nil, _home), do: []

  def tasks(
        %MingaEditor.Agent.Tasks{} = tasks,
        %MingaEditor.State.TabBar{} = tab_bar,
        %__MODULE__{root: root}
      ) do
    for %{item: %MingaEditor.Agent.Tasks.Entry{pid: pid} = entry, depth: 0} <-
          MingaEditor.Agent.Tasks.tree(tasks),
        %{id: id, project_root: task_root} <- [
          MingaEditor.State.TabBar.find_workspace_by_session(tab_bar, pid)
        ],
        in_project?(task_root, root),
        do: {id, entry}
  end

  @spec in_project?(String.t() | nil, String.t() | nil) :: boolean()
  defp in_project?(nil, _root), do: true
  defp in_project?(_task_root, nil), do: true
  defp in_project?(task_root, root), do: Path.expand(task_root) == Path.expand(root)

  @doc "The item ids of the tasks the home lists, for the focus functions."
  @spec task_ids(MingaEditor.Agent.Tasks.t(), MingaEditor.State.TabBar.t() | nil, t()) :: [
          String.t()
        ]
  def task_ids(tasks, tab_bar, home),
    do: tasks |> tasks(tab_bar, home) |> Enum.map(fn {id, _entry} -> task_id(id) end)

  @doc "Moves focus by one step or to an edge, over the rows and the current tasks."
  @spec move_focus(t(), :next | :prev | :first | :last, [String.t()]) :: t()
  def move_focus(%__MODULE__{} = home, direction, task_ids) do
    ids = item_ids(home, task_ids)
    current = Enum.find_index(ids, &(&1 == home.focused_id)) || 0

    target =
      case direction do
        :next -> min(current + 1, length(ids) - 1)
        :prev -> max(current - 1, 0)
        :first -> 0
        :last -> length(ids) - 1
      end

    %{home | focused_id: Enum.at(ids, target)}
  end

  @doc "Sets focus to a specific item id when it exists."
  @spec focus(t(), String.t(), [String.t()]) :: t()
  def focus(%__MODULE__{} = home, id, task_ids) do
    if id in item_ids(home, task_ids), do: %{home | focused_id: id}, else: home
  end

  @doc """
  Handles a `g` keypress for the `gg` go-to-first chord.

  The first `g` arms the pending state; the second moves focus to the first item. Any other key must call `clear_pending_g/1`.
  """
  @spec press_g(t(), [String.t()]) :: t()
  def press_g(%__MODULE__{pending_g?: true} = home, task_ids) do
    %{move_focus(home, :first, task_ids) | pending_g?: false}
  end

  def press_g(%__MODULE__{} = home, _task_ids), do: %{home | pending_g?: true}

  @doc "Disarms a pending `gg` chord."
  @spec clear_pending_g(t()) :: t()
  def clear_pending_g(%__MODULE__{} = home), do: %{home | pending_g?: false}

  @spec rows(t()) :: [String.t()]
  defp rows(%__MODULE__{place: :outside, projects: projects}),
    do: projects |> Enum.with_index(1) |> Enum.map(fn {_root, i} -> project_id(i) end)

  defp rows(%__MODULE__{recents: recents}),
    do: recents |> Enum.with_index(1) |> Enum.map(fn {_path, i} -> recent_id(i) end)

  # A root with a project marker (`.git`, `mix.exs` and the others) is a project.
  # Any other directory is a folder Minga uses as the root for now.
  @spec place_of(String.t() | nil) :: place()
  defp place_of(nil), do: :outside

  defp place_of(root) do
    case Detector.detect(Path.join(root, "*home*")) do
      {:ok, ^root, _type} -> :project
      _other -> :folder
    end
  end

  @spec git_of(place(), String.t() | nil) :: git() | nil
  defp git_of(:outside, _root), do: nil

  defp git_of(_place, root) do
    case Minga.Git.Repo.cached_status_for_path(root) do
      {:ok, %{branch: branch, entries: entries}} when is_binary(branch) ->
        %{branch: branch, changed: length(entries)}

      _other ->
        nil
    end
  end

  @spec recents_of(place()) :: [String.t()]
  defp recents_of(:outside), do: []

  defp recents_of(_place) do
    Minga.Project.recent_files()
  catch
    :exit, _ -> []
  end

  @spec projects_of(place()) :: [String.t()]
  defp projects_of(:outside) do
    Minga.Project.known_projects()
  catch
    :exit, _ -> []
  end

  defp projects_of(_place), do: []
end
