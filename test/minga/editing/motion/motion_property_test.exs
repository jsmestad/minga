defmodule Minga.Editing.Motion.MotionPropertyTest do
  @moduledoc """
  Property-based tests for motion functions.

  Verifies that any motion applied to any valid buffer state
  produces a cursor position that remains within buffer bounds.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Editing.Motion.Document, as: DocMotion
  alias Minga.Editing.Motion.Line
  alias Minga.Editing.Motion.Word

  import Minga.Test.Generators

  defp assert_in_bounds({line, col}, content) do
    lines = String.split(content, "\n")
    line_count = length(lines)
    assert line >= 0, "line #{line} is negative"
    assert line < line_count, "line #{line} >= line_count #{line_count}"
    line_text = Enum.at(lines, line, "")
    assert col >= 0, "col #{col} is negative"
    assert col <= byte_size(line_text), "col #{col} > line length #{byte_size(line_text)}"
  end

  # ── Word motions ─────────────────────────────────────────────────────────

  property "word_forward always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Word.word_forward(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "word_backward always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Word.word_backward(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "word_end always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Word.word_end(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "word_forward_big always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Word.word_forward_big(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "word_backward_big always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Word.word_backward_big(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  # ── Line motions ──────────────────────────────────────────────────────────

  property "line_start always returns col 0" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      {_line, col} = Line.line_start(doc, pos)
      assert col == 0
    end
  end

  property "line_end always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Line.line_end(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "first_non_blank always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = Line.first_non_blank(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  # ── Document motions ──────────────────────────────────────────────────────

  property "document_start always returns {0, 0}" do
    check all(content <- buffer_content(), max_runs: 100) do
      doc = Document.new(content)
      assert DocMotion.document_start(doc) == {0, 0}
    end
  end

  property "document_end always produces a position within buffer bounds" do
    check all(content <- buffer_content(), max_runs: 100) do
      doc = Document.new(content)
      result = DocMotion.document_end(doc)
      assert_in_bounds(result, content)
    end
  end

  property "paragraph_forward always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = DocMotion.paragraph_forward(doc, pos)
      assert_in_bounds(result, content)
    end
  end

  property "paragraph_backward always produces a position within buffer bounds" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      result = DocMotion.paragraph_backward(doc, pos)
      assert_in_bounds(result, content)
    end
  end
end
