defmodule MingaEditor.RenderModel.Window.SourceOffsetMapTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow

  describe "unchanged source mapping" do
    test "maps UTF-8 byte boundaries through UTF-16 for non-ASCII text" do
      assert_boundaries("éééA", [{0, 0}, {2, 1}, {4, 2}, {6, 3}, {7, 4}])
      assert_boundaries("界A", [{0, 0}, {3, 1}, {4, 2}])
    end

    test "astral and combining graphemes use grapheme boundaries for affinity" do
      astral = plain_map("a😀b")
      assert SourceOffsetMap.composed_utf16_to_source_byte(astral, 2, :start) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(astral, 2, :end) == 5
      assert_boundaries("a😀b", [{0, 0}, {1, 1}, {5, 3}, {6, 4}])

      combining = plain_map("e\u0301x")
      assert SourceOffsetMap.composed_utf16_to_source_byte(combining, 1, :start) == 0
      assert SourceOffsetMap.composed_utf16_to_source_byte(combining, 1, :end) == 3
      assert SourceOffsetMap.composed_utf16_to_source_byte(combining, 2, :start) == 3
    end

    test "keeps an unmodified long line as one compact span" do
      text = String.duplicate("é", 10_000)
      map = plain_map(text)
      assert %SourceOffsetMap{spans: [{:source, 0, 20_000, 0, 10_000}]} = map

      boundaries = for utf16 <- 0..10_000//1_000, do: {utf16, :start}

      assert SourceOffsetMap.composed_utf16_to_source_bytes(map, boundaries) ==
               Enum.map(0..10_000//1_000, &(&1 * 2))
    end
  end

  describe "composition edits" do
    test "inline virtual text maps every composed boundary to its source anchor" do
      {_id, decorations} =
        Decorations.add_virtual_text(Decorations.new(), {0, 1},
          segments: [{"XY", Face.new()}],
          placement: :inline
        )

      map = SourceOffsetMap.new("ab", "aXYb", decorations, 0)

      assert SourceOffsetMap.source_to_composed_utf16(map, 1, :end) == 1
      assert SourceOffsetMap.source_to_composed_utf16(map, 1, :start) == 3

      for offset <- 1..3 do
        assert SourceOffsetMap.composed_utf16_to_source_byte(map, offset, :start) == 1
        assert SourceOffsetMap.composed_utf16_to_source_byte(map, offset, :end) == 1
      end
    end

    test "conceal replacements expose their source range through affinity" do
      {_id, decorations} =
        Decorations.add_conceal(Decorations.new(), {0, 1}, {0, 4}, replacement: "😀")

      map = SourceOffsetMap.new("abcdef", "a😀ef", decorations, 0)

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 1, :start) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 2, :start) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 2, :end) == 4
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 3, :end) == 4
      assert SourceOffsetMap.source_to_composed_utf16(map, 4, :start) == 3
    end

    test "conceal without a replacement maps the shared boundary by affinity" do
      {_id, decorations} = Decorations.add_conceal(Decorations.new(), {0, 1}, {0, 4})
      map = SourceOffsetMap.new("abcdef", "aef", decorations, 0)

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 1, :start) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 1, :end) == 4
    end

    test "tabs use their composed column after virtual text" do
      {_id, decorations} =
        Decorations.add_virtual_text(Decorations.new(), {0, 0},
          segments: [{"xx", Face.new()}],
          placement: :inline
        )

      map = SourceOffsetMap.new("\tb", "xx  b", decorations, 0, tab_width: 4)

      assert SourceOffsetMap.source_to_composed_utf16(map, 0, :end) == 0
      assert SourceOffsetMap.source_to_composed_utf16(map, 0, :start) == 2
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 3, :start) == 0
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 3, :end) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 4, :end) == 1
    end

    test "unmapped fold summary text anchors to source end-of-line" do
      map = SourceOffsetMap.new("abc", "abc ··· 2 lines", Decorations.new(), 0)

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 8, :start) == 3
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 100, :end) == 3
    end
  end

  describe "VisualRow.source_position/2" do
    test "subtracts continuation indent and clamps clicks past EOL" do
      source = "abcdef"
      map = plain_map(source) |> SourceOffsetMap.slice(2, 6, 2, 6)
      row = row(:wrap_continuation, "  cdef")
      entry = VisualRow.new(row, map, 2, 6, 2)

      assert VisualRow.source_position(entry, 0) == {:ok, {7, 2}}
      assert VisualRow.source_position(entry, 2) == {:ok, {7, 2}}
      assert VisualRow.source_position(entry, 3) == {:ok, {7, 3}}
      assert VisualRow.source_position(entry, 100) == {:ok, {7, 6}}
    end

    test "maps fold summary text to source EOL and rejects non-source rows" do
      fold_map = SourceOffsetMap.new("abc", "abc ··· 2 lines", Decorations.new(), 7)
      fold_entry = VisualRow.new(row(:fold_start, "abc ··· 2 lines"), fold_map, 0, 3, 0)
      virtual_entry = VisualRow.new(row(:virtual_line, "hint"), plain_map("hint"), 0, 4, 0)

      assert VisualRow.source_position(fold_entry, 8) == {:ok, {7, 3}}
      assert VisualRow.source_position(virtual_entry, 0) == :not_source_backed
    end
  end

  defp assert_boundaries(text, boundaries) do
    map = plain_map(text)

    for {source_byte, composed_utf16} <- boundaries do
      assert SourceOffsetMap.source_to_composed_utf16(map, source_byte, :start) == composed_utf16
      assert SourceOffsetMap.source_to_composed_utf16(map, source_byte, :end) == composed_utf16

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, composed_utf16, :start) ==
               source_byte

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, composed_utf16, :end) ==
               source_byte
    end
  end

  defp plain_map(text), do: SourceOffsetMap.new(text, text, Decorations.new(), 0)

  defp row(row_type, text) do
    %Row{
      row_id: 1,
      row_type: row_type,
      buf_line: 7,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }
  end
end
