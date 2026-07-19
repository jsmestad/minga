defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate

  @op_gui_minibuffer Minga.Protocol.Opcodes.gui_minibuffer()

  describe "encode/2" do
    test "encodes hidden minibuffer" do
      {cmd, _caches} = MinibufferEncoder.encode(%Minibuffer{}, Caches.new())

      assert cmd == <<@op_gui_minibuffer, 0::8>>
    end

    test "encodes visible command minibuffer with two candidates and total count" do
      model = %Minibuffer{
        visible?: true,
        mode: :command,
        cursor_pos: 1,
        prompt: ":",
        input: "w",
        context: "",
        selected_index: 0,
        candidates: [
          %Candidate{
            label: "write",
            description: "Save the current buffer",
            match_score: 150,
            annotation: "",
            match_positions: [0]
          },
          %Candidate{
            label: "wq",
            description: "Save and quit",
            match_score: 140,
            annotation: "",
            match_positions: [0]
          }
        ],
        total_candidates: 47
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_minibuffer, 1::8, 0::8, 1::16, 1::8, ":", 1::16, "w", 0::16, "", 0::16,
                 2::16, 47::16, 150::8, 5::16, "write", 23::16, "Save the current buffer", 0::16,
                 "", 1::8, 0::16, 140::8, 2::16, "wq", 13::16, "Save and quit", 0::16, "", 1::8,
                 0::16>>
    end

    test "encodes visible minibuffer with annotation and match positions" do
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

    test "encodes search-forward context" do
      model = %Minibuffer{
        visible?: true,
        mode: :search_forward,
        cursor_pos: 5,
        prompt: "/",
        input: "hello",
        context: "3 of 42",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_minibuffer, 1::8, 1::8, 5::16, 1::8, "/", 5::16, "hello", 7::16,
                 "3 of 42", 0::16, 0::16, 0::16>>
    end

    test "encodes text prompt mode" do
      model = %Minibuffer{
        visible?: true,
        mode: :text_prompt,
        cursor_pos: 6,
        prompt: "Add project: ",
        input: "~/code",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_minibuffer, 1::8, 10::8, 6::16, 13::8, "Add project: ", 6::16, "~/code",
                 0::16, "", 0::16, 0::16, 0::16>>
    end

    test "encodes no-cursor confirmation mode with sentinel" do
      model = %Minibuffer{
        visible?: true,
        mode: :substitute_confirm,
        cursor_pos: nil,
        prompt: "replace with foo?",
        input: "",
        context: "y/n/a/q (2 of 15)",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())

      assert cmd ==
               <<@op_gui_minibuffer, 1::8, 5::8, 0xFFFF::16, 17::8, "replace with foo?", 0::16,
                 "", 17::16, "y/n/a/q (2 of 15)", 0::16, 0::16, 0::16>>
    end

    test "encodes unicode input with byte length" do
      model = %Minibuffer{
        visible?: true,
        mode: :search_forward,
        cursor_pos: 3,
        prompt: "?",
        input: "héllo",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      {cmd, _caches} = MinibufferEncoder.encode(model, Caches.new())
      input_bytes = byte_size("héllo")

      assert <<@op_gui_minibuffer, 1::8, 1::8, 3::16, 1::8, "?", ^input_bytes::16, "héllo", 0::16,
               "", 0::16, 0::16, 0::16>> = cmd
    end

    test "raises instead of clamping an out-of-range candidate score" do
      model = %Minibuffer{
        visible?: true,
        candidates: [%Candidate{label: "overflow", match_score: 256}]
      }

      assert_raise EncodingError,
                   "cannot encode gui_minibuffer.candidate_match_score=256; expected 0..255",
                   fn -> MinibufferEncoder.encode(model, Caches.new()) end
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
