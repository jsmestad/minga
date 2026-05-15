defmodule Minga.Buffer.SelectionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.{Document, Selection, Span}

  describe "characterwise/3" do
    test "selects text inclusively between two positions" do
      doc = Document.new("abc\ndef")
      selection = Selection.characterwise(doc, {0, 1}, {1, 1})

      assert selection.kind == :characterwise
      assert selection.span == %Span{start: 1, stop: 6}
      assert selection.cursor == {0, 1}
      assert Selection.contents(doc, selection) == "bc\nde"
    end

    test "normalises reversed positions and keeps the cursor at the earlier position" do
      doc = Document.new("abc\ndef")
      selection = Selection.characterwise(doc, {1, 1}, {0, 1})

      assert selection.span == %Span{start: 1, stop: 6}
      assert selection.cursor == {0, 1}
      assert Selection.contents(doc, selection) == "bc\nde"
    end

    test "clamps stale coordinates without crashing" do
      doc = Document.new("hello\n\nworld")
      selection = Selection.characterwise(doc, {1, 43}, {0, 0})

      assert is_binary(Selection.contents(doc, selection))
    end

    test "returns an empty selection when both positions resolve beyond the text" do
      doc = Document.new("ab")
      selection = Selection.characterwise(doc, {99, 99}, {99, 99})

      assert Selection.contents(doc, selection) == ""
    end
  end

  describe "linewise/3" do
    test "selects complete lines including the trailing newline when another line follows" do
      doc = Document.new("a\nb\nc\nd")
      selection = Selection.linewise(doc, 1, 2)

      assert selection.kind == :linewise
      assert selection.span == %Span{start: 2, stop: 6}
      assert selection.cursor == {1, 0}
      assert Selection.contents(doc, selection) == "b\nc\n"
    end

    test "normalises reversed lines" do
      doc = Document.new("a\nb\nc\nd")
      selection = Selection.linewise(doc, 2, 1)

      assert selection.span == %Span{start: 2, stop: 6}
      assert selection.cursor == {1, 0}
    end

    test "clamps lines past the end of the document" do
      doc = Document.new("a\nb")
      selection = Selection.linewise(doc, 1, 99)

      assert selection.span == %Span{start: 2, stop: 3}
      assert Selection.contents(doc, selection) == "b"
    end
  end

  describe "line_contents/3" do
    test "returns joined line contents without a trailing newline" do
      doc = Document.new("a\nb\nc\nd")

      assert Selection.line_contents(doc, 1, 2) == "b\nc"
    end

    test "normalises reversed line arguments" do
      doc = Document.new("a\nb\nc\nd")

      assert Selection.line_contents(doc, 2, 1) == "b\nc"
    end
  end

  describe "delete/2" do
    test "deletes a characterwise selection and places the cursor at the earlier position" do
      doc = Document.new("abc\ndef")
      selection = Selection.characterwise(doc, {0, 1}, {1, 1})
      updated = Selection.delete(doc, selection)

      assert Document.content(updated) == "af"
      assert Document.cursor(updated) == {0, 1}
      assert Document.line_count(updated) == 1
    end

    test "deletes a linewise selection from the middle of the document" do
      doc = Document.new("a\nb\nc\nd")
      selection = Selection.linewise(doc, 1, 2)
      updated = Selection.delete(doc, selection)

      assert Document.content(updated) == "a\nd"
      assert Document.cursor(updated) == {1, 0}
      assert Document.line_count(updated) == 2
    end

    test "trims the dangling newline when deleting through the final line" do
      doc = Document.new("a\nb\nc")
      selection = Selection.linewise(doc, 1, 2)
      updated = Selection.delete(doc, selection)

      assert Document.content(updated) == "a"
      assert Document.cursor(updated) == {0, 0}
      assert Document.line_count(updated) == 1
    end

    test "deletes the only line" do
      doc = Document.new("only")
      selection = Selection.linewise(doc, 0, 0)
      updated = Selection.delete(doc, selection)

      assert Document.content(updated) == ""
      assert Document.cursor(updated) == {0, 0}
      assert Document.line_count(updated) == 1
    end
  end

  describe "clear_line/2" do
    test "returns the cleared text and leaves an empty line" do
      doc = Document.new("one\ntwo\nthree")
      {cleared, updated} = Selection.clear_line(doc, 1)

      assert cleared == "two"
      assert Document.content(updated) == "one\n\nthree"
      assert Document.cursor(updated) == {1, 0}
    end

    test "moves to an already empty line" do
      doc = Document.new("one\n\nthree")
      {cleared, updated} = Selection.clear_line(doc, 1)

      assert cleared == ""
      assert Document.content(updated) == "one\n\nthree"
      assert Document.cursor(updated) == {1, 0}
    end

    test "returns the original document when the line does not exist" do
      doc = Document.new("one")
      {cleared, updated} = Selection.clear_line(doc, 99)

      assert cleared == ""
      assert updated == doc
    end
  end
end
