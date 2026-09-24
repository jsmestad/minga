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
  alias Minga.RenderModel.Window.Span
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.UI.FontRegistry

  describe "segments_to_text_and_spans/2" do
    test "allocates fallback families in encounter order and reuses repeated families" do
      first = Face.new(font_family: "First Fallback")
      second = Face.new(font_family: "Second Fallback")

      {text, spans, registry} =
        Composition.segments_to_text_and_spans(
          [{"one", first}, {" two", first}, {" three", second}],
          FontRegistry.new()
        )

      assert text == "one two three"
      assert Enum.map(spans, & &1.font_id) == [1, 1, 2]

      assert FontRegistry.pending_registrations(registry) == [
               {1, "First Fallback"},
               {2, "Second Fallback"}
             ]
    end

    test "the same input and initial registry produce identical spans and registry values" do
      segments = [
        {"ordinary", Face.new(font_family: "Ordinary Fallback")},
        {" virtual", Face.new(font_family: "Virtual Fallback")}
      ]

      initial = FontRegistry.new()
      first = Composition.segments_to_text_and_spans(segments, initial)
      second = Composition.segments_to_text_and_spans(segments, initial)

      assert first == second
      assert initial == FontRegistry.new()
    end

    test "successive and concurrent computations cannot influence one another" do
      build = fn family ->
        Composition.segments_to_text_and_spans(
          [{family, Face.new(font_family: family)}],
          FontRegistry.new()
        )
      end

      {_, [%Span{font_id: 1}], first_registry} = build.("First")
      {_, [%Span{font_id: 1}], second_registry} = build.("Second")

      first_task = Task.async(fn -> build.("Task First") end)
      second_task = Task.async(fn -> build.("Task Second") end)

      {_, [%Span{font_id: 1}], task_first_registry} = Task.await(first_task)
      {_, [%Span{font_id: 1}], task_second_registry} = Task.await(second_task)

      assert FontRegistry.pending_registrations(first_registry) == [{1, "First"}]
      assert FontRegistry.pending_registrations(second_registry) == [{1, "Second"}]
      assert FontRegistry.pending_registrations(task_first_registry) == [{1, "Task First"}]
      assert FontRegistry.pending_registrations(task_second_registry) == [{1, "Task Second"}]
    end
  end

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

  describe "present_whitespace/4" do
    @text_face Face.new(fg: :white)
    @ws_face Face.new(fg: :bright_black)

    test "expands tabs to spaces with the source face when invisibles are hidden" do
      segments = [{"a\tb\t", @text_face}]

      assert Composition.present_whitespace(segments, 4, false, @ws_face) == [
               {"a", @text_face},
               {"   ", @text_face},
               {"b", @text_face},
               {"   ", @text_face}
             ]
    end

    test "uses the composed column across styled and virtual-looking segments" do
      virtual_face = Face.new(fg: :cyan)

      assert Composition.present_whitespace(
               [{"xx", virtual_face}, {"\tvalue", @text_face}],
               4,
               true,
               @ws_face
             ) == [
               {"xx", virtual_face},
               {"→ ", @ws_face},
               {"value", @text_face}
             ]
    end
  end
end
