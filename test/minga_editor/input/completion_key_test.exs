defmodule MingaEditor.Input.CompletionKeyTest do
  @moduledoc "Tests for keyboard interaction with the completion popup."
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias Minga.Mode
  alias MingaEditor.Input.Completion, as: CompletionInput
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.WhichKey
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @arrow_up_legacy 0x415B1B
  @arrow_down_legacy 0x425B1B
  @arrow_up_kitty 57_352
  @arrow_down_kitty 57_353
  @arrow_up_mac 0xF700
  @arrow_down_mac 0xF701

  defp completion_state do
    completion = Completion.new(sample_items(), {0, 0})
    payload = CompletionPayload.new(:tab1, completion: completion)

    %EditorState{
      port_manager: nil,
      backend: :headless,
      shell_state: %MingaEditor.Shell.Traditional.State{
        modal: {:completion, payload},
        whichkey: %WhichKey{}
      },
      workspace: %MingaEditor.Workspace.State{
        editing: %VimState{mode: :insert, mode_state: Mode.initial_state()},
        viewport: Viewport.new(30, 80)
      }
    }
  end

  defp sample_items do
    [
      completion_item("append"),
      completion_item("apply"),
      completion_item("assert")
    ]
  end

  defp completion_item(label) do
    %{
      label: label,
      insert_text: label,
      filter_text: label,
      kind: :function,
      detail: "",
      documentation: "",
      sort_text: label,
      text_edit: nil,
      raw: nil
    }
  end

  describe "arrow keys" do
    test "kitty down/up arrows navigate completion selection" do
      state = completion_state()

      {:handled, state} = CompletionInput.handle_key(state, @arrow_down_kitty, 0)
      assert ModalOverlay.completion(state).selected == 1

      {:handled, state} = CompletionInput.handle_key(state, @arrow_up_kitty, 0)
      assert ModalOverlay.completion(state).selected == 0
    end

    test "macOS down/up arrows navigate completion selection" do
      state = completion_state()

      {:handled, state} = CompletionInput.handle_key(state, @arrow_down_mac, 0)
      assert ModalOverlay.completion(state).selected == 1

      {:handled, state} = CompletionInput.handle_key(state, @arrow_up_mac, 0)
      assert ModalOverlay.completion(state).selected == 0
    end

    test "legacy escape-sequence down/up arrows still navigate completion selection" do
      state = completion_state()

      {:handled, state} = CompletionInput.handle_key(state, @arrow_down_legacy, 0)
      assert ModalOverlay.completion(state).selected == 1

      {:handled, state} = CompletionInput.handle_key(state, @arrow_up_legacy, 0)
      assert ModalOverlay.completion(state).selected == 0
    end
  end
end
