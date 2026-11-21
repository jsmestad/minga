defmodule Minga.Core.WrapMapTest do
  use ExUnit.Case, async: true

  alias Minga.Core.WidthOracle.Measured
  alias Minga.Core.WrapMap

  describe "compute/3 with no wrapping needed" do
    test "short line produces a single visual row" do
      [entry] = WrapMap.compute(["hello"], 40)
      assert Enum.count(entry) == 1
      assert WrapMap.display_text(hd(entry)) == "hello"
      assert hd(entry).byte_offset == 0
    end

    test "empty line produces a single empty visual row" do
      [entry] = WrapMap.compute([""], 40)
      assert Enum.count(entry) == 1
      assert WrapMap.display_text(hd(entry)) == ""
      assert hd(entry).source_text == ""
      assert hd(entry).indent_width == 0
    end

    test "line exactly at width produces a single visual row" do
      line = String.duplicate("a", 40)
      [entry] = WrapMap.compute([line], 40)
      assert Enum.count(entry) == 1
      assert WrapMap.display_text(hd(entry)) == line
    end
  end

  describe "compute/3 with word-boundary wrapping" do
    test "wraps at the last space before the width limit" do
      # "hello world foo" at width 12 should break after "hello world"
      [entry] = WrapMap.compute(["hello world foo"], 12)
      assert Enum.count(entry) == 2
      assert WrapMap.display_text(Enum.at(entry, 0)) == "hello world "
      assert WrapMap.display_text(Enum.at(entry, 1)) == "foo"
    end

    test "rolls back to the last fitting tab but keeps the final row intact" do
      source = "e\u0301  \t界x y"
      [entry] = WrapMap.compute([source], 7, breakindent: false, tab_width: 4)

      assert Enum.map(entry, &{&1.source_text, &1.byte_offset}) == [
               {"e\u0301  \t", 0},
               {"界x y", 6}
             ]
    end

    test "narrow continuation rows never use the old four-column minimum" do
      [entry] = WrapMap.compute(["abcdef"], 2, breakindent: false)
      assert Enum.map(entry, & &1.text) == ["ab", "cd", "ef"]
      assert Enum.map(entry, & &1.byte_offset) == [0, 2, 4]
    end

    test "wraps long text into multiple visual rows" do
      line = "one two three four five six seven eight"
      [entry] = WrapMap.compute([line], 15)
      assert Enum.count(entry) >= 3
      # Every visual row's text should be <= 15 display columns
      Enum.each(entry, fn row ->
        assert String.length(row.text) <= 15
      end)
    end

    test "hard-breaks when no space exists" do
      line = String.duplicate("x", 30)
      [entry] = WrapMap.compute([line], 10)
      assert Enum.count(entry) == 3
      assert Enum.at(entry, 0).text == String.duplicate("x", 10)
      assert Enum.at(entry, 1).text == String.duplicate("x", 10)
      assert Enum.at(entry, 2).text == String.duplicate("x", 10)
    end
  end

  describe "compute/3 with linebreak: false" do
    test "breaks at exact width, not at word boundaries" do
      [entry] = WrapMap.compute(["hello world foobar"], 10, linebreak: false)
      assert WrapMap.display_text(Enum.at(entry, 0)) == "hello worl"
    end

    test "advances raw tabs to the configured tab stop" do
      [entry] = WrapMap.compute(["a\tb"], 4, linebreak: false, tab_width: 4)

      assert Enum.map(entry, & &1.source_text) == ["a\t", "b"]
      assert Enum.map(entry, & &1.byte_offset) == [0, 2]
    end

    test "a tab on a stop boundary advances by a full tab width" do
      [entry] = WrapMap.compute(["abcd\t"], 4, linebreak: false, tab_width: 4)

      assert Enum.map(entry, & &1.source_text) == ["abcd", "\t"]
    end
  end

  test "count_rows matches materialized rows at wrap boundaries" do
    oracle = Measured.new(%{"a" => 2, "界" => 8, "e\u0301" => 0, "b" => 2})

    cases = [
      {"", 1, [], [""]},
      {"a b", 3, [], ["a b"]},
      {" abcd", 3, [breakindent: false], [" ab", "cd"]},
      {"hello world foobar", 10, [], ["hello ", "world ", "foobar"]},
      {"hello world foobar", 10, [linebreak: false], ["hello worl", "d foobar"]},
      {"  abcdef", 4, [linebreak: false], ["  ab", "cd", "ef"]},
      {"  abcdef", 4, [breakindent: false, linebreak: false], ["  ab", "cdef"]},
      {"    界x", 2, [], ["  ", " ", " ", "界", "x"]},
      {"ab\tcde", 6, [tab_width: 4], ["ab\t", "cde"]},
      {"\t abcd\txy", 8, [tab_width: 4, linebreak: false], ["\t abc", "d\t", "xy"]},
      {"a界e\u0301b", 2, [oracle: oracle], ["a", "界", "e\u0301b"]}
    ]

    for {text, width, opts, expected} <- cases do
      [rows] = WrapMap.compute([text], width, opts)
      assert Enum.map(rows, & &1.source_text) == expected
      assert WrapMap.count_rows(text, width, opts) == length(rows)
    end
  end

  test "counts a batch of logical lines, including empty lines" do
    assert WrapMap.count_rows([], 4, []) == 0
    assert WrapMap.count_rows(["", "abc def", "abcdefghi"], 4, []) == 6
  end

  describe "byte_offset tracking" do
    test "byte offsets are cumulative" do
      [entry] = WrapMap.compute(["hello world foo"], 12)
      assert Enum.at(entry, 0).byte_offset == 0
      assert Enum.at(entry, 1).byte_offset > 0
    end
  end

  describe "row_at_byte/2" do
    test "selects continuations by start byte and keeps the last row past the end" do
      [rows] = WrapMap.compute(["éabcde"], 2)
      [first, second, last] = rows

      assert WrapMap.row_at_byte(rows, 2) == {0, first}
      assert WrapMap.row_at_byte(rows, 3) == {1, second}
      assert WrapMap.row_at_byte(rows, 5) == {2, last}
      assert WrapMap.row_at_byte(rows, 99) == {2, last}

      indexed = List.to_tuple(rows)
      assert WrapMap.row_index_at_byte(indexed, 2) == 0
      assert WrapMap.row_index_at_byte(indexed, 3) == 1
      assert WrapMap.row_index_at_byte(indexed, 4) == 1
      assert WrapMap.row_index_at_byte(indexed, 5) == 2
      assert WrapMap.row_index_at_byte(indexed, 99) == 2
    end

    test "selects the only row of an empty logical line" do
      [[row] = rows] = WrapMap.compute([""], 2)
      assert WrapMap.row_at_byte(rows, 0) == {0, row}
      assert WrapMap.row_index_at_byte({row}, 0) == 0
    end
  end

  describe "visual_row_count/1" do
    test "counts total visual rows across all entries" do
      map = WrapMap.compute(["short", String.duplicate("x", 30), "also short"], 10)
      count = WrapMap.visual_row_count(map)
      # "short" = 1, "xxx...30" = 3, "also short" = 1
      assert count == 5
    end

    test "non-wrapping lines each count as 1" do
      map = WrapMap.compute(["a", "b", "c"], 40)
      assert WrapMap.visual_row_count(map) == 3
    end
  end

  describe "logical_to_visual/2" do
    test "first line starts at visual row 0" do
      map = WrapMap.compute(["hello", "world"], 40)
      assert WrapMap.logical_to_visual(map, 0) == 0
    end

    test "second line starts after the first line's visual rows" do
      # First line wraps to 3 visual rows
      map = WrapMap.compute([String.duplicate("x", 30), "hello"], 10)
      assert WrapMap.logical_to_visual(map, 1) == 3
    end
  end

  describe "breakindent" do
    test "display_text accepts legacy plain map rows" do
      assert WrapMap.display_text(%{text: "foo"}) == "foo"
      assert WrapMap.display_text(%{text: "bar", indent_width: 2}) == "  bar"
    end

    test "continuation rows preserve indentation in display text" do
      line = "    alpha beta gamma delta"
      [entry] = WrapMap.compute([line], 12, breakindent: true)

      assert WrapMap.display_text(Enum.at(entry, 0)) == "    alpha "
      assert WrapMap.display_text(Enum.at(entry, 1)) =~ ~r/^    /
      assert Enum.at(entry, 1).source_text == "beta "
      assert Enum.at(entry, 1).indent_width == 4
    end

    test "continuation rows use narrower width to leave room for indent" do
      # 4 spaces indent + text. At width 20, first row gets 20 cols,
      # continuation rows get 20 - 4 = 16 cols.
      line = "    " <> String.duplicate("x", 40)
      [entry] = WrapMap.compute([line], 20, breakindent: true)
      # First row: 20 chars. Continuation: 16 chars each.
      assert Enum.count(entry) >= 3
    end

    test "tabs in leading whitespace count using the configured tab width" do
      line = "\t" <> String.duplicate("x", 40)
      [entry] = WrapMap.compute([line], 12, breakindent: true, tab_width: 4)

      assert Enum.count(entry) >= 2
      assert Enum.at(entry, 1).indent_width == 4
      assert WrapMap.display_text(Enum.at(entry, 1)) =~ ~r/^ {4}/
    end

    test "ignores a leading break and expands continuation tabs from the indent column" do
      [entry] = WrapMap.compute([" abcde\tf"], 5, tab_width: 4)

      assert Enum.map(entry, &{&1.source_text, &1.byte_offset, &1.indent_width}) == [
               {" abcd", 0, 0},
               {"e\tf", 5, 1}
             ]
    end

    test "no breakindent gives full width on continuation rows" do
      line = "    " <> String.duplicate("x", 40)
      [entry_bi] = WrapMap.compute([line], 20, breakindent: true)
      [entry_no] = WrapMap.compute([line], 20, breakindent: false)
      # Without breakindent, fewer visual rows needed
      assert Enum.count(entry_no) <= Enum.count(entry_bi)
    end
  end

  describe "width oracle" do
    test "uses supplied oracle for wrap decisions" do
      oracle = Minga.Core.WidthOracle.Measured.new(%{"a" => 2})
      [entry] = WrapMap.compute(["aaaa"], 4, oracle: oracle, linebreak: false)

      assert Enum.map(entry, & &1.text) == ["aa", "aa"]
    end

    test "always consumes an over-wide grapheme" do
      grapheme = "e\u0301"
      oracle = Minga.Core.WidthOracle.Measured.new(%{grapheme => 10})
      [entry] = WrapMap.compute([grapheme <> "b"], 4, oracle: oracle, linebreak: false)

      assert Enum.map(entry, &{&1.source_text, &1.byte_offset}) == [{grapheme, 0}, {"b", 3}]
    end
  end

  describe "multiple lines" do
    test "each line gets its own wrap entry" do
      map = WrapMap.compute(["short", "also short", "tiny"], 40)
      assert Enum.count(map) == 3
    end
  end
end
