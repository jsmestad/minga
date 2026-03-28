defmodule Minga.Core.IndentGuideTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Core.IndentGuide

  @tw 2

  # ── indent_level/2 ──

  describe "indent_level/2" do
    test "returns 0 for unindented line" do
      assert IndentGuide.indent_level("hello", @tw) == 0
    end

    test "counts leading spaces divided by tab_width" do
      assert IndentGuide.indent_level("    hello", 2) == 2
      assert IndentGuide.indent_level("    hello", 4) == 1
    end

    test "counts tabs as tab_width spaces each" do
      assert IndentGuide.indent_level("\thello", 4) == 1
      assert IndentGuide.indent_level("\t\thello", 4) == 2
    end

    test "returns 0 for empty line" do
      assert IndentGuide.indent_level("", @tw) == 0
    end

    test "returns indent level for whitespace-only line" do
      # Whitespace-only lines get their raw indent level.
      # Blank line propagation happens in effective_indent_levels.
      assert IndentGuide.indent_level("    ", 2) == 2
    end

    test "mixed spaces and tabs" do
      # \t counts as tab_width (4), + 2 spaces = 6 total columns, floor(6/4) = 1
      assert IndentGuide.indent_level("\t  hello", 4) == 1
    end

    test "tab_width of 1 treats each space as a level" do
      assert IndentGuide.indent_level(" x", 1) == 1
      assert IndentGuide.indent_level("   x", 1) == 3
    end

    test "unicode content after indent does not affect level" do
      assert IndentGuide.indent_level("  日本語", 2) == 1
    end
  end

  # ── effective_indent_levels/2 ──

  describe "effective_indent_levels/2" do
    test "non-blank lines return their own indent levels" do
      lines = ["hello", "  world", "    deep"]
      assert IndentGuide.effective_indent_levels(lines, @tw) == [0, 1, 2]
    end

    test "blank line inherits next non-blank line's indent" do
      lines = ["  a", "", "  b"]
      assert IndentGuide.effective_indent_levels(lines, @tw) == [1, 1, 1]
    end

    test "consecutive blank lines all inherit from next non-blank" do
      lines = ["    a", "", "", "    b"]
      assert IndentGuide.effective_indent_levels(lines, @tw) == [2, 2, 2, 2]
    end

    test "trailing blank lines get level 0" do
      lines = ["  a", "", ""]
      assert IndentGuide.effective_indent_levels(lines, @tw) == [1, 0, 0]
    end

    test "all blank lines returns all zeros" do
      lines = ["", "", ""]
      assert IndentGuide.effective_indent_levels(lines, @tw) == [0, 0, 0]
    end

    test "empty list returns empty list" do
      assert IndentGuide.effective_indent_levels([], @tw) == []
    end
  end

  # ── compute/3 ──

  describe "compute/3" do
    test "flat code produces no guides" do
      assert IndentGuide.compute(["a", "b", "c"], @tw, 0) == []
    end

    test "empty list produces no guides" do
      assert IndentGuide.compute([], @tw, 0) == []
    end

    test "all blank lines produce no guides" do
      assert IndentGuide.compute(["", "", ""], @tw, 4) == []
    end

    test "basic indented block produces guide at the indent column" do
      lines = ["def foo", "  bar", "  baz", "end"]
      guides = IndentGuide.compute(lines, @tw, 0)

      assert [%{col: 2, active: false}] = guides
    end

    test "nested indentation produces multiple guides" do
      lines = ["def foo", "  if x", "    bar", "  end", "end"]
      guides = IndentGuide.compute(lines, @tw, 4)

      assert [%{col: 2, active: false}, %{col: 4, active: true}] = guides
    end

    test "active guide is deepest guide at or before cursor column" do
      lines = ["def foo", "  if x", "    bar", "  end", "end"]

      # cursor at col 2: guide at 2 is active
      guides = IndentGuide.compute(lines, @tw, 2)
      assert [%{col: 2, active: true}, %{col: 4, active: false}] = guides

      # cursor at col 5: deepest guide <= 5 is col 4
      guides = IndentGuide.compute(lines, @tw, 5)
      assert [%{col: 2, active: false}, %{col: 4, active: true}] = guides
    end

    test "cursor_col 0 means no active guide" do
      lines = ["def foo", "  bar", "end"]
      guides = IndentGuide.compute(lines, @tw, 0)

      assert Enum.all?(guides, fn g -> g.active == false end)
    end

    test "blank lines do not break guide continuity" do
      lines = ["def foo", "  bar", "", "  baz", "end"]
      guides = IndentGuide.compute(lines, @tw, 2)

      assert [%{col: 2, active: true}] = guides
    end

    test "tab indentation with tab_width 4" do
      lines = ["fn", "\tbar", "\t\tbaz", "end"]
      guides = IndentGuide.compute(lines, 4, 4)

      assert [%{col: 4, active: true}, %{col: 8, active: false}] = guides
    end

    test "deeply nested code produces many guides" do
      lines = [
        "a",
        "  b",
        "    c",
        "      d",
        "        e",
        "          f",
        "a"
      ]

      guides = IndentGuide.compute(lines, @tw, 10)

      assert length(guides) == 5
      assert Enum.map(guides, & &1.col) == [2, 4, 6, 8, 10]
      assert Enum.count(guides, & &1.active) == 1
    end
  end

  # ── Property tests ──

  describe "properties" do
    property "at most one guide is active" do
      check all(
              lines <- list_of(line_gen(), min_length: 1, max_length: 15),
              tw <- member_of([2, 4, 8]),
              cursor_col <- integer(0..20)
            ) do
        guides = IndentGuide.compute(lines, tw, cursor_col)
        assert Enum.count(guides, & &1.active) <= 1
      end
    end

    property "all guide columns are positive multiples of tab_width" do
      check all(
              lines <- list_of(line_gen(), min_length: 1, max_length: 15),
              tw <- member_of([2, 4, 8])
            ) do
        guides = IndentGuide.compute(lines, tw, 0)
        assert Enum.all?(guides, fn g -> g.col > 0 and rem(g.col, tw) == 0 end)
      end
    end

    property "active guide col is always <= cursor_col" do
      check all(
              lines <- list_of(line_gen(), min_length: 1, max_length: 15),
              tw <- member_of([2, 4, 8]),
              cursor_col <- integer(0..20)
            ) do
        guides = IndentGuide.compute(lines, tw, cursor_col)
        active = Enum.filter(guides, & &1.active)

        case active do
          [] -> :ok
          [g] -> assert g.col <= cursor_col
        end
      end
    end

    property "effective_indent_levels length matches input length" do
      check all(
              lines <- list_of(line_gen(), min_length: 0, max_length: 20),
              tw <- member_of([2, 4, 8])
            ) do
        levels = IndentGuide.effective_indent_levels(lines, tw)
        assert length(levels) == length(lines)
      end
    end
  end

  # ── Generators ──

  defp line_gen do
    frequency([
      {3,
       StreamData.bind(StreamData.integer(1..8), fn indent ->
         StreamData.bind(
           StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
           fn text ->
             StreamData.constant(String.duplicate(" ", indent) <> text)
           end
         )
       end)},
      {1, StreamData.constant("")},
      {1, StreamData.string(:alphanumeric, min_length: 1, max_length: 10)}
    ])
  end
end
