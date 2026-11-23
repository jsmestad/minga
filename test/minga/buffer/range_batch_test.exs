defmodule Minga.Buffer.RangeBatchTest do
  @moduledoc """
  Pins batch range replacement to the sequential algorithm it replaced.

  `Minga.Test.SequentialRangeReplace` is the pre-change algorithm and serves as the control: every case compares the resulting content, cursor, line index, and undo patches.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Operation
  alias Minga.Buffer.RangeBatch
  alias Minga.Buffer.UndoPatch
  alias Minga.Test.SequentialRangeReplace

  # Fragments that stress grapheme, code point, and line rules: combining marks, CRLF, a lone CR,
  # four-byte emoji, regional-indicator pairs, a ZWJ sequence, Hangul jamo, and a prepended mark.
  @fragments [
    "a",
    "b",
    " ",
    "\t",
    "é",
    "é",
    "́",
    "\n",
    "\r\n",
    "\r",
    "😀",
    "🇺🇸",
    "\u{1F1FA}",
    "👩‍💻",
    "‍",
    "ᄀ",
    "ᅡ",
    "字",
    "\u0600"
  ]

  describe "replace_ranges_with_patches/2 matches the sequential control" do
    # Each row is current behavior, recorded with the sequential control before the change.
    @cases [
      {"unsorted edits apply from the end", "abc\ndef\nghi",
       [{{0, 0}, {0, 0}, "A"}, {{2, 1}, {2, 1}, "H"}, {{1, 2}, {1, 2}, "F"}], "Abc\ndeF\ngHi",
       {0, 1}},
      {"an equal start and end replaces the one character there", "hello",
       [{{0, 0}, {0, 0}, "J"}], "Jello", {0, 1}},
      {"a range at end of file inserts", "ab", [{{0, 2}, {0, 2}, "!"}], "ab!", {0, 3}},
      {"a second end-of-file edit replaces the first one's text", "ab",
       [{{0, 2}, {0, 2}, "1"}, {{0, 2}, {0, 2}, "2"}], "ab2", {0, 3}},
      {"a repeated start applies the later list entry first", "abcdef",
       [{{0, 1}, {0, 1}, "X"}, {{0, 1}, {0, 2}, "Y"}], "aYdef", {0, 2}},
      {"overlapping ranges resolve against the previous edit", "abcdef",
       [{{0, 1}, {0, 3}, "X"}, {{0, 2}, {0, 4}, "Y"}], "aX", {0, 2}},
      {"adjacent ranges both apply", "abcdef", [{{0, 1}, {0, 1}, "X"}, {{0, 2}, {0, 2}, "Y"}],
       "aXYdef", {0, 2}},
      {"a reversed range is normalized", "abcdef", [{{0, 4}, {0, 1}, "R"}], "aRf", {0, 2}},
      {"a line past the end resolves to the final line", "ab\ncd", [{{9, 0}, {9, 0}, "Z"}],
       "ab\nZd", {1, 1}},
      {"a column past the line end inserts at the line end", "ab\ncd", [{{0, 5}, {0, 5}, "Z"}],
       "abZ\ncd", {0, 3}},
      {"a CRLF is one character", "a\r\nb\r\nc", [{{0, 1}, {0, 1}, "X"}, {{1, 0}, {1, 0}, "Y"}],
       "aXY\r\nc", {0, 2}},
      {"a combining mark after the span joins the caret", "aéb", [{{0, 1}, {0, 1}, "X"}], "aXb",
       {0, 2}},
      {"a grapheme with a combining mark is one character", "xéy\nzz",
       [{{0, 0}, {0, 0}, "Q"}, {{1, 1}, {1, 1}, "W"}], "Qéy\nzW", {0, 1}},
      {"a column inside a code point keeps the sequential bytes", "aéb", [{{0, 2}, {0, 2}, "X"}],
       <<97, 195, 88, 98>>, {0, 3}},
      {"four-byte characters use byte columns", "😀a😀b",
       [{{0, 0}, {0, 0}, "1"}, {{0, 5}, {0, 5}, "2"}], "1a2b", {0, 1}},
      {"replacements may add lines", "ab\ncd",
       [{{0, 0}, {0, 0}, "x\ny"}, {{1, 1}, {1, 1}, "z\n"}], "x\nyb\ncz\n", {1, 1}},
      {"ranges may delete line breaks", "ab\ncd\nef",
       [{{0, 2}, {0, 2}, ""}, {{1, 2}, {1, 2}, ""}], "abcdef", {0, 2}},
      {"an empty document accepts an insertion", "", [{{0, 0}, {0, 0}, "new"}], "new", {0, 3}},
      {"a line that an earlier edit creates is the line a later endpoint names", "ab\ncdef",
       [{{1, 3}, {1, 3}, "1\n2\n"}, {{0, 1}, {3, 0}, "Q"}], "aQ", {0, 2}},
      {"a deletion that joins a prepended mark moves the insertion to the cluster start",
       "\u0600xa", [{{0, 2}, {0, 2}, "X"}], "X\u0600a", {0, 1}},
      {"invalid UTF-8 text applies edits one at a time", <<0xFF, "abc\ndef">>,
       [{{1, 1}, {1, 1}, "X"}, {{0, 2}, {0, 2}, "Y"}], <<0xFF, "aYc\ndXf">>, {0, 3}}
    ]

    for {name, text, edits, content, cursor} <- @cases do
      @tag text: text, edits: edits, content: content, cursor: cursor
      test name, %{text: text, edits: edits, content: content, cursor: cursor} do
        doc = text |> Document.new() |> Document.move_to({0, 1})

        {new_doc, _patches} = result = Operation.replace_ranges_with_patches(doc, edits)

        assert Document.content(new_doc) == content
        assert Document.cursor(new_doc) == cursor
        assert_same_result(result, SequentialRangeReplace.replace_ranges_with_patches(doc, edits))
      end
    end

    property "random batches over Unicode and CRLF text" do
      check all(
              text <- text_gen(),
              cursor <- position_gen(text),
              edits <- list_of(edit_gen(text), max_length: 8),
              max_runs: 1_500
            ) do
        doc = text |> Document.new() |> Document.move_to(cursor)

        # Positions inside a code point can make segmentation raise; both must raise alike.
        case outcome(fn -> SequentialRangeReplace.replace_ranges_with_patches(doc, edits) end) do
          {:ok, expected} ->
            assert_same_result(Operation.replace_ranges_with_patches(doc, edits), expected)

          {:raised, exception} ->
            assert_raise exception, fn -> Operation.replace_ranges_with_patches(doc, edits) end
        end
      end
    end

    property "separated batches at caret boundaries" do
      check all(
              lines <- list_of(line_gen(), min_length: 1, max_length: 12),
              picks <- list_of({integer(0..11), integer(0..20), integer(0..3), fragment_gen()}),
              max_runs: 500
            ) do
        text = Enum.join(lines, "\n")
        doc = Document.new(text)
        edits = separated_edits(lines, picks)

        assert_same_result(
          Operation.replace_ranges_with_patches(doc, edits),
          SequentialRangeReplace.replace_ranges_with_patches(doc, edits)
        )
      end
    end

    property "many edits at code point stops, including lines past the end" do
      check all(
              text <- text_gen(),
              picks <-
                list_of(
                  {integer(0..200), integer(0..3), integer(0..9),
                   one_of([constant(""), text_gen()])},
                  max_length: 24
                ),
              max_runs: 1_000
            ) do
        doc = Document.new(text)
        edits = code_point_edits(text, picks)

        case outcome(fn -> SequentialRangeReplace.replace_ranges_with_patches(doc, edits) end) do
          {:ok, expected} ->
            assert_same_result(Operation.replace_ranges_with_patches(doc, edits), expected)

          {:raised, exception} ->
            assert_raise exception, fn -> Operation.replace_ranges_with_patches(doc, edits) end
        end
      end
    end
  end

  describe "apply_run/3" do
    test "applies separated ASCII edits in one run" do
      doc = Document.new(Enum.map_join(0..99, "\n", fn line -> "line #{line} text" end))
      edits = for line <- 99..0//-3, do: {{line, 0}, {line, 3}, "LINE"}

      assert {:applied, new_doc, patches, []} = apply_run(doc, edits)
      assert length(patches) == length(edits)

      assert_same_result(
        {new_doc, patches},
        SequentialRangeReplace.replace_ranges_with_patches(doc, edits)
      )
    end

    test "ends the run at the first edit that reaches into the previous edit's span" do
      doc = Document.new("abcdefgh")
      edits = [{{0, 5}, {0, 6}, "X"}, {{0, 3}, {0, 5}, "Y"}, {{0, 0}, {0, 0}, "Z"}]

      assert {:applied, _doc, [_patch], [{{0, 3}, {0, 5}, "Y"} | _rest]} =
               apply_run(doc, edits)
    end

    test "leaves an edit whose caret column is past its line to the sequential operation" do
      assert :sequential = apply_run(Document.new("ab\ncd"), [{{0, 5}, {0, 5}, "Z"}])
    end

    test "leaves an edit whose deletion joins a Hangul syllable to the sequential operation" do
      # Deleting "x" joins the leading and vowel jamo, so the caret snaps to the syllable start.
      doc = Document.new("ᄀxᅡ")
      edits = [{{0, 3}, {0, 3}, "X"}]

      assert :sequential = apply_run(doc, edits)
      {new_doc, _patches} = Operation.replace_ranges_with_patches(doc, edits)
      assert Document.content(new_doc) == "X가"
    end
  end

  defp apply_run(doc, edits), do: RangeBatch.apply_run(doc, Lines.snapshot(doc), edits)

  defp outcome(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, exception.__struct__}
  end

  @spec assert_same_result({Document.t(), [UndoPatch.t()]}, {Document.t(), [UndoPatch.t()]}) ::
          true
  defp assert_same_result({doc, patches}, {expected_doc, expected_patches}) do
    assert Document.content(doc) == Document.content(expected_doc)
    assert Document.cursor(doc) == Document.cursor(expected_doc)
    assert Document.line_count(doc) == Document.line_count(expected_doc)
    assert Lines.snapshot(doc) == Lines.snapshot(expected_doc)
    assert patches == expected_patches
  end

  defp fragment_gen, do: member_of(@fragments)

  defp text_gen do
    gen all(fragments <- list_of(fragment_gen(), max_length: 30)) do
      Enum.join(fragments)
    end
  end

  defp line_gen do
    gen all(fragments <- list_of(member_of(@fragments -- ["\n", "\r\n"]), max_length: 10)) do
      Enum.join(fragments)
    end
  end

  # Positions may fall past a line, past the document, or inside a code point.
  defp position_gen(text) do
    line_count = Lines.count(text)
    tuple({integer(0..line_count), integer(0..(byte_size(text) + 2))})
  end

  defp edit_gen(text) do
    replacement = one_of([constant(""), text_gen()])
    tuple({position_gen(text), position_gen(text), replacement})
  end

  # Starts each edit at a code point stop, spans up to three more stops, and sometimes names a
  # line past the end for the range end.
  defp code_point_edits(text, picks) do
    stops = code_point_stops(text)
    doc = Document.new(text)
    line_count = Document.line_count(doc)

    Enum.map(picks, fn {pick, width, past_end, replacement} ->
      start = Enum.at(stops, rem(pick, length(stops)))
      stop = Enum.at(stops, min(rem(pick, length(stops)) + width, length(stops) - 1))

      to_pos =
        if past_end == 0, do: {line_count + 1, 0}, else: Document.offset_to_position(doc, stop)

      {Document.offset_to_position(doc, start), to_pos, replacement}
    end)
  end

  defp code_point_stops(text),
    do: [0 | text |> String.codepoints() |> Enum.scan(0, &(byte_size(&1) + &2))]

  # Picks a caret-boundary start column on distinct lines, with a span of up to three characters.
  # The generated pick order is the list order, so batches arrive unsorted.
  defp separated_edits(lines, picks) do
    picks
    |> Enum.uniq_by(fn {line, _col, _width, _replacement} -> line end)
    |> Enum.flat_map(fn {line, col_pick, width, replacement} ->
      case Enum.at(lines, line) do
        nil -> []
        text -> [{{line, caret_column(text, col_pick)}, width, text, replacement}]
      end
    end)
    |> Enum.map(fn {{line, col}, width, text, replacement} ->
      {{line, col}, {line, to_column(text, col, width)}, replacement}
    end)
  end

  defp caret_column(text, pick) do
    stops = caret_stops(text)
    Enum.at(stops, rem(pick, length(stops)))
  end

  defp to_column(text, col, width) do
    text |> caret_stops() |> Enum.filter(&(&1 >= col)) |> Enum.at(width, col)
  end

  defp caret_stops(text),
    do: [0 | text |> String.graphemes() |> Enum.scan(0, &(byte_size(&1) + &2))]
end
