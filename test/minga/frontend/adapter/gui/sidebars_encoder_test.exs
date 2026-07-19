defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SidebarsEncoder
  alias Minga.RenderModel.UI.Sidebars
  alias Minga.RenderModel.UI.Sidebars.Sidebar

  @gui_sidebars_opcode Minga.Protocol.Opcodes.gui_sidebars()

  describe "encode/2" do
    test "encodes empty sidebar metadata" do
      {cmd, _caches} = SidebarsEncoder.encode(%Sidebars{}, Caches.new())

      assert <<@gui_sidebars_opcode, len::32, payload::binary-size(len)>> = cmd
      assert <<1::8, 0::16, 0::16>> = payload
    end

    test "encodes sidebar entries in canonical wire order" do
      model = %Sidebars{
        active_id: "files",
        sidebars: [
          %Sidebar{
            id: "git_status",
            display_name: "Git Status",
            semantic_kind: "git_status",
            icon: "point.3.filled.connected.trianglepath.dotted",
            order: 20,
            visible?: false,
            focused?: false,
            preferred_width: 30,
            badge_count: 7
          },
          %Sidebar{
            id: "files",
            display_name: "File Tree",
            semantic_kind: "file_tree",
            icon: "folder",
            order: 10,
            visible?: true,
            focused?: true,
            preferred_width: 32,
            badge_count: nil
          }
        ]
      }

      {cmd, _caches} = SidebarsEncoder.encode(model, Caches.new())

      assert <<@gui_sidebars_opcode, len::32, payload::binary-size(len)>> = cmd
      assert byte_size(payload) == len
      assert <<1::8, 2::16, rest::binary>> = payload

      {active_id, rest} = take_string16(rest)
      assert active_id == "files"

      {id, rest} = take_string16(rest)
      {display_name, rest} = take_string16(rest)
      {semantic_kind, rest} = take_string16(rest)
      {icon, rest} = take_string16(rest)
      assert <<10::16, flags::8, 32::16, 0xFFFF::16, rest::binary>> = rest
      assert id == "files"
      assert display_name == "File Tree"
      assert semantic_kind == "file_tree"
      assert icon == "folder"
      assert Bitwise.band(flags, 0x01) != 0
      assert Bitwise.band(flags, 0x02) != 0

      {id, rest} = take_string16(rest)
      {display_name, rest} = take_string16(rest)
      {semantic_kind, rest} = take_string16(rest)
      {icon, rest} = take_string16(rest)
      assert <<20::16, 0::8, 30::16, 7::16>> = rest
      assert id == "git_status"
      assert display_name == "Git Status"
      assert semantic_kind == "git_status"
      assert icon == "point.3.filled.connected.trianglepath.dotted"
    end

    test "returns nil on second call with same semantic data" do
      model = %Sidebars{
        active_id: "files",
        sidebars: [
          %Sidebar{id: "files", display_name: "Files", semantic_kind: "file_tree", order: 1}
        ]
      }

      {cmd1, caches} = SidebarsEncoder.encode(model, Caches.new())
      {cmd2, _caches} = SidebarsEncoder.encode(model, caches)

      assert cmd1 != nil
      assert cmd2 == nil
    end
  end

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>) do
    {value, rest}
  end
end
