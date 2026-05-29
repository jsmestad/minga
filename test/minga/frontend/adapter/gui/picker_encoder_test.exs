defmodule Minga.Frontend.Adapter.GUI.PickerEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.Picker.ActionMenu
  alias Minga.RenderModel.UI.Picker.Item
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Picker, as: LegacyPicker
  alias MingaEditor.UI.Picker.Item, as: LegacyPickerItem

  @op_gui_picker Minga.Protocol.Opcodes.gui_picker()
  @op_gui_picker_preview Minga.Protocol.Opcodes.gui_picker_preview()

  describe "encode/2" do
    test "encodes closed picker and hidden preview" do
      {cmd, _caches} = PickerEncoder.encode(%Picker{}, Caches.new())

      assert cmd == <<@op_gui_picker, 0::8, @op_gui_picker_preview, 0::8>>
    end

    test "matches legacy picker and preview wire format" do
      model = %Picker{
        visible?: true,
        title: "Pick",
        query: "o",
        selected_index: 0,
        filtered_count: 1,
        total_count: 2,
        marked_count: 1,
        has_preview?: true,
        items: [
          %Item{
            id: "one",
            label: "One",
            description: "First",
            annotation: "open",
            icon_color: 0x123456,
            two_line?: true,
            marked?: true,
            match_positions: [0, 2]
          }
        ],
        action_menu: %ActionMenu{actions: ["Open"], selected_index: 0},
        mode_prefix: ">",
        load_status: {:error, "boom"},
        preview_lines: [[{"hello", 0xFFFFFF, true}]]
      }

      legacy_item = %LegacyPickerItem{
        id: "one",
        label: "One",
        description: "First",
        annotation: "open",
        icon_color: 0x123456,
        two_line: true,
        match_positions: [0, 2]
      }

      legacy_picker = %LegacyPicker{
        items: [legacy_item, %LegacyPickerItem{id: "two", label: "Two"}],
        filtered: [legacy_item],
        title: "Pick",
        query: "o",
        selected: 0,
        marked: %{"one" => true}
      }

      {cmd, _caches} = PickerEncoder.encode(model, Caches.new())

      assert cmd ==
               IO.iodata_to_binary([
                 ProtocolGUI.encode_gui_picker(
                   legacy_picker,
                   true,
                   {[{"Open", :open}], 0},
                   100,
                   ">",
                   {:error, "boom"}
                 ),
                 ProtocolGUI.encode_gui_picker_preview([[{"hello", 0xFFFFFF, true}]])
               ])
    end

    test "encodes open picker with action menu and preview" do
      model = %Picker{
        visible?: true,
        title: "Pick",
        query: "o",
        selected_index: 0,
        filtered_count: 1,
        total_count: 2,
        marked_count: 1,
        has_preview?: true,
        items: [%Item{id: "one", label: "One", marked?: true, match_positions: [0]}],
        action_menu: %ActionMenu{actions: ["open"], selected_index: 0},
        mode_prefix: ">",
        preview_lines: [[{"hello", 0xFFFFFF, true}]]
      }

      {cmd, _caches} = PickerEncoder.encode(model, Caches.new())

      assert <<@op_gui_picker, 6::8, _picker_sections::binary>> =
               binary_part(cmd, 0, byte_size(cmd) - 2)

      assert :binary.match(cmd, <<@op_gui_picker_preview, 1::8>>) != :nomatch
    end

    test "returns nil on second call with same semantic data" do
      model = %Picker{}

      {cmd1, caches} = PickerEncoder.encode(model, Caches.new())
      {cmd2, _caches} = PickerEncoder.encode(model, caches)

      assert cmd1 != nil
      assert cmd2 == nil
    end
  end
end
