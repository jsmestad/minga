defmodule Minga.Input.Prompt do
  @moduledoc """
  Input handler for the text input prompt overlay.

  When a prompt is active, all keys route to `PromptUI.handle_key/3`.
  The prompt is a single-line text input used by extensions for
  collecting free-form text (capture titles, rename targets, etc.).
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.PromptUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Prompt, as: PromptState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{prompt_ui: %PromptState{handler: handler}} = state, codepoint, modifiers)
      when handler != nil do
    {new_state, _action} = PromptUI.handle_key(state, codepoint, modifiers)
    {:handled, new_state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: Minga.Input.Handler.result()
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end
end
