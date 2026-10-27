defmodule Minga.Core.PositionEncodingTest do
  @moduledoc "Coordinate conversion tests checked against Erlang's UTF-16 encoder."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Core.PositionEncoding

  # "a", "é", "中", "😀", decomposed "e" + U+0301, ZWJ "👩‍💻", "z"
  @mixed "aé中😀e\u0301👩\u200D💻z"

  describe "UTF-16 conversion" do
    test "counts code units at every codepoint boundary" do
      for line <- ["", "plain ascii", @mixed, String.duplicate("中😀", 512)],
          byte_col <- codepoint_boundaries(line) do
        character = utf16_units(binary_part(line, 0, byte_col))

        assert PositionEncoding.to_lsp({3, byte_col}, line, :utf16) == position(3, character)

        assert PositionEncoding.from_lsp(position(3, character), line, :utf16) == {3, byte_col}

        assert PositionEncoding.exact_byte_column(line, character, :utf16) == {:ok, byte_col}
      end
    end

    property "round-trips every codepoint boundary of valid UTF-8" do
      check all(line <- string(:utf8, max_length: 64)) do
        for byte_col <- codepoint_boundaries(line) do
          %{"character" => character} = PositionEncoding.to_lsp({0, byte_col}, line, :utf16)

          assert character == utf16_units(binary_part(line, 0, byte_col))

          assert PositionEncoding.from_lsp(position(0, character), line, :utf16) == {0, byte_col}
        end
      end
    end

    test "clamps columns past the end of the line" do
      line = "a😀"

      assert PositionEncoding.to_lsp({0, 99}, line, :utf16) == position(0, 3)
      assert PositionEncoding.from_lsp(position(0, 99), line, :utf16) == {0, 5}
    end

    test "a column inside a surrogate pair keeps the best-effort walk to the line end" do
      assert PositionEncoding.from_lsp(position(0, 1), "😀abc", :utf16) == {0, 7}
    end

    test "invalid UTF-8 prefixes raise the String.to_charlist/1 conversion error" do
      for {line, byte_col} <- [{"ab" <> <<0xFF>> <> "c", 4}, {"aé", 2}] do
        expected = catch_error(String.to_charlist(binary_part(line, 0, byte_col)))

        assert %UnicodeConversionError{} = expected
        assert catch_error(PositionEncoding.to_lsp({0, byte_col}, line, :utf16)) == expected
      end
    end
  end

  describe "UTF-32 inverse conversion" do
    test "walks one codepoint per character and clamps at the line end" do
      line = @mixed
      boundaries = codepoint_boundaries(line)

      for {byte_col, character} <- Enum.with_index(boundaries) do
        assert PositionEncoding.from_lsp(position(1, character), line, :utf32) == {1, byte_col}

        assert PositionEncoding.exact_byte_column(line, character, :utf32) == {:ok, byte_col}
      end

      assert PositionEncoding.from_lsp(position(1, 99), line, :utf32) == {1, byte_size(line)}
    end

    test "converts positions near the end of very long lines" do
      line = String.duplicate("😀", 100_000)

      assert PositionEncoding.from_lsp(position(0, 100_000), line, :utf32) == {0, 400_000}
    end
  end

  describe "exact_byte_column/3" do
    test "rejects columns that split a codepoint or fall past the line end" do
      zwj = "👩\u200D💻"
      combining = "e\u0301"

      for {line, column, encoding, expected} <- [
            {"a😀b", 2, :utf16, {:error, :column_not_boundary}},
            {"a😀b", 3, :utf16, {:ok, 5}},
            {"a😀b", 4, :utf16, {:ok, 6}},
            {"a😀b", 5, :utf16, {:error, :column_out_of_range}},
            {zwj, 1, :utf16, {:error, :column_not_boundary}},
            {zwj, 3, :utf16, {:ok, 7}},
            {zwj, 4, :utf16, {:error, :column_not_boundary}},
            {zwj, 5, :utf16, {:ok, 11}},
            {zwj, 6, :utf16, {:error, :column_out_of_range}},
            {zwj, 2, :utf32, {:ok, 7}},
            {zwj, 4, :utf32, {:error, :column_out_of_range}},
            {combining, 1, :utf32, {:ok, 1}},
            {combining, 2, :utf32, {:ok, 3}},
            {combining, 3, :utf32, {:error, :column_out_of_range}},
            {combining, 2, :utf8, {:error, :column_not_boundary}},
            {combining, 3, :utf8, {:ok, 3}},
            {combining, 4, :utf8, {:error, :column_out_of_range}},
            {"", 0, :utf16, {:ok, 0}},
            {"", 1, :utf16, {:error, :column_out_of_range}}
          ] do
        assert PositionEncoding.exact_byte_column(line, column, encoding) == expected,
               "#{inspect(line)} column #{column} as #{encoding}"
      end
    end
  end

  describe "UTF-8 passthrough" do
    test "returns byte columns unchanged" do
      assert PositionEncoding.to_lsp({0, 3}, "é", :utf8) == position(0, 3)
      assert PositionEncoding.from_lsp(position(0, 9), "é", :utf8) == {0, 9}
    end
  end

  defp position(line, character), do: %{"line" => line, "character" => character}

  defp codepoint_boundaries(line) do
    line
    |> String.codepoints()
    |> Enum.scan(0, &(byte_size(&1) + &2))
    |> then(&[0 | &1])
  end

  defp utf16_units(text) do
    text |> :unicode.characters_to_binary(:utf8, {:utf16, :big}) |> byte_size() |> div(2)
  end
end
