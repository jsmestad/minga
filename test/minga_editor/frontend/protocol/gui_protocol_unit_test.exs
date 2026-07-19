defmodule MingaEditor.Frontend.Protocol.GUIProtocolUnitTest do
  @moduledoc """
  BEAM-side encoding tests for GUI protocol commands.
  No Swift harness needed; asserts on binary structure directly.
  """
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.IndentGuides
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary

  describe "encode_gui_tab_bar/1 with group_id" do
    test "tab entry includes group_id in wire format" do
      tab = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 3}
      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      <<0x71, _active_index::8, _tab_count::8, _flags::8, _tab_id::32, group_id::16,
        _rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)

      assert group_id == 3
    end

    test "default group_id encodes as 0" do
      tab = %Tab{id: 1, kind: :file, label: "a.ex"}
      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      <<0x71, _active_index::8, _tab_count::8, _flags::8, _tab_id::32, group_id::16,
        _rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)

      assert group_id == 0
    end

    test "multiple visible tabs each carry their own group_id" do
      tab1 = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 5}
      tab2 = %Tab{id: 2, kind: :file, label: "b.ex", group_id: 5}
      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      binary = ProtocolGUI.encode_gui_tab_bar(tb)
      <<0x71, _::8, 2::8, rest::binary>> = binary

      <<_flags1::8, _id1::32, gid1::16, icon1_len::8, _icon1::binary-size(icon1_len),
        label1_len::16, _label1::binary-size(label1_len), _tint1::32, rest2::binary>> = rest

      <<_flags2::8, _id2::32, gid2::16, _rest3::binary>> = rest2

      assert gid1 == 5
      assert gid2 == 5
    end

    test "tab entry includes pinned flag and tint color bytes" do
      tab =
        TabSummary.new(
          id: 1,
          workspace_id: 3,
          kind: :file,
          label: "pinned.ex",
          path: "/tmp/pinned.ex",
          icon: "",
          pinned?: true,
          tint_color: 0x12_34_56
        )

      chrome_state = chrome_state(active_workspace_id: 3, active_tab_id: 1, visible_tabs: [tab])

      <<0x71, 0::8, 1::8, flags::8, 1::32, 3::16, icon_len::8, _icon::binary-size(icon_len),
        label_len::16, label::binary-size(label_len), tint::32>> =
        ProtocolGUI.encode_gui_tab_bar(chrome_state)

      assert Bitwise.band(flags, 0x80) == 0x80
      assert label == "pinned.ex"
      assert tint == 0x12_34_56
    end

    test "raw tab bar entry includes pinned flag and zero tint color" do
      tab = %Tab{id: 1, kind: :file, label: "pinned.ex", pinned?: true}
      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      <<0x71, 0::8, 1::8, flags::8, 1::32, 0::16, icon_len::8, _icon::binary-size(icon_len),
        label_len::16, label::binary-size(label_len), tint::32>> =
        ProtocolGUI.encode_gui_tab_bar(tb)

      assert Bitwise.band(flags, 0x80) == 0x80
      assert label == "pinned.ex"
      assert tint == 0
    end

    test "uses 255 active index when the active tab is hidden from visible tabs" do
      chrome_state = %ChromeState{
        workspaces: [
          workspace_summary(id: 0, kind: :manual, label: "Files", icon: "folder"),
          workspace_summary(id: 1, kind: :agent, label: "Agent", icon: "cpu")
        ],
        visible_tabs: [
          TabSummary.new(
            id: 1,
            workspace_id: 1,
            kind: :file,
            label: "agent.ex",
            path: "/tmp/agent.ex",
            icon: "A",
            dirty?: false,
            draft_state: :none,
            attention?: false
          )
        ],
        mode: :agent,
        active_workspace_id: 1,
        active_tab_id: 99,
        background_count: 0,
        attention_count: 0,
        draft_count: 0,
        conflict_count: 0
      }

      <<0x71, active_index::8, tab_count::8, flags::8, _id::32, _workspace::16, icon_len::8,
        _icon::binary-size(icon_len), label_len::16, _label::binary-size(label_len), _tint::32>> =
        ProtocolGUI.encode_gui_tab_bar(chrome_state)

      assert active_index == 255
      assert tab_count == 1
      assert Bitwise.band(flags, 0x01) == 0
    end

    test "agent workspace shows its agent tab and file tabs while omitting other workspaces" do
      tab1 = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 0}
      tab2 = %Tab{id: 2, kind: :agent, label: "Agent", group_id: 7}
      tab3 = %Tab{id: 3, kind: :file, label: "b.ex", group_id: 7}

      tb = %TabBar{
        tabs: [tab1, tab2, tab3],
        active_id: 2,
        next_id: 4,
        workspaces: [Workspace.new_manual(nil), Workspace.new_agent(7, "Agent")]
      }

      <<0x71, active_index::8, 2::8, rest::binary>> = ProtocolGUI.encode_gui_tab_bar(tb)
      {agent_flags, agent_id, rest} = decode_tab_header(rest)
      {_file_flags, file_id, _rest} = decode_tab_header(rest)

      assert active_index == 0
      assert Bitwise.band(agent_flags, 0x04) == 0x04
      assert agent_id == 2
      assert file_id == 3
    end
  end

  defp chrome_state(attrs) do
    %ChromeState{
      workspaces: Keyword.get(attrs, :workspaces, []),
      visible_tabs: Keyword.get(attrs, :visible_tabs, []),
      mode: Keyword.get(attrs, :mode, :editor),
      active_workspace_id: Keyword.get(attrs, :active_workspace_id, 0),
      active_tab_id: Keyword.get(attrs, :active_tab_id),
      background_count: Keyword.get(attrs, :background_count, 0),
      attention_count: Keyword.get(attrs, :attention_count, 0),
      draft_count: Keyword.get(attrs, :draft_count, 0),
      conflict_count: Keyword.get(attrs, :conflict_count, 0)
    }
  end

  defp workspace_summary(attrs) do
    WorkspaceSummary.new(
      id: Keyword.fetch!(attrs, :id),
      kind: Keyword.fetch!(attrs, :kind),
      label: Keyword.fetch!(attrs, :label),
      icon: Keyword.fetch!(attrs, :icon),
      color: Keyword.get(attrs, :color, 0),
      status: Keyword.get(attrs, :status, :idle),
      attention?: Keyword.get(attrs, :attention?, false),
      tab_count: Keyword.get(attrs, :tab_count, 0),
      draft_count: Keyword.get(attrs, :draft_count, 0),
      conflict_count: Keyword.get(attrs, :conflict_count, 0),
      running_background_count: Keyword.get(attrs, :running_background_count, 0),
      closeable?: Keyword.get(attrs, :closeable?, Keyword.get(attrs, :kind) == :agent)
    )
  end

  describe "decode_gui_action for gutter fold actions" do
    test "decodes fold toggle at line" do
      assert {:ok, {:fold_toggle_at_line, 7, 42}} ==
               ProtocolGUI.decode_gui_action(0x41, <<7::16, 42::32>>)

      assert :error == ProtocolGUI.decode_gui_action(0x41, <<42::32>>)
    end
  end

  describe "decode_gui_action for agent chat pin intents (#2654)" do
    test "decodes the two no-payload pin intents" do
      assert {:ok, :chat_scrolled_away_from_bottom} ==
               ProtocolGUI.decode_gui_action(0x5C, <<>>)

      assert {:ok, :chat_returned_to_bottom} ==
               ProtocolGUI.decode_gui_action(0x5D, <<>>)
    end

    test "rejects unexpected payload bytes" do
      assert :error == ProtocolGUI.decode_gui_action(0x5C, <<1>>)
      assert :error == ProtocolGUI.decode_gui_action(0x5D, <<1>>)
    end
  end

  describe "decode_gui_action for power and thermal state" do
    test "decodes low power and thermal tiers" do
      assert {:ok, {:power_thermal_state, false, :nominal}} ==
               ProtocolGUI.decode_gui_action(0x47, <<0, 0>>)

      assert {:ok, {:power_thermal_state, true, :fair}} ==
               ProtocolGUI.decode_gui_action(0x47, <<1, 1>>)

      assert {:ok, {:power_thermal_state, true, :serious}} ==
               ProtocolGUI.decode_gui_action(0x47, <<1, 2>>)

      assert {:ok, {:power_thermal_state, true, :critical}} ==
               ProtocolGUI.decode_gui_action(0x47, <<1, 3>>)
    end

    test "rejects invalid low power byte and preserves unknown thermal byte" do
      assert :error == ProtocolGUI.decode_gui_action(0x47, <<2, 0>>)

      assert {:ok, {:power_thermal_state, false, {:unknown, 255}}} ==
               ProtocolGUI.decode_gui_action(0x47, <<0, 255>>)
    end

    test "rejects malformed payloads" do
      assert :error == ProtocolGUI.decode_gui_action(0x47, <<0>>)
      assert :error == ProtocolGUI.decode_gui_action(0x47, <<0, 1, 2>>)
    end
  end

  describe "decode_gui_action for system_will_unmount" do
    test "decodes the unmounting volume path from a string16 payload" do
      path = "/Volumes/USB"
      payload = <<byte_size(path)::16, path::binary>>

      assert {:ok, {:system_will_unmount, ^path}} =
               ProtocolGUI.decode_gui_action(0x5A, payload)
    end

    test "rejects a payload whose declared length does not match" do
      assert :error == ProtocolGUI.decode_gui_action(0x5A, <<99::16, "short"::binary>>)
    end
  end

  describe "decode_gui_action for sidebar actions" do
    test "decodes semantic sidebar action payload" do
      id = "git_status"
      kind = "git_status"
      action = "toggle"

      payload =
        <<byte_size(id)::16, id::binary, byte_size(kind)::16, kind::binary, byte_size(action)::16,
          action::binary>>

      assert {:ok, {:sidebar_action, id, kind, action}} ==
               ProtocolGUI.decode_gui_action(0x57, payload)
    end

    test "rejects malformed semantic sidebar action payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x57, <<0, 20, "short">>)
    end
  end

  describe "decode_gui_action for observatory inspection" do
    test "decodes selected process PID" do
      pid = "#PID<0.123.0>"

      assert {:ok, {:observatory_inspect, pid}} ==
               ProtocolGUI.decode_gui_action(0x4D, <<byte_size(pid)::16, pid::binary>>)
    end

    test "rejects malformed selected process PID payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x4D, <<0, 20, "short">>)
    end
  end

  describe "decode_gui_action for float popup dismiss" do
    test "decodes an empty-payload float_popup_dismiss" do
      opcode = Minga.Protocol.Opcodes.gui_action_float_popup_dismiss()
      assert {:ok, :float_popup_dismiss} == ProtocolGUI.decode_gui_action(opcode, <<>>)
    end

    test "rejects a float_popup_dismiss carrying a payload" do
      opcode = Minga.Protocol.Opcodes.gui_action_float_popup_dismiss()
      assert :error == ProtocolGUI.decode_gui_action(opcode, <<1>>)
    end
  end

  describe "decode_gui_action for context menu actions" do
    test "decodes file tree open in split" do
      assert {:ok, {:file_tree_open_in_split, 9}} ==
               ProtocolGUI.decode_gui_action(0x3D, <<9::16>>)
    end

    test "decodes tab copy path" do
      assert {:ok, {:tab_copy_path, 42}} == ProtocolGUI.decode_gui_action(0x3E, <<42::32>>)
    end

    test "decodes tab reorder" do
      assert {:ok, {:tab_reorder, 42, 3}} ==
               ProtocolGUI.decode_gui_action(0x48, <<42::32, 3::16>>)
    end

    test "decodes id-scoped tab context actions" do
      assert {:ok, {:tab_pin, 42}} == ProtocolGUI.decode_gui_action(0x49, <<42::32>>)
      assert {:ok, {:tab_unpin, 42}} == ProtocolGUI.decode_gui_action(0x4A, <<42::32>>)
      assert {:ok, {:tab_move_left, 42}} == ProtocolGUI.decode_gui_action(0x4B, <<42::32>>)
      assert {:ok, {:tab_move_right, 42}} == ProtocolGUI.decode_gui_action(0x4C, <<42::32>>)
    end

    test "decodes hover open action" do
      assert {:ok, :hover_open_action} == ProtocolGUI.decode_gui_action(0x3F, <<>>)
    end
  end

  describe "decode_gui_action for workspace actions" do
    test "decodes workspace rename" do
      name = "My Research"
      payload = <<42::16, byte_size(name)::16, name::binary>>

      assert {:ok, {:workspace_rename, 42, "My Research"}} ==
               ProtocolGUI.decode_gui_action(0x1F, payload)
    end

    test "decodes workspace set icon" do
      icon = "brain"
      payload = <<7::16, byte_size(icon)::8, icon::binary>>

      assert {:ok, {:workspace_set_icon, 7, "brain"}} ==
               ProtocolGUI.decode_gui_action(0x20, payload)
    end

    test "decodes workspace close" do
      payload = <<3::16>>
      assert {:ok, {:workspace_close, 3}} == ProtocolGUI.decode_gui_action(0x21, payload)
    end
  end

  # ── Clipboard write (forward-compatible 0x90+ format) ──────────────────

  describe "encode_clipboard_write/2" do
    test "encodes general pasteboard write with length prefix" do
      binary = ProtocolGUI.encode_clipboard_write("hello")

      # Format: opcode(1) + payload_length(4) + target(1) + text_len(4) + text
      assert <<0x90, payload_len::32, 0::8, text_len::32, text::binary>> = binary
      assert text == "hello"
      assert text_len == 5
      assert payload_len == 1 + 4 + 5
    end

    test "encodes find pasteboard write" do
      binary = ProtocolGUI.encode_clipboard_write("search", :find)

      assert <<0x90, _payload_len::32, 1::8, text_len::32, text::binary>> = binary
      assert text == "search"
      assert text_len == 6
    end

    test "encodes empty text" do
      binary = ProtocolGUI.encode_clipboard_write("")

      assert <<0x90, payload_len::32, 0::8, 0::32>> = binary
      assert payload_len == 5
    end

    test "encodes unicode text" do
      binary = ProtocolGUI.encode_clipboard_write("日本語")

      assert <<0x90, _payload_len::32, 0::8, text_len::32, text::binary>> = binary
      assert text == "日本語"
      assert text_len == byte_size("日本語")
    end

    test "forward-compatible: starts with 0x90 and length prefix is skippable" do
      binary = ProtocolGUI.encode_clipboard_write("test")

      # Verify a decoder that doesn't know 0x90 can still skip it:
      # read opcode (1 byte), read payload_len (4 bytes), skip payload_len bytes
      <<0x90, payload_len::32, _payload::binary-size(payload_len)>> = binary
    end

    test "encodes 65,536 UTF-8 bytes without truncation" do
      text = String.duplicate("x", 65_536)

      assert <<0x90, payload_len::32, 0::8, text_len::32, ^text::binary>> =
               ProtocolGUI.encode_clipboard_write(text)

      assert text_len == 65_536
      assert payload_len == 65_541
    end
  end

  # ── Find Pasteboard gui_action decode ────────────────────────────────────

  describe "decode_gui_action for find_pasteboard_search" do
    test "decodes forward search" do
      text = "hello"
      payload = <<0::8, byte_size(text)::16, text::binary>>

      assert {:ok, {:find_pasteboard_search, "hello", 0}} ==
               ProtocolGUI.decode_gui_action(0x24, payload)
    end

    test "decodes backward search" do
      text = "world"
      payload = <<1::8, byte_size(text)::16, text::binary>>

      assert {:ok, {:find_pasteboard_search, "world", 1}} ==
               ProtocolGUI.decode_gui_action(0x24, payload)
    end
  end

  describe "WindowEncoder indent guide encoding" do
    test "encodes guides with correct opcode, window_id, and columns" do
      data = %{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 4,
        guide_cols: [2, 4],
        line_indent_levels: [1, 2, 2, 1, 0]
      }

      binary = encode_indent_guides(data)

      <<0x91, payload_len::16, win_id::16, tw::8, active_col::16, count::8, rest::binary>> =
        binary

      assert win_id == 1
      assert tw == 2
      assert active_col == 4
      assert count == 2
      # 6 (header) + 2*2 (guide cols) + 2 (line_count) + 5 (levels)
      assert payload_len == 6 + 2 * 2 + 2 + 5

      <<col1::16, col2::16, line_count::16, levels::binary>> = rest
      assert col1 == 2
      assert col2 == 4
      assert line_count == 5
      assert levels == <<1, 2, 2, 1, 0>>
    end

    test "encodes empty guide list" do
      binary =
        encode_indent_guides(%{
          window_id: 3,
          tab_width: 0,
          active_guide_col: 0xFFFF,
          guide_cols: [],
          line_indent_levels: []
        })

      <<0x91, payload_len::16, win_id::16, _tw::8, active_col::16, count::8>> = binary

      assert win_id == 3
      assert active_col == 0xFFFF
      assert count == 0
      assert payload_len == 6
    end

    test "guide columns round-trip through binary encoding" do
      cols = [4, 8, 12, 16]

      data = %{
        window_id: 2,
        tab_width: 4,
        active_guide_col: 8,
        guide_cols: cols,
        line_indent_levels: [2, 4, 4, 3, 1]
      }

      binary = encode_indent_guides(data)

      <<0x91, _len::16, _win::16, _tw::8, _active::16, count::8, rest::binary>> = binary

      col_bytes_len = count * 2
      <<col_data::binary-size(^col_bytes_len), line_count::16, levels::binary>> = rest

      decoded_cols =
        for <<col::16 <- col_data>>, do: col

      assert count == 4
      assert decoded_cols == cols
      assert line_count == 5
      assert levels == <<2, 4, 4, 3, 1>>
    end

    test "indent levels above 255 are rejected instead of clamped to fit uint8 wire format" do
      data = %{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 0xFFFF,
        guide_cols: [2],
        line_indent_levels: [300, 0, 256, 255]
      }

      error =
        assert_raise Minga.Frontend.Adapter.GUI.EncodingError, fn ->
          encode_indent_guides(data)
        end

      assert %{
               command: :gui_indent_guides,
               field: :indent_level,
               actual: 300,
               min: 0,
               max: 255
             } = error
    end
  end

  defp decode_tab_header(
         <<flags::8, id::32, _workspace::16, icon_len::8, _icon::binary-size(icon_len),
           label_len::16, _label::binary-size(label_len), _tint::32, rest::binary>>
       ) do
    {flags, id, rest}
  end

  defp encode_indent_guides(data) do
    model = %Window{
      window_id: data.window_id,
      content_kind: :buffer,
      rect: {0, 0, 1, 1},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      indent_guides: %IndentGuides{
        window_id: data.window_id,
        tab_width: data.tab_width,
        active_guide_col: data.active_guide_col,
        guide_cols: data.guide_cols,
        line_indent_levels: data.line_indent_levels
      }
    }

    Enum.find(WindowEncoder.encode(model), fn <<opcode::8, _rest::binary>> -> opcode == 0x91 end)
  end
end
