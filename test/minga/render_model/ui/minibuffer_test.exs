defmodule Minga.RenderModel.UI.MinibufferTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate

  describe "%Minibuffer{}" do
    test "defaults to hidden" do
      model = %Minibuffer{}

      refute model.visible?
      assert model.candidates == []
      assert model.cursor_pos == nil
    end

    test "carries visible minibuffer candidates" do
      candidate = %Candidate{label: "write", description: "Save", match_score: 99}

      model = %Minibuffer{
        visible?: true,
        mode: :command,
        cursor_pos: 1,
        prompt: ":",
        input: "w",
        candidates: [candidate],
        total_candidates: 1
      }

      assert model.visible?
      assert model.candidates == [candidate]
    end
  end
end
