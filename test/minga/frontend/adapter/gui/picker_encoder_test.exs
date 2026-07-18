defmodule Minga.Frontend.Adapter.GUI.PickerEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.EncodingError
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
        query_generation: 7,
        acknowledged_query_edit_seq: 11,
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

      # Query (0x02): text plus native-edit generation and acknowledgement.
      assert <<1::16, "o", 7::32, 11::32>> = sections[0x02]

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

    test "rejects oversized picker header coordinates and counts" do
      base = valid_picker()

      for field <- [:selected_index, :filtered_count, :total_count, :marked_count] do
        assert_encoding_error(Map.put(base, field, 65_536), field, 65_536, 65_535)
      end

      assert_encoding_error(
        %{base | items: List.duplicate(hd(base.items), 65_536)},
        :item_count,
        65_536,
        65_535
      )
    end

    test "rejects every oversized picker header and conditional string" do
      oversized = String.duplicate("x", 65_536)
      base = valid_picker()

      for {field, model} <- [
            title: %{base | title: oversized},
            query: %{base | query: oversized},
            mode_prefix: %{base | mode_prefix: oversized},
            load_status_message: %{base | load_status: {:error, oversized}}
          ] do
        assert_encoding_error(model, field, 65_536, 65_535)
      end
    end

    test "rejects oversized nested picker item fields and preserves all match positions" do
      base = valid_picker()
      [item] = base.items
      oversized = String.duplicate("x", 65_536)

      for {field, changed_item, actual, max} <- [
            {:item_icon_color, %{item | icon_color: 0x1000000}, 0x1000000, 0xFFFFFF},
            {:item_flags, %{item | flags: 256}, 256, 255},
            {:item_label, %{item | label: oversized}, 65_536, 65_535},
            {:item_description, %{item | description: oversized}, 65_536, 65_535},
            {:item_annotation, %{item | annotation: oversized}, 65_536, 65_535},
            {:item_match_position_count, %{item | match_positions: Enum.to_list(0..255)}, 256,
             255},
            {:item_match_position, %{item | match_positions: [65_536]}, 65_536, 65_535}
          ] do
        assert_encoding_error(%{base | items: [changed_item]}, field, actual, max)
      end
    end

    test "rejects oversized picker action menu fields" do
      base = valid_picker()
      oversized = String.duplicate("x", 65_536)

      for {field, menu, actual, max} <- [
            {:action_menu_selected_index, %ActionMenu{actions: [], selected_index: 256}, 256,
             255},
            {:action_count, %ActionMenu{actions: List.duplicate("Open", 256), selected_index: 0},
             256, 255},
            {:action_name, %ActionMenu{actions: [oversized], selected_index: 0}, 65_536, 65_535}
          ] do
        assert_encoding_error(%{base | action_menu: menu}, field, actual, max)
      end
    end
  end

  defp valid_picker do
    %Picker{
      visible?: true,
      title: "Pick",
      query: "",
      items: [
        %{
          icon_color: 0,
          flags: 0,
          label: "One",
          description: "",
          annotation: "",
          match_positions: []
        }
      ]
    }
  end

  defp assert_encoding_error(model, adapter_field, actual, max) do
    field_path = picker_schema_path(adapter_field)
    field = Enum.find(Enum.reverse(field_path), &is_atom/1)
    error = assert_raise EncodingError, fn -> PickerEncoder.encode_command(model) end

    assert %EncodingError{
             command: :gui_picker,
             field: ^field,
             field_path: ^field_path,
             actual: ^actual,
             min: 0,
             max: ^max
           } = error
  end

  defp picker_schema_path(field)
       when field in [:selected_index, :filtered_count, :total_count, :marked_count, :title],
       do: [:header, field]

  defp picker_schema_path(:item_count), do: [:items]
  defp picker_schema_path(:query), do: [:query, :text]
  defp picker_schema_path(:mode_prefix), do: [:mode_prefix, :text]
  defp picker_schema_path(:load_status_message), do: [:load_status, :message]
  defp picker_schema_path(:item_icon_color), do: [:items, 0, :icon_color]
  defp picker_schema_path(:item_flags), do: [:items, 0, :flags]
  defp picker_schema_path(:item_label), do: [:items, 0, :label]
  defp picker_schema_path(:item_description), do: [:items, 0, :description]
  defp picker_schema_path(:item_annotation), do: [:items, 0, :annotation]
  defp picker_schema_path(:item_match_position_count), do: [:items, 0, :match_positions]
  defp picker_schema_path(:item_match_position), do: [:items, 0, :match_positions, 0]
  defp picker_schema_path(:action_menu_selected_index), do: [:action_menu, :selected_index]
  defp picker_schema_path(:action_count), do: [:action_menu, :actions]
  defp picker_schema_path(:action_name), do: [:action_menu, :actions, 0]

  # Splits `count` self-describing sections (id:1, len:2, payload:len) off the
  # front of the picker payload, returning a section-id => payload map and the
  # trailing remainder (the gui_picker_preview command).
  defp take_sections(rest, 0, acc), do: {acc, rest}

  defp take_sections(<<id::8, len::16, payload::binary-size(len), rest::binary>>, n, acc) do
    take_sections(rest, n - 1, Map.put(acc, id, payload))
  end
end
