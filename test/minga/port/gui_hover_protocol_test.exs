defmodule Minga.Port.GUIHoverProtocolTest do
  @moduledoc """
  Tests for the gui_hover_popup (0x81) and gui_signature_help (0x82)
  protocol encoders.

  Verifies the binary wire format for both visible and hidden states,
  including markdown content encoding and signature parameter encoding.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.HoverPopup
  alias Minga.Editor.SignatureHelp
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  @op_gui_hover_popup 0x81
  @op_gui_signature_help 0x82

  # ── Hover Popup ──────────────────────────────────────────────────────

  describe "encode_gui_hover_popup/1" do
    test "nil encodes to hidden (2 bytes)" do
      assert <<@op_gui_hover_popup, 0>> = ProtocolGUI.encode_gui_hover_popup(nil)
    end

    test "empty content encodes to hidden" do
      popup = %HoverPopup{content_lines: [], anchor_row: 0, anchor_col: 0}
      assert <<@op_gui_hover_popup, 0>> = ProtocolGUI.encode_gui_hover_popup(popup)
    end

    test "single line plain text encodes correctly" do
      popup = %HoverPopup{
        content_lines: [{[{"hello world", :plain}], :text}],
        anchor_row: 10,
        anchor_col: 5,
        scroll_offset: 0,
        focused: false
      }

      result = ProtocolGUI.encode_gui_hover_popup(popup)

      # opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) + focused(1) +
      # scroll_offset(2) + line_count(2)
      assert <<@op_gui_hover_popup, 1, 10::16, 5::16, 0, 0::16, 1::16, rest::binary>> = result

      # line: line_type(1) + segment_count(2)
      # segment: style(1) + text_len(2) + text
      assert <<0, 1::16, 0, 11::16, "hello world">> = rest
    end

    test "focused popup sets focused byte" do
      popup = %HoverPopup{
        content_lines: [{[{"test", :plain}], :text}],
        anchor_row: 0,
        anchor_col: 0,
        scroll_offset: 3,
        focused: true
      }

      result = ProtocolGUI.encode_gui_hover_popup(popup)
      # Check focused byte and scroll offset
      assert <<@op_gui_hover_popup, 1, 0::16, 0::16, 1, 3::16, _rest::binary>> = result
    end

    test "multiple styled segments encode correctly" do
      popup = %HoverPopup{
        content_lines: [
          {[{"def ", :plain}, {"my_func", :bold}, {"(arg)", :code}], :text}
        ],
        anchor_row: 5,
        anchor_col: 0,
        scroll_offset: 0,
        focused: false
      }

      result = ProtocolGUI.encode_gui_hover_popup(popup)

      assert <<@op_gui_hover_popup, 1, 5::16, 0::16, 0, 0::16, 1::16, rest::binary>> = result

      # line_type=text(0), 3 segments
      assert <<0, 3::16, seg_data::binary>> = rest

      # segment 1: plain(0), "def "
      assert <<0, 4::16, "def ", remaining::binary>> = seg_data
      # segment 2: bold(1), "my_func"
      assert <<1, 7::16, "my_func", remaining2::binary>> = remaining
      # segment 3: code(4), "(arg)"
      assert <<4, 5::16, "(arg)">> = remaining2
    end

    test "code block line type encodes as 1" do
      popup = %HoverPopup{
        content_lines: [{[{"x = 1", {:code_content, "elixir"}}], :code}],
        anchor_row: 0,
        anchor_col: 0
      }

      result = ProtocolGUI.encode_gui_hover_popup(popup)
      # anchor_row(2) + anchor_col(2) + focused(1) + scroll_offset(2) + line_count(2) = 9 bytes
      assert <<@op_gui_hover_popup, 1, _::binary-size(9), rest::binary>> = result
      # line_type = code (1), segment_count = 1
      assert <<1, 1::16, _seg::binary>> = rest
    end
  end

  # ── Signature Help ──────────────────────────────────────────────────

  describe "encode_gui_signature_help/1" do
    test "nil encodes to hidden (2 bytes)" do
      assert <<@op_gui_signature_help, 0>> = ProtocolGUI.encode_gui_signature_help(nil)
    end

    test "empty signatures encodes to hidden" do
      sh = %SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      assert <<@op_gui_signature_help, 0>> = ProtocolGUI.encode_gui_signature_help(sh)
    end

    test "single signature with parameters encodes correctly" do
      sh = %SignatureHelp{
        signatures: [
          %{
            label: "String.split(string, pattern)",
            documentation: "Splits a string.",
            parameters: [
              %{label: "string", documentation: "The input string"},
              %{label: "pattern", documentation: "The split pattern"}
            ]
          }
        ],
        active_signature: 0,
        active_parameter: 1,
        anchor_row: 15,
        anchor_col: 8
      }

      result = ProtocolGUI.encode_gui_signature_help(sh)

      # opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) +
      # active_signature(1) + active_parameter(1) + signature_count(1)
      assert <<@op_gui_signature_help, 1, 15::16, 8::16, 0, 1, 1, rest::binary>> = result

      # signature: label_len(2) + label + doc_len(2) + doc + param_count(1)
      label = "String.split(string, pattern)"
      label_len = byte_size(label)
      doc = "Splits a string."
      doc_len = byte_size(doc)

      assert <<^label_len::16, ^label::binary-size(label_len), ^doc_len::16,
               ^doc::binary-size(doc_len), 2, params::binary>> = rest

      # param 1: label_len(2) + label + doc_len(2) + doc
      assert <<6::16, "string", 16::16, "The input string", remaining::binary>> = params
      # param 2
      assert <<7::16, "pattern", 17::16, "The split pattern">> = remaining
    end

    test "multiple signatures encode" do
      sh = %SignatureHelp{
        signatures: [
          %{label: "foo(a)", documentation: "", parameters: [%{label: "a", documentation: ""}]},
          %{label: "foo(a, b)", documentation: "", parameters: []}
        ],
        active_signature: 1,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      result = ProtocolGUI.encode_gui_signature_help(sh)
      # Check active_signature=1 and signature_count=2
      assert <<@op_gui_signature_help, 1, 0::16, 0::16, 1, 0, 2, _rest::binary>> = result
    end
  end
end
