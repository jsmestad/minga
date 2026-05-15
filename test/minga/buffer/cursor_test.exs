defmodule Minga.Buffer.CursorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{Document, Cursor}

  # ── Movement ──

  describe "move/2 :left" do
    test "moves cursor left" do
      buf = Document.new("hello") |> Cursor.place({0, 3}) |> Cursor.move(:left)
      assert Document.cursor(buf) == {0, 2}
    end

    test "stays at start when already at {0, 0}" do
      buf = Document.new("hello") |> Cursor.move(:left)
      assert Document.cursor(buf) == {0, 0}
    end

    test "wraps to end of previous line" do
      buf = Document.new("ab\ncd") |> Cursor.place({1, 0}) |> Cursor.move(:left)
      assert Document.cursor(buf) == {0, 2}
    end
  end

  describe "move/2 :right" do
    test "moves cursor right" do
      buf = Document.new("hello") |> Cursor.move(:right)
      assert Document.cursor(buf) == {0, 1}
    end

    test "stays at end when already at the end" do
      buf = Document.new("hi") |> Cursor.place({0, 2}) |> Cursor.move(:right)
      assert Document.cursor(buf) == {0, 2}
    end

    test "wraps to start of next line" do
      buf = Document.new("ab\ncd") |> Cursor.place({0, 2}) |> Cursor.move(:right)
      assert Document.cursor(buf) == {1, 0}
    end

    test "moves by byte size for multi-byte characters" do
      buf = Document.new("🥨ab") |> Cursor.move(:right)
      # 🥨 is 4 bytes
      assert Document.cursor(buf) == {0, 4}
    end
  end

  describe "move/2 :up" do
    test "moves cursor to the same column on previous line" do
      buf = Document.new("hello\nworld") |> Cursor.place({1, 3}) |> Cursor.move(:up)
      assert Document.cursor(buf) == {0, 3}
    end

    test "clamps column when previous line is shorter" do
      buf = Document.new("hi\nworld") |> Cursor.place({1, 4}) |> Cursor.move(:up)
      assert Document.cursor(buf) == {0, 2}
    end

    test "stays on first line when already on line 0" do
      buf = Document.new("hello\nworld") |> Cursor.move(:up)
      assert Document.cursor(buf) == {0, 0}
    end
  end

  describe "move/2 :down" do
    test "moves cursor to the same column on next line" do
      buf = Document.new("hello\nworld") |> Cursor.place({0, 3}) |> Cursor.move(:down)
      assert Document.cursor(buf) == {1, 3}
    end

    test "clamps column when next line is shorter" do
      buf = Document.new("hello\nhi") |> Cursor.place({0, 4}) |> Cursor.move(:down)
      assert Document.cursor(buf) == {1, 2}
    end

    test "stays on last line when already on the last line" do
      buf = Document.new("hello\nworld") |> Cursor.place({1, 0}) |> Cursor.move(:down)
      assert Document.cursor(buf) == {1, 0}
    end
  end

  describe "place/2" do
    test "places at exact position" do
      buf = Document.new("abc\ndef\nghi") |> Cursor.place({2, 1})
      assert Document.cursor(buf) == {2, 1}
    end

    test "clamps line to last line" do
      buf = Document.new("abc\ndef") |> Cursor.place({99, 0})
      assert Document.cursor(buf) == {1, 0}
    end

    test "clamps column to end of line (byte size)" do
      buf = Document.new("abc\ndef") |> Cursor.place({0, 99})
      assert Document.cursor(buf) == {0, 3}
    end

    test "preserves buffer content after placement" do
      text = "hello\nworld"
      buf = Document.new(text) |> Cursor.place({1, 3})
      assert Document.content(buf) == text
    end

    test "clamps to grapheme boundary for multi-byte chars" do
      # "café" — é is 2 bytes (0xC3 0xA9), byte_size is 5
      buf = Document.new("café") |> Cursor.place({0, 4})
      # byte 4 is in the middle of é (which starts at byte 3)
      # Should clamp to byte 3 (start of é)
      assert Document.cursor(buf) == {0, 3}
    end
  end

  describe "cache updates" do
    test "place updates cursor cache" do
      doc = Document.new("abc\ndef\nghi") |> Cursor.place({2, 1})

      assert_cache_valid(doc)
      assert Document.cursor(doc) == {2, 1}
    end

    test "moving left across a newline updates line and column" do
      doc = Document.new("ab\ncd") |> Cursor.place({1, 0}) |> Cursor.move(:left)

      assert_cache_valid(doc)
      assert Document.cursor(doc) == {0, 2}
    end

    test "moving right across a newline updates line and column" do
      doc = Document.new("ab\ncd") |> Cursor.place({0, 2}) |> Cursor.move(:right)

      assert_cache_valid(doc)
      assert Document.cursor(doc) == {1, 0}
    end
  end

  property "moving does not alter content" do
    check all(
            text <- string(:printable, min_length: 1, max_length: 200),
            moves <-
              list_of(member_of([:left, :right, :up, :down]), min_length: 1, max_length: 20)
          ) do
      buf = Document.new(text)

      result =
        Enum.reduce(moves, buf, fn dir, acc ->
          Cursor.move(acc, dir)
        end)

      assert Document.content(result) == text
    end
  end

  property "cursor is always within valid bounds" do
    check all(
            text <- string(:printable, min_length: 0, max_length: 200),
            moves <-
              list_of(member_of([:left, :right, :up, :down]), min_length: 0, max_length: 30)
          ) do
      buf = Document.new(text)

      buf =
        Enum.reduce(moves, buf, fn dir, acc ->
          Cursor.move(acc, dir)
        end)

      {line, byte_col} = Document.cursor(buf)
      max_line = Document.line_count(buf) - 1
      assert line >= 0 and line <= max_line

      current_line = Document.line_at(buf, line)
      max_col = byte_size(current_line)
      assert byte_col >= 0 and byte_col <= max_col
    end
  end

  @spec assert_cache_valid(Document.t()) :: :ok
  defp assert_cache_valid(%Document{
         before: before,
         after: after_,
         cursor_line: cursor_line,
         cursor_col: cursor_col,
         line_count: line_count
       }) do
    lines_before = :binary.split(before, "\n", [:global])
    expected_line = length(lines_before) - 1
    expected_column = lines_before |> List.last() |> byte_size()
    text = before <> after_

    expected_line_count =
      case text do
        "" -> 1
        _ -> length(:binary.matches(text, "\n")) + 1
      end

    assert cursor_line == expected_line
    assert cursor_col == expected_column
    assert line_count == expected_line_count

    :ok
  end
end
