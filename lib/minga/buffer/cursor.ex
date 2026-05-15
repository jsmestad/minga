defmodule Minga.Buffer.Cursor do
  @moduledoc """
  Moves the document cursor while preserving valid editor caret positions.
  """

  alias Minga.Buffer.{Document, Lines}

  @type direction :: :left | :right | :up | :down

  @doc "Moves the cursor one step in the requested direction."
  @spec step(Document.t(), direction()) :: Document.t()
  def step(%Document{before: ""} = doc, :left), do: doc

  def step(%Document{cursor_line: line} = doc, :left) do
    {new_before, character} = previous_character(doc.before)
    new_line = if character == "\n", do: line - 1, else: line
    new_column = Lines.last_line_width(new_before)

    %{
      doc
      | before: new_before,
        after: character <> doc.after,
        cursor_line: new_line,
        cursor_col: new_column
    }
  end

  def step(%Document{after: ""} = doc, :right), do: doc

  def step(%Document{} = doc, :right) do
    case next_character(doc.after) do
      {"\n", rest} ->
        %{
          doc
          | before: doc.before <> "\n",
            after: rest,
            cursor_line: doc.cursor_line + 1,
            cursor_col: 0
        }

      {character, rest} ->
        %{
          doc
          | before: doc.before <> character,
            after: rest,
            cursor_col: doc.cursor_col + byte_size(character)
        }

      nil ->
        doc
    end
  end

  def step(%Document{cursor_line: 0} = doc, :up), do: doc

  def step(%Document{} = doc, :up), do: place(doc, {doc.cursor_line - 1, doc.cursor_col})

  def step(%Document{cursor_line: line, line_count: line_count} = doc, :down)
      when line >= line_count - 1,
      do: doc

  def step(%Document{} = doc, :down), do: place(doc, {doc.cursor_line + 1, doc.cursor_col})

  @doc "Places the cursor at the nearest valid caret position for the requested editor position."
  @spec place(Document.t(), Document.position()) :: Document.t()
  def place(%Document{} = doc, {target_line, target_column})
      when target_line >= 0 and target_column >= 0 do
    {line_starts, text} = Lines.snapshot(doc)
    text_size = byte_size(text)
    line = min(target_line, tuple_size(line_starts) - 1)
    {line_start, line_length} = Lines.span(line_starts, line, text_size)
    line_text = binary_part(text, line_start, line_length)
    column = target_column |> min(line_length) |> caret_column(line_text)
    point = line_start + column
    before = binary_part(text, 0, point)
    after_ = binary_part(text, point, text_size - point)

    %{
      doc
      | before: before,
        after: after_,
        cursor_line: line,
        cursor_col: column,
        line_offsets: nil
    }
  end

  @doc "Splits the character immediately before a caret from the preceding text."
  @spec previous_character(String.t()) :: {String.t(), String.t()}
  def previous_character(text) when is_binary(text) do
    text_size = byte_size(text)
    {character_start, _size} = final_character(text, 0)
    rest = binary_part(text, 0, character_start)
    character = binary_part(text, character_start, text_size - character_start)
    {rest, character}
  end

  @doc "Returns the character immediately after a caret."
  @spec next_character(String.t()) :: {String.t(), String.t()} | nil
  def next_character(text) when is_binary(text), do: String.next_grapheme(text)

  @spec caret_column(non_neg_integer(), String.t()) :: non_neg_integer()
  defp caret_column(0, _line_text), do: 0

  defp caret_column(target_column, line_text) when target_column >= byte_size(line_text) do
    byte_size(line_text)
  end

  defp caret_column(target_column, line_text) do
    previous_caret_stop(line_text, target_column, 0)
  end

  @spec previous_caret_stop(String.t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp previous_caret_stop(text, target_column, current_column) do
    case String.next_grapheme_size(text) do
      {size, _rest} when current_column + size > target_column ->
        current_column

      {size, rest} ->
        previous_caret_stop(rest, target_column, current_column + size)

      nil ->
        current_column
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
