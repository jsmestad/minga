defmodule MingaEditor.RenderModel.UI.MinibufferBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate
  alias MingaEditor.MinibufferData
  alias MingaEditor.RenderModel.UI.MinibufferBuilder

  describe "build/1" do
    test "builds hidden minibuffer when data is nil" do
      model = MinibufferBuilder.build(nil)

      assert %Minibuffer{visible?: false, candidates: []} = model
    end

    test "builds hidden minibuffer when visible is false" do
      data = %MinibufferData{visible: false}
      model = MinibufferBuilder.build(data)

      assert %Minibuffer{visible?: false, candidates: []} = model
    end

    test "builds visible minibuffer" do
      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 3,
        prompt: ":",
        input: "wq",
        context: "",
        selected_index: 0,
        candidates: [
          %{
            label: "write",
            description: "Save",
            match_score: 80,
            match_positions: [0],
            annotation: "cmd"
          }
        ],
        total_candidates: 1
      }

      model = MinibufferBuilder.build(data)

      assert %Minibuffer{visible?: true, prompt: ":", input: "wq"} = model
      assert [%Candidate{label: "write", annotation: "cmd"}] = model.candidates
    end

    test "maps generic text prompt mode" do
      data = %MinibufferData{
        visible: true,
        mode: 10,
        cursor_pos: 6,
        prompt: "Add project: ",
        input: "~/code",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      model = MinibufferBuilder.build(data)

      assert %Minibuffer{visible?: true, mode: :text_prompt, cursor_pos: 6} = model
      assert model.prompt == "Add project: "
      assert model.input == "~/code"
    end

    test "semantic model changes when input changes" do
      base = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 3,
        prompt: ":",
        input: "wq",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      model1 = MinibufferBuilder.build(base)
      model2 = MinibufferBuilder.build(%{base | input: "q!"})

      assert model1 != model2
    end
  end
end
