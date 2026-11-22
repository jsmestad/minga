defmodule MingaEditor.Extension.Prompt.Handler do
  @moduledoc """
  Receives a user response after the host closes a source-owned prompt.

  Implement `on_submit/3` for a text prompt and `on_confirm/3` for a confirmation.
  Text handlers may also implement `on_cancel/2`. Each callback receives the
  original arguments and returns editor state using the `MingaEditor.Extension.EditorAPI`
  contract. Replacing a prompt or unloading its source does not call the handler.
  """

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Prompt

  @doc "Receives submitted text and the arguments captured when the text prompt opened."
  @callback on_submit(EditorAPI.state(), String.t(), args :: term()) :: EditorAPI.state()

  @doc "Optionally handles cancellation of a text prompt."
  @callback on_cancel(EditorAPI.state(), args :: term()) :: EditorAPI.state()

  @doc "Receives the decision from a Yes/No confirmation."
  @callback on_confirm(EditorAPI.state(), Prompt.decision(), args :: term()) :: EditorAPI.state()

  @optional_callbacks on_submit: 3, on_cancel: 2, on_confirm: 3
end
