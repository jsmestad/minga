defmodule Minga.ProjectTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot

  @moduletag :tmp_dir

  # Start a private Project GenServer for each test to avoid global state.
  defp start_project!(opts \\ []) do
    name = :"project_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:subscribe, false)
      |> Keyword.put_new(:command_frecency, %{})
      |> Project.start_link()

    {pid, name}
  end

  # Waits for any pending cast to be processed by the GenServer.
  # :sys.get_state is a synchronous call that sits behind any queued
  # casts in the GenServer mailbox, so when it returns we know all
  # prior casts have been handled.
  defp flush(name), do: :sys.get_state(name)

  # Waits for the async rebuild Task to complete.
  # Subscribes to :project_rebuilt and uses assert_receive if the
  # GenServer is still rebuilding. Pins root to avoid consuming
  # events from concurrent tests (async: true).
  defp await_rebuild(name) do
    Minga.Events.subscribe(:project_rebuilt)

    if Project.rebuilding?(name) do
      root = Project.root(name)

      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    _ = :sys.get_state(name)
  end

  describe "resolve_root/0" do
    test "returns nil from a fresh project server with no root set" do
      {_pid, name} = start_project!()
      assert Project.root(name) == nil
    end
  end

  describe "buffer-open isolation" do
    test "opening loose files never promotes marker ancestors", %{tmp_dir: tmp} do
      fake_home = Path.join(tmp, "home")
      File.mkdir_p!(fake_home)

      {_pid, name} = start_project!()

      for marker <- ["package.json", ".git", "mix.exs", ".minga"] do
        ancestor = Path.join(fake_home, String.replace(marker, ".", "_"))
        File.mkdir_p!(ancestor)
        write_marker(ancestor, marker)
        file = Path.join(ancestor, "notes.org")
        File.write!(file, "notes")

        send(
          name,
          {:minga_event, :buffer_opened, %Minga.Events.BufferEvent{buffer: self(), path: file}}
        )

        state = flush(name)

        assert Project.root(name) == nil
        assert Project.workspace_root(name) == nil
        assert Project.snapshot(name) == nil
        assert Project.known_projects(name) == []
        assert state.workspace == nil
      end
    end
  end

  describe "activate/2 and snapshot/1" do
    test "activation synchronously returns the installed typed workspace while discovery runs", %{
      tmp_dir: tmp
    } do
      project = Path.join(tmp, "immediate_activation")
      File.mkdir_p!(project)
      {:ok, root} = Root.directory(project)
      {_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)

      assert {:ok, %WorkspaceSnapshot{root: ^root, files: [], rebuilding?: true} = installed} =
               Project.activate(name, root)

      assert Project.snapshot(name) == installed
      assert Project.root(name) == project
      assert Project.workspace_root(name) == root
    end

    test "completion atomically installs relative files and the matching rebuild status", %{
      tmp_dir: tmp
    } do
      project = Path.join(tmp, "atomic_completion")
      File.mkdir_p!(project)
      {:ok, root} = Root.directory(project)
      {_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)
      Minga.Events.subscribe(:project_rebuilt)

      assert {:ok, %WorkspaceSnapshot{rebuilding?: true} = activated} =
               Project.activate(name, root)

      activation_id = activated.activation_id
      worker = flush(name).rebuild_pid
      worker_ref = Process.monitor(worker)

      :ok = Minga.Project.SlowFileFind.complete(worker, {:ok, ["lib/app.ex", "README.md"]})

      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^project}},
                     1_000

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000

      assert %WorkspaceSnapshot{
               root: ^root,
               activation_id: ^activation_id,
               files: ["lib/app.ex", "README.md"],
               rebuilding?: false
             } = Project.snapshot(name)
    end

    test "rapid rerooting cannot install a superseded worker result", %{tmp_dir: tmp} do
      first = Path.join(tmp, "snapshot_first")
      second = Path.join(tmp, "snapshot_second")
      File.mkdir_p!(first)
      File.mkdir_p!(second)
      {:ok, first_root} = Root.directory(first)
      {:ok, second_root} = Root.directory(second)
      {_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)

      assert {:ok, %WorkspaceSnapshot{root: ^first_root, rebuilding?: true}} =
               Project.activate(name, first_root)

      first_worker = flush(name).rebuild_pid
      first_ref = Process.monitor(first_worker)

      assert {:ok, %WorkspaceSnapshot{root: ^second_root, files: [], rebuilding?: true}} =
               Project.activate(name, second_root)

      second_worker = flush(name).rebuild_pid
      assert_receive {:DOWN, ^first_ref, :process, ^first_worker, :normal}, 1_000

      send(name, {:file_find_done, first_worker, {:ok, ["stale-first.txt"]}})
      _ = flush(name)

      assert %WorkspaceSnapshot{root: ^second_root, files: [], rebuilding?: true} =
               Project.snapshot(name)

      Minga.Events.subscribe(:project_rebuilt)
      :ok = Minga.Project.SlowFileFind.complete(second_worker, {:ok, ["second.txt"]})

      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^second}},
                     1_000

      assert %WorkspaceSnapshot{root: ^second_root, files: ["second.txt"], rebuilding?: false} =
               Project.snapshot(name)
    end

    test "rejects a non-directory typed root without replacing the workspace", %{tmp_dir: tmp} do
      project = Path.join(tmp, "directory")
      file = Path.join(tmp, "loose.txt")
      File.mkdir_p!(project)
      File.write!(file, "loose")
      {:ok, root} = Root.directory(project)
      {_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)

      assert {:ok, installed} = Project.activate(name, root)
      assert {:error, :not_a_directory_root} = Project.activate(name, Root.file(file))

      unconfirmed_home = %Root{kind: :directory, path: Path.expand("~")}

      assert {:error, :broad_root_confirmation_required} =
               Project.activate(name, unconfirmed_home)

      assert Project.snapshot(name) == installed
    end
  end

  describe "files/1" do
    test "returns cached file list after explicit folder activation", %{tmp_dir: tmp} do
      project = Path.join(tmp, "files_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "README.md"), "hello")
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "lib/app.ex"), "")
      init_git_repo!(project)

      {_pid, name} = start_project!()
      Project.switch(name, project)
      await_rebuild(name)

      files = Project.files(name)
      assert is_list(files)
      assert "README.md" in files or "lib/app.ex" in files
    end

    test "returns empty list when no project is set" do
      {_pid, name} = start_project!()
      assert Project.files(name) == []
    end
  end

  describe "switch/2" do
    test "switches to a different project root", %{tmp_dir: tmp} do
      project_a = Path.join(tmp, "project_a")
      project_b = Path.join(tmp, "project_b")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      File.write!(Path.join(project_a, "mix.exs"), "")
      File.write!(Path.join(project_b, "Cargo.toml"), "")

      {_pid, name} = start_project!()
      Project.switch(name, project_a)
      flush(name)
      assert Project.root(name) == project_a

      Project.switch(name, project_b)
      flush(name)
      assert Project.root(name) == project_b
      assert %Root{kind: :directory, path: ^project_b} = Project.workspace_root(name)
    end

    test "rejects broad roots without explicit confirmation" do
      {_pid, name} = start_project!()

      Project.switch(name, Path.expand("~"))
      state = flush(name)

      assert Project.root(name) == nil
      assert Project.workspace_root(name) == nil
      assert state.workspace == nil
    end

    test "adds switched project to known projects", %{tmp_dir: tmp} do
      project = Path.join(tmp, "switch_known")
      File.mkdir_p!(project)

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      assert project in Project.known_projects(name)
    end

    test "does not add test fixture tmp projects to known projects", %{tmp_dir: tmp} do
      project =
        Path.join([
          tmp,
          "tmp",
          "MingaEditor.UI.Picker.FileSourceTest",
          "test-files-opened",
          "frecency_picker_project_123"
        ])

      File.mkdir_p!(project)

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      assert Project.root(name) == project
      refute project in Project.known_projects(name)
    end
  end

  describe "discovery lifecycle" do
    test "switching roots and closing the workspace cancel in-flight discovery", %{tmp_dir: tmp} do
      first = Path.join(tmp, "first")
      second = Path.join(tmp, "second")
      File.mkdir_p!(first)
      File.mkdir_p!(second)
      {_project_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)

      Project.switch(name, first)
      first_worker = flush(name).rebuild_pid
      first_ref = Process.monitor(first_worker)

      Project.switch(name, second)
      second_worker = flush(name).rebuild_pid
      second_ref = Process.monitor(second_worker)

      assert_receive {:DOWN, ^first_ref, :process, ^first_worker, :normal}, 1_000
      assert first_worker != second_worker

      Project.close(name)
      state = flush(name)

      assert_receive {:DOWN, ^second_ref, :process, ^second_worker, :normal}, 1_000
      assert state.workspace == nil
      assert Project.snapshot(name) == nil
    end

    test "discovery timeout cancels the worker", %{tmp_dir: tmp} do
      root = Path.join(tmp, "timeout")
      File.mkdir_p!(root)

      {_project_pid, name} =
        start_project!(file_find_module: Minga.Project.SlowFileFind, rebuild_timeout_ms: 10)

      Project.switch(name, root)
      worker = flush(name).rebuild_pid
      ref = Process.monitor(worker)

      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
      state = flush(name)
      assert %WorkspaceSnapshot{root: %Root{path: ^root}, rebuilding?: false} = state.workspace
      assert state.rebuild_pid == nil
    end

    test "project shutdown cancels the worker", %{tmp_dir: tmp} do
      root = Path.join(tmp, "shutdown")
      File.mkdir_p!(root)
      {project_pid, name} = start_project!(file_find_module: Minga.Project.SlowFileFind)

      Project.switch(name, root)
      worker = flush(name).rebuild_pid
      ref = Process.monitor(worker)

      GenServer.stop(project_pid)

      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    end
  end

  describe "invalidate/1" do
    test "clears cache and triggers rebuild", %{tmp_dir: tmp} do
      project = Path.join(tmp, "invalidate_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "file.ex"), "")
      init_git_repo!(project)

      {_pid, name} = start_project!()
      Project.switch(name, project)
      await_rebuild(name)

      # Should have files
      assert Project.files(name) != []

      # Invalidate
      Project.invalidate(name)
      await_rebuild(name)

      # Should have files again after rebuild
      assert Project.files(name) != []
    end
  end

  describe "add/2 and remove/2" do
    test "manually adds and removes known projects", %{tmp_dir: tmp} do
      project = Path.join(tmp, "manual_add")
      File.mkdir_p!(project)

      {_pid, name} = start_project!()
      Project.add(name, project)
      flush(name)

      assert project in Project.known_projects(name)

      Project.remove(name, project)
      flush(name)

      refute project in Project.known_projects(name)
    end

    test "add ignores non-existent directories", %{tmp_dir: tmp} do
      bogus = Path.join(tmp, "does_not_exist")

      {_pid, name} = start_project!()
      Project.add(name, bogus)
      flush(name)

      refute bogus in Project.known_projects(name)
    end

    test "add ignores test fixture tmp projects", %{tmp_dir: tmp} do
      project =
        Path.join([
          tmp,
          "tmp",
          "MingaEditor.DropOpenDirectoryTest",
          "test-dropping-a-directory",
          "project"
        ])

      File.mkdir_p!(project)

      {_pid, name} = start_project!()
      Project.add(name, project)
      flush(name)

      refute project in Project.known_projects(name)
    end
  end

  describe "record_file/2 and recent_files/1" do
    test "records a file and returns it in recent files list", %{tmp_dir: tmp} do
      project = Path.join(tmp, "recent_test")
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "lib/app.ex"), "")

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      Project.record_file(name, Path.join(project, "lib/app.ex"))
      flush(name)

      recent = Project.recent_files(name)
      assert "lib/app.ex" in recent
    end

    test "root-scoped recording updates captured project history without switching workspaces", %{
      tmp_dir: tmp
    } do
      project_a = Path.join(tmp, "captured_project")
      project_b = Path.join(tmp, "active_project")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      File.write!(Path.join(project_a, "captured.ex"), "")
      {:ok, root_a} = Root.directory(project_a)

      {_pid, name} = start_project!()
      Project.switch(name, project_b)
      flush(name)

      Project.record_file_for_root(name, root_a, "captured.ex")
      flush(name)

      assert %WorkspaceSnapshot{root: %Root{path: ^project_b}} = Project.snapshot(name)
      assert Project.recent_files(name) == []
      assert Project.frecency_scores(name) == %{}

      Project.switch(name, project_a)
      flush(name)

      assert Project.recent_files(name) == ["captured.ex"]
      assert Project.frecency_scores(name)["captured.ex"] > 0
    end

    test "most recently opened file appears first", %{tmp_dir: tmp} do
      project = Path.join(tmp, "recent_order")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(lib, "a.ex"), "")
      File.write!(Path.join(lib, "b.ex"), "")
      File.write!(Path.join(lib, "c.ex"), "")

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      Project.record_file(name, Path.join(lib, "a.ex"))
      flush(name)
      Project.record_file(name, Path.join(lib, "b.ex"))
      flush(name)
      Project.record_file(name, Path.join(lib, "c.ex"))
      flush(name)

      recent = Project.recent_files(name)
      assert recent == ["lib/c.ex", "lib/b.ex", "lib/a.ex"]
    end

    test "reopening a file moves it to the front", %{tmp_dir: tmp} do
      project = Path.join(tmp, "recent_dedup")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(lib, "a.ex"), "")
      File.write!(Path.join(lib, "b.ex"), "")

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      Project.record_file(name, Path.join(lib, "a.ex"))
      flush(name)
      Project.record_file(name, Path.join(lib, "b.ex"))
      flush(name)

      assert Project.recent_files(name) == ["lib/b.ex", "lib/a.ex"]

      # Reopen a.ex — should move to front
      Project.record_file(name, Path.join(lib, "a.ex"))
      flush(name)

      assert Project.recent_files(name) == ["lib/a.ex", "lib/b.ex"]
    end

    test "ignores files outside the current project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "recent_outside")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")

      outside_file = Path.join(tmp, "outside.txt")
      File.write!(outside_file, "")

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      Project.record_file(name, outside_file)
      flush(name)

      assert Project.recent_files(name) == []
    end

    test "returns empty list when no project is set" do
      {_pid, name} = start_project!()
      assert Project.recent_files(name) == []
    end

    test "no-op when no project root is set" do
      {_pid, name} = start_project!()

      Project.record_file(name, "/some/random/file.ex")
      flush(name)

      assert Project.recent_files(name) == []
    end

    test "recent files are scoped per project", %{tmp_dir: tmp} do
      project_a = Path.join(tmp, "proj_a")
      project_b = Path.join(tmp, "proj_b")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      File.write!(Path.join(project_a, "mix.exs"), "")
      File.write!(Path.join(project_b, "mix.exs"), "")
      File.write!(Path.join(project_a, "a.ex"), "")
      File.write!(Path.join(project_b, "b.ex"), "")

      {_pid, name} = start_project!()

      # Record file in project A
      Project.switch(name, project_a)
      flush(name)
      Project.record_file(name, Path.join(project_a, "a.ex"))
      flush(name)

      assert Project.recent_files(name) == ["a.ex"]

      # Switch to project B and record a different file
      Project.switch(name, project_b)
      flush(name)
      Project.record_file(name, Path.join(project_b, "b.ex"))
      flush(name)

      assert Project.recent_files(name) == ["b.ex"]

      # Switch back to A — should see A's recent files
      Project.switch(name, project_a)
      flush(name)

      assert Project.recent_files(name) == ["a.ex"]
    end
  end

  describe "command frecency" do
    test "record_command/2 scores repeated command executions higher" do
      {_pid, name} = start_project!()

      Enum.each(1..3, fn _ ->
        Project.record_command(name, :save)
        flush(name)
      end)

      Project.record_command(name, :quit)
      flush(name)

      scores = Project.command_frecency_scores(name)
      assert scores.save > scores.quit
    end

    test "record_command/2 keeps the newest command events within the limit" do
      {_pid, name} = start_project!()

      Enum.each(1..25, fn _ ->
        Project.record_command(name, :save)
        flush(name)
      end)

      state = flush(name)
      assert Enum.count(state.command_frecency.save) == 20
    end
  end

  describe "frecency" do
    test "score_accesses/2 applies Mozilla-style decay buckets" do
      now = 1_700_000_000

      timestamps = [
        now - 60,
        now - 8 * 60 * 60,
        now - 2 * 24 * 60 * 60,
        now - 10 * 24 * 60 * 60,
        now - 90 * 24 * 60 * 60
      ]

      assert Project.score_accesses(timestamps, now) == 100 + 80 + 60 + 40 + 20
    end

    test "score_accesses/2 is monotonic when adding another same-time access" do
      check all(n <- StreamData.integer(0..20)) do
        now = 1_700_000_000
        timestamps = List.duplicate(now - 60, n)
        with_extra = [now - 60 | timestamps]

        assert Project.score_accesses(with_extra, now) >= Project.score_accesses(timestamps, now)
      end
    end

    test "more opens produce a higher frecency score", %{tmp_dir: tmp} do
      project = Path.join(tmp, "frecency_project")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(lib, "hot.ex"), "")
      File.write!(Path.join(lib, "cold.ex"), "")

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      Enum.each(1..5, fn _ ->
        Project.record_file(name, Path.join(lib, "hot.ex"))
        flush(name)
      end)

      Project.record_file(name, Path.join(lib, "cold.ex"))
      flush(name)

      scores = Project.frecency_scores(name)
      assert scores["lib/hot.ex"] > scores["lib/cold.ex"]
    end
  end

  @spec write_marker(String.t(), String.t()) :: :ok
  defp write_marker(ancestor, marker) when marker in [".git", ".minga"] do
    File.mkdir_p!(Path.join(ancestor, marker))
  end

  defp write_marker(ancestor, marker) do
    File.write!(Path.join(ancestor, marker), "")
  end

  # Makes a fixture directory a self-contained git repo so file discovery uses
  # the git-first path. Without an inner `.git`, git would resolve to the outer
  # minga repo, where the test's `tmp/` fixtures are gitignored and list empty.
  defp init_git_repo!(dir) do
    {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    :ok
  end
end
