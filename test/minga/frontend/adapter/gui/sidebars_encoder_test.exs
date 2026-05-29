defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SidebarsEncoder
  alias Minga.RenderModel.UI.Sidebars
  alias Minga.RenderModel.UI.Sidebars.Sidebar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_sidebars Minga.Protocol.Opcodes.gui_sidebars()

  describe "encode/2" do
    test "encodes empty sidebar metadata" do
      {cmd, _caches} = SidebarsEncoder.encode(%Sidebars{}, Caches.new())

      assert <<@op_gui_sidebars, len::32, payload::binary-size(len)>> = cmd
      assert <<1::8, 0::16, 0::16>> = payload
    end

    test "matches legacy sidebar metadata wire format" do
      sidebars = [
        %{
          id: "files",
          display_name: "Files",
          semantic_kind: "file_tree",
          icon: "󰙅",
          order: 1,
          visible?: true,
          focused?: true,
          preferred_width: 32,
          badge_count: 4
        }
      ]

      model = %Sidebars{
        active_id: "files",
        sidebars: [
          %Sidebar{
            id: "files",
            display_name: "Files",
            semantic_kind: "file_tree",
            icon: "󰙅",
            order: 1,
            visible?: true,
            focused?: true,
            preferred_width: 32,
            badge_count: 4
          }
        ]
      }

      {cmd, _caches} = SidebarsEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_sidebars(sidebars, "files")
    end

    test "encodes sidebar entries" do
      model = %Sidebars{
        active_id: "files",
        sidebars: [
          %Sidebar{
            id: "files",
            display_name: "Files",
            semantic_kind: "file_tree",
            icon: "󰙅",
            order: 1,
            visible?: true,
            focused?: true
          }
        ]
      }

      {cmd, _caches} = SidebarsEncoder.encode(model, Caches.new())

      assert <<@op_gui_sidebars, len::32, payload::binary-size(len)>> = cmd

      assert <<1::8, 1::16, active_len::16, active::binary-size(active_len), rest::binary>> =
               payload

      assert active == "files"
      assert <<id_len::16, id::binary-size(id_len), _entry_rest::binary>> = rest
      assert id == "files"
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
end
