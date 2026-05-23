defmodule Minga.Buffer.LineIndex do
  @moduledoc """
  Tracks line starts and lengths for a `Document` without materializing full text.

  The index stores line lengths in small chunks. Cursor movement keeps the same index, line lookup walks chunk metadata and extracts a byte span, and edits rewrite only the chunk that contains the edit plus an adjacent chunk when a newline is deleted across a chunk boundary.
  """

  @chunk_size 256

  @enforce_keys [:line_count, :byte_size, :chunks]
  defstruct [:line_count, :byte_size, :chunks]

  @typedoc "A zero-based line number."
  @type line :: non_neg_integer()

  @typedoc "A byte span for one editor line, excluding its trailing newline."
  @type span :: {start :: non_neg_integer(), length :: non_neg_integer()}

  @typep chunk ::
           {line_count :: pos_integer(), text_bytes :: non_neg_integer(), lengths :: tuple()}

  @typedoc "Cached chunked line lengths for document text."
  @type t :: %__MODULE__{
          line_count: pos_integer(),
          byte_size: non_neg_integer(),
          chunks: [chunk()]
        }

  @doc "Builds a line index from document text."
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    lengths = lengths_from_text(text)

    %__MODULE__{
      line_count: length(lengths),
      byte_size: Kernel.byte_size(text),
      chunks: chunks_from_lengths(lengths)
    }
  end

  @doc "Returns the number of indexed editor lines."
  @spec count(t()) :: pos_integer()
  def count(%__MODULE__{line_count: count}), do: count

  @doc "Returns the total byte size of the indexed document text."
  @spec byte_size(t()) :: non_neg_integer()
  def byte_size(%__MODULE__{byte_size: size}), do: size

  @doc "Returns the content span for one editor line."
  @spec span(t(), line()) :: span() | nil
  def span(%__MODULE__{line_count: count}, line) when line >= count, do: nil

  def span(%__MODULE__{} = index, line) when line >= 0 do
    {_prefix, chunk, local_line, _suffix, chunk_start} = locate_chunk(index.chunks, line, [], 0)
    {chunk_start + local_start(chunk, local_line), chunk_length(chunk, local_line)}
  end

  @doc "Returns where one editor line starts in the document text."
  @spec start(t(), line()) :: non_neg_integer()
  def start(%__MODULE__{} = index, line) when line >= 0 and line < index.line_count do
    {start, _length} = span(index, line)
    start
  end

  @doc "Returns the byte length of one editor line without its trailing newline."
  @spec line_length(t(), line()) :: non_neg_integer()
  def line_length(%__MODULE__{} = index, line) when line >= 0 and line < index.line_count do
    {_prefix, chunk, local_line, _suffix, _chunk_start} = locate_chunk(index.chunks, line, [], 0)
    chunk_length(chunk, local_line)
  end

  @doc "Returns the document point for an editor position."
  @spec point_in(t(), line(), non_neg_integer()) :: non_neg_integer()
  def point_in(%__MODULE__{} = index, line, column) when line >= 0 and column >= 0 do
    max_line = index.line_count - 1
    clamped_line = min(line, max_line)
    point = start(index, clamped_line) + column
    min(point, index.byte_size)
  end

  @doc "Returns the editor position at a document point."
  @spec position_at(t(), non_neg_integer()) :: {line(), non_neg_integer()}
  def position_at(%__MODULE__{} = index, point) when point >= 0 do
    clamped_point = min(point, index.byte_size)
    position_in_chunks(index.chunks, clamped_point, 0, 0)
  end

  @doc "Updates the index after text is inserted into one line at a byte column."
  @spec insert_text(t(), line(), non_neg_integer(), String.t()) :: t()
  def insert_text(%__MODULE__{} = index, _line, _column, ""), do: index

  def insert_text(%__MODULE__{} = index, line, column, text)
      when line >= 0 and line < index.line_count and column >= 0 and is_binary(text) do
    :ok = validate_column(index, line, column)
    replacement = inserted_line_lengths(line_length(index, line), column, lengths_from_text(text))
    replace_line_with_lengths(index, line, replacement, Kernel.byte_size(text))
  end

  @doc "Updates the index after deleting the character before the cursor."
  @spec delete_before(t(), line(), String.t()) :: t()
  def delete_before(%__MODULE__{} = index, line, "\n") when line > 0 do
    merge_lines(index, line - 1)
  end

  def delete_before(%__MODULE__{} = index, line, removed)
      when line >= 0 and line < index.line_count and is_binary(removed) do
    adjust_line_length(index, line, -Kernel.byte_size(removed))
  end

  @doc "Updates the index after deleting the character at the cursor."
  @spec delete_at(t(), line(), String.t()) :: t()
  def delete_at(%__MODULE__{} = index, line, "\n")
      when line >= 0 and line + 1 < index.line_count do
    merge_lines(index, line)
  end

  def delete_at(%__MODULE__{} = index, line, removed)
      when line >= 0 and line < index.line_count and is_binary(removed) do
    adjust_line_length(index, line, -Kernel.byte_size(removed))
  end

  @spec adjust_line_length(t(), line(), integer()) :: t()
  defp adjust_line_length(%__MODULE__{} = index, line, 0) when line >= 0, do: index

  defp adjust_line_length(%__MODULE__{} = index, line, delta) when line >= 0 do
    {prefix, chunk, local_line, suffix, _chunk_start} = locate_chunk(index.chunks, line, [], 0)
    old_length = chunk_length(chunk, local_line)
    new_length = old_length + delta
    :ok = validate_line_length(new_length)
    new_chunk = put_chunk_length(chunk, local_line, new_length)

    %__MODULE__{
      index
      | byte_size: index.byte_size + delta,
        chunks: prefix ++ [new_chunk | suffix]
    }
  end

  @spec replace_line_with_lengths(t(), line(), [non_neg_integer()], non_neg_integer()) :: t()
  defp replace_line_with_lengths(%__MODULE__{} = index, line, replacement, inserted_bytes) do
    {prefix, {_count, _text_bytes, lengths}, local_line, suffix, _chunk_start} =
      locate_chunk(index.chunks, line, [], 0)

    {before_lengths, [_old | after_lengths]} =
      lengths |> Tuple.to_list() |> Enum.split(local_line)

    new_chunks = chunks_from_lengths(before_lengths ++ replacement ++ after_lengths)

    %__MODULE__{
      index
      | line_count: index.line_count + length(replacement) - 1,
        byte_size: index.byte_size + inserted_bytes,
        chunks: prefix ++ new_chunks ++ suffix
    }
  end

  @spec merge_lines(t(), line()) :: t()
  defp merge_lines(%__MODULE__{} = index, line) do
    {prefix, chunk, local_line, suffix, _chunk_start} = locate_chunk(index.chunks, line, [], 0)
    {new_chunks, suffix} = merged_chunks(chunk, local_line, suffix)

    %__MODULE__{
      index
      | line_count: index.line_count - 1,
        byte_size: index.byte_size - 1,
        chunks: prefix ++ new_chunks ++ suffix
    }
  end

  @spec merged_chunks(chunk(), line(), [chunk()]) :: {[chunk()], [chunk()]}
  defp merged_chunks({_count, _text_bytes, lengths}, local_line, suffix)
       when local_line + 1 < tuple_size(lengths) do
    list = Tuple.to_list(lengths)
    {before_lengths, [first, second | after_lengths]} = Enum.split(list, local_line)
    {chunks_from_lengths(before_lengths ++ [first + second] ++ after_lengths), suffix}
  end

  defp merged_chunks({_count, _text_bytes, lengths}, local_line, [next_chunk | rest_suffix]) do
    {_next_count, _next_text_bytes, next_lengths} = next_chunk
    first = elem(lengths, local_line)
    second = elem(next_lengths, 0)
    current_prefix = lengths |> Tuple.to_list() |> Enum.take(local_line)
    next_suffix = next_lengths |> Tuple.to_list() |> Enum.drop(1)
    merged_lengths = current_prefix ++ [first + second] ++ next_suffix
    {chunks_from_lengths(merged_lengths), rest_suffix}
  end

  @spec inserted_line_lengths(non_neg_integer(), non_neg_integer(), [non_neg_integer()]) :: [
          non_neg_integer()
        ]
  defp inserted_line_lengths(current_length, _column, [inserted_length]) do
    [current_length + inserted_length]
  end

  defp inserted_line_lengths(current_length, column, [first_inserted | rest_inserted]) do
    tail_length = current_length - column
    {middle_inserted, last_inserted} = split_last(rest_inserted)
    [column + first_inserted | middle_inserted] ++ [last_inserted + tail_length]
  end

  @spec split_last([non_neg_integer()]) :: {[non_neg_integer()], non_neg_integer()}
  defp split_last([last]), do: {[], last}

  defp split_last([head | rest]) do
    {middle, last} = split_last(rest)
    {[head | middle], last}
  end

  @spec locate_chunk([chunk()], line(), [chunk()], non_neg_integer()) ::
          {[chunk()], chunk(), line(), [chunk()], non_neg_integer()}
  defp locate_chunk([chunk | suffix], line, prefix, chunk_start) do
    {count, _text_bytes, _lengths} = chunk

    if line < count do
      {Enum.reverse(prefix), chunk, line, suffix, chunk_start}
    else
      locate_chunk(
        suffix,
        line - count,
        [chunk | prefix],
        chunk_start + chunk_span(chunk, suffix)
      )
    end
  end

  @spec position_in_chunks([chunk()], non_neg_integer(), line(), non_neg_integer()) ::
          {line(), non_neg_integer()}
  defp position_in_chunks([chunk], point, line_start, chunk_start) do
    position_in_chunk(chunk, point - chunk_start, line_start, 0, 0)
  end

  defp position_in_chunks([chunk | suffix], point, line_start, chunk_start) do
    next_chunk_start = chunk_start + chunk_span(chunk, suffix)

    if point < next_chunk_start do
      position_in_chunk(chunk, point - chunk_start, line_start, 0, 0)
    else
      {count, _text_bytes, _lengths} = chunk
      position_in_chunks(suffix, point, line_start + count, next_chunk_start)
    end
  end

  @spec position_in_chunk(chunk(), non_neg_integer(), line(), line(), non_neg_integer()) ::
          {line(), non_neg_integer()}
  defp position_in_chunk(
         {_count, _text_bytes, lengths} = chunk,
         point,
         base_line,
         local_line,
         local_start
       ) do
    length = elem(lengths, local_line)
    next_start = local_start + length + 1

    if local_line + 1 == tuple_size(lengths) or point < next_start do
      {base_line + local_line, min(point - local_start, length)}
    else
      position_in_chunk(chunk, point, base_line, local_line + 1, next_start)
    end
  end

  @spec local_start(chunk(), line()) :: non_neg_integer()
  defp local_start({_count, _text_bytes, lengths}, line) do
    prefix_length(lengths, line, 0, 0)
  end

  @spec prefix_length(tuple(), line(), line(), non_neg_integer()) :: non_neg_integer()
  defp prefix_length(_lengths, target, target, acc), do: acc

  defp prefix_length(lengths, target, line, acc) do
    prefix_length(lengths, target, line + 1, acc + elem(lengths, line) + 1)
  end

  @spec chunk_length(chunk(), line()) :: non_neg_integer()
  defp chunk_length({_count, _text_bytes, lengths}, line), do: elem(lengths, line)

  @spec put_chunk_length(chunk(), line(), non_neg_integer()) :: chunk()
  defp put_chunk_length({count, text_bytes, lengths}, line, new_length) do
    old_length = elem(lengths, line)
    {count, text_bytes + new_length - old_length, put_elem(lengths, line, new_length)}
  end

  @spec chunk_span(chunk(), [chunk()]) :: non_neg_integer()
  defp chunk_span({count, text_bytes, _lengths}, []), do: text_bytes + count - 1
  defp chunk_span({count, text_bytes, _lengths}, [_next | _rest]), do: text_bytes + count

  @spec chunks_from_lengths([non_neg_integer()]) :: [chunk()]
  defp chunks_from_lengths([]), do: []

  defp chunks_from_lengths(lengths) do
    lengths
    |> Enum.chunk_every(@chunk_size)
    |> Enum.map(&chunk_from_lengths/1)
  end

  @spec chunk_from_lengths([non_neg_integer()]) :: chunk()
  defp chunk_from_lengths(lengths) do
    {length(lengths), Enum.sum(lengths), List.to_tuple(lengths)}
  end

  @spec validate_column(t(), line(), non_neg_integer()) :: :ok
  defp validate_column(%__MODULE__{} = index, line, column) do
    validate_column(column <= line_length(index, line), line, column)
  end

  @spec validate_column(boolean(), line(), non_neg_integer()) :: :ok
  defp validate_column(true, _line, _column), do: :ok

  defp validate_column(false, line, column) do
    raise ArgumentError, "invalid line index column: line=#{line}, column=#{column}"
  end

  @spec validate_line_length(integer()) :: :ok
  defp validate_line_length(length) when length >= 0, do: :ok

  defp validate_line_length(length) do
    raise ArgumentError, "line index length cannot be negative: #{length}"
  end

  @spec lengths_from_text(String.t()) :: [non_neg_integer()]
  defp lengths_from_text(text) do
    do_lengths_from_matches(:binary.matches(text, "\n"), 0, Kernel.byte_size(text), [])
  end

  @spec do_lengths_from_matches(
          [{non_neg_integer(), pos_integer()}],
          non_neg_integer(),
          non_neg_integer(),
          [non_neg_integer()]
        ) :: [non_neg_integer()]
  defp do_lengths_from_matches([], start, text_size, acc) do
    Enum.reverse([text_size - start | acc])
  end

  defp do_lengths_from_matches([{newline, _length} | rest], start, text_size, acc) do
    do_lengths_from_matches(rest, newline + 1, text_size, [newline - start | acc])
  end
end
