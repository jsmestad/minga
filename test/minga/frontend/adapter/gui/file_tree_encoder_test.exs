defmodule Minga.Frontend.Adapter.GUI.FileTreeEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Flags
  alias Minga.RenderModel.UI.FileTree.Row
  alias MingaEditor.FileTree.Diagnostics, as: LegacyDiagnostics
  alias MingaEditor.FileTree.Row, as: LegacyRow
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_file_tree Minga.Protocol.Opcodes.gui_file_tree()
  @op_gui_file_tree_selection Minga.Protocol.Opcodes.gui_file_tree_selection()

  describe "encode/2 - hidden/state fingerprints" do
    test "encodes hidden file tree on first call" do
      model = %FileTree{root_path: "/tmp/project", status: :hidden}

      {cmd, _caches} = FileTreeEncoder.encode(model, Caches.new())

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd
    end

    test "returns nil on second call with same hidden tree" do
      model = %FileTree{root_path: "/tmp/project", status: :hidden}

      {_cmd1, caches} = FileTreeEncoder.encode(model, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd2 == nil
    end

    test "re-encodes when state changes" do
      model1 = %FileTree{root_path: "/tmp/first", status: :hidden}
      model2 = %FileTree{root_path: "/tmp/second", status: :hidden}

      {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd2
    end
  end

  describe "encode/2 - ready tree selection path" do
    test "matches legacy file-tree wire format" do
      model = %FileTree{
        root_path: "/project",
        tree_width: 30,
        status: :ready,
        focused?: true,
        selected_id: "/project/lib",
        rows: [
          %Row{
            id: "/project/lib",
            path: "/project/lib",
            name: "lib",
            icon: "󰉋",
            flags: %Flags{
              directory?: true,
              expanded?: true,
              active?: true,
              dirty?: true,
              last_child?: true
            },
            git_status: :modified,
            diagnostics: {2, 1, 0, 0},
            depth: 1,
            guides: [true]
          }
        ]
      }

      legacy_rows = [
        LegacyRow.new(
          id: "/project/lib",
          path: "/project/lib",
          name: "lib",
          directory?: true,
          expanded?: true,
          selected?: true,
          focused?: true,
          active?: true,
          dirty?: true,
          git_status: :modified,
          diagnostics: LegacyDiagnostics.new({2, 1, 0, 0}),
          depth: 1,
          guides: [true],
          last_child?: true
        )
      ]

      {cmd, _caches} = FileTreeEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, true, legacy_rows)
    end

    test "encodes full tree on first call" do
      model = ready_tree("/project/a.ex")

      {cmd, _caches} = FileTreeEncoder.encode(model, Caches.new())

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd
    end

    test "returns nil when nothing changed" do
      model = ready_tree("/project/a.ex")

      {_cmd1, caches} = FileTreeEncoder.encode(model, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd2 == nil
    end

    test "sends selection-only command when only selection changes" do
      model1 = ready_tree("/project/a.ex")
      model2 = ready_tree("/project/b.ex")

      {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert <<@op_gui_file_tree_selection, len::16, payload::binary-size(len)>> = cmd2
      assert <<1::8, id_len::16, selected_id::binary-size(id_len)>> = payload
      assert selected_id == "/project/b.ex"
    end

    test "sends full tree when row structure changes" do
      model1 = ready_tree("/project/a.ex")
      model2 = %{ready_tree("/project/a.ex") | rows: [row("/project/a.ex"), row("/project/c.ex")]}

      {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd2
    end
  end

  @spec ready_tree(String.t()) :: FileTree.t()
  defp ready_tree(selected_id) do
    rows = Enum.map(["/project/a.ex", "/project/b.ex"], &row/1)

    %FileTree{
      root_path: "/project",
      tree_width: 30,
      status: :ready,
      focused?: true,
      selected_id: selected_id,
      rows: rows
    }
  end

  @spec row(String.t()) :: Row.t()
  defp row(path) do
    %Row{
      id: path,
      path: path,
      name: Path.basename(path),
      icon: "",
      depth: 0,
      guides: [],
      diagnostics: {1, 0, 0, 0}
    }
  end
end
