defmodule MingaEditor.FileTree.FeatureTest do
  # Mutates global input/sidebar registries.
  use ExUnit.Case, async: false

  alias Minga.Project.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Input
  alias MingaEditor.Shell.Traditional.Layout.TUI, as: LayoutTUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    Sidebar.unregister_source(:builtin)

    on_exit(fn ->
      Sidebar.unregister_source(:builtin)
      Input.reset_handlers()
    end)

    :ok
  end

  test "FileTree state is stored through feature-state accessors" do
    workspace = %MingaEditor.Session.State{viewport: MingaEditor.Viewport.new(24, 80)}
    file_tree = %FileTreeState{project_root: "/tmp/project"}

    workspace = MingaEditor.Session.State.set_file_tree(workspace, file_tree)

    assert MingaEditor.Session.State.file_tree_state(workspace) == file_tree

    assert MingaEditor.Session.State.get_feature_state(workspace, :builtin, :file_tree) ==
             file_tree
  end

  test "FileTree dynamic handler uses a built-in source that extension cleanup cannot remove" do
    Input.reset_handlers()
    :ok = FileTreeFeature.register_contributions(%FileTreeState{})

    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert FileTreeFeature.input_source() == :builtin
    assert Enum.count(handlers, &(&1 == MingaEditor.Input.FileTreeHandler)) == 1

    :ok = Input.unregister_source({:extension, :file_tree})
    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert Enum.count(handlers, &(&1 == MingaEditor.Input.FileTreeHandler)) == 1
  after
    Input.reset_handlers()
  end

  test "layout uses FileTree sidebar registry visibility and width" do
    state = base_state(cols: 80, rows: 24)
    tree = FileTree.new(File.cwd!(), width: 26)
    file_tree = %FileTreeState{} |> FileTreeState.open(tree, nil)

    state = EditorState.set_file_tree(state, file_tree)
    layout = LayoutTUI.compute(state)

    assert {1, 0, 26, 21} = layout.file_tree
    assert {1, 27, 53, 21} = layout.editor_area

    state = EditorState.set_file_tree(state, FileTreeState.close(file_tree))
    assert LayoutTUI.compute(state).file_tree == nil
  end

  test "workspace replacement re-syncs the active FileTree sidebar" do
    state = base_state(cols: 80, rows: 24)
    open_tree = %FileTreeState{} |> FileTreeState.open(FileTree.new(File.cwd!(), width: 24), nil)
    open_workspace = MingaEditor.Session.State.set_file_tree(state.workspace, open_tree)

    state = EditorState.set_workspace(state, open_workspace)
    assert %{id: "file_tree", visible?: true, preferred_width: 24} = Sidebar.get("file_tree")

    closed_workspace =
      MingaEditor.Session.State.set_file_tree(state.workspace, FileTreeState.close(open_tree))

    _state = EditorState.set_workspace(state, closed_workspace)
    assert %{id: "file_tree", visible?: false} = Sidebar.get("file_tree")
  end

  test "dropping FileTree feature state is safe and toggle recreates it" do
    state = base_state(cols: 80, rows: 24)
    state = EditorState.set_file_tree(state, %FileTreeState{project_root: File.cwd!()})
    state = EditorState.drop_file_tree(state)

    assert EditorState.file_tree_state(state).tree == nil

    state = MingaEditor.Commands.FileTree.toggle(state)

    assert %FileTree{} = EditorState.file_tree_state(state).tree
  end
end
