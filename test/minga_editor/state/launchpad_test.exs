defmodule MingaEditor.State.LaunchpadTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Launchpad

  @moduletag :tmp_dir

  defp home(opts) do
    defaults = [project_root: "/work/minga", place: :project, git: nil, recents: [], projects: []]
    Launchpad.new(Keyword.merge(defaults, opts))
  end

  describe "item_ids/2" do
    test "recent files, then Minga's tasks, then the next actions" do
      lp = home(recents: ["a.ex", "b.ex"])

      assert Launchpad.item_ids(lp, ["task-7"]) == [
               "recent-1",
               "recent-2",
               "task-7",
               "action-project_find_file",
               "action-agent_new_session",
               "action-toggle_file_tree",
               "action-project_switch"
             ]
    end

    test "outside a project the rows are recent projects" do
      lp = home(project_root: nil, place: :outside, projects: ["/a", "/b"])

      assert Launchpad.item_ids(lp, []) == [
               "project-1",
               "project-2",
               "action-project_switch",
               "action-find_file",
               "action-project_add"
             ]
    end

    test "a folder that is not a project offers the file tree first" do
      lp = home(project_root: "/tmp/notes", place: :folder)
      assert lp.focused_id == "action-toggle_file_tree"
    end
  end

  describe "number keys" do
    test "open recent files in a project and recent projects outside one" do
      assert Launchpad.numbered_id(home(recents: ["a.ex"]), 1) == "recent-1"
      assert Launchpad.numbered_id(home(recents: ["a.ex"]), 2) == nil

      outside = home(project_root: nil, place: :outside, projects: ["/a"])
      assert Launchpad.numbered_id(outside, 1) == "project-1"
    end

    test "resolve recent files against the root and projects to their root" do
      lp = home(recents: ["lib/a.ex"])
      assert Launchpad.recent_path(lp, "recent-1") == "/work/minga/lib/a.ex"
      assert Launchpad.recent_path(lp, "recent-9") == nil

      outside = home(project_root: nil, place: :outside, projects: ["/a"])
      assert Launchpad.project_root(outside, "project-1") == "/a"
    end
  end

  describe "move_focus/3" do
    test "moves over rows and tasks and clamps at the edges" do
      lp = home(recents: ["a.ex"])
      assert lp.focused_id == "recent-1"

      assert Launchpad.move_focus(lp, :prev, []).focused_id == "recent-1"
      assert Launchpad.move_focus(lp, :next, ["task-3"]).focused_id == "task-3"
      assert Launchpad.move_focus(lp, :last, []).focused_id == "action-project_switch"
    end

    test "gg goes to the first row" do
      lp = home(recents: ["a.ex"]) |> Launchpad.move_focus(:last, [])
      lp = lp |> Launchpad.press_g([]) |> Launchpad.press_g([])

      assert lp.focused_id == "recent-1"
      refute lp.pending_g?
    end
  end

  describe "new/1 reads the root" do
    test "a root with a project marker is a project, any other directory a folder", %{
      tmp_dir: dir
    } do
      project = Path.join(dir, "project")
      folder = Path.join(dir, "folder")
      File.mkdir_p!(project)
      File.mkdir_p!(folder)
      File.write!(Path.join(project, "mix.exs"), "")

      assert Launchpad.new(project_root: project, recents: [], git: nil).place == :project
      assert Launchpad.new(project_root: folder, recents: [], git: nil).place == :folder
      assert Launchpad.new(project_root: nil, projects: []).place == :outside
    end
  end

  describe "tasks/3" do
    alias MingaEditor.Agent.Tasks
    alias MingaEditor.State.TabBar
    alias MingaEditor.State.Workspace

    # One followed task per {workspace id, project root}, each shown by its own Agent workspace.
    defp followed(specs) do
      pids = Enum.map(specs, fn _spec -> spawn(fn -> :ok end) end)

      workspaces =
        specs
        |> Enum.zip(pids)
        |> Enum.map(fn {{id, root}, pid} -> Workspace.new_agent(id, "Task #{id}", pid, root) end)

      tasks =
        pids
        |> Enum.with_index()
        |> Enum.reduce(Tasks.new(), fn {pid, i}, acc ->
          Tasks.follow(acc, pid, i, title: "Goal #{i}")
        end)

      {tasks, TabBar.restore_workspaces(TabBar.new_empty(nil), workspaces, nil)}
    end

    defp listed(tasks, tab_bar, home),
      do: tasks |> Launchpad.tasks(tab_bar, home) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    test "a project's home lists that project's tasks and tasks tied to no project" do
      {tasks, tab_bar} = followed([{1, "/work/minga"}, {2, "/work/other"}, {3, nil}])

      assert listed(tasks, tab_bar, home([])) == [1, 3]
    end

    test "outside a project every task is listed" do
      {tasks, tab_bar} = followed([{1, "/work/minga"}, {2, "/work/other"}])

      assert listed(tasks, tab_bar, home(project_root: nil, place: :outside)) == [1, 2]
    end

    test "a conversation that was opened and never prompted is not listed" do
      pid = spawn(fn -> :ok end)
      workspace = Workspace.new_agent(1, "Agent", pid, "/work/minga")
      tab_bar = TabBar.restore_workspaces(TabBar.new_empty(nil), [workspace], nil)

      # Following a session with no title, turn, work or request leaves no goal to show.
      tasks = Tasks.follow(Tasks.new(), pid, 0, [])

      assert listed(tasks, tab_bar, home([])) == []
    end

    test "a task no workspace shows is not listed" do
      {tasks, _tab_bar} = followed([{1, "/work/minga"}])

      assert listed(tasks, TabBar.new_empty(nil), home([])) == []
    end
  end

  describe "mark_waiting/2" do
    test "marks the recent projects with unsaved text waiting, comparing canonical roots", %{
      tmp_dir: dir
    } do
      waiting = Path.join(dir, "waiting")
      clean = Path.join(dir, "clean")
      File.mkdir_p!(waiting)
      File.mkdir_p!(clean)
      outside = home(project_root: nil, place: :outside, projects: [waiting, clean])

      marked =
        Launchpad.mark_waiting(outside, [
          %{root: waiting <> "/", files: 2},
          %{root: nil, files: 1}
        ])

      assert Launchpad.waiting?(marked, waiting)
      refute Launchpad.waiting?(marked, clean)
    end
  end

  describe "accept_git/2" do
    test "takes the branch and change count of the repository the root is in" do
      event = %Minga.Events.GitStatusEvent{
        git_root: "/work/minga",
        entries: [:a, :b],
        branch: "main",
        ahead: 0,
        behind: 0
      }

      assert Launchpad.accept_git(home([]), event).git == %{branch: "main", changed: 2}

      other = %{event | git_root: "/work/other"}
      assert Launchpad.accept_git(home([]), other).git == nil
    end
  end
end
