defmodule Minga.Buffer.CursorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{Document, Cursor, Lines}

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

    test "clamps clusters that the gap splits and keeps line-end placement before LF" do
      for {prefix, suffix, target, expected} <- [
            {"ae", "\u0301x", {0, 2}, {0, 1}},
            {"👩", "\u200D💻!", {0, 6}, {0, 0}},
            {"🇨", "🇦🇺🇸", {0, 9}, {0, 8}},
            {"ab\r", "\nnext", {0, 99}, {0, 3}},
            {"ab\r", "\nnext", {1, 2}, {1, 2}}
          ],
          doc = suffix |> Document.new() |> Document.insert_text(prefix),
          doc <- [doc, %{doc | line_offsets: nil}] do
        placed = Cursor.place(doc, target)

        assert Document.cursor(placed) == expected
        assert Document.content(placed) == prefix <> suffix
        assert_cache_valid(placed)
      end
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

  test "previous_character preserves empty text and line-break graphemes" do
    for {text, expected} <- [
          {"", {"", ""}},
          {"\n", {"", "\n"}},
          {"\r\n", {"", "\r\n"}},
          {"界\n", {"界", "\n"}},
          {"界\r\n", {"界", "\r\n"}}
        ] do
      assert Cursor.previous_character(text) == expected
    end
  end

  property "suffix scans preserve Unicode graphemes across line and chunk boundaries" do
    fragments = [
      "a",
      "\n",
      "\r",
      "\r\n",
      "界",
      "é",
      "e\u0301",
      "👩‍💻",
      "🇨🇦",
      "\u0600A",
      "\u0301",
      "\u200D"
    ]

    check all(
            prefix <- list_of(member_of(fragments), max_length: 20),
            padding <- member_of([0, 1, 4095, 4096, 4097, 8191, 8192, 8193]),
            separator <- member_of(["", "\n", "\r\n"]),
            ending <- list_of(member_of(fragments), max_length: 10)
          ) do
      text = Enum.join(prefix) <> separator <> String.duplicate("x", padding) <> Enum.join(ending)
      last = List.last(String.graphemes(text)) || ""
      preceding = binary_part(text, 0, byte_size(text) - byte_size(last))
      expected_width = text |> String.split("\n") |> List.last() |> byte_size()

      assert Cursor.previous_character(text) == {preceding, last}
      assert Lines.last_line_width(text) == expected_width
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

  # Fragments that join into longer graphemes (combining marks, ZWJ and skin-tone emoji,
  # regional indicators, prepend, Hangul jamo, Indic conjuncts), so a split between two of
  # them can leave the gap inside a cluster or inside a CRLF pair.
  @place_fragments [
    "a",
    "\n",
    "\r",
    "\r\n",
    "é",
    "e",
    "\u0301",
    "\u200D",
    "👩",
    "💻",
    "👩\u200D💻",
    "\u{1F3FB}",
    "🇨",
    "🇦",
    "🇨🇦",
    "界",
    "\u0600",
    "\u1100",
    "\u1161",
    "\u11A8",
    "\u0915",
    "\u094D"
  ]

  property "place/2 matches a whole-line caret clamp from every gap and index state" do
    check all(
            prefix <- list_of(member_of(@place_fragments), max_length: 12),
            suffix <- list_of(member_of(@place_fragments), max_length: 12),
            state <- member_of([:split, :pending_insert, :pending_delete, :missing])
          ) do
      doc =
        suffix
        |> Enum.join()
        |> Document.new()
        |> Document.insert_text(Enum.join(prefix))
        |> in_index_state(state)

      text = Document.content(doc)
      line_starts = Lines.build_index(text)
      widest = text |> String.split("\n") |> Enum.map(&byte_size/1) |> Enum.max()

      for line <- 0..tuple_size(line_starts), column <- 0..(widest + 1) do
        placed = Cursor.place(doc, {line, column})

        assert Document.content(placed) == text

        assert {Document.cursor_offset(placed), Document.cursor(placed)} ==
                 whole_line_place(text, line_starts, {line, column})

        assert_cache_valid(placed)
      end
    end
  end

  @spec in_index_state(Document.t(), :split | :pending_insert | :pending_delete | :missing) ::
          Document.t()
  defp in_index_state(doc, :split), do: doc
  defp in_index_state(doc, :pending_insert), do: Document.insert_text(doc, "x")
  defp in_index_state(doc, :pending_delete), do: Document.delete_before(doc)
  defp in_index_state(doc, :missing), do: %{doc | line_offsets: nil}

  # The previous placement contract: clamp against the whole target line of the flat text.
  @spec whole_line_place(String.t(), Lines.line_starts(), Document.position()) ::
          {non_neg_integer(), Document.position()}
  defp whole_line_place(text, line_starts, {target_line, target_column}) do
    line = min(target_line, tuple_size(line_starts) - 1)
    {start, length} = Lines.span(line_starts, line, byte_size(text))
    line_text = binary_part(text, start, length)
    column = Cursor.caret_column(line_text, min(target_column, length))
    {start + column, {line, column}}
  end

  @spec assert_cache_valid(Document.t()) :: :ok
  defp assert_cache_valid(%Document{
         before: before,
         after: after_,
         cursor_line: cursor_line,
         cursor_col: cursor_col,
         line_count: line_count,
         line_offsets: ls
       }) do
    lines_before = :binary.split(before, "\n", [:global])
    expected_line = Enum.count(lines_before) - 1
    expected_column = lines_before |> Enum.at(-1) |> byte_size()
    text = before <> after_

    expected_line_count =
      case text do
        "" -> 1
        _ -> Enum.count(:binary.matches(text, "\n")) + 1
      end

    assert cursor_line == expected_line
    assert cursor_col == expected_column
    assert line_count == expected_line_count

    resolved_ls = resolve_offsets(ls)
    assert is_tuple(resolved_ls), "line_offsets must resolve to a tuple, got: #{inspect(ls)}"
    expected_ls = Minga.Buffer.Lines.build_index(text)

    assert resolved_ls == expected_ls,
           "line_offsets mismatch: resolved=#{inspect(resolved_ls)}, expected #{inspect(expected_ls)}"

    :ok
  end

  @spec resolve_offsets(Document.line_offsets()) :: tuple() | nil
  defp resolve_offsets({:pending, starts, adjust_after, delta}) do
    Minga.Buffer.Lines.flush_to_tuple(starts, adjust_after, delta)
  end

  defp resolve_offsets(ls) when is_tuple(ls), do: ls
  defp resolve_offsets(nil), do: nil
end
