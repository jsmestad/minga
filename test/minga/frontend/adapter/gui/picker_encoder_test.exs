defmodule Minga.Frontend.Adapter.GUI.PickerEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.Picker.ActionMenu

  @op_gui_picker Minga.Protocol.Opcodes.gui_picker()
  @op_gui_picker_preview Minga.Protocol.Opcodes.gui_picker_preview()

  describe "encode/2" do
    test "encodes closed picker and hidden preview" do
      {cmd, _caches} = PickerEncoder.encode(%Picker{}, Caches.new())

      assert cmd == <<@op_gui_picker, 0::8, @op_gui_picker_preview, 0::8>>
    end

    # Byte-exactness against the schema-generated codec is proven by the
    # cross-language golden tests (test/support/protocol_golden.ex +
    # go/tui/internal/protocol/golden_cross_lang_test.go), which replaced the
    # former hand-written ProtocolGUI.encode_gui_picker parity oracle for this
    # family. The case below decodes the production wire format and asserts on
    # every section's decoded fields, preserving the coverage the oracle-anchored
    # test carried: header counts/title/preview flag, a flagged item with
    # match_positions, the query, an action menu, the mode prefix, an error load
    # status, and the styled preview line.
    test "encodes every picker section and the preview into the wire format" do
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
          # Wire-shaped item map as produced by the builder: flags 0b11 = 3
          # (two_line + marked), icon_color present, no nil defaulting needed.
          %{
            icon_color: 0x123456,
            flags: 3,
            label: "One",
            description: "First",
            annotation: "open",
            match_positions: [0, 2]
          }
        ],
        action_menu: %ActionMenu{actions: ["Open"], selected_index: 0},
        mode_prefix: ">",
        load_status: {:error, "boom"},
        preview_lines: [[{"hello", 0xFFFFFF, true}]]
      }

      {cmd, _caches} = PickerEncoder.encode(model, Caches.new())

      # The command is the picker payload followed by the preview payload.
      <<@op_gui_picker, 6::8, picker_rest::binary>> = cmd
      {sections, preview} = take_sections(picker_rest, 6, %{})

      # Header (0x01)
      <<1::8, selected::16, filtered::16, total::16, has_preview::8, title_len::16,
        title::binary-size(title_len), marked::16>> = sections[0x01]

      assert selected == 0
      assert filtered == 1
      assert total == 2
      assert has_preview == 1
      assert title == "Pick"
      assert marked == 1

      # Query (0x02): length-prefixed "o"
      assert <<1::16, "o">> = sections[0x02]

      # Items (0x03): one item, flags 3, icon color, match positions [0, 2]
      <<1::16, icon_color::24, flags::8, label_len::16, label::binary-size(label_len),
        desc_len::16, desc::binary-size(desc_len), ann_len::16, ann::binary-size(ann_len),
        pos_count::8, pos_rest::binary>> = sections[0x03]

      assert icon_color == 0x123456
      assert flags == 3
      assert label == "One"
      assert desc == "First"
      assert ann == "open"
      assert pos_count == 2
      assert <<0::16, 2::16>> = pos_rest

      # Action menu (0x04): visible, selected 0, one action "Open"
      assert <<1::8, 0::8, 1::8, 4::16, "Open">> = sections[0x04]

      # Mode prefix (0x05)
      assert <<1::16, ">">> = sections[0x05]

      # Load status (0x06): error (2) with message
      assert <<2::8, 4::16, "boom">> = sections[0x06]

      # Preview: visible, one line, one bold white "hello" segment.
      assert <<@op_gui_picker_preview, 1::8, 1::16, 1::8, 0xFFFFFF::24, 1::8, 5::16, "hello">> =
               preview
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
        items: [
          %{
            icon_color: 0,
            flags: 2,
            label: "One",
            description: "",
            annotation: "",
            match_positions: [0]
          }
        ],
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

  # Splits `count` self-describing sections (id:1, len:2, payload:len) off the
  # front of the picker payload, returning a section-id => payload map and the
  # trailing remainder (the gui_picker_preview command).
  defp take_sections(rest, 0, acc), do: {acc, rest}

  defp take_sections(<<id::8, len::16, payload::binary-size(len), rest::binary>>, n, acc) do
    take_sections(rest, n - 1, Map.put(acc, id, payload))
  end
end
