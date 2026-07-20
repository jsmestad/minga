defmodule Minga.Frontend.Adapter.GUI.FileTreeEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Flags
  alias Minga.RenderModel.UI.FileTree.Row
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.RenderModel.UI.FileTree.Editing

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
    test "encodes full tree bytes from the canonical render model" do
      model = %FileTree{
        root_path: "/project",
        tree_width: 30,
        status: :ready,
        focused?: true,
        local_navigation?: true,
        selected_id: "/project/lib/ñ📄.ex",
        rows: [
          %Row{
            id: "/project/lib/ñ📄.ex",
            path: "/project/lib/ñ📄.ex",
            name: "ñ📄.ex",
            icon: "",
            icon_color: 0x9B59B6,
            flags: %Flags{
              directory?: true,
              expanded?: true,
              active?: true,
              dirty?: true,
              last_child?: true
            },
            git_status: :modified,
            diagnostics: {1, 2, 3, 4},
            heat_level: 3,
            depth: 1,
            guides: [true, false],
            editing: %Editing{type: :rename, text: "renamed.txt"}
          }
        ]
      }

      cmd = FileTreeEncoder.encode_command(model)

      assert <<@op_gui_file_tree, payload_len::32, payload::binary-size(payload_len)>> = cmd
      assert payload_len == byte_size(payload)
      assert <<2::8, tree_flags::8, 3::8, rest::binary>> = payload
      assert Bitwise.band(tree_flags, 0x01) != 0
      assert Bitwise.band(tree_flags, 0x02) != 0
      assert Bitwise.band(tree_flags, 0x20) != 0

      <<selected_len::16, selected::binary-size(selected_len), rest::binary>> = rest
      assert selected == model.selected_id
      assert selected_len == byte_size(model.selected_id)

      <<root_len::16, root::binary-size(root_len), 30::16, 1::16, error_len::16,
        error_reason::binary-size(error_len), row_payload::binary>> = rest

      assert root == "/project"
      assert error_reason == ""

      [row] = model.rows
      expected_hash = :erlang.phash2(row.id, 0xFFFFFFFF)

      assert <<^expected_hash::32, row_flags::16, 1::8, 1::8, 1::16, 2::16, 3::16, 4::16, 2::8,
               1::8, 0::8, strings::binary>> = row_payload

      assert Bitwise.band(row_flags, 0x01) != 0
      assert Bitwise.band(row_flags, 0x02) != 0
      assert Bitwise.band(row_flags, 0x04) != 0
      assert Bitwise.band(row_flags, 0x08) != 0
      assert Bitwise.band(row_flags, 0x10) != 0
      assert Bitwise.band(row_flags, 0x20) != 0
      assert Bitwise.band(row_flags, 0x40) != 0
      assert Bitwise.band(row_flags, 0x80) != 0

      {id, strings} = take_string16(strings)
      {path, strings} = take_string16(strings)
      {rel_path, strings} = take_string16(strings)
      {name, strings} = take_string16(strings)
      {icon, strings} = take_string8(strings)

      <<2::8, editing_text_len::16, editing_text::binary-size(editing_text_len), 0x9B::8, 0x59::8,
        0xB6::8, 3::8>> = strings

      assert id == row.id
      assert path == row.path
      assert rel_path == "lib/ñ📄.ex"
      assert name == row.name
      assert byte_size(name) > String.length(name)
      assert icon == ""
      assert editing_text == "renamed.txt"
    end

    test "encodes editing type bytes directly" do
      for {editing, expected_type} <- [
            {%Editing{type: :new_file, text: "new.ex"}, 0},
            {%Editing{type: :new_folder, text: "src"}, 1},
            {%Editing{type: :rename, text: "renamed.ex"}, 2},
            {nil, 0xFF}
          ] do
        strings = row_strings(%{row("/project/a.ex") | editing: editing})

        {_id, strings} = take_string16(strings)
        {_path, strings} = take_string16(strings)
        {_rel_path, strings} = take_string16(strings)
        {_name, strings} = take_string16(strings)
        {_icon, strings} = take_string8(strings)

        assert <<^expected_type::8, _editing_len::16, _rest::binary>> = strings
      end
    end

    test "encodes heat-level bytes directly" do
      for {heat_level, expected_byte} <- [{0, 0}, {1, 1}, {2, 2}, {3, 3}, {4, 4}, {nil, 0xFF}] do
        strings = row_strings(%{row("/project/a.ex") | heat_level: heat_level})

        {_id, strings} = take_string16(strings)
        {_path, strings} = take_string16(strings)
        {_rel_path, strings} = take_string16(strings)
        {_name, strings} = take_string16(strings)
        {_icon, strings} = take_string8(strings)

        assert <<_editing_type::8, editing_len::16, _editing_text::binary-size(editing_len),
                 _rgb::binary-size(3), ^expected_byte::8>> = strings
      end
    end

    test "canonical writer rejects diagnostic counts outside uint16 range" do
      model = %{
        ready_tree("/project/noisy.ex")
        | rows: [%{row("/project/noisy.ex") | diagnostics: {70_000, 1, 2, 3}}],
          selected_id: "/project/noisy.ex"
      }

      assert_raise EncodingError, fn -> FileTreeEncoder.encode_command(model) end
    end

    test "encodes non-ready file-tree states without rows" do
      empty =
        FileTreeEncoder.encode_command(%FileTree{
          root_path: "/project",
          tree_width: 30,
          status: :empty
        })

      loading =
        FileTreeEncoder.encode_command(%FileTree{
          root_path: "/project",
          tree_width: 30,
          status: :loading
        })

      error =
        FileTreeEncoder.encode_command(%FileTree{
          root_path: "/project",
          tree_width: 30,
          status: {:error, "permission denied"}
        })

      assert <<@op_gui_file_tree, _::32, 2::8, empty_flags::8, 2::8, _empty_rest::binary>> = empty
      assert Bitwise.band(empty_flags, 0x01) != 0
      assert Bitwise.band(empty_flags, 0x10) != 0

      assert <<@op_gui_file_tree, _::32, 2::8, loading_flags::8, 1::8, _loading_rest::binary>> =
               loading

      assert Bitwise.band(loading_flags, 0x01) != 0
      refute Bitwise.band(loading_flags, 0x10) != 0

      assert <<@op_gui_file_tree, payload_len::32, payload::binary-size(payload_len)>> = error

      assert <<2::8, error_flags::8, 4::8, selected_len::16, _selected::binary-size(selected_len),
               root_len::16, _root::binary-size(root_len), 30::16, 0::16, reason_len::16,
               reason::binary-size(reason_len)>> = payload

      assert Bitwise.band(error_flags, 0x01) != 0
      assert reason == "permission denied"
    end

    test "encodes payloads larger than 64KB without length truncation" do
      rows =
        for index <- 1..220 do
          suffix = String.duplicate("nested-segment-", 20) <> Integer.to_string(index)

          %Row{
            id: "/project/#{suffix}.ex",
            path: "/project/#{suffix}.ex",
            name: "#{suffix}.ex",
            icon: "",
            depth: 2,
            guides: [true, false],
            flags: %Flags{last_child?: index == 220}
          }
        end

      encoded =
        FileTreeEncoder.encode_command(%FileTree{
          root_path: "/project",
          tree_width: 30,
          status: :ready,
          selected_id: hd(rows).id,
          rows: rows
        })

      assert <<@op_gui_file_tree, payload_len::32, payload::binary-size(payload_len)>> = encoded
      assert payload_len == byte_size(payload)
      assert payload_len > 65_535
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

    test "encodes selection-only command bytes for focused and unfocused trees" do
      for {focused?, expected_flags} <- [{false, 0}, {true, 1}] do
        model1 = %{ready_tree("/project/a.ex") | focused?: focused?}
        model2 = %{ready_tree("/project/b.ex") | focused?: focused?}

        {_, caches} = FileTreeEncoder.encode(model1, Caches.new())
        {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

        assert <<@op_gui_file_tree_selection, len::16, payload::binary-size(len)>> = cmd2
        assert <<^expected_flags::8, id_len::16, selected_id::binary-size(id_len)>> = payload
        assert selected_id == "/project/b.ex"
      end
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

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>), do: {value, rest}
  defp take_string8(<<len::8, value::binary-size(len), rest::binary>>), do: {value, rest}

  defp row_strings(%Row{} = row) do
    encoded =
      FileTreeEncoder.encode_command(%FileTree{
        root_path: "/project",
        tree_width: 30,
        status: :ready,
        selected_id: row.id,
        rows: [row]
      })

    assert <<@op_gui_file_tree, payload_len::32, payload::binary-size(payload_len)>> = encoded

    assert <<2::8, _tree_flags::8, 3::8, selected_len::16, _selected::binary-size(selected_len),
             root_len::16, _root::binary-size(root_len), 30::16, 1::16, 0::16, _hash::32,
             _row_flags::16, _depth::8, _git::8, _diag::binary-size(8), 0::8, strings::binary>> =
             payload

    strings
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
