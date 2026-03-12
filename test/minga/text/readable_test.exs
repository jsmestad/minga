defmodule Minga.Text.ReadableTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Text.Readable

  describe "Document implementation" do
    test "content/1 returns full text" do
      doc = Document.new("hello\nworld")
      assert Readable.content(doc) == "hello\nworld"
    end

    test "line_at/2 returns the nth line" do
      doc = Document.new("alpha\nbeta\ngamma")
      assert Readable.line_at(doc, 0) == "alpha"
      assert Readable.line_at(doc, 1) == "beta"
      assert Readable.line_at(doc, 2) == "gamma"
    end

    test "line_at/2 returns nil for out-of-range index" do
      doc = Document.new("hello")
      assert Readable.line_at(doc, 5) == nil
    end

    test "line_count/1 returns number of lines" do
      assert Readable.line_count(Document.new("one\ntwo\nthree")) == 3
      assert Readable.line_count(Document.new("single")) == 1
      assert Readable.line_count(Document.new("")) == 1
    end

    test "offset_to_position/2 converts byte offset to {line, col}" do
      doc = Document.new("ab\ncd\nef")
      assert Readable.offset_to_position(doc, 0) == {0, 0}
      assert Readable.offset_to_position(doc, 1) == {0, 1}
      assert Readable.offset_to_position(doc, 3) == {1, 0}
      assert Readable.offset_to_position(doc, 6) == {2, 0}
    end
  end
end
