defmodule MingaEditor.State.Prompt do
  @moduledoc """
  Groups prompt-related fields from EditorState.

  Tracks the current prompt handler, input text, cursor position,
  and label. Used by `MingaEditor.PromptUI` for text input prompts.
  """

  @type t :: %__MODULE__{
          handler: module() | nil,
          generation: non_neg_integer(),
          text: String.t(),
          cursor: non_neg_integer(),
          label: String.t(),
          context: map() | nil
        }

  defstruct handler: nil,
            generation: 0,
            text: "",
            cursor: 0,
            label: "",
            context: nil

  @doc "Returns true if a prompt is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{handler: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Resolves an action only for the exact opening that offered it."
  @spec resolve_activation(t(), non_neg_integer(), binary()) ::
          {:ok, :submit | :cancel} | {:error, :not_found | :stale_generation}
  def resolve_activation(%__MODULE__{handler: nil}, _generation, _item_id),
    do: {:error, :not_found}

  def resolve_activation(%__MODULE__{generation: current}, generation, _item_id)
      when current != generation or generation == 0,
      do: {:error, :stale_generation}

  def resolve_activation(%__MODULE__{}, _generation, "Submit"), do: {:ok, :submit}
  def resolve_activation(%__MODULE__{}, _generation, "Cancel"), do: {:ok, :cancel}
  def resolve_activation(%__MODULE__{}, _generation, _item_id), do: {:error, :not_found}
end
