defmodule MingaEditor.RenderModel.Window.SourceOffsetMapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

    test "identity lines map every grapheme boundary in both directions" do
      for text <- [
            "",
            "plain ascii",
            "界界A",
            "a😀b",
            "e\u0301x\u0301",
            "👨\u200D👩\u200D👧 family",
            "line\r\n",
            "raw\ttab"
          ] do
        assert_identity_mapping(text, Decorations.new(), [])
      end
    end

    property "tab-free identity lines map grapheme boundaries with any tab width" do
      check all(text <- identity_text_gen(), opts <- member_of([[], [tab_width: 4]])) do
        assert_identity_mapping(text, Decorations.new(), opts)
        assert_identity_mapping(text, other_line_decorations(), opts)
      end
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

    test "a conceal whose replacement equals its source keeps replacement affinity" do
      {_id, decorations} =
        Decorations.add_conceal(Decorations.new(), {0, 1}, {0, 3}, replacement: "bc")

      map = SourceOffsetMap.new("abcd", "abcd", decorations, 0)

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 2, :start) == 1
      assert SourceOffsetMap.composed_utf16_to_source_byte(map, 2, :end) == 3

      assert SourceOffsetMap.composed_utf16_to_source_bytes(map, [{2, :start}, {2, :end}]) ==
               [1, 3]

      assert SourceOffsetMap.source_to_composed_utf16(map, 1, :start) == 1
      assert SourceOffsetMap.source_to_composed_utf16(map, 2, :start) == 3
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

  describe "VisualRow.source_character_position/2" do
    test "row-end hits stay on the final grapheme while insertion boundaries remain exact" do
      for {source, first_text, source_end, composed_end, last_byte} <- [
            {"ab", "a", 1, 1, 0},
            {"a😀b", "a😀", 5, 3, 1},
            {"ae\u0301b", "ae\u0301", 4, 3, 1},
            {"a界b", "a界", 4, 2, 1}
          ] do
        map = plain_map(source) |> SourceOffsetMap.slice(0, source_end, 0, composed_end)
        entry = VisualRow.new(row(:normal, first_text), map, 0, composed_end, 0)

        assert VisualRow.source_character_position(entry, composed_end) == {:ok, {7, last_byte}}
        assert VisualRow.source_character_position(entry, 100) == {:ok, {7, last_byte}}
        assert VisualRow.source_position(entry, composed_end) == {:ok, {7, source_end}}
      end
    end

    test "expanded tabs, concealed replacements and virtual text keep their source mapping" do
      {_id, conceal} =
        Decorations.add_conceal(Decorations.new(), {0, 1}, {0, 4}, replacement: "😀")

      {_id, virtual} =
        Decorations.add_virtual_text(Decorations.new(), {0, 1},
          segments: [{"XY", Face.new()}],
          placement: :inline
        )

      for {source, composed, text, decorations, source_end, composed_end, expected} <- [
            {"\tb", "    b", "    ", Decorations.new(), 1, 4, 0},
            {"abcdef", "a😀ef", "a😀", conceal, 4, 3, 1},
            {"ab", "aXYb", "aXY", virtual, 1, 3, 1}
          ] do
        map = SourceOffsetMap.new(source, composed, decorations, 0, tab_width: 4)
        map = SourceOffsetMap.slice(map, 0, source_end, 0, composed_end)
        entry = VisualRow.new(row(:normal, text), map, 0, composed_end, 0)
        assert VisualRow.source_character_position(entry, 100) == {:ok, {7, expected}}
      end
    end

    test "continuation indentation, final rows and empty rows retain modal character targets" do
      map = plain_map("abcdef") |> SourceOffsetMap.slice(2, 6, 2, 6)
      entry = VisualRow.new(row(:wrap_continuation, "  cdef"), map, 2, 6, 2)
      assert VisualRow.source_character_position(entry, 0) == {:ok, {7, 2}}
      assert VisualRow.source_character_position(entry, 6) == {:ok, {7, 5}}
      assert VisualRow.source_character_position(entry, 100) == {:ok, {7, 5}}

      empty = VisualRow.new(row(:normal, ""), plain_map(""), 0, 0, 0)
      virtual = VisualRow.new(row(:virtual_line, "hint"), plain_map("hint"), 0, 4, 0)
      assert VisualRow.source_character_position(empty, 100) == {:ok, {7, 0}}
      assert VisualRow.source_character_position(virtual, 100) == :not_source_backed
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

  # Derive boundaries with String.graphemes/1 and :unicode, independently of the map under test.
  # Interior UTF-16 offsets resolve to the edge selected by affinity.
  defp assert_identity_mapping(text, decorations, opts) do
    map = SourceOffsetMap.new(text, text, decorations, 0, opts)
    graphemes = grapheme_extents(text)
    source_end = byte_size(text)
    utf16_end = utf16_units(text)

    for {start_byte, end_byte, start_utf16, end_utf16} <- graphemes,
        affinity <- [:start, :end] do
      assert SourceOffsetMap.source_to_composed_utf16(map, start_byte, affinity) == start_utf16

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, start_utf16, affinity) ==
               start_byte

      expected = if affinity == :start, do: start_byte, else: end_byte

      for interior <- (start_utf16 + 1)..(end_utf16 - 1)//1 do
        assert SourceOffsetMap.composed_utf16_to_source_byte(map, interior, affinity) == expected
      end
    end

    for affinity <- [:start, :end] do
      assert SourceOffsetMap.source_to_composed_utf16(map, source_end, affinity) == utf16_end
      assert SourceOffsetMap.source_to_composed_utf16(map, source_end + 3, affinity) == utf16_end

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, utf16_end, affinity) ==
               source_end

      assert SourceOffsetMap.composed_utf16_to_source_byte(map, utf16_end + 3, affinity) ==
               source_end

      boundaries = for utf16 <- 0..(utf16_end + 1), do: {utf16, affinity}

      assert SourceOffsetMap.composed_utf16_to_source_bytes(map, boundaries) ==
               Enum.map(boundaries, fn {utf16, affinity} ->
                 SourceOffsetMap.composed_utf16_to_source_byte(map, utf16, affinity)
               end)
    end
  end

  defp grapheme_extents(text) do
    {extents, _byte, _utf16} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], 0, 0}, fn grapheme, {extents, byte, utf16} ->
        next_byte = byte + byte_size(grapheme)
        next_utf16 = utf16 + utf16_units(grapheme)
        {[{byte, next_byte, utf16, next_utf16} | extents], next_byte, next_utf16}
      end)

    Enum.reverse(extents)
  end

  defp utf16_units(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)

  # Joined graphemes may fuse (combining marks, ZWJ, CR+LF), so the oracle
  # re-segments the final text rather than trusting the generated pieces.
  defp identity_text_gen do
    ascii = ["a", " ", "Z"]
    wide = ["界", "😀", "👨\u200D👩\u200D👧"]
    joiners = ["e", "\u0301", "é", "\u200D", "\r", "\n", "\r\n"]

    (ascii ++ wide ++ joiners)
    |> member_of()
    |> list_of(max_length: 24)
    |> map(&Enum.join/1)
  end

  # Decorations on other lines must not change an undecorated line's mapping.
  defp other_line_decorations do
    {_id, decorations} =
      Decorations.add_conceal(Decorations.new(), {1, 0}, {1, 2}, replacement: "x")

    {_id, decorations} =
      Decorations.add_virtual_text(decorations, {2, 0},
        segments: [{"hint", Face.new()}],
        placement: :inline
      )

    decorations
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
