defmodule MingaEditor.UI.Picker.FileSourceTest do
  @moduledoc "Tests frecency ordering in FileSource candidates."

  # Uses the global Minga.Project singleton to drive FileSource.project_root/0.
  use Minga.Test.EditorCase, async: false

  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item

  @moduletag :tmp_dir

  setup do
    reset_global_project!()

    on_exit(fn ->
      reset_global_project!()
    end)

    :ok
  end

  test "on_select opens project-relative paths from the project root and records the selection",
       %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "frecency_select_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "initial.ex"), "initial")
    File.write!(Path.join(lib, "hot.ex"), "hot")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    ctx =
      start_editor("initial", file_path: Path.join(project, "initial.ex"), project_root: project)

    state = editor_state(ctx)
    initial_pids = state.workspace.buffers.list

    state = FileSource.on_select(%Item{id: "lib/hot.ex", label: "hot.ex"}, state)
    flush_project()
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))

    on_exit(fn -> stop_pids(new_pids) end)

    assert Minga.Buffer.file_path(state.workspace.buffers.active) == Path.join(lib, "hot.ex")
    assert Minga.Project.frecency_scores()["lib/hot.ex"] > 0
  end

  test "preview selections do not record frecency until confirmed", %{tmp_dir: tmp_dir} do
    project =
      Path.join(tmp_dir, "frecency_preview_project_#{:erlang.unique_integer([:positive])}")

    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "initial.ex"), "initial")
    File.write!(Path.join(lib, "previewed.ex"), "previewed")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    ctx =
      start_editor("initial", file_path: Path.join(project, "initial.ex"), project_root: project)

    state = editor_state(ctx) |> MingaEditor.State.set_buffer_add_context(:preview)
    initial_pids = state.workspace.buffers.list

    new_state = FileSource.on_select(%Item{id: "lib/previewed.ex", label: "previewed.ex"}, state)
    flush_project()
    new_pids = Enum.reject(new_state.workspace.buffers.list, &Enum.member?(initial_pids, &1))

    on_exit(fn -> stop_pids(new_pids) end)

    refute Map.has_key?(Minga.Project.frecency_scores(), "lib/previewed.ex")
  end

  test "files opened more often rank above files opened once", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "frecency_picker_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(lib, "hot.ex"), "")
    File.write!(Path.join(lib, "cold.ex"), "")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    Enum.each(1..5, fn _ ->
      Minga.Project.record_file(Path.join(lib, "hot.ex"))
      flush_project()
    end)

    Minga.Project.record_file(Path.join(lib, "cold.ex"))
    flush_project()

    ids = FileSource.candidates(nil) |> Enum.map(& &1.id)

    hot_index = Enum.find_index(ids, &(&1 == "lib/hot.ex"))
    cold_index = Enum.find_index(ids, &(&1 == "lib/cold.ex"))

    assert is_integer(hot_index)
    assert is_integer(cold_index)
    assert hot_index < cold_index
  end

  test "reads the project file cache for the active root without re-discovering on disk",
       %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "cache_active_root_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "cached.ex"), "cached")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    # Create a new file AFTER the cache was built. A fresh discovery would list
    # it; reading the cache must not, proving the picker uses Minga.Project.files/0.
    File.write!(Path.join(project, "added_after_cache.ex"), "late")

    state =
      TestHelpers.base_state(content: "cached")
      |> EditorState.set_file_tree(%FileTree{project_root: project})

    ids =
      state
      |> Context.from_editor_state()
      |> FileSource.candidates()
      |> Enum.map(& &1.id)

    assert "cached.ex" in ids
    refute "added_after_cache.ex" in ids
  end

  test "falls back to direct discovery for a root that is not the active project",
       %{tmp_dir: tmp_dir} do
    active = Path.join(tmp_dir, "fallback_active_#{:erlang.unique_integer([:positive])}")
    other = Path.join(tmp_dir, "fallback_other_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(active)
    File.mkdir_p!(other)
    File.write!(Path.join(active, "mix.exs"), "")
    File.write!(Path.join(other, "outside.txt"), "outside")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(active)
    await_project_rebuild(active)

    state =
      TestHelpers.base_state(content: "active")
      |> EditorState.set_file_tree(%FileTree{project_root: active})

    picker_context = Context.from_editor_state(state, %{project_root: other})

    ids = FileSource.candidates(picker_context) |> Enum.map(& &1.id)

    # The non-active root is discovered directly on disk, not from the cache.
    assert "outside.txt" in ids
  end

  test "explicit picker project root overrides stale file tree root", %{tmp_dir: tmp_dir} do
    stale_root = Path.join(tmp_dir, "stale_file_source_root")
    selected_root = Path.join(tmp_dir, "selected_file_source_root")

    File.mkdir_p!(stale_root)
    File.mkdir_p!(selected_root)
    File.write!(Path.join(stale_root, "stale.txt"), "stale")
    File.write!(Path.join(selected_root, "target.txt"), "target")

    state =
      TestHelpers.base_state(content: "stale")
      |> EditorState.set_file_tree(%FileTree{project_root: stale_root})

    picker_context = Context.from_editor_state(state, %{project_root: selected_root})

    ids = FileSource.candidates(picker_context) |> Enum.map(& &1.id)

    assert "target.txt" in ids
    refute "stale.txt" in ids
  end

  defp stop_pids(pids) do
    Enum.each(pids, fn pid ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp reset_global_project! do
    root = File.cwd!()
    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(root)
    await_project_rebuild(root)
  end

  defp await_project_rebuild(root) do
    if Minga.Project.rebuilding?() do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    _ = :sys.get_state(Minga.Project)
  end

  defp flush_project, do: _ = :sys.get_state(Minga.Project)
end
