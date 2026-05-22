defmodule MingaEditor.UI.Picker.FileSourceTest do
  @moduledoc "Tests frecency ordering in FileSource candidates."

  # Uses the global Minga.Project singleton to drive FileSource.project_root/0.
  use Minga.Test.EditorCase, async: false

  alias MingaEditor.PickerUI
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
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

  test "on_bulk_select opens all marked project-relative files", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "frecency_bulk_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "initial.ex"), "initial")
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    ctx =
      start_editor("initial", file_path: Path.join(project, "initial.ex"), project_root: project)

    state = editor_state(ctx)
    initial_pids = state.workspace.buffers.list

    state =
      FileSource.on_bulk_select(
        [%Item{id: "lib/one.ex", label: "one.ex"}, %Item{id: "lib/two.ex", label: "two.ex"}],
        state
      )

    paths = Enum.map(state.workspace.buffers.list, &Minga.Buffer.file_path/1)
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))

    on_exit(fn -> stop_pids(new_pids) end)

    assert Path.join(lib, "one.ex") in paths
    assert Path.join(lib, "two.ex") in paths
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == Path.join(lib, "two.ex")
  end

  test "PickerUI Enter opens marked files through the UI path", %{tmp_dir: tmp_dir} do
    project =
      Path.join(tmp_dir, "frecency_ui_select_project_#{:erlang.unique_integer([:positive])}")

    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "initial.ex"), "initial")
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    ctx =
      start_editor("initial", file_path: Path.join(project, "initial.ex"), project_root: project)

    state = editor_state(ctx)
    initial_pids = state.workspace.buffers.list

    picker_state =
      build_file_picker_state(state, [
        %Item{id: "lib/one.ex", label: "one.ex"},
        %Item{id: "lib/two.ex", label: "two.ex"}
      ])

    new_state = PickerUI.handle_key(picker_state, 13, 0)
    flush_project()
    paths = Enum.map(new_state.workspace.buffers.list, &Minga.Buffer.file_path/1)
    new_pids = Enum.reject(new_state.workspace.buffers.list, &Enum.member?(initial_pids, &1))

    on_exit(fn -> stop_pids(new_pids) end)

    assert new_state.shell_state.modal == :none
    assert Path.join(lib, "one.ex") in paths
    assert Path.join(lib, "two.ex") in paths
    assert Minga.Buffer.file_path(new_state.workspace.buffers.active) == Path.join(lib, "two.ex")
  end

  test "PickerUI bulk action menu dispatches on_bulk_action for marked files", %{tmp_dir: tmp_dir} do
    project =
      Path.join(tmp_dir, "frecency_ui_bulk_project_#{:erlang.unique_integer([:positive])}")

    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "initial.ex"), "initial")
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(project)
    await_project_rebuild(project)

    ctx =
      start_editor("initial", file_path: Path.join(project, "initial.ex"), project_root: project)

    state = editor_state(ctx)
    initial_pids = state.workspace.buffers.list

    picker_state =
      build_file_picker_state(state, [
        %Item{id: "lib/one.ex", label: "one.ex"},
        %Item{id: "lib/two.ex", label: "two.ex"}
      ])

    menu_state = PickerUI.handle_key(picker_state, ?o, MingaEditor.Input.mod_ctrl())

    assert {:picker,
            %{picker_ui: %{action_menu: {[{"Open all marked", {:bulk, :open_marked, items}}], 0}}}} =
             menu_state.shell_state.modal

    assert Enum.map(items, & &1.id) == ["lib/one.ex", "lib/two.ex"]

    new_state = PickerUI.handle_key(menu_state, 13, 0)
    flush_project()
    paths = Enum.map(new_state.workspace.buffers.list, &Minga.Buffer.file_path/1)
    new_pids = Enum.reject(new_state.workspace.buffers.list, &Enum.member?(initial_pids, &1))

    on_exit(fn -> stop_pids(new_pids) end)

    assert new_state.shell_state.modal == :none
    assert Path.join(lib, "one.ex") in paths
    assert Path.join(lib, "two.ex") in paths
    assert Minga.Buffer.file_path(new_state.workspace.buffers.active) == Path.join(lib, "two.ex")
  end

  test "bulk actions expose open all marked" do
    assert FileSource.bulk_actions([%Item{id: "lib/one.ex", label: "one.ex"}]) == [
             {"Open all marked", :open_marked}
           ]
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

  defp build_file_picker_state(state, items) do
    picker = items |> Picker.new(title: "Find file", max_visible: 10) |> mark_all_picker()

    picker_state = %PickerState{
      picker: picker,
      source: FileSource,
      restore: state.workspace.buffers.active_index
    }

    ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
  end

  defp mark_all_picker(%Picker{items: []} = picker), do: picker

  defp mark_all_picker(%Picker{} = picker) do
    Enum.reduce(1..length(picker.items), picker, fn _, acc ->
      Picker.toggle_mark(acc) |> Picker.move_down()
    end)
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
