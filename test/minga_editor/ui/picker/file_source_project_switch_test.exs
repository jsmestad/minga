defmodule MingaEditor.UI.Picker.FileSourceProjectSwitchTest do
  @moduledoc "Tests delayed project-file choices against the globally registered Project."

  # Candidate production must reroot the globally registered Project between workspaces.
  use ExUnit.Case, async: false

  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  @moduletag :tmp_dir

  setup do
    original_workspace = Project.snapshot()

    on_exit(fn -> restore_project(original_workspace) end)
  end

  test "all delayed action paths stay tied to Project A after Project and file tree switch to B",
       %{
         tmp_dir: tmp_dir
       } do
    project_a = Path.join(tmp_dir, "project_a")
    project_b = Path.join(tmp_dir, "project_b")

    relative_paths = [
      "single.txt",
      "preview.txt",
      "delete.txt",
      "marked/one.txt",
      "marked/two.txt",
      "bulk/one.txt",
      "bulk/two.txt"
    ]

    write_workspace(project_a, relative_paths, "A")
    write_workspace(project_b, relative_paths, "B")
    {:ok, root_a} = Root.directory(project_a)
    {:ok, root_b} = Root.directory(project_b)

    activate_project!(root_a)

    Enum.each(1..2, fn _ ->
      Project.record_file_for_root(root_a, "marked/two.txt")
      _ = :sys.get_state(Project)
    end)

    production_state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: project_a})

    items =
      production_state
      |> Context.from_editor_state()
      |> FileSource.candidates()

    items_by_path = Map.new(items, fn item -> {item.id.path, item} end)

    assert Enum.sort(Map.keys(items_by_path)) == Enum.sort(relative_paths)
    assert hd(items).id.path == "marked/two.txt"

    assert Enum.all?(items, fn item ->
             match?(%ProjectFileCandidate{root: ^root_a}, item.id) and
               item.meta == %{git: nil}
           end)

    activate_project!(root_b)

    rerooted_state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: project_b})

    single_picker_state = open_single_picker(rerooted_state, items_by_path["single.txt"])
    single_state = PickerUI.handle_key(single_picker_state, 13, 0)
    on_exit(fn -> stop_added_buffers(single_state, rerooted_state) end)

    assert Minga.Buffer.file_path(single_state.workspace.buffers.active) ==
             Path.join(project_a, "single.txt")

    assert File.read!(Path.join(project_b, "single.txt")) == "B:single.txt"

    preview_model =
      items_by_path["preview.txt"]
      |> picker_modal()
      |> build_preview_context(rerooted_state)
      |> PickerBuilder.build()

    assert %PickerModel{preview_lines: [[{"A:preview.txt", 0xCCCCCC, false}]]} = preview_model

    for legacy_id <- ["preview.txt", Path.join(project_b, "preview.txt")] do
      legacy_preview_model =
        %Picker.Item{id: legacy_id, label: "preview.txt"}
        |> picker_modal()
        |> build_preview_context(rerooted_state)
        |> PickerBuilder.build()

      assert legacy_preview_model.preview_lines == nil
    end

    FileSource.on_action(:delete, items_by_path["delete.txt"], rerooted_state)
    refute File.exists?(Path.join(project_a, "delete.txt"))
    assert File.read!(Path.join(project_b, "delete.txt")) == "B:delete.txt"

    marked_items = [items_by_path["marked/one.txt"], items_by_path["marked/two.txt"]]
    marked_state = open_marked_picker(rerooted_state, marked_items)
    entered_state = PickerUI.handle_key(marked_state, 13, 0)
    on_exit(fn -> stop_added_buffers(entered_state, rerooted_state) end)

    assert opened_paths(entered_state, rerooted_state) == [
             Path.join(project_a, "marked/one.txt"),
             Path.join(project_a, "marked/two.txt")
           ]

    assert Minga.Buffer.file_path(entered_state.workspace.buffers.active) ==
             Path.join(project_a, "marked/two.txt")

    bulk_items = [items_by_path["bulk/one.txt"], items_by_path["bulk/two.txt"]]
    bulk_state = open_marked_picker(rerooted_state, bulk_items)
    menu_state = PickerUI.handle_key(bulk_state, ?o, MingaEditor.Input.mod_ctrl())
    bulk_opened_state = PickerUI.handle_key(menu_state, 13, 0)
    on_exit(fn -> stop_added_buffers(bulk_opened_state, rerooted_state) end)

    assert opened_paths(bulk_opened_state, rerooted_state) == [
             Path.join(project_a, "bulk/one.txt"),
             Path.join(project_a, "bulk/two.txt")
           ]

    assert Minga.Buffer.file_path(bulk_opened_state.workspace.buffers.active) ==
             Path.join(project_a, "bulk/two.txt")

    assert Project.frecency_scores() == %{}

    assert %Minga.Project.WorkspaceSnapshot{
             root: ^root_b,
             files: project_b_files,
             rebuilding?: false
           } = Project.snapshot()

    assert Enum.sort(project_b_files) == Enum.sort(relative_paths)

    activate_project!(root_a)
    assert "single.txt" in Project.recent_files()
    assert Project.frecency_scores()["single.txt"] > 0
  end

  test "a stale nested-root candidate attributes a new buffer open only to its captured root", %{
    tmp_dir: tmp_dir
  } do
    project_b = Path.join(tmp_dir, "live_project")
    project_a = Path.join(project_b, "stale_nested_project")
    relative_path = "nested.txt"
    absolute_path = Path.join(project_a, relative_path)

    File.mkdir_p!(project_a)
    File.write!(absolute_path, "nested")
    {:ok, root_a} = Root.directory(project_a)
    {:ok, root_b} = Root.directory(project_b)
    {:ok, stale_candidate} = ProjectFileCandidate.new(root_a, relative_path)

    activate_project!(root_b)

    initial_state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: project_b})

    selected_state =
      FileSource.on_select(
        %Picker.Item{id: stale_candidate, label: relative_path},
        initial_state
      )

    on_exit(fn -> stop_added_buffers(selected_state, initial_state) end)
    _ = :sys.get_state(Project)

    assert Minga.Buffer.file_path(selected_state.workspace.buffers.active) == absolute_path
    assert Project.recent_files() == []
    assert Project.frecency_scores() == %{}

    activate_project!(root_a)
    assert Project.recent_files() == [relative_path]
    assert Project.frecency_scores() == %{relative_path => 100}
  end

  @spec activate_project!(Root.t()) :: :ok
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     5_000
    end

    _ = :sys.get_state(Project)
    :ok
  end

  @spec restore_project(Minga.Project.WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end

  @spec write_workspace(String.t(), [String.t()], String.t()) :: :ok
  defp write_workspace(root, relative_paths, prefix) do
    Enum.each(relative_paths, fn relative_path ->
      absolute_path = Path.join(root, relative_path)
      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, "#{prefix}:#{relative_path}")
    end)
  end

  @spec set_file_tree(MingaEditor.State.t(), FileTree.t()) :: MingaEditor.State.t()
  defp set_file_tree(state, file_tree) do
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end

  @spec picker_modal(MingaEditor.UI.Picker.Item.t()) :: term()
  defp picker_modal(item) do
    picker = Picker.new([item], title: "Files")

    {:picker,
     %{
       picker_ui: %PickerState{
         picker: picker,
         source: FileSource
       }
     }}
  end

  @spec build_preview_context(term(), MingaEditor.State.t()) ::
          MingaEditor.Frontend.Emit.Context.t()
  defp build_preview_context(modal, state) do
    %MingaEditor.Frontend.Emit.Context{
      port_manager: self(),
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      theme: %{fg: 0xCCCCCC},
      font_registry: MingaEditor.UI.FontRegistry.new(),
      windows: state.workspace.windows,
      layout: %MingaEditor.Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 24},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{}
      },
      shell: MingaEditor.Shell.Traditional,
      shell_state: %{modal: modal},
      buffers: state.workspace.buffers,
      highlight: %{highlights: %{}}
    }
  end

  @spec open_single_picker(MingaEditor.State.t(), MingaEditor.UI.Picker.Item.t()) ::
          MingaEditor.State.t()
  defp open_single_picker(state, item) do
    picker_state = %PickerState{
      picker: Picker.new([item], title: "Files"),
      source: FileSource,
      restore: state.workspace.buffers.active_index
    }

    ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
  end

  @spec open_marked_picker(MingaEditor.State.t(), [MingaEditor.UI.Picker.Item.t()]) ::
          MingaEditor.State.t()
  defp open_marked_picker(state, items) do
    picker =
      items
      |> Picker.new(title: "Files")
      |> Picker.toggle_mark()
      |> Picker.move_down()
      |> Picker.toggle_mark()

    picker_state = %PickerState{
      picker: picker,
      source: FileSource,
      restore: state.workspace.buffers.active_index
    }

    ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
  end

  @spec opened_paths(MingaEditor.State.t(), MingaEditor.State.t()) :: [String.t()]
  defp opened_paths(result_state, initial_state) do
    initial_buffers = MapSet.new(initial_state.workspace.buffers.list)

    result_state.workspace.buffers.list
    |> Enum.reject(&MapSet.member?(initial_buffers, &1))
    |> Enum.map(&Minga.Buffer.file_path/1)
  end

  @spec stop_added_buffers(MingaEditor.State.t(), MingaEditor.State.t()) :: :ok
  defp stop_added_buffers(result_state, initial_state) do
    initial_buffers = MapSet.new(initial_state.workspace.buffers.list)

    result_state.workspace.buffers.list
    |> Enum.reject(&MapSet.member?(initial_buffers, &1))
    |> Enum.each(&stop_pid/1)
  end

  @spec stop_pid(pid()) :: :ok
  defp stop_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
