defmodule Minga.Input.WrapTest do
  use ExUnit.Case, async: true

  alias Minga.Input.Wrap

  # ── wrap_line/2 ───────────────────────────────────────────────────────────

  describe "wrap_line/2" do
    test "empty string returns single empty entry" do
      assert Wrap.wrap_line("", 20) == [%{text: "", col_offset: 0}]
    end

    test "short line fits in one row" do
      assert Wrap.wrap_line("hello", 20) == [%{text: "hello", col_offset: 0}]
    end

    test "line exactly at width returns single entry" do
      assert Wrap.wrap_line("12345", 5) == [%{text: "12345", col_offset: 0}]
    end

    test "breaks at word boundary" do
      result = Wrap.wrap_line("hello world foo", 10)
      assert length(result) == 2
      assert Enum.at(result, 0) == %{text: "hello ", col_offset: 0}
      assert Enum.at(result, 1) == %{text: "world foo", col_offset: 6}
    end

    test "hard-wraps when no spaces exist" do
      result = Wrap.wrap_line("abcdefghijklmno", 5)
      assert length(result) == 3
      assert Enum.at(result, 0) == %{text: "abcde", col_offset: 0}
      assert Enum.at(result, 1) == %{text: "fghij", col_offset: 5}
      assert Enum.at(result, 2) == %{text: "klmno", col_offset: 10}
    end

    test "URL-like string hard-wraps and preserves all text" do
      url = "https://example.com/very/long/path/to/something"
      result = Wrap.wrap_line(url, 20)
      assert length(result) >= 2
      joined = result |> Enum.map_join(& &1.text)
      assert joined == url
    end

    test "col_offsets are cumulative" do
      result = Wrap.wrap_line("abcdefghij", 5)
      assert Enum.at(result, 0).col_offset == 0
      assert Enum.at(result, 1).col_offset == 5
    end

    test "width below minimum truncates" do
      result = Wrap.wrap_line("hello world", 3)
      assert result == [%{text: "hel", col_offset: 0}]
    end

    test "narrow width wraps character by character" do
      result = Wrap.wrap_line("hello", 4)
      assert length(result) == 2
      assert Enum.at(result, 0).text == "hell"
      assert Enum.at(result, 1).text == "o"
    end

    test "unicode characters wrap correctly" do
      result = Wrap.wrap_line("héllo wörld", 7)
      joined = result |> Enum.map_join(& &1.text)
      assert joined == "héllo wörld"
    end

    test "multiple spaces preserved" do
      result = Wrap.wrap_line("hello   world", 10)
      joined = result |> Enum.map_join(& &1.text)
      assert joined == "hello   world"
    end

    test "trailing space at wrap boundary" do
      # "hello " is exactly 6 chars, fits in width 6
      result = Wrap.wrap_line("hello world", 6)
      assert length(result) == 2
      joined = result |> Enum.map_join(& &1.text)
      assert joined == "hello world"
    end

    test "wraps multiple times for very long line" do
      line = String.duplicate("word ", 20) |> String.trim()
      result = Wrap.wrap_line(line, 15)
      assert length(result) > 1
      joined = result |> Enum.map_join(& &1.text)
      assert joined == line
    end
  end

  # ── wrap_lines/2 ──────────────────────────────────────────────────────────

  describe "wrap_lines/2" do
    test "tags each visual line with its logical line index" do
      lines = ["short", "this is a longer line that wraps"]
      result = Wrap.wrap_lines(lines, 15)

      # First logical line: no wrap
      assert {0, %{text: "short"}} = Enum.at(result, 0)

      # Second logical line wraps, all tagged with index 1
      rest = Enum.drop(result, 1)
      assert Enum.all?(rest, fn {idx, _} -> idx == 1 end)
    end

    test "preserves logical line indices for short lines" do
      lines = ["a", "b", "c"]
      result = Wrap.wrap_lines(lines, 20)
      assert [{0, _}, {1, _}, {2, _}] = result
    end

    test "empty lines included" do
      lines = ["hello", "", "world"]
      result = Wrap.wrap_lines(lines, 20)
      assert length(result) == 3
      assert {1, %{text: ""}} = Enum.at(result, 1)
    end
  end

  # ── visual_line_count/2 ──────────────────────────────────────────────────

  describe "visual_line_count/2" do
    test "counts wraps" do
      lines = ["short", "this is a very long line indeed"]
      count = Wrap.visual_line_count(lines, 10)
      assert count > 2
    end

    test "single short line counts as 1" do
      assert Wrap.visual_line_count(["hi"], 20) == 1
    end

    test "empty line counts as 1" do
      assert Wrap.visual_line_count([""], 20) == 1
    end

    test "multiple empty lines" do
      assert Wrap.visual_line_count(["", "", ""], 20) == 3
    end
  end

  # ── visible_height/3 ──────────────────────────────────────────────────────

  describe "visible_height/3" do
    test "clamps to max_visible" do
      lines = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
      assert Wrap.visible_height(lines, 20, 5) == 5
    end

    test "returns actual count when under max" do
      assert Wrap.visible_height(["a", "b"], 20, 8) == 2
    end

    test "minimum is 1" do
      assert Wrap.visible_height([""], 20, 8) == 1
    end

    test "accounts for wrapping in height" do
      # A single long line that wraps to 3 visual rows
      lines = ["this is a long line that wraps around"]
      visual = Wrap.visual_line_count(lines, 10)
      assert Wrap.visible_height(lines, 10, 8) == visual
    end
  end

  # ── logical_to_visual/3 ──────────────────────────────────────────────────

  describe "logical_to_visual/3" do
    test "cursor on short line unchanged" do
      {vl, vc} = Wrap.logical_to_visual(["hello"], 20, {0, 3})
      assert vl == 0
      assert vc == 3
    end

    test "cursor on second line accounts for first line wraps" do
      lines = ["this is a long first line", "second"]
      first_vl_count = length(Wrap.wrap_line("this is a long first line", 10))
      {vl, vc} = Wrap.logical_to_visual(lines, 10, {1, 3})
      assert vl == first_vl_count
      assert vc == 3
    end

    test "cursor in wrapped portion of line" do
      # "hello world foo bar" at width 10:
      # row 0: "hello "     (col_offset 0, len 6)
      # row 1: "world foo " (col_offset 6, len 10)
      # row 2: "bar"        (col_offset 16)
      lines = ["hello world foo bar"]
      {vl, vc} = Wrap.logical_to_visual(lines, 10, {0, 12})
      assert vl >= 1
      assert vc >= 0
    end

    test "cursor at start" do
      {vl, vc} = Wrap.logical_to_visual(["hello"], 20, {0, 0})
      assert {vl, vc} == {0, 0}
    end

    test "cursor at end of line" do
      {vl, vc} = Wrap.logical_to_visual(["hello"], 20, {0, 5})
      assert {vl, vc} == {0, 5}
    end

    test "cursor at start of second visual row" do
      lines = ["abcdefghij"]
      # Wraps at 5: "abcde" (0-4), "fghij" (5-9)
      {vl, vc} = Wrap.logical_to_visual(lines, 5, {0, 5})
      assert vl == 1
      assert vc == 0
    end

    test "cursor at end of second visual row" do
      lines = ["abcdefghij"]
      {vl, vc} = Wrap.logical_to_visual(lines, 5, {0, 9})
      assert vl == 1
      assert vc == 4
    end

    test "handles empty line" do
      {vl, vc} = Wrap.logical_to_visual([""], 20, {0, 0})
      assert {vl, vc} == {0, 0}
    end
  end

  # ── scroll_offset/3 ──────────────────────────────────────────────────────

  describe "scroll_offset/3" do
    test "no scroll needed when cursor is visible" do
      assert Wrap.scroll_offset(2, 5, 10) == 0
    end

    test "scrolls to keep cursor visible" do
      assert Wrap.scroll_offset(7, 5, 10) == 3
    end

    test "clamps to max scroll" do
      assert Wrap.scroll_offset(9, 5, 10) == 5
    end

    test "no scroll when total fits in window" do
      assert Wrap.scroll_offset(3, 10, 5) == 0
    end
  end
end
