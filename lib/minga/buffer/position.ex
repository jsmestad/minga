defmodule Minga.Buffer.Position do
  @moduledoc """
  Resolves editor positions into concrete places in document text.

  A position is still stored as `{line, column}` for the rest of the editor, but this module owns the translation between that editor-facing coordinate and the document's internal text point.
  """

  alias Minga.Buffer.{Document, LineIndex, Lines}

  @typedoc "A zero-indexed editor position."
  @type t :: {line :: non_neg_integer(), column :: non_neg_integer()}

  @typedoc "An absolute point in the document text."
  @type point :: non_neg_integer()

  @doc "Returns the document point for an editor position."
  @spec point_for(Document.t(), t()) :: point()
  def point_for(%Document{} = doc, {line, column})
      when line >= 0 and column >= 0 do
    point_in(doc.line_index, line, column, LineIndex.byte_size(doc.line_index))
  end

  @doc "Returns the editor position at a document point."
  @spec from_point(Document.t(), point()) :: t()
  def from_point(%Document{} = doc, point) when point >= 0 do
    LineIndex.position_at(doc.line_index, point)
  end

  @doc "Returns the document point for an editor position against an existing line index."
  @spec point_in(Lines.line_starts(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          point()
  def point_in(%LineIndex{} = line_starts, line, column, text_size)
      when line >= 0 and column >= 0 do
    line_starts |> LineIndex.point_in(line, column) |> min(text_size)
  end

  @doc "Returns the on-screen column for an editor position."
  @spec display_column(Document.t(), t()) :: non_neg_integer()
  def display_column(%Document{} = doc, {line, column}) do
    case Lines.fetch(doc, line) do
      nil -> 0
      text -> visible_steps_before(text, column)
    end
  end

  @doc "Returns the position of the last selectable character on a line."
  @spec last_character_on_line(String.t()) :: non_neg_integer()
  def last_character_on_line(""), do: 0

  def last_character_on_line(text) when is_binary(text) do
    {point, _size} = final_character(text, 0)
    point
  end

  @doc "Returns the point immediately after the character at `point`."
  @spec after_character_at(String.t(), point()) :: point()
  def after_character_at(text, point) when is_binary(text) and is_integer(point) and point >= 0 do
    text_size = byte_size(text)
    clamped_point = min(point, text_size)
    remaining = binary_part(text, clamped_point, text_size - clamped_point)

    case String.next_grapheme_size(remaining) do
      {size, _rest} -> min(clamped_point + size, text_size)
      nil -> clamped_point
    end
  end

  @spec visible_steps_before(String.t(), non_neg_integer()) :: non_neg_integer()
  defp visible_steps_before(_text, 0), do: 0

  defp visible_steps_before(text, column), do: count_visible_steps(text, column, 0, 0)

  @spec count_visible_steps(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp count_visible_steps(_text, target_column, current_column, visible_steps)
       when current_column >= target_column do
    visible_steps
  end

  defp count_visible_steps(text, target_column, current_column, visible_steps) do
    case String.next_grapheme_size(text) do
      {size, rest} ->
        count_visible_steps(rest, target_column, current_column + size, visible_steps + 1)

      nil ->
        visible_steps
    end
  end

  @spec final_character(String.t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  defp final_character(text, current_point) do
    case String.next_grapheme_size(text) do
      {size, ""} -> {current_point, size}
      {size, rest} -> final_character(rest, current_point + size)
      nil -> {current_point, 0}
    end
  end
end
