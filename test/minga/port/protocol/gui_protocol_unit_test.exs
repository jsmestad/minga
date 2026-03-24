defmodule Minga.Port.Protocol.GUIProtocolUnitTest do
  @moduledoc """
  BEAM-side encoding tests for GUI protocol commands.
  No Swift harness needed; asserts on binary structure directly.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.State.AgentGroup
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
end
