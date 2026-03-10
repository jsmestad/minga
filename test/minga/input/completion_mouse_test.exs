defmodule Minga.Input.CompletionMouseTest do
  @moduledoc "Tests for mouse interaction with the completion popup."
  use ExUnit.Case, async: true

  alias Minga.Completion
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Input.Completion, as: CompletionInput
  alias Minga.Mode

  defp completion_state(items) do
    completion =
      Completion.new(items, max_visible: 10)

    %EditorState{
      port_manager: nil,
      mode: :insert,
      mode_state: Mode.initial_state(),
      viewport: %Viewport{rows: 30, cols: 80, top: 0, left: 0},
      completion: completion
    }
  end

  defp sample_items do
    [
      %{label: "append", insert_text: "append", kind: :function, sort_text: "append"},
      %{label: "apply", insert_text: "apply", kind: :function, sort_text: "apply"},
      %{label: "assert", insert_text: "assert", kind: :function, sort_text: "assert"}
    ]
  end

  describe "scroll wheel" do
    test "wheel_down moves completion selection down" do
      state = completion_state(sample_items())

      {:handled, new_state} =
        CompletionInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)

      assert new_state.completion.selected == 1
    end

    test "wheel_up moves completion selection up" do
      state = completion_state(sample_items())
      {:handled, state} = CompletionInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      {:handled, new_state} = CompletionInput.handle_mouse(state, 10, 10, :wheel_up, 0, :press, 1)
      assert new_state.completion.selected == 0
    end
  end

  describe "passthrough when inactive" do
    test "passes through when no completion is active" do
      state = %EditorState{
        port_manager: nil,
        mode: :normal,
        mode_state: Mode.initial_state(),
        viewport: %Viewport{rows: 30, cols: 80, top: 0, left: 0},
        completion: nil
      }

      {:passthrough, ^state} = CompletionInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end

    test "passes through when in normal mode even with completion" do
      state = completion_state(sample_items())
      state = %{state | mode: :normal}
      {:passthrough, ^state} = CompletionInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end
  end
end
