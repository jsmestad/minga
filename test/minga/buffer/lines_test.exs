defmodule Minga.Buffer.LinesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{Document, Lines}

  describe "count/1" do
    test "empty text has one line" do
      assert Lines.count("") == 1
    end

    test "single line without newline" do
      assert Lines.count("hello") == 1
    end

    test "counts lines separated by newlines" do
      assert Lines.count("a\nb\nc") == 3
    end

    test "trailing newline adds an empty line" do
      assert Lines.count("a\nb\n") == 3
    end
  end

  describe "fetch/2" do
    test "returns the first line" do
      buf = Document.new("hello\nworld")
      assert Lines.fetch(buf, 0) == "hello"
    end

    test "returns the second line" do
      buf = Document.new("hello\nworld")
      assert Lines.fetch(buf, 1) == "world"
    end

    test "returns nil for out-of-range line" do
      buf = Document.new("hello")
      assert Lines.fetch(buf, 5) == nil
    end

    test "returns empty string for empty line" do
      buf = Document.new("hello\n\nworld")
      assert Lines.fetch(buf, 1) == ""
    end
  end

  describe "slice/3" do
    test "returns a range of lines" do
      buf = Document.new("a\nb\nc\nd\ne")
      assert Lines.slice(buf, 1, 3) == ["b", "c", "d"]
    end

    test "returns empty list when start is past end" do
      buf = Document.new("a\nb")
      assert Lines.slice(buf, 10, 5) == []
    end

    test "returns fewer lines when count exceeds available" do
      buf = Document.new("a\nb\nc")
      assert Lines.slice(buf, 1, 10) == ["b", "c"]
    end
  end

  property "fetch/2 matches naive String.split for random content" do
    check all(
            text <- string(:printable, min_length: 0, max_length: 500),
            line_num <- integer(0..20)
          ) do
      buf = Document.new(text)
      naive = text |> String.split("\n") |> Enum.at(line_num)
      indexed = Lines.fetch(buf, line_num)
      assert indexed == naive
    end
  end

  property "slice/3 matches naive String.split |> Enum.slice for random content" do
    check all(
            text <- string(:printable, min_length: 0, max_length: 500),
            start <- integer(0..15),
            count <- integer(1..10)
          ) do
      buf = Document.new(text)
      naive = text |> String.split("\n") |> Enum.slice(start, count)
      indexed = Lines.slice(buf, start, count)
      assert indexed == naive
    end
  end

  test "fetch/2 works after mutations invalidate the cache" do
    buf = Document.new("aaa\nbbb\nccc")
    assert Lines.fetch(buf, 1) == "bbb"

    # Insert invalidates cache
    buf = Document.insert_text(buf, "X")
    assert Lines.fetch(buf, 0) == "Xaaa"

    # Move invalidates cache
    buf = Document.move_to(buf, {1, 0})
    assert Lines.fetch(buf, 1) == "bbb"

    # Delete invalidates cache
    buf = Document.delete_at(buf)
    assert Lines.fetch(buf, 1) == "bb"
  end
end
