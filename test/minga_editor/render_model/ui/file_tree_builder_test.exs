defmodule MingaEditor.RenderModel.UI.FileTreeBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FileTree, as: FileTreeModel
  alias Minga.Project.FileTree, as: ProjectFileTree
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers

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

      file_tree =
        %FileTreeState{}
        |> FileTreeState.open(tree, nil)
        |> Map.put(
          :interaction,
          {:editing, %{index: 0, type: :rename, text: "renamed", original_name: "lib"}}
        )

      ctx = build_minimal_context(file_tree: file_tree)
      model = FileTreeBuilder.build(ctx)

      assert %FileTreeModel{status: :ready, focused?: true, tree_width: 32} = model
      refute model.local_navigation?
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
      # Named folders resolve to per-folder Devicon colors ("lib" = source blue).
      assert row.icon_color == 0x42A5F5
    end

    test "builds the full tree with rows even when the sidebar is hidden" do
      path = "/project/lib"

      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project", path]),
        git_status: %{path => :modified},
        entries: [
          %{path: path, name: "lib", dir?: true, depth: 1, last_child?: true, guides: [true]}
        ]
      }

      # `visibility: :hidden` keeps the loaded tree alive; the sidebar is just toggled off.
      file_tree =
        %FileTreeState{}
        |> FileTreeState.open(tree, nil)
        |> FileTreeState.hide()

      model = FileTreeBuilder.build(build_minimal_context(file_tree: file_tree))

      # Visibility flag still reports hidden so the frontend skips rendering...
      assert model.status == :hidden
      refute model.focused?
      refute model.local_navigation?
      # ...but the data is always present in the frame (AC1/AC2).
      assert [row] = model.rows
      assert row.id == path
      assert row.name == "lib"
      assert row.git_status == :modified
      assert model.root_path == "/project"
      assert model.tree_width == 32
    end

    test "disables local navigation while filtering" do
      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project"]),
        git_status: %{},
        entries: [
          %{
            path: "/project/main.rs",
            name: "main.rs",
            dir?: false,
            depth: 1,
            last_child?: true,
            guides: []
          }
        ]
      }

      file_tree =
        %FileTreeState{}
        |> FileTreeState.open(tree, nil)
        |> Map.put(:interaction, :filtering)

      model = FileTreeBuilder.build(build_minimal_context(file_tree: file_tree))

      assert model.status == :ready
      refute model.local_navigation?
    end

    test "disables local navigation while help is visible" do
      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project"]),
        git_status: %{},
        entries: [
          %{
            path: "/project/main.rs",
            name: "main.rs",
            dir?: false,
            depth: 1,
            last_child?: true,
            guides: []
          }
        ]
      }

      file_tree =
        %FileTreeState{}
        |> FileTreeState.open(tree, nil)
        |> Map.put(:interaction, :help)

      model = FileTreeBuilder.build(build_minimal_context(file_tree: file_tree))

      assert model.status == :ready
      refute model.local_navigation?
    end

    test "disables local navigation when file tree is not focused" do
      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project"]),
        git_status: %{},
        entries: [
          %{
            path: "/project/main.rs",
            name: "main.rs",
            dir?: false,
            depth: 1,
            last_child?: true,
            guides: []
          }
        ]
      }

      file_tree = %FileTreeState{} |> FileTreeState.open(tree, nil) |> FileTreeState.unfocus()
      model = FileTreeBuilder.build(build_minimal_context(file_tree: file_tree))

      assert model.status == :ready
      refute model.local_navigation?
    end

    test "resolves per-filetype icon colors from the active theme" do
      path = "/project/main.rs"

      tree = %ProjectFileTree{
        root: "/project",
        width: 32,
        cursor: 0,
        expanded: MapSet.new(["/project"]),
        git_status: %{},
        entries: [
          %{path: path, name: "main.rs", dir?: false, depth: 1, last_child?: true, guides: []}
        ]
      }

      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

      astrodark =
        FileTreeBuilder.build(build_minimal_context(file_tree: file_tree, theme: :astrodark))

      doom = FileTreeBuilder.build(build_minimal_context(file_tree: file_tree, theme: :doom_one))

      assert astrodark.local_navigation?
      assert doom.local_navigation?
      assert [%{icon_color: astrodark_color}] = astrodark.rows
      assert [%{icon_color: doom_color}] = doom.rows

      # astrodark overrides Rust's icon color; doom_one keeps the language default.
      assert astrodark_color == 0xDEA584
      assert doom_color == Minga.Language.Devicon.color(:rust)
    end

    test "loading and error content with retained tree emit state-only models" do
      tree =
        "/project"
        |> ProjectFileTree.new()
        |> ProjectFileTree.put_entries([
          %{
            path: "/project/main.rs",
            name: "main.rs",
            dir?: false,
            depth: 1,
            last_child?: true,
            guides: []
          }
        ])

      loading = %FileTreeState{} |> FileTreeState.open(tree, nil) |> FileTreeState.loading()
      loading_model = FileTreeBuilder.build(build_minimal_context(file_tree: loading))

      assert loading_model.status == :loading
      assert loading_model.rows == []
      assert loading_model.root_path == "/project"

      hidden_loading_model =
        FileTreeBuilder.build(build_minimal_context(file_tree: FileTreeState.hide(loading)))

      assert hidden_loading_model.status == :hidden
      assert [%{name: "main.rs"}] = hidden_loading_model.rows

      errored = FileTreeState.error(FileTreeState.open(%FileTreeState{}, tree, nil), :eacces)
      error_model = FileTreeBuilder.build(build_minimal_context(file_tree: errored))

      assert error_model.status == {:error, "permission denied"}
      assert error_model.rows == []
      assert error_model.root_path == "/project"

      hidden_error_model =
        FileTreeBuilder.build(build_minimal_context(file_tree: FileTreeState.hide(errored)))

      assert hidden_error_model.status == :hidden
      assert [%{name: "main.rs"}] = hidden_error_model.rows
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
    theme = Keyword.get(opts, :theme, :doom_one)

    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    workspace = %{ctx.workspace | file_tree: file_tree || %FileTreeState{}}
    frame = %{ctx.intent.frame | theme: MingaEditor.UI.Theme.get!(theme)}

    %{ctx | workspace: workspace, intent: %{ctx.intent | frame: frame, workspace: workspace}}
  end
end
