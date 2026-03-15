defmodule Minga.ProjectTest do
  use ExUnit.Case, async: true

  alias Minga.Project

  @moduletag :tmp_dir

  # Start a private Project GenServer for each test to avoid global state.
  defp start_project!(opts \\ []) do
    name = :"project_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:subscribe, false)
      |> Project.start_link()

    {pid, name}
  end

  # Waits for any pending cast to be processed by the GenServer.
  # :sys.get_state is a synchronous call that sits behind any queued
  # casts in the GenServer mailbox, so when it returns we know all
  # prior casts have been handled.
  defp flush(name), do: :sys.get_state(name)

  # Polls until the async rebuild Task completes and files are cached.
  # The rebuild is a Task.async that sends its result back to the
  # GenServer via handle_info.
  defp await_rebuild(name, max_attempts \\ 50) do
    state = :sys.get_state(name)

    if state.rebuilding? and max_attempts > 0 do
      Process.sleep(10)
      await_rebuild(name, max_attempts - 1)
    else
      state
    end
  end

  describe "detect_and_set/2" do
    test "detects project root from a file inside a git repo", %{tmp_dir: tmp} do
      project = Path.join(tmp, "myproject")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.mkdir_p!(Path.join(project, ".git"))
      File.write!(Path.join(lib, "app.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(lib, "app.ex"))
      flush(name)

      assert Project.root(name) == project
    end

    test "detects mix project root", %{tmp_dir: tmp} do
      project = Path.join(tmp, "mix_app")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(lib, "foo.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(lib, "foo.ex"))
      flush(name)

      assert Project.root(name) == project
    end

    test "adds detected project to known projects", %{tmp_dir: tmp} do
      project = Path.join(tmp, "known_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "package.json"), "")
      File.write!(Path.join(project, "index.js"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(project, "index.js"))
      flush(name)

      known = Project.known_projects(name)
      assert project in known
    end

    test "does not change root when detection finds the same project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "same_root")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "a.ex"), "")
      File.write!(Path.join(project, "b.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(project, "a.ex"))
      flush(name)
      assert Project.root(name) == project

      # Detecting from another file in the same project should not change root
      Project.detect_and_set(name, Path.join(project, "b.ex"))
      flush(name)
      assert Project.root(name) == project
    end

    test "does not duplicate known projects on repeated detection", %{tmp_dir: tmp} do
      project = Path.join(tmp, "dedup_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "go.mod"), "")
      File.write!(Path.join(project, "main.go"), "")

      {_pid, name} = start_project!()
      file = Path.join(project, "main.go")
      Project.detect_and_set(name, file)
      flush(name)
      Project.detect_and_set(name, file)
      flush(name)

      known = Project.known_projects(name)
      count = Enum.count(known, &(&1 == project))
      assert count == 1
    end
  end

  describe "files/1" do
    test "returns cached file list after detection", %{tmp_dir: tmp} do
      project = Path.join(tmp, "files_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "README.md"), "hello")
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "lib/app.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(project, "lib/app.ex"))
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
      Project.detect_and_set(name, Path.join(project_a, "mix.exs"))
      flush(name)
      assert Project.root(name) == project_a

      Project.switch(name, project_b)
      flush(name)
      assert Project.root(name) == project_b
    end

    test "adds switched project to known projects", %{tmp_dir: tmp} do
      project = Path.join(tmp, "switch_known")
      File.mkdir_p!(project)

      {_pid, name} = start_project!()
      Project.switch(name, project)
      flush(name)

      assert project in Project.known_projects(name)
    end
  end

  describe "invalidate/1" do
    test "clears cache and triggers rebuild", %{tmp_dir: tmp} do
      project = Path.join(tmp, "invalidate_test")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "file.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(project, "file.ex"))
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
  end

  describe "record_file/2 and recent_files/1" do
    test "records a file and returns it in recent files list", %{tmp_dir: tmp} do
      project = Path.join(tmp, "recent_test")
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "lib/app.ex"), "")

      {_pid, name} = start_project!()
      Project.detect_and_set(name, Path.join(project, "lib/app.ex"))
      flush(name)

      Project.record_file(name, Path.join(project, "lib/app.ex"))
      flush(name)

      recent = Project.recent_files(name)
      assert "lib/app.ex" in recent
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
      Project.detect_and_set(name, Path.join(lib, "a.ex"))
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
      Project.detect_and_set(name, Path.join(lib, "a.ex"))
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
      Project.detect_and_set(name, Path.join(project, "mix.exs"))
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
      Project.detect_and_set(name, Path.join(project_a, "a.ex"))
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
end
