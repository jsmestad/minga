defmodule MingaAgent.Tool.Output.LineSelection do
  @moduledoc "Bounded line selection shared by streamed disk reads and atomic in-memory owner reads."

  @chunk_bytes 64 * 1_024
  @type t :: %__MODULE__{
          chunks: [binary()],
          retained: non_neg_integer(),
          line: non_neg_integer(),
          complete: boolean()
        }
  @type result :: {binary(), non_neg_integer(), non_neg_integer() | :unknown, boolean()}
  @typep window ::
           {non_neg_integer() | nil, non_neg_integer(), non_neg_integer(), non_neg_integer(),
            boolean()}
  defstruct chunks: [], retained: 0, line: 0, complete: true

  @doc "Starts a bounded selection before the first source chunk."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Consumes one bounded chunk, retaining at most one contiguous slice rather than one allocation per line."
  @spec consume(t(), binary(), non_neg_integer(), pos_integer(), pos_integer()) :: t()
  def consume(%__MODULE__{} = selection, chunk, start, count, max_bytes)
      when is_binary(chunk) and byte_size(chunk) <= @chunk_bytes do
    window = {nil, 0, selection.retained, selection.line, selection.complete}
    {first, last, retained, line, complete} = segments(chunk, 0, start, count, max_bytes, window)

    chunks =
      if is_nil(first) or first == last,
        do: selection.chunks,
        else: [binary_part(chunk, first, last - first) | selection.chunks]

    %__MODULE__{selection | chunks: chunks, retained: retained, line: line, complete: complete}
  end

  @doc "Reports whether the requested lines or byte budget have reached a terminal boundary."
  @spec finished?(t(), non_neg_integer(), pos_integer(), pos_integer()) :: boolean()
  def finished?(
        %__MODULE__{line: line, retained: retained, complete: complete},
        start,
        count,
        max_bytes
      ),
      do: line >= start + count or (retained >= max_bytes and not complete)

  @doc "Materializes only retained chunks and reports the observed line bounds."
  @spec result(t(), non_neg_integer(), pos_integer(), boolean()) :: result()
  def result(%__MODULE__{} = selection, start, count, eof?) do
    total = if eof?, do: selection.line + 1, else: :unknown
    selected_count = min(max(selection.line + 1 - start, 0), count)
    bytes = selection.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {bytes, selected_count, total, selection.complete}
  end

  @doc "Selects from a resident binary without allocating an index or scanning the unused tail."
  @spec from_binary(binary(), non_neg_integer(), pos_integer(), pos_integer()) :: result()
  def from_binary(bytes, start, count, max_bytes) when is_binary(bytes),
    do: scan(bytes, 0, new(), start, count, max_bytes)

  defp scan(bytes, offset, selection, start, count, _max_bytes) when offset == byte_size(bytes),
    do: result(selection, start, count, true)

  defp scan(bytes, offset, selection, start, count, max_bytes) do
    size = min(@chunk_bytes, byte_size(bytes) - offset)
    next = consume(selection, binary_part(bytes, offset, size), start, count, max_bytes)

    if finished?(next, start, count, max_bytes) do
      result(next, start, count, offset + size == byte_size(bytes))
    else
      scan(bytes, offset + size, next, start, count, max_bytes)
    end
  end

  @spec segments(
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          window()
        ) :: window()
  defp segments(
         chunk,
         offset,
         start,
         count,
         max_bytes,
         {_first, _last, _retained, line, _complete} = window
       ) do
    case :binary.match(chunk, "\n", scope: {offset, byte_size(chunk) - offset}) do
      :nomatch ->
        retain(window, offset, byte_size(chunk) - offset, start, count, max_bytes)

      {newline, 1} ->
        line_length = newline - offset + selected_separator(line, start, count)

        {first, last, retained, line, complete} =
          retain(window, offset, line_length, start, count, max_bytes)

        segments(
          chunk,
          newline + 1,
          start,
          count,
          max_bytes,
          {first, last, retained, line + 1, complete}
        )
    end
  end

  @spec selected_separator(non_neg_integer(), non_neg_integer(), pos_integer()) :: 0 | 1
  defp selected_separator(line, start, count)
       when line >= start and line + 1 < start + count,
       do: 1

  defp selected_separator(_line, _start, _count), do: 0

  defp retain({first, _last, retained, line, complete}, offset, length, start, count, max_bytes)
       when line >= start and line < start + count and retained < max_bytes do
    accepted = min(length, max_bytes - retained)
    first = if is_nil(first), do: offset, else: first
    {first, offset + accepted, retained + accepted, line, complete and accepted == length}
  end

  defp retain({first, last, retained, line, _complete}, _offset, length, start, count, _max_bytes)
       when line >= start and line < start + count and length > 0,
       do: {first, last, retained, line, false}

  defp retain(window, _offset, _length, _start, _count, _max_bytes), do: window
end
