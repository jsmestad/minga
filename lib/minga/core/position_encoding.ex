defmodule Minga.Core.PositionEncoding do
  @moduledoc """
  Converts between byte-indexed positions and external text position encodings.

  Minga stores positions as `{line, byte_col}` where `byte_col` is a byte offset within the line. Some external protocols, including LSP, use UTF-16 or UTF-32 character offsets instead. This module keeps that conversion pure so Layer 0 data structures can translate ranges without depending on stateful LSP services.
  """

  @typedoc "An external offset encoding for character positions."
  @type encoding :: :utf8 | :utf16 | :utf32

  @typedoc "A zero-indexed line and byte-column position."
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

  @doc """
  Negotiates the best offset encoding from a supported list.

  Prefers UTF-8, then UTF-16, then UTF-32. Falls back to UTF-16 when the server or external source does not advertise support.
  """
  @spec negotiate([String.t()]) :: encoding()
  def negotiate(server_encodings) when is_list(server_encodings) do
    preference = [:utf8, :utf16, :utf32]

    normalized =
      server_encodings
      |> Enum.map(&normalize_encoding/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.find(preference, :utf16, fn enc -> MapSet.member?(normalized, enc) end)
  end

  @doc "Returns the supported encoding strings in client preference order."
  @spec client_supported_encodings() :: [String.t()]
  def client_supported_encodings do
    ["utf-8", "utf-32", "utf-16"]
  end

  @doc "Converts a byte-column position to an external position map."
  @spec to_lsp(position(), String.t(), encoding()) :: map()
  def to_lsp({line, byte_col}, line_text, encoding)
      when is_integer(line) and is_integer(byte_col) and is_binary(line_text) do
    character = byte_col_to_lsp(byte_col, line_text, encoding)
    %{"line" => line, "character" => character}
  end

  @doc "Converts an external position map back to a byte-column position."
  @spec from_lsp(map(), String.t(), encoding()) :: position()
  def from_lsp(%{"line" => line, "character" => character}, line_text, encoding)
      when is_integer(line) and is_integer(character) and is_binary(line_text) do
    byte_col = lsp_to_byte_col(character, line_text, encoding)
    {line, byte_col}
  end

  @doc "Converts an exact external column to a byte column without clamping invalid positions."
  @spec exact_byte_column(String.t(), non_neg_integer(), encoding()) ::
          {:ok, non_neg_integer()} | {:error, :column_out_of_range | :column_not_boundary}
  def exact_byte_column(line_text, column, encoding)
      when is_binary(line_text) and is_integer(column) and column >= 0 and
             encoding in [:utf8, :utf16, :utf32] do
    exact_byte_column_for_encoding(line_text, column, encoding)
  end

  @spec exact_byte_column_for_encoding(String.t(), non_neg_integer(), encoding()) ::
          {:ok, non_neg_integer()} | {:error, :column_out_of_range | :column_not_boundary}
  defp exact_byte_column_for_encoding(line_text, column, :utf8) do
    if column <= byte_size(line_text) and utf8_boundary?(line_text, column),
      do: {:ok, column},
      else: exact_utf8_error(line_text, column)
  end

  defp exact_byte_column_for_encoding(line_text, column, :utf32),
    do: exact_codepoint_column(line_text, column, 0)

  defp exact_byte_column_for_encoding(line_text, column, :utf16),
    do: exact_utf16_column(line_text, column, 0)

  @spec exact_utf8_error(String.t(), non_neg_integer()) ::
          {:error, :column_out_of_range | :column_not_boundary}
  defp exact_utf8_error(line_text, column) when column > byte_size(line_text),
    do: {:error, :column_out_of_range}

  defp exact_utf8_error(_line_text, _column), do: {:error, :column_not_boundary}

  @spec utf8_boundary?(String.t(), non_neg_integer()) :: boolean()
  defp utf8_boundary?(_line_text, 0), do: true

  defp utf8_boundary?(line_text, column) when column == byte_size(line_text), do: true

  defp utf8_boundary?(line_text, column) do
    <<_prefix::binary-size(^column), byte, _rest::binary>> = line_text
    Bitwise.band(byte, 0xC0) != 0x80
  end

  @spec exact_codepoint_column(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :column_out_of_range}
  defp exact_codepoint_column(_line_text, 0, byte_offset), do: {:ok, byte_offset}
  defp exact_codepoint_column("", _remaining, _byte_offset), do: {:error, :column_out_of_range}

  defp exact_codepoint_column(<<codepoint::utf8, rest::binary>>, remaining, byte_offset) do
    exact_codepoint_column(rest, remaining - 1, byte_offset + byte_size(<<codepoint::utf8>>))
  end

  @spec exact_utf16_column(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :column_out_of_range | :column_not_boundary}
  defp exact_utf16_column(_line_text, 0, byte_offset), do: {:ok, byte_offset}
  defp exact_utf16_column("", _remaining, _byte_offset), do: {:error, :column_out_of_range}

  defp exact_utf16_column(<<codepoint::utf8, rest::binary>>, remaining, byte_offset) do
    units = utf16_units_for_codepoint(codepoint)
    exact_utf16_step(rest, remaining, byte_offset, codepoint, units)
  end

  @spec exact_utf16_step(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          1 | 2
        ) :: {:ok, non_neg_integer()} | {:error, :column_out_of_range | :column_not_boundary}
  defp exact_utf16_step(_rest, remaining, _byte_offset, _codepoint, units)
       when remaining < units,
       do: {:error, :column_not_boundary}

  defp exact_utf16_step(rest, remaining, byte_offset, codepoint, units) do
    exact_utf16_column(rest, remaining - units, byte_offset + byte_size(<<codepoint::utf8>>))
  end

  @spec normalize_encoding(String.t()) :: encoding() | nil
  defp normalize_encoding("utf-8"), do: :utf8
  defp normalize_encoding("utf-16"), do: :utf16
  defp normalize_encoding("utf-32"), do: :utf32
  defp normalize_encoding(_), do: nil

  @spec byte_col_to_lsp(non_neg_integer(), String.t(), encoding()) :: non_neg_integer()
  defp byte_col_to_lsp(byte_col, _line_text, :utf8), do: byte_col

  defp byte_col_to_lsp(byte_col, line_text, :utf32) do
    safe_byte_col = min(byte_col, byte_size(line_text))
    prefix = binary_part(line_text, 0, safe_byte_col)
    String.length(prefix)
  end

  defp byte_col_to_lsp(byte_col, line_text, :utf16) do
    safe_byte_col = min(byte_col, byte_size(line_text))
    prefix = binary_part(line_text, 0, safe_byte_col)
    count_utf16_code_units(prefix)
  end

  @spec lsp_to_byte_col(non_neg_integer(), String.t(), encoding()) :: non_neg_integer()
  defp lsp_to_byte_col(character, _line_text, :utf8), do: character
  defp lsp_to_byte_col(character, line_text, :utf32), do: walk_codepoints(line_text, character)

  defp lsp_to_byte_col(character, line_text, :utf16),
    do: walk_utf16_units(line_text, character, 0)

  @spec count_utf16_code_units(binary()) :: non_neg_integer()
  defp count_utf16_code_units(binary) do
    binary
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc ->
      acc + utf16_units_for_codepoint(codepoint)
    end)
  end

  @spec utf16_units_for_codepoint(non_neg_integer()) :: 1 | 2
  defp utf16_units_for_codepoint(cp) when cp <= 0xFFFF, do: 1
  defp utf16_units_for_codepoint(_cp), do: 2

  @spec walk_codepoints(binary(), non_neg_integer()) :: non_neg_integer()
  defp walk_codepoints(_binary, 0), do: 0
  defp walk_codepoints(<<>>, _remaining), do: 0

  defp walk_codepoints(<<c::utf8, rest::binary>>, remaining) do
    byte_size_of_char = byte_size(<<c::utf8>>)
    byte_size_of_char + walk_codepoints(rest, remaining - 1)
  end

  @spec walk_utf16_units(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp walk_utf16_units(_binary, 0, byte_offset), do: byte_offset
  defp walk_utf16_units(<<>>, _remaining, byte_offset), do: byte_offset

  defp walk_utf16_units(<<c::utf8, rest::binary>>, remaining, byte_offset) do
    char_bytes = byte_size(<<c::utf8>>)
    units = utf16_units_for_codepoint(c)
    walk_utf16_units(rest, remaining - units, byte_offset + char_bytes)
  end
end
