defmodule Minga.Frontend.GUIMinibufferProtocolTest do
  @moduledoc """
  Tests for the gui_minibuffer (0x7F) protocol encoder.

  Verifies the binary wire format for both visible and hidden states,
  including candidate list encoding with match positions, annotations,
  and total candidate count.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.MinibufferData
  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_minibuffer 0x7F

  describe "encode_gui_minibuffer/1" do
    test "hidden state encodes to 2 bytes" do
      data = %MinibufferData{visible: false}
      result = ProtocolGUI.encode_gui_minibuffer(data)
      assert <<@op_gui_minibuffer, 0>> = result
    end

    test "visible command mode with no candidates" do
      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 3,
        prompt: ":",
        input: "set",
        context: "",
        selected_index: 0,
        candidates: []
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)

      # Header: op(1) visible(1) mode(1) cursor_pos(2) prompt_len(1) prompt
      #         input_len(2) input context_len(2) context
      #         selected_index(2) candidate_count(2) total_candidates(2)
      assert <<@op_gui_minibuffer, 1, 0, 3::16, 1, ":", 3::16, "set", 0::16, "", 0::16, 0::16,
               0::16>> = result
    end

    test "visible search forward mode with context" do
      data = %MinibufferData{
        visible: true,
        mode: 1,
        cursor_pos: 5,
        prompt: "/",
        input: "hello",
        context: "3 of 42",
        selected_index: 0,
        candidates: []
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)

      assert <<@op_gui_minibuffer, 1, 1, 5::16, 1, "/", 5::16, "hello", 7::16, "3 of 42", 0::16,
               0::16, 0::16>> = result
    end

    test "visible command mode with candidates includes total_candidates" do
      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 1,
        prompt: ":",
        input: "w",
        context: "",
        selected_index: 0,
        candidates: [
          %{
            label: "write",
            description: "Save the current buffer",
            match_score: 150,
            match_positions: [0],
            annotation: ""
          },
          %{
            label: "wq",
            description: "Save and quit",
            match_score: 140,
            match_positions: [0],
            annotation: ""
          }
        ],
        total_candidates: 47
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)

      # candidate_count(2) = 2, total_candidates(2) = 47, then candidate data
      assert <<@op_gui_minibuffer, 1, 0, 1::16, 1, ":", 1::16, "w", 0::16, "", 0::16, 2::16,
               47::16, 150, 5::16, "write", 23::16, "Save the current buffer", 0::16, 1, 0::16,
               140, 2::16, "wq", 13::16, "Save and quit", 0::16, 1, 0::16>> = result
    end

    test "substitute confirm mode with no cursor" do
      data = %MinibufferData{
        visible: true,
        mode: 5,
        cursor_pos: 0xFFFF,
        prompt: "replace with foo?",
        input: "",
        context: "y/n/a/q (2 of 15)",
        selected_index: 0,
        candidates: []
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)

      assert <<@op_gui_minibuffer, 1, 5, 0xFFFF::16, 17, "replace with foo?", 0::16, "", 17::16,
               "y/n/a/q (2 of 15)", 0::16, 0::16, 0::16>> = result
    end

    test "match_score is clamped to 255" do
      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 0,
        prompt: ":",
        input: "",
        context: "",
        selected_index: 0,
        candidates: [
          %{label: "test", description: "", match_score: 300, match_positions: [], annotation: ""}
        ]
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)

      # After header + candidate_count(2) + total_candidates(2), score byte
      # total_candidates defaults to length(candidates) = 1
      <<@op_gui_minibuffer, 1, 0, 0::16, 1, ":", 0::16, "", 0::16, "", 0::16, 1::16, _total::16,
        score, _rest::binary>> = result

      assert score == 255
    end

    test "unicode prompt and input encode correctly" do
      data = %MinibufferData{
        visible: true,
        mode: 1,
        cursor_pos: 3,
        prompt: "?",
        input: "héllo",
        context: "",
        selected_index: 0,
        candidates: []
      }

      result = ProtocolGUI.encode_gui_minibuffer(data)
      input_bytes = byte_size("héllo")

      assert <<@op_gui_minibuffer, 1, 1, 3::16, 1, "?", ^input_bytes::16, "héllo", 0::16, "",
               0::16, 0::16, 0::16>> = result
    end
  end

  describe "decode_gui_action for minibuffer_select (0x17)" do
    test "decodes a valid candidate index" do
      assert {:ok, {:minibuffer_select, 3}} ==
               ProtocolGUI.decode_gui_action(0x17, <<3::16>>)
    end

    test "decodes index 0" do
      assert {:ok, {:minibuffer_select, 0}} ==
               ProtocolGUI.decode_gui_action(0x17, <<0::16>>)
    end

    test "decodes max uint16 index" do
      assert {:ok, {:minibuffer_select, 65_535}} ==
               ProtocolGUI.decode_gui_action(0x17, <<65_535::16>>)
    end

    test "returns error for short payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x17, <<3>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x17, <<>>)
    end
  end
end
