defmodule Minga.LSP.PositionEncoding do
  @moduledoc """
  Converts between Minga's byte-indexed positions and LSP positions.

  LSP historically uses UTF-16 code unit offsets for character positions
  (a legacy of the Java/TypeScript origins). Modern servers support UTF-8
  offset encoding via capability negotiation (LSP 3.17+).

  Minga stores positions as `{line, byte_col}` where `byte_col` is a byte
  offset within the line. When the negotiated encoding is UTF-8, conversion
  is zero-cost (byte offset = UTF-8 offset). When UTF-16, we must count
  UTF-16 code units, which is O(n) in the line length.

  ## Negotiation

  During `initialize`, the client advertises supported position encodings.
  The server responds with its chosen encoding. We prefer UTF-8 (zero-cost
  for Minga), falling back to UTF-32, then UTF-16.
  """

  @typedoc "The negotiated offset encoding for a server session."
  @type encoding :: :utf8 | :utf16 | :utf32

  @doc """
  Negotiates the best offset encoding from the server's supported list.

  Prefers UTF-8 (zero-cost), then UTF-32 (codepoint = straightforward),
  then UTF-16 (requires surrogate pair counting). Falls back to UTF-16
  if the server doesn't advertise support (LSP spec default).

  ## Examples

      iex> Minga.LSP.PositionEncoding.negotiate(["utf-8", "utf-16"])
      :utf8

      iex> Minga.LSP.PositionEncoding.negotiate(["utf-16"])
      :utf16

      iex> Minga.LSP.PositionEncoding.negotiate([])
      :utf16
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

  @doc """
  Returns the LSP encoding string for capability advertisement.

  ## Examples

      iex> Minga.LSP.PositionEncoding.client_supported_encodings()
      ["utf-8", "utf-32", "utf-16"]
  """
  @spec client_supported_encodings() :: [String.t()]
  def client_supported_encodings do
    ["utf-8", "utf-32", "utf-16"]
  end

  @doc """
  Converts a Minga `{line, byte_col}` position to an LSP position map.

  The `line_text` parameter is the content of the line (needed for UTF-16
  conversion). For UTF-8 encoding, `byte_col` passes through directly.

  ## Examples

      iex> Minga.LSP.PositionEncoding.to_lsp({3, 10}, "hello world", :utf8)
      %{"line" => 3, "character" => 10}
  """
  @spec to_lsp({non_neg_integer(), non_neg_integer()}, String.t(), encoding()) :: map()
  def to_lsp({line, byte_col}, line_text, encoding)
      when is_integer(line) and is_integer(byte_col) and is_binary(line_text) do
    character = byte_col_to_lsp(byte_col, line_text, encoding)
    %{"line" => line, "character" => character}
  end

  @doc """
  Converts an LSP position map back to a Minga `{line, byte_col}` tuple.

  The `line_text` parameter is the content of the line (needed for UTF-16
  conversion). For UTF-8 encoding, the character offset passes through.

  ## Examples

      iex> Minga.LSP.PositionEncoding.from_lsp(%{"line" => 3, "character" => 10}, "hello world", :utf8)
      {3, 10}
  """
  @spec from_lsp(map(), String.t(), encoding()) :: {non_neg_integer(), non_neg_integer()}
  def from_lsp(%{"line" => line, "character" => character}, line_text, encoding)
      when is_integer(line) and is_integer(character) and is_binary(line_text) do
    byte_col = lsp_to_byte_col(character, line_text, encoding)
    {line, byte_col}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec normalize_encoding(String.t()) :: encoding() | nil
  defp normalize_encoding("utf-8"), do: :utf8
  defp normalize_encoding("utf-16"), do: :utf16
  defp normalize_encoding("utf-32"), do: :utf32
  defp normalize_encoding(_), do: nil

  # UTF-8: byte_col IS the LSP character offset (zero cost)
  @spec byte_col_to_lsp(non_neg_integer(), String.t(), encoding()) :: non_neg_integer()
  defp byte_col_to_lsp(byte_col, _line_text, :utf8), do: byte_col

  # UTF-32: count codepoints in the bytes before byte_col
  defp byte_col_to_lsp(byte_col, line_text, :utf32) do
    safe_byte_col = min(byte_col, byte_size(line_text))
    prefix = binary_part(line_text, 0, safe_byte_col)
    String.length(prefix)
  end

  # UTF-16: count UTF-16 code units in the bytes before byte_col
  defp byte_col_to_lsp(byte_col, line_text, :utf16) do
    safe_byte_col = min(byte_col, byte_size(line_text))
    prefix = binary_part(line_text, 0, safe_byte_col)
    count_utf16_code_units(prefix)
  end

  # UTF-8: LSP character offset IS byte_col
  @spec lsp_to_byte_col(non_neg_integer(), String.t(), encoding()) :: non_neg_integer()
  defp lsp_to_byte_col(character, _line_text, :utf8), do: character

  # UTF-32: walk codepoints until we've consumed `character` of them
  defp lsp_to_byte_col(character, line_text, :utf32) do
    walk_codepoints(line_text, character)
  end

  # UTF-16: walk codepoints, counting UTF-16 code units, until consumed
  defp lsp_to_byte_col(character, line_text, :utf16) do
    walk_utf16_units(line_text, character, 0)
  end

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
