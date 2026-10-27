defmodule Minga.Buffer.PositionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{Document, Position}
  alias Minga.Test.Generators

  describe "display_column/2" do
    test "ASCII: storage column equals display column" do
      doc = Document.new("hello")

      assert Position.display_column(doc, {0, 3}) == 3
    end

    test "multi-byte: storage column can be larger than display column" do
      doc = Document.new("café")

      assert Position.display_column(doc, {0, 3}) == 3
      assert Position.display_column(doc, {0, 5}) == 4
    end

    test "emoji: one character can occupy multiple bytes" do
      doc = Document.new("🥨ab")

      assert Position.display_column(doc, {0, 0}) == 0
      assert Position.display_column(doc, {0, 4}) == 1
      assert Position.display_column(doc, {0, 5}) == 2
    end
  end

  describe "last_character_on_line/1" do
    test "empty string returns 0" do
      assert Position.last_character_on_line("") == 0
    end

    test "ASCII string" do
      assert Position.last_character_on_line("hello") == 4
    end

    test "multi-byte last character" do
      assert Position.last_character_on_line("café") == 3
    end

    test "emoji last character" do
      assert Position.last_character_on_line("hi🥨") == 2
    end
  end

  describe "point_for/2" do
    test "uses line starts for direct lookup" do
      doc = Document.new("hello\nworld\nfoo")

      assert Position.point_for(doc, {0, 0}) == 0
      assert Position.point_for(doc, {1, 0}) == 6
      assert Position.point_for(doc, {2, 0}) == 12
      assert Position.point_for(doc, {2, 2}) == 14
    end

    test "clamps column beyond line length to text size" do
      doc = Document.new("ab\ncd")

      assert Position.point_for(doc, {0, 50}) == 5
    end

    test "clamps line beyond last line" do
      doc = Document.new("ab\ncd")

      assert Position.point_for(doc, {99, 0}) == 3
    end

    test "keeps a column past the line end as a byte offset into later lines" do
      doc = Document.new("ab\ncd\nef")

      assert Position.point_for(doc, {0, 4}) == 4
      assert Position.point_for(doc, {1, 3}) == 6
    end

    test "an empty document resolves every position to zero" do
      assert Position.point_for(Document.new(""), {3, 9}) == 0
    end

    test "uses pending line shifts and a missing index" do
      pending =
        "ab\ncd\nef" |> Document.new() |> Document.move_to({0, 1}) |> Document.insert_text("é")

      missing = %{Document.new("ab\ncd\nef") | line_offsets: nil}

      assert {:pending, _starts, 0, 2} = pending.line_offsets
      assert Position.point_for(pending, {2, 1}) == 9
      assert Position.point_for(pending, {2, 99}) == 10
      assert Position.point_for(missing, {2, 1}) == 7
    end
  end

  describe "from_point/2" do
    test "returns the editor position at a document point" do
      doc = Document.new("ab\ncd")

      assert Position.from_point(doc, 0) == {0, 0}
      assert Position.from_point(doc, 2) == {0, 2}
      assert Position.from_point(doc, 3) == {1, 0}
      assert Position.from_point(doc, 5) == {1, 2}
    end

    test "a newline belongs to the line it ends" do
      doc = Document.new("ab\ncd\n")

      assert Position.from_point(doc, 2) == {0, 2}
      assert Position.from_point(doc, 5) == {1, 2}
      assert Position.from_point(doc, 6) == {2, 0}
    end

    test "points past the end resolve to the document end" do
      assert Position.from_point(Document.new("ab\ncd"), 99) == {1, 2}
      assert Position.from_point(Document.new("ab\n"), 99) == {1, 0}
      assert Position.from_point(Document.new(""), 4) == {0, 0}
    end

    test "points inside a multi-byte codepoint keep their exact byte column" do
      doc = Document.new("é\n🥨b")

      assert Position.from_point(doc, 1) == {0, 1}
      assert Position.from_point(doc, 4) == {1, 1}
      assert Position.from_point(doc, 7) == {1, 4}
    end

    test "uses pending positive and negative line shifts" do
      grown =
        "ab\ncd\nef" |> Document.new() |> Document.move_to({0, 1}) |> Document.insert_text("XY")

      shrunk =
        "abc\nde\nf" |> Document.new() |> Document.move_to({1, 1}) |> Document.delete_before()

      assert {:pending, _starts, 0, 2} = grown.line_offsets
      assert {:pending, _starts, 1, -1} = shrunk.line_offsets
      assert Position.from_point(grown, 9) == {2, 1}
      assert Position.from_point(shrunk, 5) == {1, 1}
      assert Position.from_point(shrunk, 6) == {2, 0}
    end

    test "rebuilds a missing index from content" do
      doc = %{Document.new("ab\ncd") | line_offsets: nil}

      assert Position.from_point(doc, 4) == {1, 1}
    end
  end

  describe "position and point conversion" do
    property "matches a naive byte walk in both directions for every index state" do
      check all({doc, _state} <- Generators.indexed_document()) do
        text = Document.content(doc)
        size = byte_size(text)
        line_count = text |> :binary.split("\n", [:global]) |> length()

        for point <- 0..(size + 2) do
          position = Position.from_point(doc, point)

          assert position == naive_from_point(text, point)
          assert Position.point_for(doc, position) == min(point, size)
        end

        for line <- 0..line_count, column <- [0, 1, 3, size, size + 50_000] do
          assert Position.point_for(doc, {line, column}) == naive_point_for(text, {line, column})
        end
      end
    end
  end

  describe "after_character_at/2" do
    test "moves to the point after an ASCII character" do
      assert Position.after_character_at("abc", 1) == 2
    end

    test "moves to the point after a multi-byte character" do
      assert Position.after_character_at("a🥨b", 1) == 5
    end

    test "stays at the end of text" do
      assert Position.after_character_at("ab", 2) == 2
    end
  end

  # The previous implementation's byte walk: count newlines and bytes up to the point.
  @spec naive_from_point(String.t(), Position.point()) :: Position.t()
  defp naive_from_point(text, point) do
    segments =
      text |> binary_part(0, min(point, byte_size(text))) |> :binary.split("\n", [:global])

    {length(segments) - 1, segments |> List.last() |> byte_size()}
  end

  @spec naive_point_for(String.t(), Position.t()) :: Position.point()
  defp naive_point_for(text, {line, column}) do
    lines = :binary.split(text, "\n", [:global])
    preceding = Enum.take(lines, min(line, length(lines) - 1))
    line_start = Enum.reduce(preceding, 0, &(byte_size(&1) + 1 + &2))
    min(line_start + column, byte_size(text))
  end
end
