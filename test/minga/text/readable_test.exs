defmodule Minga.Text.ReadableTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Input.TextField
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

  describe "TextField implementation" do
    test "content/1 returns full text" do
      tf = TextField.new("hello\nworld")
      assert Readable.content(tf) == "hello\nworld"
    end

    test "line_at/2 returns the nth line" do
      tf = TextField.new("alpha\nbeta\ngamma")
      assert Readable.line_at(tf, 0) == "alpha"
      assert Readable.line_at(tf, 1) == "beta"
      assert Readable.line_at(tf, 2) == "gamma"
    end

    test "line_at/2 returns nil for out-of-range index" do
      tf = TextField.new("hello")
      assert Readable.line_at(tf, 5) == nil
    end

    test "line_count/1 returns number of lines" do
      assert Readable.line_count(TextField.new("one\ntwo\nthree")) == 3
      assert Readable.line_count(TextField.new("single")) == 1
      assert Readable.line_count(TextField.new()) == 1
    end

    test "offset_to_position/2 converts byte offset to {line, col}" do
      tf = TextField.new("ab\ncd\nef")
      assert Readable.offset_to_position(tf, 0) == {0, 0}
      assert Readable.offset_to_position(tf, 1) == {0, 1}
      assert Readable.offset_to_position(tf, 3) == {1, 0}
      assert Readable.offset_to_position(tf, 6) == {2, 0}
    end
  end

  describe "motions work with TextField" do
    test "word_forward on TextField" do
      tf = TextField.new("hello world")
      assert Minga.Motion.word_forward(tf, {0, 0}) == {0, 6}
    end

    test "word_backward on TextField" do
      tf = TextField.new("hello world")
      assert Minga.Motion.word_backward(tf, {0, 6}) == {0, 0}
    end

    test "word_end on TextField" do
      tf = TextField.new("hello world")
      assert Minga.Motion.word_end(tf, {0, 0}) == {0, 4}
    end

    test "line_start on TextField" do
      tf = TextField.new("  hello")
      assert Minga.Motion.line_start(tf, {0, 4}) == {0, 0}
    end

    test "line_end on TextField" do
      tf = TextField.new("hello\nworld")
      assert Minga.Motion.line_end(tf, {0, 0}) == {0, 4}
    end

    test "first_non_blank on TextField" do
      tf = TextField.new("  hello")
      assert Minga.Motion.first_non_blank(tf, {0, 0}) == {0, 2}
    end

    test "document_start on TextField" do
      tf = TextField.new("hello\nworld")
      assert Minga.Motion.document_start(tf) == {0, 0}
    end

    test "document_end on TextField" do
      tf = TextField.new("hello\nworld")
      assert Minga.Motion.document_end(tf) == {1, 4}
    end

    test "paragraph_forward on TextField" do
      tf = TextField.new("hello\nworld\n\nfoo")
      assert Minga.Motion.paragraph_forward(tf, {0, 0}) == {2, 0}
    end

    test "find_char_forward on TextField" do
      tf = TextField.new("hello world")
      assert Minga.Motion.find_char_forward(tf, {0, 0}, "w") == {0, 6}
    end

    test "inner_word text object on TextField" do
      tf = TextField.new("hello world")
      assert Minga.TextObject.inner_word(tf, {0, 0}) == {{0, 0}, {0, 4}}
    end

    test "a_word text object on TextField" do
      tf = TextField.new("hello world")
      assert Minga.TextObject.a_word(tf, {0, 0}) == {{0, 0}, {0, 5}}
    end
  end
end
