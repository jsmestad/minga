defmodule MingaEditor.Renderer.InvisibleCharsTest do
  @moduledoc "Tests for invisible character substitution in the line renderer."
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.Line

  describe "substitute_invisible_pairs/2" do
    test "no invisible chars returns pairs unchanged" do
      pairs = [{"h", 1}, {"i", 1}]
      assert Line.substitute_invisible_pairs(pairs, 4) == pairs
    end

    test "tab at column 0 expands to arrow + fill spaces" do
      pairs = [{"	", 0}, {"x", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"→", 1}, {" ", 1}, {" ", 1}, {" ", 1}, {"x", 1}]
    end

    test "tab at column 2 with tab_width 4 expands to 2 chars" do
      pairs = [{"a", 1}, {"b", 1}, {"	", 0}, {"x", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"a", 1}, {"b", 1}, {"→", 1}, {" ", 1}, {"x", 1}]
    end

    test "tab at tab stop boundary expands to full tab_width" do
      pairs = [{"a", 1}, {"b", 1}, {"c", 1}, {"d", 1}, {"	", 0}]
      result = Line.substitute_invisible_pairs(pairs, 4)

      assert result == [
               {"a", 1},
               {"b", 1},
               {"c", 1},
               {"d", 1},
               {"→", 1},
               {" ", 1},
               {" ", 1},
               {" ", 1}
             ]
    end

    test "tab with tab_width 2" do
      pairs = [{"	", 0}, {"x", 1}]
      result = Line.substitute_invisible_pairs(pairs, 2)
      assert result == [{"→", 1}, {" ", 1}, {"x", 1}]
    end

    test "trailing spaces become dots" do
      pairs = [{"h", 1}, {"i", 1}, {" ", 1}, {" ", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"h", 1}, {"i", 1}, {"·", 1}, {"·", 1}]
    end

    test "interior spaces are not replaced" do
      pairs = [{"h", 1}, {" ", 1}, {"i", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"h", 1}, {" ", 1}, {"i", 1}]
    end

    test "interior spaces after tabs are not replaced" do
      pairs = [{"	", 0}, {" ", 1}, {"x", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"→", 1}, {" ", 1}, {" ", 1}, {" ", 1}, {" ", 1}, {"x", 1}]
    end

    test "line with only spaces becomes all dots" do
      pairs = [{" ", 1}, {" ", 1}, {" ", 1}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"·", 1}, {"·", 1}, {"·", 1}]
    end

    test "empty line returns empty" do
      assert Line.substitute_invisible_pairs([], 4) == []
    end

    test "mixed tabs and trailing whitespace" do
      pairs = [{"	", 0}, {"h", 1}, {"i", 1}, {" ", 1}, {"	", 0}]
      result = Line.substitute_invisible_pairs(pairs, 4)

      assert result == [
               {"→", 1},
               {" ", 1},
               {" ", 1},
               {" ", 1},
               {"h", 1},
               {"i", 1},
               {"·", 1},
               {"→", 1}
             ]
    end

    test "consecutive tabs expand correctly" do
      pairs = [{"	", 0}, {"	", 0}]
      result = Line.substitute_invisible_pairs(pairs, 4)

      assert result == [
               {"→", 1},
               {" ", 1},
               {" ", 1},
               {" ", 1},
               {"→", 1},
               {" ", 1},
               {" ", 1},
               {" ", 1}
             ]
    end

    test "trailing tab after text expands and becomes visible" do
      pairs = [{"x", 1}, {"	", 0}]
      result = Line.substitute_invisible_pairs(pairs, 4)
      assert result == [{"x", 1}, {"→", 1}, {" ", 1}, {" ", 1}]
    end
  end
end
