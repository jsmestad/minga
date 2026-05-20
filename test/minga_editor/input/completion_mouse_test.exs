defmodule MingaEditor.Input.CompletionMouseTest do
  @moduledoc "Tests for mouse interaction with the completion popup."
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.WhichKey
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input.Completion, as: CompletionInput
  alias Minga.Mode

  defp completion_state(items, opts \\ []) do
    mode = Keyword.get(opts, :mode, :insert)
    completion = Completion.new(items, max_visible: 10)
    payload = CompletionPayload.new(:tab1, completion: completion)

    %EditorState{
      port_manager: nil,
      shell_state: %MingaEditor.Shell.Traditional.State{
        modal: {:completion, payload},
        whichkey: %WhichKey{}
      },
      workspace: %MingaEditor.Session.State{
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        viewport: Viewport.new(30, 80)
      }
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

      assert ModalOverlay.completion(new_state).selected == 1
    end

    test "wheel_up moves completion selection up" do
      state = completion_state(sample_items())
      {:handled, state} = CompletionInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      {:handled, new_state} = CompletionInput.handle_mouse(state, 10, 10, :wheel_up, 0, :press, 1)
      assert ModalOverlay.completion(new_state).selected == 0
    end
  end

  describe "passthrough when inactive" do
    test "passes through when no completion is active" do
      state = %EditorState{
        port_manager: nil,
        shell_state: %MingaEditor.Shell.Traditional.State{whichkey: %WhichKey{}},
        workspace: %MingaEditor.Session.State{
          editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
          viewport: Viewport.new(30, 80)
        }
      }

      {:passthrough, ^state} = CompletionInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end

    test "passes through when in normal mode even with completion" do
      state = completion_state(sample_items(), mode: :normal)
      {:passthrough, ^state} = CompletionInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end
  end
end
