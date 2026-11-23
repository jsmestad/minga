defmodule Minga.Editing.Completion.ItemTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion.Item

  @line "héllo 🎉 fo(x)"

  defp edit(start_line, start_col, end_line, end_col) do
    %{
      range: %{start_line: start_line, start_col: start_col, end_line: end_line, end_col: end_col},
      new_text: "foo"
    }
  end

  describe "follow_cursor/3" do
    test "moves a request-line range past text typed or deleted at the cursor" do
      for {range, request_col, cursor_col, expected} <- [
            # Nothing changed.
            {{4, 7}, 7, 7, {4, 7}},
            # One character typed: an end at the request column follows the cursor.
            {{4, 7}, 7, 8, {4, 8}},
            # One character deleted.
            {{4, 7}, 7, 6, {4, 6}},
            # An end past the request column keeps its distance from the cursor.
            {{4, 9}, 7, 8, {4, 10}},
            {{4, 9}, 7, 5, {4, 7}},
            # An insertion at the request column also replaces what was typed after it.
            {{7, 7}, 7, 9, {7, 9}},
            # A start inside deleted text lands at the cursor.
            {{6, 7}, 7, 4, {4, 4}},
            # A range entirely after the request column moves with the cursor.
            {{8, 10}, 7, 9, {10, 12}}
          ] do
        assert Item.follow_cursor(range, request_col, cursor_col) == expected,
               "#{inspect(range)} from #{request_col} to #{cursor_col}"
      end
    end
  end

  describe "byte_columns/4" do
    test "converts a half-open LSP range to byte columns in the provider's encoding" do
      for {encoding, range, cursor_line, expected} <- [
            # "héllo " is 6 UTF-16 units and 7 bytes; "🎉" is 2 units, 1 code point, 4 bytes.
            {:utf16, edit(0, 9, 0, 11), 0, {:ok, {12, 14}}},
            {:utf32, edit(0, 8, 0, 10), 0, {:ok, {12, 14}}},
            {:utf8, edit(0, 12, 0, 14), 0, {:ok, {12, 14}}},
            {:utf16, edit(2, 0, 2, 3), 2, {:ok, {0, 4}}},
            {:utf16, edit(0, 7, 0, 11), 0, {:error, :column_not_boundary}},
            {:utf8, edit(0, 2, 0, 3), 0, {:error, :column_not_boundary}},
            {:utf16, edit(0, 0, 0, 99), 0, {:error, :column_out_of_range}},
            {:utf16, edit(0, 5, 0, 2), 0, {:error, :inverted_range}},
            {:utf16, edit(1, 0, 1, 2), 0, {:error, :not_on_cursor_line}},
            {:utf16, edit(0, 0, 1, 2), 0, {:error, :not_on_cursor_line}},
            {:utf16, edit(0, "0", 0, 2), 0, {:error, :malformed_range}}
          ] do
        assert Item.byte_columns(range, cursor_line, @line, encoding) == expected,
               "#{encoding} #{inspect(range.range)}"
      end
    end
  end
end
