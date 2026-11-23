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
