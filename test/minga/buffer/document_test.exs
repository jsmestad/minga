defmodule Minga.Buffer.DocumentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document

  describe "new/1" do
    test "creates an empty buffer" do
      buf = Document.new()
      assert Document.content(buf) == ""
      assert Document.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a string" do
      buf = Document.new("hello")
      assert Document.content(buf) == "hello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a multi-line string" do
      buf = Document.new("hello\nworld\n!")
      assert Document.content(buf) == "hello\nworld\n!"
      assert Document.cursor(buf) == {0, 0}
    end
  end

  describe "empty?/1" do
    test "returns true for empty buffer" do
      assert Document.empty?(Document.new())
    end

    test "returns false for non-empty buffer" do
      refute Document.empty?(Document.new("x"))
    end
  end

  describe "cursor/1" do
    test "starts at {0, 0} for new buffer" do
      assert Document.cursor(Document.new("hello")) == {0, 0}
    end
  end

  # ── Insertion ──

  describe "insert_text/2" do
    test "inserts at the beginning of a buffer" do
      buf = Document.new("hello") |> Document.insert_text("X")
      assert Document.content(buf) == "Xhello"
      assert Document.cursor(buf) == {0, 1}
    end

    test "inserts in the middle after moving" do
      buf =
        Document.new("hello")
        |> Document.move(:right)
        |> Document.move(:right)
        |> Document.insert_text("X")

      assert Document.content(buf) == "heXllo"
      assert Document.cursor(buf) == {0, 3}
    end

    test "inserts at the end" do
      buf = Document.new("hi") |> Document.move_to({0, 2}) |> Document.insert_text("!")
      assert Document.content(buf) == "hi!"
    end

    test "inserts a newline" do
      buf = Document.new("ab") |> Document.move(:right) |> Document.insert_text("\n")
      assert Document.content(buf) == "a\nb"
      assert Document.cursor(buf) == {1, 0}
    end

    test "inserts unicode emoji — byte_col reflects byte size" do
      buf = Document.new("hi") |> Document.insert_text("🥨")
      assert Document.content(buf) == "🥨hi"
      # 🥨 is 4 bytes
      assert Document.cursor(buf) == {0, 4}
    end

    test "inserts multi-byte CJK character" do
      buf = Document.new("hi") |> Document.insert_text("日")
      assert Document.content(buf) == "日hi"
      # 日 is 3 bytes
      assert Document.cursor(buf) == {0, 3}
    end

    test "inserts into empty buffer" do
      buf = Document.new() |> Document.insert_text("a")
      assert Document.content(buf) == "a"
      assert Document.cursor(buf) == {0, 1}
    end

    test "inserts a multi-character string in one operation" do
      buf = Document.new("world") |> Document.insert_text("hello ")
      assert Document.content(buf) == "hello world"
      assert Document.cursor(buf) == {0, 6}
    end

    test "inserts text containing newlines" do
      buf = Document.new("end") |> Document.insert_text("line1\nline2\n")
      assert Document.content(buf) == "line1\nline2\nend"
      assert Document.cursor(buf) == {2, 0}
      assert Document.line_count(buf) == 3
    end

    test "empty string is a no-op" do
      buf = Document.new("hello")
      assert Document.insert_text(buf, "") == buf
    end

    test "inserts at cursor position after move" do
      buf =
        Document.new("hello world")
        |> Document.move_to({0, 5})
        |> Document.insert_text(" beautiful")

      assert Document.content(buf) == "hello beautiful world"
      assert Document.cursor(buf) == {0, 15}
    end

    test "inserts unicode text in bulk" do
      buf = Document.new("end") |> Document.insert_text("🎉🎊")
      assert Document.content(buf) == "🎉🎊end"
      # Each emoji is 4 bytes
      assert Document.cursor(buf) == {0, 8}
    end

    test "inserts multi-line text in the middle of existing content" do
      buf =
        Document.new("startend")
        |> Document.move_to({0, 5})
        |> Document.insert_text("A\nB\nC")

      assert Document.content(buf) == "startA\nB\nCend"
      assert Document.cursor(buf) == {2, 1}
      assert Document.line_count(buf) == 3
    end
  end

  # ── Deletion ──

  describe "delete_before/1" do
    test "deletes the character before the cursor" do
      buf =
        Document.new("hello")
        |> Document.move(:right)
        |> Document.move(:right)
        |> Document.delete_before()

      assert Document.content(buf) == "hllo"
      assert Document.cursor(buf) == {0, 1}
    end

    test "does nothing at the start of the buffer" do
      buf = Document.new("hello") |> Document.delete_before()
      assert Document.content(buf) == "hello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "deleting newline joins lines" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.delete_before()
      assert Document.content(buf) == "abcd"
      assert Document.cursor(buf) == {0, 2}
    end

    test "deletes unicode character" do
      buf =
        Document.new("🥨hi")
        |> Document.move(:right)
        |> Document.delete_before()

      assert Document.content(buf) == "hi"
    end

    test "does nothing on empty buffer" do
      buf = Document.new() |> Document.delete_before()
      assert Document.content(buf) == ""
      assert Document.empty?(buf)
    end
  end

  describe "delete_at/1" do
    test "deletes the character at the cursor" do
      buf = Document.new("hello") |> Document.delete_at()
      assert Document.content(buf) == "ello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "does nothing at the end of the buffer" do
      buf = Document.new("hi") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert Document.content(buf) == "hi"
    end

    test "deletes newline at cursor joins lines" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert Document.content(buf) == "abcd"
      assert Document.cursor(buf) == {0, 2}
    end

    test "deletes unicode character at cursor" do
      buf = Document.new("🥨hi") |> Document.delete_at()
      assert Document.content(buf) == "hi"
    end
  end

  # ── Round-trip integrity ──

  describe "content integrity" do
    test "insert then delete_before restores original" do
      buf = Document.new("hello")
      original = Document.content(buf)

      buf =
        buf |> Document.move(:right) |> Document.insert_text("X") |> Document.delete_before()

      assert Document.content(buf) == original
    end

    test "moving around does not change content" do
      text = "hello\nworld\nfoo"
      buf = Document.new(text)

      buf =
        buf
        |> Document.move(:right)
        |> Document.move(:down)
        |> Document.move(:left)
        |> Document.move(:up)
        |> Document.move_to({2, 1})
        |> Document.move_to({0, 0})

      assert Document.content(buf) == text
    end

    test "multiple insertions and deletions" do
      buf =
        Document.new()
        |> Document.insert_text("a")
        |> Document.insert_text("b")
        |> Document.insert_text("c")
        |> Document.delete_before()
        |> Document.insert_text("C")

      assert Document.content(buf) == "abC"
    end
  end

  # ── Unicode edge cases ──

  describe "unicode handling" do
    test "handles combining characters" do
      # é as e + combining acute accent
      text = "cafe\u0301"
      buf = Document.new(text)
      assert Document.line_count(buf) == 1
      assert Document.content(buf) == text
    end

    test "handles emoji sequences" do
      buf = Document.new("🇩🇪") |> Document.insert_text("!")
      assert Document.content(buf) == "!🇩🇪"
    end
  end

  # ── Property-based tests ──

  describe "property: insert/delete round-trip" do
    property "inserting then deleting before restores the buffer" do
      check all(
              text <- string(:ascii, min_length: 0, max_length: 100),
              char <- string(:ascii, length: 1),
              pos <- integer(0..max(byte_size("") + 100, 1))
            ) do
        buf = Document.new(text)
        clamped_pos = min(pos, byte_size(text))
        line_col = byte_offset_to_position(text, clamped_pos)

        buf =
          buf
          |> Document.move_to(line_col)
          |> Document.insert_text(char)
          |> Document.delete_before()

        assert Document.content(buf) == text
      end
    end
  end

  # ── Cache validity tests ──

  describe "cache: cursor and line_count accuracy" do
    test "insert at start of line updates col" do
      buf = Document.new("hello") |> Document.insert_text("X")
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 1}
    end

    test "insert in middle of line updates col" do
      buf =
        Document.new("hello")
        |> Document.move_to({0, 2})
        |> Document.insert_text("X")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 3}
    end

    test "insert at end of line updates col" do
      buf =
        Document.new("hello")
        |> Document.move_to({0, 5})
        |> Document.insert_text("X")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 6}
    end

    test "inserting a newline increments line and resets col" do
      buf = Document.new("ab") |> Document.move(:right) |> Document.insert_text("\n")
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {1, 0}
      assert Document.line_count(buf) == 2
    end

    test "inserting multi-line string updates cursor and line_count" do
      buf =
        Document.new("start") |> Document.move_to({0, 5}) |> Document.insert_text("a\nb\nc")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {2, 1}
      assert Document.line_count(buf) == 3
    end

    test "delete_before at start of line joins lines, updates cursor and line_count" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.delete_before()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
      assert Document.line_count(buf) == 1
    end

    test "delete_before in middle of line decrements col" do
      buf = Document.new("hello") |> Document.move_to({0, 3}) |> Document.delete_before()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
    end

    test "delete_at on newline decrements line_count, cursor unchanged" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
      assert Document.line_count(buf) == 1
    end

    test "delete_at on regular char, cursor and line_count unchanged" do
      buf = Document.new("hello") |> Document.delete_at()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 0}
      assert Document.line_count(buf) == 1
    end
  end

  # ── Property: cache always matches recomputed values ──

  describe "property: cache consistency" do
    property "cached cursor and line_count match recomputed values after any operations" do
      check all(
              text <- string(:ascii, min_length: 0, max_length: 80),
              ops <-
                list_of(
                  one_of([
                    member_of([:left, :right, :up, :down, :delete_before, :delete_at]),
                    {:insert, string(:ascii, length: 1)},
                    {:move_to, integer(0..5), integer(0..20)}
                  ]),
                  min_length: 0,
                  max_length: 20
                )
            ) do
        buf = Document.new(text)

        result =
          Enum.reduce(ops, buf, fn
            {:insert, char}, acc -> Document.insert_text(acc, char)
            {:move_to, l, c}, acc -> Document.move_to(acc, {l, c})
            :delete_before, acc -> Document.delete_before(acc)
            :delete_at, acc -> Document.delete_at(acc)
            dir, acc -> Document.move(acc, dir)
          end)

        assert_cache_valid(result)
      end
    end
  end

  # ── Test helpers ──

  # Verifies that the cached cursor_line, cursor_col, and line_count fields
  # match values recomputed from the raw buffer content.
  # cursor_col is now a byte offset within the current line.
  @spec assert_cache_valid(Document.t()) :: :ok
  defp assert_cache_valid(%Document{
         before: before,
         after: after_,
         cursor_line: cl,
         cursor_col: cc,
         line_count: lc
       }) do
    # Recompute cursor from `before`
    lines_before = :binary.split(before, "\n", [:global])
    expected_line = length(lines_before) - 1
    expected_col = lines_before |> List.last() |> byte_size()

    # Recompute line_count from full content
    text = before <> after_

    expected_lc =
      case text do
        "" -> 1
        _ -> length(:binary.matches(text, "\n")) + 1
      end

    assert cl == expected_line,
           "cursor_line: got #{cl}, expected #{expected_line} (before=#{inspect(before)})"

    assert cc == expected_col,
           "cursor_col: got #{cc}, expected #{expected_col} (before=#{inspect(before)})"

    assert lc == expected_lc,
           "line_count: got #{lc}, expected #{expected_lc} (content=#{inspect(text)})"

    :ok
  end

  # Convert a byte offset in text to a {line, byte_col} position.
  @spec byte_offset_to_position(String.t(), non_neg_integer()) :: Document.position()
  defp byte_offset_to_position(text, byte_offset) do
    before_cursor = binary_part(text, 0, min(byte_offset, byte_size(text)))
    lines = :binary.split(before_cursor, "\n", [:global])
    line = length(lines) - 1
    col = lines |> List.last() |> byte_size()
    {line, col}
  end
end
