defmodule Minga.Port.Protocol.GUIProtocolUnitTest do
  @moduledoc """
  BEAM-side encoding tests for GUI protocol commands.
  No Swift harness needed; asserts on binary structure directly.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

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
      # Skip opcode(1) + active_index(1) + tab_count(1)
      <<0x71, _::8, 2::8, rest::binary>> = binary

      # Parse first tab: flags(1) + id(4) + group_id(2) + icon_len(1) + icon + label_len(2) + label
      <<_flags1::8, _id1::32, gid1::16, icon1_len::8, _icon1::binary-size(icon1_len),
        label1_len::16, _label1::binary-size(label1_len), rest2::binary>> = rest

      <<_flags2::8, _id2::32, gid2::16, _rest3::binary>> = rest2

      assert gid1 == 0
      assert gid2 == 5
    end
  end

  describe "encode_gui_workspace_bar/1" do
    test "encodes correct header and workspace count" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _ws} = TabBar.add_agent_workspace(tb, "Agent")

      <<0x86, active_ws_id::16, ws_count::8, _rest::binary>> =
        ProtocolGUI.encode_gui_workspace_bar(tb)

      assert active_ws_id == 0
      assert ws_count == 2
    end

    test "manual workspace encodes as kind 0" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))

      <<0x86, _::16, 1::8, _ws_id::16, kind::8, _rest::binary>> =
        ProtocolGUI.encode_gui_workspace_bar(tb)

      assert kind == 0
    end

    test "agent workspace encodes as kind 1 with correct color" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_workspace(tb, "Agent")

      binary = ProtocolGUI.encode_gui_workspace_bar(tb)
      # Skip header(3) + first workspace
      <<0x86, _active::16, 2::8, rest::binary>> = binary

      # Skip manual workspace entry (label + icon)
      <<_manual_id::16, 0::8, _manual_status::8, _mr::8, _mg::8, _mb::8, _mtc::16,
        manual_label_len::8, _manual_label::binary-size(manual_label_len),
        manual_icon_len::8, _manual_icon::binary-size(manual_icon_len), rest2::binary>> = rest

      # Parse agent workspace (label + icon)
      <<agent_id::16, agent_kind::8, agent_status::8, r::8, g::8, b::8, _tc::16, label_len::8,
        label::binary-size(label_len), icon_len::8, icon::binary-size(icon_len),
        _rest3::binary>> = rest2

      assert agent_id == ws.id
      assert agent_kind == 1
      assert agent_status == 0

      # Color should match the workspace's color
      expected_r = Bitwise.bsr(Bitwise.band(ws.color, 0xFF0000), 16)
      expected_g = Bitwise.bsr(Bitwise.band(ws.color, 0x00FF00), 8)
      expected_b = Bitwise.band(ws.color, 0x0000FF)
      assert r == expected_r
      assert g == expected_g
      assert b == expected_b
      assert label == "Agent"
      assert icon == "cpu"
    end

    test "tab_count reflects tabs in each workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, ws} = TabBar.add_agent_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, 1, ws.id)

      binary = ProtocolGUI.encode_gui_workspace_bar(tb)
      <<0x86, _active::16, 2::8, rest::binary>> = binary

      # Manual workspace: should have 1 tab (b.ex, tab id 2)
      <<_id::16, _kind::8, _status::8, _r::8, _g::8, _b::8, manual_tc::16, manual_ll::8,
        _manual_label::binary-size(manual_ll), manual_il::8,
        _manual_icon::binary-size(manual_il), rest2::binary>> = rest

      # Agent workspace: should have 1 tab (a.ex, tab id 1)
      <<_id2::16, _kind2::8, _status2::8, _r2::8, _g2::8, _b2::8, agent_tc::16,
        _rest3::binary>> = rest2

      assert manual_tc == 1
      assert agent_tc == 1
    end
  end

  describe "workspace bar encodes icon field" do
    test "icon is included in workspace entry" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))

      tb =
        TabBar.update_workspace(tb, 0, &Minga.Editor.State.Workspace.set_icon(&1, "star"))

      binary = ProtocolGUI.encode_gui_workspace_bar(tb)

      <<0x86, _active::16, 1::8, _id::16, _kind::8, _status::8, _r::8, _g::8, _b::8,
        _tc::16, label_len::8, _label::binary-size(label_len), icon_len::8,
        icon::binary-size(icon_len), _rest::binary>> = binary

      assert icon == "star"
    end
  end

  describe "decode_gui_action for workspace actions" do
    test "decodes workspace rename" do
      name = "My Research"
      payload = <<42::16, byte_size(name)::16, name::binary>>

      assert {:ok, {:workspace_rename, 42, "My Research"}} ==
               ProtocolGUI.decode_gui_action(0x1F, payload)
    end

    test "decodes workspace rename with empty name" do
      payload = <<0::16, 0::16>>
      assert {:ok, {:workspace_rename, 0, ""}} == ProtocolGUI.decode_gui_action(0x1F, payload)
    end

    test "decodes workspace set icon" do
      icon = "brain"
      payload = <<7::16, byte_size(icon)::8, icon::binary>>

      assert {:ok, {:workspace_set_icon, 7, "brain"}} ==
               ProtocolGUI.decode_gui_action(0x20, payload)
    end

    test "decodes workspace set icon with long SF Symbol name" do
      icon = "chevron.left.forwardslash.chevron.right"
      payload = <<0::16, byte_size(icon)::8, icon::binary>>
      assert {:ok, {:workspace_set_icon, 0, ^icon}} = ProtocolGUI.decode_gui_action(0x20, payload)
    end
  end
end
