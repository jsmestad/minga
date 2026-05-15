defmodule Minga.Buffer.PositionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.{Document, Position}

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
  end

  describe "from_point/2" do
    test "returns the editor position at a document point" do
      doc = Document.new("ab\ncd")

      assert Position.from_point(doc, 0) == {0, 0}
      assert Position.from_point(doc, 2) == {0, 2}
      assert Position.from_point(doc, 3) == {1, 0}
      assert Position.from_point(doc, 5) == {1, 2}
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
end
