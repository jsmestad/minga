defmodule Minga.LSP.TextEdit do
  @moduledoc """
  Applies LSP text edits to one immutable content snapshot.

  Ranges are converted with the negotiated position encoding, validated against the original content, checked for overlap, and assembled in one pass. Invalid server output never produces partial content.
  """

  alias Minga.LSP.PositionEncoding

  @enforce_keys [:start_offset, :end_offset, :new_text, :response_index]
  defstruct [:start_offset, :end_offset, :new_text, :response_index]

  @type t :: %__MODULE__{
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          new_text: String.t(),
          response_index: non_neg_integer()
        }

  @type line_meta :: %{start_offset: non_neg_integer(), text: String.t()}
  @type error :: :invalid_edit | :overlapping_edits

  @doc "Applies a list of LSP TextEdit maps to `content` using `encoding`."
  @spec apply(String.t(), [map()], PositionEncoding.encoding()) ::
          {:ok, String.t()} | {:error, error()}
  def apply(content, edits, encoding)
      when is_binary(content) and is_list(edits) and encoding in [:utf8, :utf16, :utf32] do
    lines = index_lines(content)

    with {:ok, normalized} <- normalize_all(edits, lines, encoding),
         :ok <- validate_non_overlapping(normalized) do
      {:ok, assemble(content, normalized)}
    end
  end

  @spec normalize_all([map()], tuple(), PositionEncoding.encoding()) ::
          {:ok, [t()]} | {:error, :invalid_edit}
  defp normalize_all(edits, lines, encoding) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, response_index}, {:ok, normalized} ->
      case normalize(edit, response_index, lines, encoding) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, :invalid_edit} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok, Enum.sort_by(normalized, &{&1.start_offset, &1.end_offset, &1.response_index})}

      error ->
        error
    end
  end

  @spec normalize(map(), non_neg_integer(), tuple(), PositionEncoding.encoding()) ::
          {:ok, t()} | {:error, :invalid_edit}
  defp normalize(
         %{
           "range" => %{
             "start" => %{"line" => start_line, "character" => start_character},
             "end" => %{"line" => end_line, "character" => end_character}
           },
           "newText" => new_text
         },
         response_index,
         lines,
         encoding
       )
       when is_integer(start_line) and start_line >= 0 and is_integer(start_character) and
              start_character >= 0 and is_integer(end_line) and end_line >= 0 and
              is_integer(end_character) and end_character >= 0 and is_binary(new_text) do
    with {:ok, start_offset} <- absolute_offset(lines, start_line, start_character, encoding),
         {:ok, end_offset} <- absolute_offset(lines, end_line, end_character, encoding),
         true <- start_offset <= end_offset do
      {:ok,
       %__MODULE__{
         start_offset: start_offset,
         end_offset: end_offset,
         new_text: new_text,
         response_index: response_index
       }}
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp normalize(_edit, _response_index, _lines, _encoding), do: {:error, :invalid_edit}

  @spec absolute_offset(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          PositionEncoding.encoding()
        ) ::
          {:ok, non_neg_integer()} | {:error, :invalid_edit}
  defp absolute_offset(lines, line, character, encoding) when line < tuple_size(lines) do
    %{start_offset: start_offset, text: line_text} = elem(lines, line)

    with {:ok, byte_col} <- byte_column(line_text, character, encoding) do
      {:ok, start_offset + byte_col}
    end
  end

  defp absolute_offset(_lines, _line, _character, _encoding), do: {:error, :invalid_edit}

  @spec byte_column(String.t(), non_neg_integer(), PositionEncoding.encoding()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_edit}
  defp byte_column(line, character, :utf8) when character <= byte_size(line) do
    prefix = binary_part(line, 0, character)
    if String.valid?(prefix), do: {:ok, character}, else: {:error, :invalid_edit}
  end

  defp byte_column(_line, _character, :utf8), do: {:error, :invalid_edit}
  defp byte_column(line, character, :utf32), do: walk_units(line, character, :utf32, 0)
  defp byte_column(line, character, :utf16), do: walk_units(line, character, :utf16, 0)

  @spec walk_units(String.t(), integer(), :utf16 | :utf32, non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_edit}
  defp walk_units(_line, 0, _encoding, byte_offset), do: {:ok, byte_offset}
  defp walk_units(<<>>, _remaining, _encoding, _byte_offset), do: {:error, :invalid_edit}

  defp walk_units(<<codepoint::utf8, rest::binary>>, remaining, encoding, byte_offset) do
    units = units(codepoint, encoding)

    if remaining < units do
      {:error, :invalid_edit}
    else
      bytes = byte_size(<<codepoint::utf8>>)
      walk_units(rest, remaining - units, encoding, byte_offset + bytes)
    end
  end

  @spec units(non_neg_integer(), :utf16 | :utf32) :: 1 | 2
  defp units(_codepoint, :utf32), do: 1
  defp units(codepoint, :utf16) when codepoint <= 0xFFFF, do: 1
  defp units(_codepoint, :utf16), do: 2

  @spec index_lines(String.t()) :: tuple()
  defp index_lines(content) do
    content
    |> scan_lines(content, 0, 0, [])
    |> Enum.reverse()
    |> List.to_tuple()
  end

  @spec scan_lines(binary(), String.t(), non_neg_integer(), non_neg_integer(), [line_meta()]) ::
          [line_meta()]
  defp scan_lines(<<>>, content, offset, line_start, lines) do
    [
      %{start_offset: line_start, text: binary_part(content, line_start, offset - line_start)}
      | lines
    ]
  end

  defp scan_lines(<<"\r\n", rest::binary>>, content, offset, line_start, lines) do
    line = %{
      start_offset: line_start,
      text: binary_part(content, line_start, offset - line_start)
    }

    scan_lines(rest, content, offset + 2, offset + 2, [line | lines])
  end

  defp scan_lines(<<separator, rest::binary>>, content, offset, line_start, lines)
       when separator in [?\n, ?\r] do
    line = %{
      start_offset: line_start,
      text: binary_part(content, line_start, offset - line_start)
    }

    scan_lines(rest, content, offset + 1, offset + 1, [line | lines])
  end

  defp scan_lines(<<_byte, rest::binary>>, content, offset, line_start, lines) do
    scan_lines(rest, content, offset + 1, line_start, lines)
  end

  @spec validate_non_overlapping([t()]) :: :ok | {:error, :overlapping_edits}
  defp validate_non_overlapping([]), do: :ok
  defp validate_non_overlapping([_edit]), do: :ok

  defp validate_non_overlapping([left, right | rest]) do
    if overlaps?(left, right) do
      {:error, :overlapping_edits}
    else
      validate_non_overlapping([right | rest])
    end
  end

  @spec overlaps?(t(), t()) :: boolean()
  defp overlaps?(%__MODULE__{} = left, %__MODULE__{} = right) do
    right.start_offset < left.end_offset or
      (right.start_offset == left.start_offset and left.end_offset > left.start_offset)
  end

  @spec assemble(String.t(), [t()]) :: String.t()
  defp assemble(content, edits) do
    {chunks, cursor} =
      Enum.reduce(edits, {[], 0}, fn edit, {chunks, cursor} ->
        untouched = binary_part(content, cursor, edit.start_offset - cursor)
        {[edit.new_text, untouched | chunks], edit.end_offset}
      end)

    suffix = binary_part(content, cursor, byte_size(content) - cursor)
    [suffix | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
  end
end
