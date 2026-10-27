defmodule Minga.Buffer.Cursor do
  @moduledoc """
  Moves the document cursor while preserving valid editor caret positions.
  """

  alias Minga.Buffer.{Document, Lines}

  @type direction :: :left | :right | :up | :down

  # Where placement reads and splits content: the gap halves, or one joined copy of them.
  @typep split_source :: :halves | {:joined, String.t()}

  @max_code_point_bytes 4

  @doc "Moves the cursor one move in the requested direction."
  @spec move(Document.t(), direction()) :: Document.t()
  def move(%Document{before: ""} = doc, :left), do: doc

  def move(%Document{cursor_line: line} = doc, :left) do
    {new_before, character} = previous_character(doc.before)
    new_line = if character in ["\n", "\r\n"], do: line - 1, else: line
    new_column = Lines.last_line_width(new_before)

    %{
      doc
      | before: new_before,
        after: character <> doc.after,
        cursor_line: new_line,
        cursor_col: new_column
    }
  end

  def move(%Document{after: ""} = doc, :right), do: doc

  def move(%Document{} = doc, :right) do
    case next_character(doc.after) do
      {newline, rest} when newline in ["\n", "\r\n"] ->
        %{
          doc
          | before: doc.before <> newline,
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

  def move(%Document{cursor_line: 0} = doc, :up), do: doc

  def move(%Document{} = doc, :up), do: place(doc, {doc.cursor_line - 1, doc.cursor_col})

  def move(%Document{cursor_line: line, line_count: line_count} = doc, :down)
      when line >= line_count - 1,
      do: doc

  def move(%Document{} = doc, :down), do: place(doc, {doc.cursor_line + 1, doc.cursor_col})

  @doc "Places the cursor at the nearest valid caret position for the requested editor position."
  @spec place(Document.t(), Document.position()) :: Document.t()
  def place(%Document{} = doc, {target_line, target_column})
      when target_line >= 0 and target_column >= 0 do
    {%Document{line_count: line_count} = doc, source} = indexed(doc)
    line = min(target_line, line_count - 1)
    line_start = Lines.start_of(doc, line)
    line_length = line_stop(doc, line, line_count) - line_start
    caret_read = {line_start, caret_read_size(line_length, target_column)}
    {before, after_, column} = relocate(source, doc, caret_read, line_length, target_column)

    %{doc | before: before, after: after_, cursor_line: line, cursor_col: column}
  end

  @doc "Returns whether a byte column is an exact editor caret boundary in a line."
  @spec caret_boundary?(String.t(), non_neg_integer()) :: boolean()
  def caret_boundary?(line_text, column) when is_binary(line_text) and column >= 0,
    do: column <= byte_size(line_text) and caret_column(line_text, column) == column

  @doc "Clamps a byte column to the nearest preceding editor caret boundary in a line."
  @spec caret_column(String.t(), non_neg_integer()) :: non_neg_integer()
  def caret_column(_line_text, 0), do: 0

  def caret_column(line_text, target_column) when target_column >= byte_size(line_text) do
    byte_size(line_text)
  end

  def caret_column(line_text, target_column) do
    previous_caret_stop(line_text, target_column, 0)
  end

  @doc "Splits the character immediately before a caret from the preceding text."
  @spec previous_character(String.t()) :: {String.t(), String.t()}
  def previous_character(text) when is_binary(text) do
    text_size = byte_size(text)
    line_start = text_size - Lines.last_line_width(text)

    search_start =
      if line_start == text_size and text_size > 0, do: text_size - 1, else: line_start

    # LF separates graphemes, except that CRLF is one grapheme.
    search_start =
      if search_start > 0 and :binary.at(text, search_start) == ?\n and
           :binary.at(text, search_start - 1) == ?\r,
         do: search_start - 1,
         else: search_start

    {character_start, _size} =
      text
      |> binary_part(search_start, text_size - search_start)
      |> final_character(search_start)

    rest = binary_part(text, 0, character_start)
    character = binary_part(text, character_start, text_size - character_start)
    {rest, character}
  end

  @doc "Returns the character immediately after a caret."
  @spec next_character(String.t()) :: {String.t(), String.t()} | nil
  def next_character(text), do: String.next_grapheme(text)

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

  @spec line_stop(Document.t(), Lines.line_index(), Lines.line_count()) :: non_neg_integer()
  defp line_stop(doc, line, line_count) when line == line_count - 1,
    do: Document.content_byte_size(doc)

  defp line_stop(doc, line, _line_count), do: Lines.start_of(doc, line + 1) - 1

  # UAX #29 resolves a break from the preceding text and the code point at the boundary.
  # Read through the code point holding the requested byte, never through a truncated code point.
  @spec caret_read_size(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp caret_read_size(line_length, target_column) when target_column >= line_length, do: 0

  defp caret_read_size(line_length, target_column),
    do: min(line_length, target_column + @max_code_point_bytes)

  # A missing index is rebuilt from joined content, which placement then splits as views.
  # An empty half lets the other serve as joined content without copying.
  @spec indexed(Document.t()) :: {Document.t(), split_source()}
  defp indexed(%Document{line_offsets: nil, before: before, after: after_} = doc) do
    text = joined(before, after_)
    {%{doc | line_offsets: Lines.build_index(text)}, {:joined, text}}
  end

  defp indexed(%Document{before: before, after: ""} = doc), do: {doc, {:joined, before}}
  defp indexed(%Document{before: "", after: after_} = doc), do: {doc, {:joined, after_}}
  defp indexed(%Document{} = doc), do: {doc, :halves}

  @spec joined(String.t(), String.t()) :: String.t()
  defp joined(before, ""), do: before
  defp joined("", after_), do: after_
  defp joined(before, after_), do: IO.iodata_to_binary([before, after_])

  # A gap-crossing caret read materializes the content once and reuses it for both halves.
  # Otherwise the read is a view and the halves use one exact copy of the content.
  @spec relocate(
          split_source(),
          Document.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer()
        ) :: {String.t(), String.t(), non_neg_integer()}
  defp relocate({:joined, text}, _doc, caret_read, line_length, target_column),
    do: split_joined(text, caret_read, line_length, target_column)

  defp relocate(
         :halves,
         %Document{before: before, after: after_},
         {read_start, read_size} = caret_read,
         line_length,
         target_column
       )
       when read_start < byte_size(before) and read_start + read_size > byte_size(before) do
    text = joined(before, after_)
    split_joined(text, caret_read, line_length, target_column)
  end

  defp relocate(:halves, doc, {read_start, read_size}, line_length, target_column) do
    read = Document.slice_byte_range(doc, read_start, read_size)
    column = caret_in(read, line_length, target_column)
    {before, after_} = split_exact(doc, read_start + column)
    {before, after_, column}
  end

  @spec split_joined(
          String.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer()
        ) :: {String.t(), String.t(), non_neg_integer()}
  defp split_joined(text, {read_start, read_size}, line_length, target_column) do
    column = caret_in(binary_part(text, read_start, read_size), line_length, target_column)
    point = read_start + column
    {binary_part(text, 0, point), binary_part(text, point, byte_size(text) - point), column}
  end

  @spec caret_in(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp caret_in(_read, line_length, target_column) when target_column >= line_length,
    do: line_length

  defp caret_in(read, _line_length, target_column) do
    tail = binary_part(read, target_column + 1, byte_size(read) - target_column - 1)

    read
    |> binary_part(0, target_column + 1 + continuation_bytes(tail))
    |> caret_column(target_column)
  end

  @spec continuation_bytes(binary()) :: non_neg_integer()
  defp continuation_bytes(<<0b10::2, _::6, rest::binary>>), do: 1 + continuation_bytes(rest)
  defp continuation_bytes(_bytes), do: 0

  @spec split_exact(Document.t(), non_neg_integer()) :: {String.t(), String.t()}
  defp split_exact(%Document{before: before, after: after_}, point)
       when point == byte_size(before),
       do: {before, after_}

  defp split_exact(%Document{} = doc, point) do
    size = Document.content_byte_size(doc)
    {exact_copy(doc, 0, point), exact_copy(doc, point, size - point)}
  end

  @spec exact_copy(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  defp exact_copy(%Document{before: before} = doc, start, count)
       when start + count <= byte_size(before) or start >= byte_size(before),
       do: doc |> Document.slice_byte_range(start, count) |> :binary.copy()

  defp exact_copy(%Document{before: before, after: after_}, start, count) do
    in_before = byte_size(before) - start

    IO.iodata_to_binary([
      binary_part(before, start, in_before),
      binary_part(after_, 0, count - in_before)
    ])
  end
end
