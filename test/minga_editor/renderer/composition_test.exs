defmodule MingaEditor.Renderer.CompositionTest do
  @moduledoc """
  Unit tests for the semantic-path composition helpers.

  The invisible-character cases here were ported from the deleted
  `MingaEditor.Renderer.Line` draw path (`substitute_invisible_pairs/2`), whose
  granular edge-case coverage moved to `Composition.apply_invisible_chars/3` when
  the draw-based line renderer was removed (issue #2324). They pin the same
  tab-stop math, trailing-vs-interior whitespace handling, and marker faces that
  the window render-model builder relies on.
  """
  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias MingaEditor.Renderer.Composition

  describe "apply_invisible_chars/3" do
    # A distinct text face and whitespace face keep content runs and marker
    # segments separate so the grouped output is unambiguous to assert on.
    @text_face Face.new(fg: :white)
    @ws_face Face.new(fg: :bright_black)

    defp seg(text), do: {text, @text_face}

    test "no invisible chars returns segments unchanged" do
      segments = [seg("hi")]
      assert Composition.apply_invisible_chars(segments, 4, @ws_face) == [seg("hi")]
    end

    test "tab at column 0 expands to arrow plus fill spaces" do
      segments = [seg("\tx")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [{"→   ", @ws_face}, seg("x")]
    end

    test "tab at column 2 with tab_width 4 expands to 2 columns" do
      segments = [seg("ab\tx")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [seg("ab"), {"→ ", @ws_face}, seg("x")]
    end

    test "tab at tab-stop boundary expands to full tab_width" do
      segments = [seg("abcd\t")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [seg("abcd"), {"→   ", @ws_face}]
    end

    test "tab with tab_width 2" do
      segments = [seg("\tx")]
      result = Composition.apply_invisible_chars(segments, 2, @ws_face)
      assert result == [{"→ ", @ws_face}, seg("x")]
    end

    test "trailing spaces become dots" do
      segments = [seg("hi  ")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [seg("hi"), {"·", @ws_face}, {"·", @ws_face}]
    end

    test "interior spaces are not replaced" do
      segments = [seg("h i")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [seg("h i")]
    end

    test "interior spaces after a tab are not replaced" do
      segments = [seg("\t x")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      # Tab fills to column 4, then a literal interior space, then "x".
      assert result == [{"→   ", @ws_face}, seg(" x")]
    end

    test "line with only spaces becomes all dots" do
      segments = [seg("   ")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [{"·", @ws_face}, {"·", @ws_face}, {"·", @ws_face}]
    end

    test "empty segments return empty" do
      assert Composition.apply_invisible_chars([], 4, @ws_face) == []
    end

    test "mixed tabs and trailing whitespace" do
      segments = [seg("\thi \t")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)

      assert result == [
               {"→   ", @ws_face},
               seg("hi"),
               {"·", @ws_face},
               {"→", @ws_face}
             ]
    end

    test "consecutive tabs expand correctly" do
      segments = [seg("\t\t")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [{"→   ", @ws_face}, {"→   ", @ws_face}]
    end

    test "trailing tab after text expands and stays visible" do
      segments = [seg("x\t")]
      result = Composition.apply_invisible_chars(segments, 4, @ws_face)
      assert result == [seg("x"), {"→  ", @ws_face}]
    end
  end
end
