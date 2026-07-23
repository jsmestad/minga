defmodule MingaEditor.FileTree.FeatureTest do
  # File-tree toggle reads the process-global Minga.Project singleton.
  use ExUnit.Case, async: false

  alias Minga.Project.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.SidebarsBuilder
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    %{sidebar_registry: table}
  end

  test "FileTree state is stored as a direct workspace field" do
    workspace = %MingaEditor.Session.State{}
    file_tree = %FileTreeState{project_root: "/tmp/project"}

    workspace = MingaEditor.Session.State.set_file_tree(workspace, file_tree)

    assert workspace.file_tree == file_tree
    assert MingaEditor.Session.State.file_tree_state(workspace) == file_tree
    assert MingaEditor.Session.State.get_feature_state(workspace, :builtin, :file_tree) == nil
  end

  test "semantic sidebar metadata uses FileTree registry visibility and width", %{
    sidebar_registry: table
  } do
    # The BEAM no longer reserves cell columns for the file tree; the frontend
    # renders it natively. The surviving behavior is that the file tree's
    # visibility and width flow into the semantic sidebar metadata the frontend
    # reads, and that closing it marks the sidebar hidden.
    state = gui_state(cols: 80, rows: 24, sidebar_registry: table)
    tree = FileTree.new(File.cwd!(), width: 26)
    file_tree = %FileTreeState{} |> FileTreeState.open(tree, nil)

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_file_tree(workspace, file_tree)
              end)
        }
      end)

    :ok = MingaEditor.FileTree.Feature.sync_sidebar(file_tree, table)

    %{sidebars: sidebars, active_id: active_id} =
      SidebarsBuilder.build(Context.from_editor_state(state))

    assert active_id == "file_tree"
    entry = Enum.find(sidebars, &(&1.id == "file_tree"))
    assert entry.visible?
    assert entry.preferred_width == 26

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_file_tree(workspace, FileTreeState.close(file_tree))
              end)
        }
      end)

    :ok = MingaEditor.FileTree.Feature.sync_sidebar(FileTreeState.close(file_tree), table)

    %{sidebars: sidebars} = SidebarsBuilder.build(Context.from_editor_state(state))
    entry = Enum.find(sidebars, &(&1.id == "file_tree"))
    refute entry.visible?
  end

  test "workspace replacement re-syncs the active FileTree sidebar", %{sidebar_registry: table} do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)
    open_tree = %FileTreeState{} |> FileTreeState.open(FileTree.new(File.cwd!(), width: 24), nil)
    open_workspace = MingaEditor.Session.State.set_file_tree(state.workspace, open_tree)

    state = then(state, fn state -> %{state | workspace: open_workspace} end)
    :ok = MingaEditor.FileTree.Feature.sync_sidebar(open_tree, table)

    assert %{id: "file_tree", visible?: true, preferred_width: 24} =
             Sidebar.get(table, "file_tree")

    closed_workspace =
      MingaEditor.Session.State.set_file_tree(state.workspace, FileTreeState.close(open_tree))

    _state = then(state, fn state -> %{state | workspace: closed_workspace} end)
    :ok = MingaEditor.FileTree.Feature.sync_sidebar(FileTreeState.close(open_tree), table)
    assert %{id: "file_tree", visible?: false} = Sidebar.get(table, "file_tree")
  end

  test "opening an unavailable project root exposes an error instead of an empty tree", %{
    sidebar_registry: table
  } do
    missing_root =
      Path.join(System.tmp_dir!(), "minga-missing-tree-#{System.unique_integer([:positive])}")

    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_file_tree(&1, %FileTreeState{
                  project_root: missing_root
                })
              )
        }
      end)

    state = MingaEditor.Commands.FileTree.toggle(state)
    file_tree = state.workspace.file_tree

    assert FileTreeState.tree(file_tree).root == Path.expand(missing_root)
    assert {:error, reason} = FileTreeState.status(file_tree)
    assert reason != ""
  end

  test "dropping FileTree feature state is safe and toggle recreates it", %{
    sidebar_registry: table
  } do
    state = base_state(cols: 80, rows: 24, sidebar_registry: table)

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_file_tree(&1, %FileTreeState{
                  project_root: File.cwd!()
                })
              )
        }
      end)

    state =
      then(state, fn state ->
        %{state | workspace: then(state.workspace, &MingaEditor.Session.State.drop_file_tree/1)}
      end)

    assert FileTreeState.tree(state.workspace.file_tree) == nil

    state = MingaEditor.Commands.FileTree.toggle(state)

    assert %FileTree{} = FileTreeState.tree(state.workspace.file_tree)
  end
end
