defmodule MingaEditor.RenderModel.UI.FileTreeBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FileTree, as: FileTreeModel
  alias Minga.Project.FileTree, as: ProjectFileTree
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.State.FileTree, as: FileTreeState

  describe "build/1" do
    test "returns hidden semantic file tree when context has no file_tree" do
      ctx = build_minimal_context()
      model = FileTreeBuilder.build(ctx)

      assert %FileTreeModel{} = model
      assert model.status == :hidden
      assert model.root_path == nil
      assert model.rows == []
    end

    test "returns hidden file tree with project root" do
      ctx = build_minimal_context(file_tree: %{project_root: "/tmp/my-project"})
      model = FileTreeBuilder.build(ctx)

      assert model.status == :hidden
      assert model.root_path == "/tmp/my-project"
    end

    test "maps ready tree rows to semantic model" do
      path = "/project/lib"

      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project", path]),
        git_status: %{path => :modified},
        entries: [
          %{
            path: path,
            name: "lib",
            dir?: true,
            depth: 1,
            last_child?: true,
            guides: [true]
          }
        ]
      }

      file_tree = %FileTreeState{
        tree: tree,
        focused: true,
        editing: %{index: 0, type: :rename, text: "renamed", original_name: "lib"},
        tree_status: :ready
      }

      ctx = build_minimal_context(file_tree: file_tree)
      model = FileTreeBuilder.build(ctx)

      assert %FileTreeModel{status: :ready, focused?: true, tree_width: 32} = model
      assert model.selected_id == path

      assert [row] = model.rows
      assert row.id == path
      assert row.path == path
      assert row.name == "lib"
      assert row.flags.directory?
      assert row.flags.expanded?
      assert row.flags.last_child?
      assert row.git_status == :modified
      assert row.depth == 1
      assert row.guides == [true]
      assert row.editing.type == :rename
      assert row.editing.text == "renamed"
    end

    test "semantic model is consistent for same hidden state" do
      ctx = build_minimal_context()
      model1 = FileTreeBuilder.build(ctx)
      model2 = FileTreeBuilder.build(ctx)

      assert model1 == model2
    end
  end

  defp build_minimal_context(opts \\ []) do
    file_tree = Keyword.get(opts, :file_tree, nil)

    %MingaEditor.Frontend.Emit.Context{
      port_manager: self(),
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      font_registry: MingaEditor.UI.FontRegistry.new(),
      windows: %MingaEditor.State.Windows{map: %{}, active: 1},
      layout: %MingaEditor.Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 24},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{}
      },
      shell: MingaEditor.Shell.Traditional,
      shell_state: %{},
      file_tree: file_tree,
      buffers: %MingaEditor.State.Buffers{}
    }
  end
end
