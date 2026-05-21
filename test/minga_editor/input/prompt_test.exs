defmodule MingaEditor.Input.PromptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Input.Prompt, as: InputPrompt
  alias MingaEditor.PromptUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  defmodule TestHandler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Input: "

    @impl true
    def on_submit(text, state) do
      Process.put(:submitted, text)
      state
    end

    @impl true
    def on_cancel(state) do
      Process.put(:cancelled, true)
      state
    end
  end

  defp base_state do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)}
    }
  end

  describe "handle_key/3" do
    test "routes keys to PromptUI when prompt is active" do
      state = PromptUI.open(base_state(), TestHandler)
      assert {:handled, new_state} = InputPrompt.handle_key(state, ?a, 0)

      {:prompt, %{prompt_ui: pui}} = new_state.shell_state.modal
      assert pui.text == "a"
    end

    test "passes through when no prompt is active" do
      state = base_state()
      assert {:passthrough, ^state} = InputPrompt.handle_key(state, ?a, 0)
    end
  end

  describe "handle_mouse/7" do
    test "always passes through" do
      state = PromptUI.open(base_state(), TestHandler, default: "hello")
      assert {:passthrough, ^state} = InputPrompt.handle_mouse(state, 10, 5, :left, 0, :press, 1)
    end
  end
end
