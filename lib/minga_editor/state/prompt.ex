defmodule MingaEditor.State.Prompt do
  @moduledoc """
  Owns the prompt's input text, grapheme cursor, and display data.

  `MingaEditor.PromptUI` handles the modal lifecycle and invokes callbacks.
  """

  @type kind :: :text | :confirm

  @type t :: %__MODULE__{
          handler: module() | nil,
          kind: kind(),
          generation: non_neg_integer(),
          text: String.t(),
          cursor: non_neg_integer(),
          label: String.t(),
          context: term(),
          sensitive: boolean()
        }

  @derive {Inspect, except: [:text, :context]}
  defstruct handler: nil,
            kind: :text,
            generation: 0,
            text: "",
            cursor: 0,
            label: "",
            context: nil,
            sensitive: false

  @doc "Builds one prompt opening with a fresh activation generation."
  @spec new(kind(), module(), String.t(), keyword()) :: t()
  def new(kind, handler, label, opts) do
    default = Keyword.get(opts, :default, "")

    %__MODULE__{
      handler: handler,
      kind: kind,
      generation: Integer.mod(System.unique_integer([:positive, :monotonic]), 4_294_967_295) + 1,
      text: default,
      cursor: String.length(default),
      label: label,
      context: Keyword.get(opts, :context),
      sensitive: Keyword.get(opts, :sensitive, false)
    }
  end

  @doc "Returns true if a prompt is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{handler: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns whether input must be excluded from presentation and key history."
  @spec sensitive?(t()) :: boolean()
  def sensitive?(%__MODULE__{sensitive: sensitive}), do: sensitive

  @doc "Inserts text at the cursor, advancing it by the inserted text's own grapheme count."
  @spec insert_text(t(), String.t()) :: t()
  def insert_text(%__MODULE__{kind: :confirm} = prompt, _inserted), do: prompt

  def insert_text(%__MODULE__{} = prompt, ""), do: prompt

  def insert_text(%__MODULE__{text: text, cursor: cursor} = prompt, inserted) do
    {before, suffix} = String.split_at(text, cursor)

    # Preserve the cursor arithmetic even when concatenation joins graphemes.
    %{prompt | text: before <> inserted <> suffix, cursor: cursor + String.length(inserted)}
  end

  @doc "Moves the cursor one position left, stopping at zero."
  @spec move_left(t()) :: t()
  def move_left(%__MODULE__{cursor: cursor} = prompt),
    do: %{prompt | cursor: max(0, cursor - 1)}

  @doc "Moves the cursor one position right, capped at the current text length."
  @spec move_right(t()) :: t()
  def move_right(%__MODULE__{text: text, cursor: cursor} = prompt),
    do: %{prompt | cursor: min(String.length(text), cursor + 1)}

  @doc "Deletes the grapheme before the cursor and moves one position left."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: 0} = prompt), do: prompt

  def backspace(%__MODULE__{text: text, cursor: cursor} = prompt) do
    new_cursor = cursor - 1
    {before, remaining} = String.split_at(text, new_cursor)

    new_text =
      case String.next_grapheme_size(remaining) do
        {_size, suffix} ->
          before <> suffix

        nil ->
          # A boundary join can leave the cursor past the end. Still remove the last grapheme.
          {prefix, _last} = String.split_at(text, -1)
          prefix
      end

    %{prompt | text: new_text, cursor: new_cursor}
  end

  @doc "Deletes the grapheme at the cursor without moving it."
  @spec delete_forward(t()) :: t()
  def delete_forward(%__MODULE__{text: text, cursor: cursor} = prompt) do
    {before, remaining} = String.split_at(text, cursor)

    case String.next_grapheme_size(remaining) do
      {_size, suffix} -> %{prompt | text: before <> suffix}
      nil -> prompt
    end
  end

  @doc "Replaces changed text and moves the cursor to the end; identical text is a no-op."
  @spec replace_text(t(), String.t()) :: t()
  def replace_text(%__MODULE__{text: text} = prompt, text), do: prompt

  def replace_text(%__MODULE__{} = prompt, text),
    do: %{prompt | text: text, cursor: String.length(text)}

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

  def render_snapshot(%__MODULE__{context: nil} = prompt), do: prompt
  def render_snapshot(%__MODULE__{} = prompt), do: %{prompt | context: nil}

  @doc "Resolves an action only for the exact opening that offered it."
  @spec resolve_activation(t(), non_neg_integer(), binary()) ::
          {:ok, :submit | :cancel} | {:error, :not_found | :stale_generation}
  def resolve_activation(%__MODULE__{handler: nil}, _generation, _item_id),
    do: {:error, :not_found}

  def resolve_activation(%__MODULE__{generation: current}, generation, _item_id)
      when current != generation or generation == 0,
      do: {:error, :stale_generation}

  def resolve_activation(%__MODULE__{kind: :text}, _generation, "Submit"), do: {:ok, :submit}
  def resolve_activation(%__MODULE__{kind: :text}, _generation, "Cancel"), do: {:ok, :cancel}
  def resolve_activation(%__MODULE__{kind: :confirm}, _generation, "Yes"), do: {:ok, :submit}
  def resolve_activation(%__MODULE__{kind: :confirm}, _generation, "No"), do: {:ok, :cancel}
  def resolve_activation(%__MODULE__{}, _generation, _item_id), do: {:error, :not_found}
end
