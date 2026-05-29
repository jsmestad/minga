defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.MinibufferData

  @op_gui_minibuffer Minga.Protocol.Opcodes.gui_minibuffer()

  describe "encode/2" do
    test "encodes hidden minibuffer" do
      {cmd, _caches} = MinibufferEncoder.encode(%Minibuffer{}, Caches.new())

      assert cmd == <<@op_gui_minibuffer, 0::8>>
    end

    test "matches legacy minibuffer wire format" do
      model = %Minibuffer{
        visible?: true,
        mode: :search_forward,
        cursor_pos: nil,
        prompt: "/",
        input: "term",
        context: "3 matches",
        selected_index: 1,
        candidates: [
          %Candidate{label: "term", description: "Match", match_score: 999, annotation: "line 4"}
        ],
        total_candidates: 4
      }

      legacy = %MinibufferData{
        visible: true,
        mode: 1,
        cursor_pos: 0xFFFF,
        prompt: "/",
        input: "term",
        context: "3 matches",
        selected_index: 1,
        candidates: [
          %{label: "term", description: "Match", match_score: 999, annotation: "line 4"}
        ],
        total_candidates: 4
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_minibuffer(legacy)
    end

    test "encodes visible minibuffer" do
      model = %Minibuffer{
        visible?: true,
        mode: :command,
        cursor_pos: 1,
        prompt: ":",
        input: "w",
        context: "commands",
        selected_index: 2,
        candidates: [
          %Candidate{
            label: "write",
            description: "Save",
            match_score: 80,
            annotation: "SPC f s",
            match_positions: [0, 2]
          }
        ],
        total_candidates: 9
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert <<@op_gui_minibuffer, 1::8, 0::8, 1::16, prompt_len::8,
               prompt::binary-size(prompt_len), input_len::16, input::binary-size(input_len),
               context_len::16, context::binary-size(context_len), 2::16, 1::16, 9::16, score::8,
               label_len::16, label::binary-size(label_len), desc_len::16,
               desc::binary-size(desc_len), annotation_len::16,
               annotation::binary-size(annotation_len), 2::8, 0::16, 2::16>> = cmd

      assert prompt == ":"
      assert input == "w"
      assert context == "commands"
      assert score == 80
      assert label == "write"
      assert desc == "Save"
      assert annotation == "SPC f s"
    end

    test "returns nil on second call with same semantic data" do
      model = %Minibuffer{}

      {cmd1, caches} = MinibufferEncoder.encode(model, Caches.new())
      {cmd2, _caches} = MinibufferEncoder.encode(model, caches)

      assert cmd1 != nil
      assert cmd2 == nil
    end
  end
end
