defmodule MingaEditor.Input.PromptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Input.Prompt, as: InputPrompt
  alias MingaEditor.PromptUI
  alias MingaEditor.State, as: EditorState

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
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{}
    }
  end

  describe "handle_key/3" do
    test "routes keys to PromptUI when prompt is active" do
      state = PromptUI.open(base_state(), TestHandler)
      assert {:handled, new_state} = InputPrompt.handle_key(state, ?a, 0)

      {:prompt, %{prompt_ui: pui}} =
        MingaEditor.Shell.Runtime.state(new_state.shell_runtime).modal

      assert pui.text == "a"
    end

    test "passes through when no prompt is active" do
      state = base_state()
      assert {:passthrough, ^state} = InputPrompt.handle_key(state, ?a, 0)
    end
  end

  describe "handle_paste/2" do
    test "advances by the pasted grapheme count even when the paste joins both neighbors" do
      state = PromptUI.open(base_state(), TestHandler, default: "e👩")
      {state, nil} = PromptUI.handle_key(state, 57_350, 0)

      assert {:handled, pasted} = InputPrompt.handle_paste(state, "\u0301👩\u200D")
      assert {"Input: ", "e\u0301👩\u200D👩", 3} = PromptUI.render_data(pasted)
    end

    test "consumes empty paste without changing the active prompt" do
      state = PromptUI.open(base_state(), TestHandler, default: "ab")
      {state, nil} = PromptUI.handle_key(state, 57_350, 0)

      assert {:handled, ^state} = InputPrompt.handle_paste(state, "")
    end
  end
end
