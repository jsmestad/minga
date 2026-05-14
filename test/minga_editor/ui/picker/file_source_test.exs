defmodule MingaEditor.UI.Picker.FileSourceTest do
  @moduledoc "Tests frecency ordering in FileSource candidates."

  # Uses the global Minga.Project singleton to drive FileSource.project_root/0.
  use Minga.Test.EditorCase, async: false

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

    state = FileSource.on_select(%Item{id: "lib/hot.ex", label: "hot.ex"}, editor_state(ctx))
    flush_project()

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

    _state = FileSource.on_select(%Item{id: "lib/previewed.ex", label: "previewed.ex"}, state)
    flush_project()

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

  defp reset_global_project! do
    root = File.cwd!()
    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(root)
    await_project_rebuild(root)
  end

  defp await_project_rebuild(root) do
    state = :sys.get_state(Minga.Project)

    if state.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    :sys.get_state(Minga.Project)
  end

  defp flush_project, do: :sys.get_state(Minga.Project)
end
