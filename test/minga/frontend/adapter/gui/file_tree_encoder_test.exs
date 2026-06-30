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

    test "encodes a hidden tree that still carries its rows with the visible flag off" do
      # A hidden-but-loaded tree (#2626): full data in the frame, but the frontend
      # must not render it, so the visible bit (0x01) stays clear.
      model = %{ready_tree("/project/a.ex") | status: :hidden, focused?: false}

      {cmd, _caches} = FileTreeEncoder.encode(model, Caches.new())

      assert <<@op_gui_file_tree, len::32, payload::binary-size(len)>> = cmd
      assert <<2::8, tree_flags::8, _tree_state::8, _rest::binary>> = payload
      assert Bitwise.band(tree_flags, 0x01) == 0
      # Row count is preserved (2 rows), proving the data is encoded while hidden.
      assert <<2::8, _flags::8, _state::8, sel::binary>> = payload

      assert <<sel_len::16, _selected_id::binary-size(sel_len), root_len::16,
               _root::binary-size(root_len), _tree_width::16, 2::16, _rest::binary>> = sel
    end

    test "re-emits the hidden tree only when its rows change (fingerprint cache)" do
      model = %{ready_tree("/project/a.ex") | status: :hidden, focused?: false}

      {cmd1, caches} = FileTreeEncoder.encode(model, Caches.new())
      {cmd2, caches} = FileTreeEncoder.encode(model, caches)

      changed = %{model | rows: [row("/project/a.ex"), row("/project/c.ex")]}
      {cmd3, _caches} = FileTreeEncoder.encode(changed, caches)

      assert <<@op_gui_file_tree, _::32, _::binary>> = cmd1
      assert cmd2 == nil
      assert <<@op_gui_file_tree, _::32, _::binary>> = cmd3
    end

    test "re-emits across a toggle cycle so the visible flag flips even when rows are unchanged" do
      # Hold focus and rows constant so ONLY `status` changes between frames.
      # This locks in that the status bit participates in re-emission: if a future
      # refactor moved `status` out of the structural fingerprint, these
      # transitions would silently cache-hit (returning nil) and the sidebar would
      # stop appearing/disappearing on toggle, with no other test catching it.
      ready = %{ready_tree("/project/a.ex") | focused?: false}
      hidden = %{ready | status: :hidden}

      {_first, caches} = FileTreeEncoder.encode(ready, Caches.new())

      # ready -> hidden: full re-emit, visible bit cleared, status byte hidden (0).
      {hidden_cmd, caches} = FileTreeEncoder.encode(hidden, caches)
      {hidden_flags, hidden_status} = file_tree_header(hidden_cmd)
      assert Bitwise.band(hidden_flags, 0x01) == 0
      assert hidden_status == 0

      # hidden -> ready: full re-emit, visible bit set, status byte ready (3).
      {ready_cmd, _caches} = FileTreeEncoder.encode(ready, caches)
      {ready_flags, ready_status} = file_tree_header(ready_cmd)
      assert Bitwise.band(ready_flags, 0x01) != 0
      assert ready_status == 3
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
            icon: "󱉇",
            # Named folder "lib" resolves to the source/code icon and color.
            icon_color: 0x42A5F5,
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

    test "encodes local navigation eligibility in tree flags" do
      model = %{ready_tree("/project/a.ex") | local_navigation?: true}

      {cmd, _caches} = FileTreeEncoder.encode(model, Caches.new())

      assert <<@op_gui_file_tree, len::32, payload::binary-size(len)>> = cmd
      assert <<2::8, tree_flags::8, _tree_state::8, _rest::binary>> = payload
      assert Bitwise.band(tree_flags, 0x20) != 0
    end

    test "sends full tree when local navigation eligibility changes" do
      model1 = ready_tree("/project/a.ex")
      model2 = %{model1 | local_navigation?: true}

      {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd2
    end

    test "sends full tree when row structure changes" do
      model1 = ready_tree("/project/a.ex")
      model2 = %{ready_tree("/project/a.ex") | rows: [row("/project/a.ex"), row("/project/c.ex")]}

      {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert <<@op_gui_file_tree, _len::32, _payload::binary>> = cmd2
    end
  end

  # Decodes the {flags, status} header bytes of a full gui_file_tree command.
  # Pattern-matches the opcode, so a nil (cache hit) or selection-only command
  # raises here, which is exactly the toggle-regression we want to fail on.
  @spec file_tree_header(binary()) :: {non_neg_integer(), non_neg_integer()}
  defp file_tree_header(<<@op_gui_file_tree, len::32, payload::binary-size(len)>>) do
    <<2::8, flags::8, status_byte::8, _rest::binary>> = payload
    {flags, status_byte}
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
