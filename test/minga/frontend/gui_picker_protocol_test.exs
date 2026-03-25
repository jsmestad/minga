defmodule Minga.Frontend.GUIPickerProtocolTest do
  @moduledoc "Tests for the extended gui_picker protocol encoding (v2)."

  use ExUnit.Case, async: true

  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.UI.Picker
  alias Minga.UI.Picker.Item

  describe "encode_gui_picker/2" do
    test "encodes nil as hidden" do
      result = ProtocolGUI.encode_gui_picker(nil)
      assert <<0x77, 0>> = result
    end

    test "encodes picker with items including match_positions and annotations" do
      items = [
        %Item{
          id: :a,
          label: "config.exs",
          description: "lib/",
          icon_color: 0xFF0000,
          annotation: "SPC f f",
          match_positions: [0, 1, 2],
          two_line: true
        },
        %Item{
          id: :b,
          label: "editor.ex",
          description: "",
          icon_color: 0x00FF00,
          annotation: "",
          match_positions: [],
          two_line: false
        }
      ]

      picker = Picker.new(items, title: "Find file")
      picker = Picker.filter(picker, "con")

      binary = ProtocolGUI.encode_gui_picker(picker)

      # Should start with opcode 0x77 and visible=1
      assert <<0x77, 1, _rest::binary>> = binary
    end

    test "encodes has_preview flag" do
      items = [%Item{id: :a, label: "test.ex", description: ""}]
      picker = Picker.new(items, title: "Test")

      without_preview = ProtocolGUI.encode_gui_picker(picker, false)
      with_preview = ProtocolGUI.encode_gui_picker(picker, true)

      # Both should be valid (different has_preview byte)
      assert <<0x77, 1, _::binary>> = without_preview
      assert <<0x77, 1, _::binary>> = with_preview
      # They should differ (the has_preview byte)
      assert without_preview != with_preview
    end

    test "encodes filtered and total counts in header" do
      items = [
        %Item{id: :a, label: "README.md", description: ""},
        %Item{id: :b, label: "config.exs", description: ""},
        %Item{id: :c, label: "mix.exs", description: ""}
      ]

      picker = Picker.new(items, title: "Test")
      picker = Picker.filter(picker, "config")

      binary = ProtocolGUI.encode_gui_picker(picker)

      # Parse header: opcode(1) + visible(1) + selected(2) + filtered(2) + total(2)
      <<0x77, 1, _selected::16, filtered::16, total::16, _rest::binary>> = binary

      assert filtered == 1
      assert total == 3
    end
  end

  describe "encode_gui_picker_preview/1" do
    test "encodes nil as hidden" do
      result = ProtocolGUI.encode_gui_picker_preview(nil)
      assert <<0x7D, 0>> = result
    end

    test "encodes preview lines with styled segments" do
      lines = [
        [{"def foo do", 0xCCCCCC, false}],
        [{"  ", 0xCCCCCC, false}, {"puts", 0xFF0000, true}, {" \"hello\"", 0x00FF00, false}],
        [{"end", 0xCCCCCC, false}]
      ]

      binary = ProtocolGUI.encode_gui_picker_preview(lines)

      # Should start with opcode and visible=1 and line_count=3
      assert <<0x7D, 1, 3::16, _rest::binary>> = binary
    end

    test "encodes empty lines list as visible with 0 lines" do
      binary = ProtocolGUI.encode_gui_picker_preview([])
      assert <<0x7D, 1, 0::16>> = binary
    end
  end
end
