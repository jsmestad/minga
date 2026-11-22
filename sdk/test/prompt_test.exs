defmodule MingaSdk.PromptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Prompt

  defmodule Handler do
    @behaviour Prompt.Handler

    @spec open_text(EditorAPI.state(), term()) :: Prompt.result()
    def open_text(state, args), do: Prompt.text(state, __MODULE__, args, label: "Title: ")

    @spec open_confirmation(EditorAPI.state(), term()) :: Prompt.result()
    def open_confirmation(state, args) do
      Prompt.confirm(state, __MODULE__, args, label: "Continue?", admission: :if_idle)
    end

    @impl true
    def on_submit(state, _text, _args), do: state

    @impl true
    def on_confirm(state, _decision, _args), do: state
  end

  test "declares prompt opening and callback contracts outside the host" do
    assert {:on_submit, 3} in Prompt.Handler.behaviour_info(:callbacks)
    assert {:on_confirm, 3} in Prompt.Handler.behaviour_info(:callbacks)
    assert {:on_cancel, 2} in Prompt.Handler.behaviour_info(:optional_callbacks)

    assert_raise RuntimeError, "minga_sdk is compile-time only", fn ->
      Handler.open_text(:editor_state, :args)
    end

    assert_raise RuntimeError, "minga_sdk is compile-time only", fn ->
      Handler.open_confirmation(:editor_state, :args)
    end
  end
end
