defmodule Minga.Editor.State.Prompt do
  @moduledoc """
  Groups prompt-related fields from EditorState.

  Tracks the current prompt handler, input text, cursor position,
  and label. Used by `Minga.Editor.PromptUI` for text input prompts.
  """

  @type t :: %__MODULE__{
          handler: module() | nil,
          text: String.t(),
          cursor: non_neg_integer(),
          label: String.t(),
          context: map() | nil
        }

  defstruct handler: nil,
            text: "",
            cursor: 0,
            label: "",
            context: nil

  @doc "Returns true if a prompt is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{handler: nil}), do: false
  def open?(%__MODULE__{}), do: true
end
