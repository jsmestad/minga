defmodule MingaEditor.RenderModel.UI.FileTreeBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias Minga.RenderModel.UI.FileTree, as: FileTreeModel

  @op_gui_file_tree Minga.Protocol.Opcodes.gui_file_tree()

  describe "build/1" do
    test "returns hidden file tree when context has no file_tree" do
      ctx = build_minimal_context()
      model = FileTreeBuilder.build(ctx)

      assert %FileTreeModel{} = model
      assert {:no_tree, _} = model.fingerprint
      assert is_binary(model.encoded)
      assert <<@op_gui_file_tree, _payload_len::32, _payload::binary>> = model.encoded
    end

    test "returns hidden file tree with project root" do
      ctx = build_minimal_context(file_tree: %{project_root: "/tmp/my-project"})
      model = FileTreeBuilder.build(ctx)

      assert %FileTreeModel{} = model
      assert {:no_tree, "/tmp/my-project"} = model.fingerprint
    end

    test "fingerprint is consistent for same hidden state" do
      ctx = build_minimal_context()
      model1 = FileTreeBuilder.build(ctx)
      model2 = FileTreeBuilder.build(ctx)

      assert model1.fingerprint == model2.fingerprint
    end

    test "hidden file tree has no selection_encoded" do
      ctx = build_minimal_context()
      model = FileTreeBuilder.build(ctx)

      assert model.selection_encoded == nil
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
      file_tree: file_tree
    }
  end
end
