defmodule Minga.Buffer.EditDelta do
  @moduledoc """
  Describes a single edit applied to a buffer's content.

  Edit deltas are used for incremental content sync with the tree-sitter
  parser process. Instead of sending the entire file content after each
  change, the BEAM sends compact deltas that describe what changed and
  where. The parser applies these to its stored copy of the source and
  performs an incremental reparse.

  ## Fields

  - `start_byte` — byte offset where the edit begins
  - `old_end_byte` — byte offset where the old (removed) text ends
  - `new_end_byte` — byte offset where the new (inserted) text ends
  - `start_position` — `{line, col}` at `start_byte`
  - `old_end_position` — `{line, col}` at `old_end_byte`
  - `new_end_position` — `{line, col}` at `new_end_byte`
  - `inserted_text` — the text that was inserted (empty for pure deletions)
  """

  @enforce_keys [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]
  defstruct [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]

  @type line_range :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          old_end_byte: non_neg_integer(),
          new_end_byte: non_neg_integer(),
          start_position: {non_neg_integer(), non_neg_integer()},
          old_end_position: {non_neg_integer(), non_neg_integer()},
          new_end_position: {non_neg_integer(), non_neg_integer()},
          inserted_text: String.t()
        }

  @doc "Returns the current-coordinate line range affected by ordered deltas."
  @spec affected_line_range([t()], line_range() | nil) :: line_range() | nil
  def affected_line_range(deltas, prior_range \\ nil) when is_list(deltas) do
    Enum.reduce(deltas, prior_range, fn delta, range ->
      range
      |> transform_line_range(delta)
      |> union_line_range(delta_range(delta))
    end)
  end

  @doc "Creates a delta for an insertion at a position (no text removed)."
  @spec insertion(
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def insertion(byte_offset, {line, col}, text, {new_line, new_col}) do
    %__MODULE__{
      start_byte: byte_offset,
      old_end_byte: byte_offset,
      new_end_byte: byte_offset + byte_size(text),
      start_position: {line, col},
      old_end_position: {line, col},
      new_end_position: {new_line, new_col},
      inserted_text: text
    }
  end

  @doc "Creates a delta for a deletion at a position (no text inserted)."
  @spec deletion(
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def deletion(start_byte, old_end_byte, start_position, old_end_position) do
    %__MODULE__{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: start_byte,
      start_position: start_position,
      old_end_position: old_end_position,
      new_end_position: start_position,
      inserted_text: ""
    }
  end

  @spec transform_line_range(line_range() | nil, t()) :: line_range() | nil
  defp transform_line_range(nil, _delta), do: nil

  defp transform_line_range({_first, last} = range, %__MODULE__{start_position: {start, _}})
       when last < start,
       do: range

  defp transform_line_range(
         {first, last},
         %__MODULE__{
           old_end_position: {old_end, _},
           new_end_position: {new_end, _}
         }
       )
       when first > old_end do
    shift = new_end - old_end
    {first + shift, last + shift}
  end

  defp transform_line_range(
         {first, last},
         %__MODULE__{
           start_position: {start, _},
           old_end_position: {old_end, _},
           new_end_position: {new_end, _}
         }
       ) do
    shifted_last = if last > old_end, do: last + new_end - old_end, else: new_end
    {min(first, start), max(new_end, shifted_last)}
  end

  @spec delta_range(t()) :: line_range()
  defp delta_range(%__MODULE__{
         start_position: {start, _},
         new_end_position: {new_end, _}
       }),
       do: {start, max(start, new_end)}

  @spec union_line_range(line_range() | nil, line_range()) :: line_range()
  defp union_line_range(nil, range), do: range

  defp union_line_range({first, last}, {new_first, new_last}),
    do: {min(first, new_first), max(last, new_last)}

  @doc "Creates a delta for a replacement (text removed and text inserted)."
  @spec replacement(
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def replacement(
        start_byte,
        old_end_byte,
        start_position,
        old_end_position,
        new_text,
        new_end_position
      ) do
    %__MODULE__{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: start_byte + byte_size(new_text),
      start_position: start_position,
      old_end_position: old_end_position,
      new_end_position: new_end_position,
      inserted_text: new_text
    }
  end
end
