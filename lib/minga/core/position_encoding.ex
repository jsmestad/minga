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
