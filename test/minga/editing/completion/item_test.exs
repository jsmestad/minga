defmodule Minga.Editing.Completion.ItemTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion.Item
  alias Minga.Test.CallCounter

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

  describe "wire_id/1" do
    test "an item carries the wire id of its identity from either constructor" do
      lsp = Item.from_lsp(:lsp, %{"label" => "map", "kind" => 3, "data" => %{"n" => 1}})
      local = Item.from_fields(:local, %{label: "map", kind: :function, detail: "Enum.map/2"})

      for item <- [lsp, local] do
        assert Item.wire_id(item) == Item.wire_id(item.id)
        assert Item.wire_id(item) =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      end

      refute Item.wire_id(lsp) == Item.wire_id(local)
    end

    test "building an item hashes its identity once and reading the wire id hashes nothing" do
      {built, item} =
        CallCounter.count({:crypto, :hash, 2}, fn ->
          Item.from_lsp(:lsp, %{"label" => "map"})
        end)

      {read, _wire_ids} =
        CallCounter.count({:crypto, :hash, 2}, fn ->
          for _ <- 1..3, do: Item.wire_id(item)
        end)

      assert {built, read} == {1, 0}
    end

    test "resolving documentation and recording the request origin keep the wire id" do
      item = Item.from_lsp(:lsp, %{"label" => "map"})

      updated =
        item
        |> Item.resolve("Docs.")
        |> Item.with_request_origin({{0, 3}, "map"})
        |> Item.with_match_ranges([{0, 1}])

      assert Item.wire_id(updated) == Item.wire_id(item)
      assert Item.wire_id(updated) == Item.wire_id(updated.id)
    end
  end
end
