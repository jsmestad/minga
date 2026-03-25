defmodule Minga.UI.Prompt.Handler do
  @moduledoc """
  Behaviour for prompt handlers.

  A prompt handler provides a text input prompt to the user. Unlike the
  picker (which selects from a list), the prompt collects free-form text
  input. This is the Minga equivalent of Emacs's `read-from-minibuffer`.

  ## Callbacks

  - `label/0` — the prompt label shown before the input field (e.g., "Title: ")
  - `on_submit/2` — called when the user presses Enter; receives the input text and editor state
  - `on_cancel/1` — called when the user presses Escape; receives editor state

  ## Example

      defmodule MyCapturePrompt do
        @behaviour Minga.UI.Prompt.Handler

        @impl true
        def label, do: "Capture title: "

        @impl true
        def on_submit(text, state) do
          # Do something with the text
          state
        end

        @impl true
        def on_cancel(state), do: state
      end

  Then open it from a command:

      PromptUI.open(state, MyCapturePrompt)
      PromptUI.open(state, MyCapturePrompt, default: "pre-filled text")
  """

  alias Minga.Editor.State, as: EditorState

  @doc "Returns the label string displayed before the text input."
  @callback label() :: String.t()

  @doc "Called when the user presses Enter. Receives the input text and editor state."
  @callback on_submit(text :: String.t(), state :: EditorState.t()) :: EditorState.t()

  @doc "Called when the user presses Escape. Receives the editor state."
  @callback on_cancel(state :: EditorState.t()) :: EditorState.t()
end
