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
          context: map() | nil,
          sensitive: boolean()
        }

  @derive {Inspect, except: [:text, :context]}
  defstruct handler: nil,
            generation: 0,
            text: "",
            cursor: 0,
            label: "",
            context: nil,
            sensitive: false

  @doc "Returns true if a prompt is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{handler: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns whether input must be excluded from presentation and key history."
  @spec sensitive?(t()) :: boolean()
  def sensitive?(%__MODULE__{sensitive: sensitive}), do: sensitive

  @doc "Returns display text and its grapheme cursor without exposing sensitive input."
  @spec render_data(t()) :: {String.t(), String.t(), non_neg_integer()}
  def render_data(%__MODULE__{sensitive: true, label: label, text: text, cursor: cursor}) do
    {label, String.duplicate("•", String.length(text)), cursor}
  end

  def render_data(%__MODULE__{sensitive: false, label: label, text: text, cursor: cursor}) do
    {label, text, cursor}
  end

  @doc "Returns already-masked render text without the live input callback context."
  @spec render_snapshot(t()) :: t()
  def render_snapshot(%__MODULE__{sensitive: true} = prompt) do
    {_label, masked, _cursor} = render_data(prompt)
    %{prompt | text: masked, context: nil, sensitive: false}
  end

  def render_snapshot(%__MODULE__{} = prompt), do: prompt

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
