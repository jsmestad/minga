defmodule Minga.Input.TextFieldTest do
  use ExUnit.Case, async: true

  alias Minga.Input.TextField

  # ── Construction ──────────────────────────────────────────────────────────

  describe "new/0" do
    test "starts with empty line and cursor at origin" do
      tf = TextField.new()
      assert tf.lines == [""]
      assert tf.cursor == {0, 0}
    end
  end

  describe "new/1" do
    test "initializes with single-line text" do
      tf = TextField.new("hello")
      assert tf.lines == ["hello"]
      assert tf.cursor == {0, 5}
    end

    test "initializes with multi-line text" do
      tf = TextField.new("hello\nworld")
      assert tf.lines == ["hello", "world"]
      assert tf.cursor == {1, 5}
    end

    test "initializes with empty string" do
      tf = TextField.new("")
      assert tf.lines == [""]
      assert tf.cursor == {0, 0}
    end

    test "cursor placed at end of last line" do
      tf = TextField.new("a\nbb\nccc")
      assert tf.cursor == {2, 3}
    end
  end

  describe "from_parts/2" do
    test "creates from lines and cursor" do
      tf = TextField.from_parts(["hello", "world"], {0, 3})
      assert tf.lines == ["hello", "world"]
      assert tf.cursor == {0, 3}
    end

    test "clamps cursor to valid bounds" do
      tf = TextField.from_parts(["hi"], {5, 100})
      assert tf.cursor == {0, 2}
    end

    test "empty lines list becomes single empty line" do
      tf = TextField.from_parts([], {0, 0})
      assert tf.lines == [""]
    end
  end

  # ── Access ────────────────────────────────────────────────────────────────

  describe "text/1" do
    test "joins lines with newlines" do
      tf = TextField.from_parts(["hello", "world"], {0, 0})
      assert TextField.text(tf) == "hello\nworld"
    end

    test "empty field returns empty string" do
      assert TextField.text(TextField.new()) == ""
    end
  end

  describe "line_count/1" do
    test "counts lines" do
      tf = TextField.from_parts(["a", "b", "c"], {0, 0})
      assert TextField.line_count(tf) == 3
    end
  end

  describe "empty?/1" do
    test "true for empty field" do
      assert TextField.empty?(TextField.new())
    end

    test "false for non-empty field" do
      refute TextField.empty?(TextField.new("x"))
    end

    test "false for field with only newline" do
      refute TextField.empty?(TextField.from_parts(["", ""], {0, 0}))
    end
  end

  describe "current_line/1" do
    test "returns the line at the cursor" do
      tf = TextField.from_parts(["hello", "world"], {1, 2})
      assert TextField.current_line(tf) == "world"
    end
  end

  # ── Editing ───────────────────────────────────────────────────────────────

  describe "insert_char/2" do
    test "inserts at cursor and advances" do
      tf = TextField.new() |> TextField.insert_char("h") |> TextField.insert_char("i")
      assert TextField.text(tf) == "hi"
      assert tf.cursor == {0, 2}
    end

    test "inserts in the middle of a line" do
      tf = TextField.new("hllo") |> TextField.set_cursor({0, 1}) |> TextField.insert_char("e")
      assert TextField.text(tf) == "hello"
      assert tf.cursor == {0, 2}
    end

    test "handles multi-byte characters" do
      tf = TextField.new() |> TextField.insert_char("é")
      assert TextField.text(tf) == "é"
      assert tf.cursor == {0, 1}
    end
  end

  describe "insert_text/2" do
    test "empty text is no-op" do
      tf = TextField.new("hello")
      assert TextField.insert_text(tf, "") == tf
    end

    test "single-line paste merges into current line" do
      tf =
        TextField.new("hd") |> TextField.set_cursor({0, 1}) |> TextField.insert_text("ello worl")

      assert TextField.text(tf) == "hello world"
    end

    test "multi-line paste splits and merges" do
      tf = TextField.new("ad") |> TextField.set_cursor({0, 1}) |> TextField.insert_text("b\nc")
      assert tf.lines == ["ab", "cd"]
      assert tf.cursor == {1, 1}
    end

    test "multi-line paste with middle lines" do
      tf = TextField.new() |> TextField.insert_text("line1\nline2\nline3")
      assert tf.lines == ["line1", "line2", "line3"]
      assert tf.cursor == {2, 5}
    end

    test "paste into middle of existing multi-line content" do
      tf = TextField.from_parts(["hello", "world"], {0, 5})
      tf = TextField.insert_text(tf, "\ninserted\n")
      # Trailing newline in pasted text creates an empty line before "world"
      assert tf.lines == ["hello", "inserted", "", "world"]
    end
  end

  describe "insert_newline/1" do
    test "splits line at cursor" do
      tf = TextField.new("hello world") |> TextField.set_cursor({0, 5})
      tf = TextField.insert_newline(tf)
      assert tf.lines == ["hello", " world"]
      assert tf.cursor == {1, 0}
    end

    test "at start of line creates empty line before" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 0})
      tf = TextField.insert_newline(tf)
      assert tf.lines == ["", "hello"]
      assert tf.cursor == {1, 0}
    end

    test "at end of line creates empty line after" do
      tf = TextField.new("hello")
      tf = TextField.insert_newline(tf)
      assert tf.lines == ["hello", ""]
      assert tf.cursor == {1, 0}
    end
  end

  describe "delete_backward/1" do
    test "no-op at {0, 0}" do
      tf = TextField.new()
      assert TextField.delete_backward(tf) == tf
    end

    test "deletes character before cursor" do
      tf = TextField.new("hello") |> TextField.delete_backward()
      assert TextField.text(tf) == "hell"
      assert tf.cursor == {0, 4}
    end

    test "deletes from middle of line" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 3}) |> TextField.delete_backward()
      assert TextField.text(tf) == "helo"
      assert tf.cursor == {0, 2}
    end

    test "joins lines when at start of non-first line" do
      tf = TextField.from_parts(["hello", "world"], {1, 0})
      tf = TextField.delete_backward(tf)
      assert tf.lines == ["helloworld"]
      assert tf.cursor == {0, 5}
    end
  end

  describe "delete_forward/1" do
    test "deletes character at cursor" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 0})
      tf = TextField.delete_forward(tf)
      assert TextField.text(tf) == "ello"
      assert tf.cursor == {0, 0}
    end

    test "joins with next line at end of line" do
      tf = TextField.from_parts(["hello", "world"], {0, 5})
      tf = TextField.delete_forward(tf)
      assert tf.lines == ["helloworld"]
    end

    test "no-op at end of last line" do
      tf = TextField.new("hello")
      assert TextField.delete_forward(tf) == tf
    end
  end

  describe "set_text/2" do
    test "replaces all content" do
      tf = TextField.new("old") |> TextField.set_text("new content")
      assert TextField.text(tf) == "new content"
    end
  end

  describe "clear/1" do
    test "resets to empty" do
      tf = TextField.new("hello\nworld") |> TextField.clear()
      assert TextField.text(tf) == ""
      assert tf.cursor == {0, 0}
    end
  end

  # ── Cursor movement ──────────────────────────────────────────────────────

  describe "move_left/1" do
    test "moves left within a line" do
      tf = TextField.new("hello") |> TextField.move_left()
      assert tf.cursor == {0, 4}
    end

    test "wraps to previous line" do
      tf = TextField.from_parts(["hello", "world"], {1, 0})
      tf = TextField.move_left(tf)
      assert tf.cursor == {0, 5}
    end

    test "no-op at {0, 0}" do
      tf = TextField.new() |> TextField.move_left()
      assert tf.cursor == {0, 0}
    end
  end

  describe "move_right/1" do
    test "moves right within a line" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 2})
      tf = TextField.move_right(tf)
      assert tf.cursor == {0, 3}
    end

    test "wraps to next line" do
      tf = TextField.from_parts(["hello", "world"], {0, 5})
      tf = TextField.move_right(tf)
      assert tf.cursor == {1, 0}
    end

    test "no-op at end of last line" do
      tf = TextField.new("hello")
      assert TextField.move_right(tf).cursor == {0, 5}
    end
  end

  describe "move_up/1" do
    test "moves up and clamps column" do
      tf = TextField.from_parts(["hi", "hello"], {1, 4})
      tf = TextField.move_up(tf)
      assert tf.cursor == {0, 2}
    end

    test "returns :at_top on first line" do
      tf = TextField.new("hello")
      assert TextField.move_up(tf) == :at_top
    end
  end

  describe "move_down/1" do
    test "moves down and clamps column" do
      tf = TextField.from_parts(["hello", "hi"], {0, 4})
      tf = TextField.move_down(tf)
      assert tf.cursor == {1, 2}
    end

    test "returns :at_bottom on last line" do
      tf = TextField.new("hello")
      assert TextField.move_down(tf) == :at_bottom
    end
  end

  describe "move_home/1" do
    test "moves to start of line" do
      tf = TextField.new("hello") |> TextField.move_home()
      assert tf.cursor == {0, 0}
    end
  end

  describe "move_end/1" do
    test "moves to end of line" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 2}) |> TextField.move_end()
      assert tf.cursor == {0, 5}
    end
  end

  describe "set_cursor/2" do
    test "sets valid cursor" do
      tf = TextField.new("hello") |> TextField.set_cursor({0, 3})
      assert tf.cursor == {0, 3}
    end

    test "clamps out-of-bounds cursor" do
      tf = TextField.new("hello") |> TextField.set_cursor({5, 100})
      assert tf.cursor == {0, 5}
    end

    test "clamps negative values" do
      tf = TextField.new("hello") |> TextField.set_cursor({-1, -5})
      assert tf.cursor == {0, 0}
    end
  end

  # ── Edge cases ────────────────────────────────────────────────────────────

  describe "unicode handling" do
    test "insert and delete unicode characters" do
      tf =
        TextField.new()
        |> TextField.insert_char("こ")
        |> TextField.insert_char("ん")
        |> TextField.insert_char("に")
        |> TextField.insert_char("ち")
        |> TextField.insert_char("は")

      assert TextField.text(tf) == "こんにちは"
      assert tf.cursor == {0, 5}

      tf = TextField.delete_backward(tf)
      assert TextField.text(tf) == "こんにち"
    end

    test "cursor movement with emoji" do
      tf = TextField.new("👋🌍") |> TextField.set_cursor({0, 1})
      tf = TextField.move_right(tf)
      assert tf.cursor == {0, 2}
    end
  end

  describe "multi-line editing sequences" do
    test "type, newline, type, backspace across lines" do
      tf =
        TextField.new()
        |> TextField.insert_char("a")
        |> TextField.insert_char("b")
        |> TextField.insert_newline()
        |> TextField.insert_char("c")
        |> TextField.delete_backward()
        |> TextField.delete_backward()

      assert tf.lines == ["ab"]
      assert tf.cursor == {0, 2}
    end

    test "navigate with arrows across lines" do
      tf = TextField.from_parts(["hello", "world"], {1, 3})

      # Move up
      tf = TextField.move_up(tf)
      assert tf.cursor == {0, 3}

      # Move to start
      tf = TextField.move_home(tf)
      assert tf.cursor == {0, 0}

      # Move left should no-op at {0,0}
      tf = TextField.move_left(tf)
      assert tf.cursor == {0, 0}

      # Move down
      tf = TextField.move_down(tf)
      assert tf.cursor == {1, 0}

      # Move to end
      tf = TextField.move_end(tf)
      assert tf.cursor == {1, 5}
    end
  end

  describe "get_range/3" do
    test "extracts text within a single line" do
      tf = TextField.new("hello world")
      assert TextField.get_range(tf, {0, 0}, {0, 5}) == "hello"
    end

    test "extracts text across lines" do
      tf = TextField.new("hello\nworld")
      assert TextField.get_range(tf, {0, 3}, {1, 2}) == "lo\nwo"
    end

    test "handles reversed positions" do
      tf = TextField.new("hello world")
      assert TextField.get_range(tf, {0, 5}, {0, 0}) == "hello"
    end

    test "returns empty string for same position" do
      tf = TextField.new("hello")
      assert TextField.get_range(tf, {0, 2}, {0, 2}) == ""
    end
  end

  describe "delete_range/3" do
    test "deletes within a single line" do
      tf = TextField.new("hello world")
      {tf, deleted} = TextField.delete_range(tf, {0, 0}, {0, 5})
      assert deleted == "hello"
      assert TextField.content(tf) == " world"
      assert tf.cursor == {0, 0}
    end

    test "deletes across lines" do
      tf = TextField.new("hello\nworld\nfoo")
      {tf, deleted} = TextField.delete_range(tf, {0, 3}, {1, 3})
      assert deleted == "lo\nwor"
      assert TextField.content(tf) == "helld\nfoo"
      assert tf.cursor == {0, 3}
    end

    test "deletes entire content" do
      tf = TextField.new("hello")
      {tf, deleted} = TextField.delete_range(tf, {0, 0}, {0, 5})
      assert deleted == "hello"
      assert TextField.content(tf) == ""
      assert tf.cursor == {0, 0}
    end
  end

  describe "delete_line/2" do
    test "deletes a middle line" do
      tf = TextField.new("one\ntwo\nthree")
      {tf, deleted} = TextField.delete_line(tf, 1)
      assert deleted == "two"
      assert tf.lines == ["one", "three"]
      assert tf.cursor == {1, 0}
    end

    test "deletes the last line" do
      tf = TextField.new("one\ntwo")
      {tf, deleted} = TextField.delete_line(tf, 1)
      assert deleted == "two"
      assert tf.lines == ["one"]
      assert tf.cursor == {0, 0}
    end

    test "clears the only line" do
      tf = TextField.new("hello")
      {tf, deleted} = TextField.delete_line(tf, 0)
      assert deleted == "hello"
      assert tf.lines == [""]
      assert tf.cursor == {0, 0}
    end

    test "out of range returns unchanged" do
      tf = TextField.new("hello")
      {tf2, deleted} = TextField.delete_line(tf, 5)
      assert deleted == ""
      assert tf2 == tf
    end
  end

  describe "replace_range/4" do
    test "replaces within a single line" do
      tf = TextField.new("hello world")
      tf = TextField.replace_range(tf, {0, 0}, {0, 5}, "goodbye")
      assert TextField.content(tf) == "goodbye world"
    end

    test "replaces across lines with single line" do
      tf = TextField.new("hello\nworld")
      tf = TextField.replace_range(tf, {0, 3}, {1, 3}, "XY")
      assert TextField.content(tf) == "helXYld"
    end

    test "replaces with multi-line text" do
      tf = TextField.new("hello world")
      tf = TextField.replace_range(tf, {0, 5}, {0, 5}, "\nnew\n")
      assert TextField.content(tf) == "hello\nnew\n world"
    end
  end
end
