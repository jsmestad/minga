defmodule Minga.Input.PromptTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Prompt, as: PromptState
  alias Minga.Input.Prompt, as: InputPrompt

  defmodule TestHandler do
    @behaviour Minga.UI.Prompt.Handler

    @impl true
    def label, do: "Input: "

    @impl true
    def on_submit(text, state), do: put_in(state[:submitted], text)

    @impl true
    def on_cancel(state), do: put_in(state[:cancelled], true)
  end

  defp make_state(prompt_overrides \\ %{}) do
    prompt = struct(%PromptState{}, prompt_overrides)

    %{
      prompt_ui: prompt,
      picker_ui: %Minga.Editor.State.Picker{},
      submitted: nil,
      cancelled: nil
    }
  end

  describe "handle_key/3" do
    test "routes keys to PromptUI when prompt is active" do
      state = make_state(%{handler: TestHandler, label: "Input: ", text: "", cursor: 0})
      assert {:handled, new_state} = InputPrompt.handle_key(state, ?a, 0)
      assert new_state.prompt_ui.text == "a"
    end

    test "passes through when no prompt is active" do
      state = make_state()
      assert {:passthrough, ^state} = InputPrompt.handle_key(state, ?a, 0)
    end
  end

  describe "handle_mouse/7" do
    test "always passes through" do
      state = make_state(%{handler: TestHandler, label: "Input: ", text: "hello", cursor: 5})
      assert {:passthrough, ^state} = InputPrompt.handle_mouse(state, 10, 5, :left, 0, :press, 1)
    end
  end
end
