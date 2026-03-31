defmodule MingaEditor.Frontend.Protocol.GUIProtocolUnitTest do
  @moduledoc """
  BEAM-side encoding tests for GUI protocol commands.
  No Swift harness needed; asserts on binary structure directly.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State.AgentGroup
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

    test "multiple tabs each carry their own group_id" do
      tab1 = %Tab{id: 1, kind: :file, label: "a.ex", group_id: 0}
      tab2 = %Tab{id: 2, kind: :file, label: "b.ex", group_id: 5}
      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      binary = ProtocolGUI.encode_gui_tab_bar(tb)
      <<0x71, _::8, 2::8, rest::binary>> = binary

      <<_flags1::8, _id1::32, gid1::16, icon1_len::8, _icon1::binary-size(icon1_len),
        label1_len::16, _label1::binary-size(label1_len), rest2::binary>> = rest

      <<_flags2::8, _id2::32, gid2::16, _rest3::binary>> = rest2

      assert gid1 == 0
      assert gid2 == 5
    end
  end

  describe "encode_gui_agent_groups/1" do
    test "encodes header with group count" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "Agent")

      <<0x86, _active::16, count::8, _rest::binary>> =
        ProtocolGUI.encode_gui_agent_groups(tb)

      assert count == 1
    end

    test "agent group encodes with correct color and no kind byte" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, group} = TabBar.add_agent_group(tb, "Agent")

      binary = ProtocolGUI.encode_gui_agent_groups(tb)
      <<0x86, _active::16, 1::8, rest::binary>> = binary

      # No kind byte: id(2) + status(1) + r(1) + g(1) + b(1) + tab_count(2) + label_len(1) + label + icon_len(1) + icon
      <<agent_id::16, agent_status::8, r::8, g::8, b::8, _tc::16, label_len::8,
        label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len), _rest2::binary>> =
        rest

      assert agent_id == group.id
      assert agent_status == 0

      expected_r = Bitwise.bsr(Bitwise.band(group.color, 0xFF0000), 16)
      expected_g = Bitwise.bsr(Bitwise.band(group.color, 0x00FF00), 8)
      expected_b = Bitwise.band(group.color, 0x0000FF)
      assert r == expected_r
      assert g == expected_g
      assert b == expected_b
      assert label == "Agent"
      assert icon == "cpu"
    end

    test "icon field is encoded" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, group} = TabBar.add_agent_group(tb, "Test")
      tb = TabBar.update_group(tb, group.id, &AgentGroup.set_icon(&1, "star"))

      binary = ProtocolGUI.encode_gui_agent_groups(tb)

      <<0x86, _active::16, 1::8, _id::16, _status::8, _r::8, _g::8, _b::8, _tc::16, label_len::8,
        _label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len), _rest::binary>> =
        binary

      assert icon == "star"
    end
  end

  describe "decode_gui_action for agent group actions" do
    test "decodes agent group rename" do
      name = "My Research"
      payload = <<42::16, byte_size(name)::16, name::binary>>

      assert {:ok, {:agent_group_rename, 42, "My Research"}} ==
               ProtocolGUI.decode_gui_action(0x1F, payload)
    end

    test "decodes agent group set icon" do
      icon = "brain"
      payload = <<7::16, byte_size(icon)::8, icon::binary>>

      assert {:ok, {:agent_group_set_icon, 7, "brain"}} ==
               ProtocolGUI.decode_gui_action(0x20, payload)
    end

    test "decodes agent group close" do
      payload = <<3::16>>
      assert {:ok, {:agent_group_close, 3}} == ProtocolGUI.decode_gui_action(0x21, payload)
    end
  end

  # ── Clipboard write (forward-compatible 0x90+ format) ──────────────────

  describe "encode_clipboard_write/2" do
    test "encodes general pasteboard write with length prefix" do
      binary = ProtocolGUI.encode_clipboard_write("hello")

      # Format: opcode(1) + payload_length(2) + target(1) + text_len(2) + text
      assert <<0x90, payload_len::16, 0::8, text_len::16, text::binary>> = binary
      assert text == "hello"
      assert text_len == 5
      assert payload_len == 1 + 2 + 5
    end

    test "encodes find pasteboard write" do
      binary = ProtocolGUI.encode_clipboard_write("search", :find)

      assert <<0x90, _payload_len::16, 1::8, text_len::16, text::binary>> = binary
      assert text == "search"
      assert text_len == 6
    end

    test "encodes empty text" do
      binary = ProtocolGUI.encode_clipboard_write("")

      assert <<0x90, payload_len::16, 0::8, 0::16>> = binary
      assert payload_len == 3
    end

    test "encodes unicode text" do
      binary = ProtocolGUI.encode_clipboard_write("日本語")

      assert <<0x90, _payload_len::16, 0::8, text_len::16, text::binary>> = binary
      assert text == "日本語"
      assert text_len == byte_size("日本語")
    end

    test "forward-compatible: starts with 0x90 and length prefix is skippable" do
      binary = ProtocolGUI.encode_clipboard_write("test")

      # Verify a decoder that doesn't know 0x90 can still skip it:
      # read opcode (1 byte), read payload_len (2 bytes), skip payload_len bytes
      <<0x90, payload_len::16, _payload::binary-size(payload_len)>> = binary
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

  describe "encode_gui_indent_guides/1" do
    test "encodes guides with correct opcode, window_id, and columns" do
      data = %{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 4,
        guide_cols: [2, 4]
      }

      binary = ProtocolGUI.encode_gui_indent_guides(data)

      # 0x91 opcode, payload_len, window_id, tab_width, active_col, guide_count, cols
      <<0x91, payload_len::16, win_id::16, tw::8, active_col::16, count::8, rest::binary>> =
        binary

      assert win_id == 1
      assert tw == 2
      assert active_col == 4
      assert count == 2
      assert payload_len == 6 + 2 * 2

      <<col1::16, col2::16>> = rest
      assert col1 == 2
      assert col2 == 4
    end

    test "encodes empty guide list" do
      binary = ProtocolGUI.encode_gui_indent_guides_empty(3)

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
        guide_cols: cols
      }

      binary = ProtocolGUI.encode_gui_indent_guides(data)

      <<0x91, _len::16, _win::16, _tw::8, _active::16, count::8, col_data::binary>> = binary

      decoded_cols =
        for <<col::16 <- col_data>>, do: col

      assert count == 4
      assert decoded_cols == cols
    end
  end

  describe "encode_gui_line_spacing/1" do
    test "encodes spacing 1.2 as 120" do
      binary = ProtocolGUI.encode_gui_line_spacing(1.2)

      <<0x92, payload_len::16, spacing_encoded::16>> = binary

      assert payload_len == 2
      assert spacing_encoded == 120
    end

    test "encodes spacing 1.0 as 100" do
      <<0x92, _::16, spacing_encoded::16>> = ProtocolGUI.encode_gui_line_spacing(1.0)
      assert spacing_encoded == 100
    end

    test "encodes spacing 1.5 as 150" do
      <<0x92, _::16, spacing_encoded::16>> = ProtocolGUI.encode_gui_line_spacing(1.5)
      assert spacing_encoded == 150
    end

    test "forward-compatible: opcode + length prefix is skippable" do
      binary = ProtocolGUI.encode_gui_line_spacing(1.2)
      <<0x92, payload_len::16, _payload::binary-size(payload_len)>> = binary
    end
  end
end
