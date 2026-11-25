defmodule Minga.Buffer.LinesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{Document, Lines}
  alias Minga.Test.Generators

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

    test "reads the same target line with the gap before, inside, and after it" do
      content = "before\nαe\u0301_target\nafter"

      for gap_position <- [{0, 0}, {1, byte_size("αe\u0301_")}, {2, 5}] do
        document = content |> Document.new() |> Document.move_to(gap_position)
        assert Lines.fetch(document, 1) == "αe\u0301_target"
      end
    end

    test "copies a fetched line out of a document-sized backing binary" do
      document = Document.new(String.duplicate("large filler line\n", 10_000) <> "target")
      line = Lines.fetch(document, 10_000)

      assert line == "target"
      assert :binary.referenced_byte_size(line) == byte_size(line)
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

  describe "bounded_contents/4" do
    test "shifts the following endpoint but not the edited line's start" do
      document =
        "ab\ncd\nef" |> Document.new() |> Document.move_to({1, 1}) |> Document.insert_text("é")

      assert {:pending, _starts, 1, 2} = document.line_offsets
      assert Lines.bounded_contents(document, 1, 1, 10) == {"céd", 1, 3, true}
      assert Lines.bounded_contents(document, 2, 1, 10) == {"ef", 1, 3, true}
    end

    test "keeps the final empty line and its preceding newline when selected" do
      document = Document.new("a\n")

      assert Lines.bounded_contents(document, 0, 2, 2) == {"a\n", 2, 2, true}
      assert Lines.bounded_contents(document, 0, 1, 2) == {"a", 1, 2, true}
      assert Lines.bounded_contents(document, 1, 1, 0) == {"", 1, 2, true}
      assert Lines.bounded_contents(document, 2, 1, 2) == {"", 0, 2, true}
      assert Lines.bounded_contents(document, 0, 0, 2) == {"", 0, 2, true}
    end

    test "caps raw bytes without reducing the selected-line count" do
      document = Document.new("é\nx")

      assert Lines.bounded_contents(document, 0, 2, 1) == {<<0xC3>>, 2, 2, false}
    end
  end

  property "bounded_contents/4 matches a byte prefix of sliced lines in every index state" do
    check all(
            {document, state} <- Generators.indexed_document(),
            lines = document |> Document.content() |> String.split("\n"),
            total = length(lines),
            first_line <- integer(0..(total + 1)),
            count <- integer(0..(total + 1)),
            selected = Enum.slice(lines, first_line, count),
            joined = Enum.join(selected, "\n"),
            size = byte_size(joined),
            max_bytes <- integer(0..(size + 1))
          ) do
      assert index_state(document) == state

      prefix = binary_part(joined, 0, min(size, max_bytes))

      assert Lines.bounded_contents(document, first_line, count, max_bytes) ==
               {prefix, length(selected), total, size <= max_bytes}
    end
  end

  describe "containing/2" do
    test "an empty document has one line starting at zero" do
      document = Document.new("")

      assert Lines.containing(document, 0) == {0, 0}
      assert Lines.containing(document, 3) == {0, 0}
    end

    test "a terminating newline belongs to the line it ends" do
      document = Document.new("ab\ncd\n")

      assert Lines.containing(document, 2) == {0, 0}
      assert Lines.containing(document, 3) == {1, 3}
      assert Lines.containing(document, 5) == {1, 3}
      assert Lines.containing(document, 6) == {2, 6}
    end

    test "points past the end resolve to the final line" do
      assert Lines.containing(Document.new("ab\ncd\n"), 99) == {2, 6}
      assert Lines.containing(Document.new("ab\ncd"), 99) == {1, 3}
    end

    test "consecutive newlines each start their own line" do
      document = Document.new("\n\n")

      assert Lines.containing(document, 0) == {0, 0}
      assert Lines.containing(document, 1) == {1, 1}
      assert Lines.containing(document, 2) == {2, 2}
    end

    test "points inside a multi-byte codepoint resolve to the line holding its bytes" do
      document = Document.new("é\n🥨b")

      assert Lines.containing(document, 1) == {0, 0}
      assert Lines.containing(document, 2) == {0, 0}
      assert Lines.containing(document, 4) == {1, 3}
    end

    test "applies a pending positive shift to lines after the edited line" do
      document =
        "ab\ncd\nef" |> Document.new() |> Document.move_to({0, 1}) |> Document.insert_text("XY")

      assert {:pending, _starts, 0, 2} = document.line_offsets
      assert Document.content(document) == "aXYb\ncd\nef"
      assert Lines.containing(document, 4) == {0, 0}
      assert Lines.containing(document, 5) == {1, 5}
      assert Lines.containing(document, 8) == {2, 8}
    end

    test "applies a pending negative shift to lines after the edited line" do
      document =
        "abc\nde\nf" |> Document.new() |> Document.move_to({1, 1}) |> Document.delete_before()

      assert {:pending, _starts, 1, -1} = document.line_offsets
      assert Document.content(document) == "abc\ne\nf"
      assert Lines.containing(document, 4) == {1, 4}
      assert Lines.containing(document, 5) == {1, 4}
      assert Lines.containing(document, 6) == {2, 6}
    end

    test "rebuilds a missing index from content" do
      document = %{Document.new("ab\ncd") | line_offsets: nil}

      assert Lines.containing(document, 2) == {0, 0}
      assert Lines.containing(document, 3) == {1, 3}
    end
  end

  describe "start_of/2" do
    test "returns each line start and clamps past the final line" do
      document = Document.new("ab\ncd\n")

      assert Enum.map(0..4, &Lines.start_of(document, &1)) == [0, 3, 6, 6, 6]
    end

    test "an empty document starts every line at zero" do
      assert Lines.start_of(Document.new(""), 7) == 0
    end

    test "applies pending shifts and rebuilds a missing index" do
      pending =
        "ab\ncd\nef" |> Document.new() |> Document.move_to({1, 1}) |> Document.insert_text("é")

      assert {:pending, _starts, 1, 2} = pending.line_offsets
      assert Enum.map(0..3, &Lines.start_of(pending, &1)) == [0, 3, 8, 8]
      assert Lines.start_of(%{Document.new("ab\ncd") | line_offsets: nil}, 1) == 3
    end
  end

  property "containing/2 and start_of/2 match a naive newline scan in every index state" do
    check all({document, state} <- Generators.indexed_document()) do
      assert index_state(document) == state

      text = Document.content(document)
      size = byte_size(text)
      starts = naive_line_starts(text)

      for point <- 0..(size + 2) do
        clamped = min(point, size)
        line = Enum.count(starts, &(&1 <= clamped)) - 1
        assert Lines.containing(document, point) == {line, Enum.at(starts, line)}
      end

      for line <- 0..(length(starts) + 1) do
        assert Lines.start_of(document, line) == Enum.at(starts, min(line, length(starts) - 1))
      end
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

  describe "update_after_append/3" do
    @starts {0, 3, 6}

    test "text without a line break leaves every form of the index as it is" do
      for index <- [@starts, {:pending, @starts, 1, 2}, appended_index(@starts, [9]), nil] do
        assert Lines.update_after_append(index, 12, "tail") == index
      end
    end

    test "new lines go to the tail while it is no longer than the base" do
      assert {:appended, @starts, tail} = Lines.update_after_append(@starts, 8, "a\nb\n")
      assert :array.to_list(tail) == [10, 12]

      assert {:appended, @starts, tail} =
               Lines.update_after_append({:appended, @starts, tail}, 12, "c\n")

      assert :array.to_list(tail) == [10, 12, 14]
    end

    test "a tail that outgrows its base is joined into a clean index" do
      index = appended_index(@starts, [10, 12, 14])

      assert Lines.update_after_append(index, 14, "d\n") == {0, 3, 6, 10, 12, 14, 16}
      assert Lines.update_after_append({0}, 0, "a\nb\n") == {0, 2, 4}
    end

    test "a pending shift is applied before the new lines are added" do
      assert {:appended, {0, 3, 8}, tail} =
               Lines.update_after_append({:pending, @starts, 1, 2}, 10, "\n")

      assert :array.to_list(tail) == [11]
    end

    test "a missing index stays missing" do
      assert Lines.update_after_append(nil, 4, "a\n") == nil
    end
  end

  describe "an appended index under other updates" do
    test "every update that is not an append joins the tail first" do
      index = appended_index({0, 3}, [6])

      assert Lines.update_after_insert(index, 0, 1, "x") == {:pending, {0, 3, 6}, 0, 1}
      assert Lines.update_after_insert(index, 0, 1, "x\n") == {0, 3, 5, 8}
      assert Lines.update_after_delete_before(index, 1, 1, true) == {0, 5}
      assert Lines.update_after_delete_at(index, 0, 1, false) == {:pending, {0, 3, 6}, 0, -1}
      assert Lines.update_after_span_replace(index, 0, 1, 0, [{1, 1}], -1) == {0, 2, 5}
    end

    test "clean_starts/1 resolves every form without storing it" do
      text = "ab\ncd\nef"

      for {document, _state} <- [
            {Document.new(text), :clean},
            {text |> Document.new() |> Document.insert_text("x"), :pending},
            {"ab\ncd" |> Document.new() |> Document.append_text("\nef"), :appended},
            {%{Document.new(text) | line_offsets: nil}, :missing}
          ] do
        assert Lines.clean_starts(document) ==
                 document |> Document.content() |> Lines.build_index()
      end
    end
  end

  property "any run of appends and edits leaves the index of a rebuilt document" do
    step =
      one_of([
        tuple({constant(:append), string([?a, ?\n, ?\r, 0xE9], max_length: 8)}),
        tuple({constant(:follow), string([?a, ?\n, ?\r, 0xE9], max_length: 8)}),
        tuple({constant(:insert), string([?x, ?\n], max_length: 3)}),
        constant(:delete_before),
        constant(:delete_at),
        tuple({constant(:move), integer(0..12), integer(0..6)})
      ])

    check all(
            text <- string([?a, ?\n, 0xE9], max_length: 20),
            steps <- list_of(step, max_length: 25)
          ) do
      document =
        Enum.reduce(steps, Document.new(text), fn step, document ->
          document = apply_step(document, step)
          content = Document.content(document)
          rebuilt = Lines.build_index(content)

          assert Lines.clean_starts(document) == rebuilt
          assert Document.line_count(document) == tuple_size(rebuilt)

          for line <- 0..tuple_size(rebuilt) do
            assert Lines.fetch(document, line) == content |> String.split("\n") |> Enum.at(line)

            assert Lines.start_of(document, line) ==
                     elem(rebuilt, min(line, tuple_size(rebuilt) - 1))
          end

          assert Lines.slice(document, 0, tuple_size(rebuilt) + 1) == String.split(content, "\n")
          document
        end)

      assert Document.cursor_offset(document) <= byte_size(Document.content(document))
    end
  end

  defp apply_step(document, {:append, text}), do: Document.append_text(document, text)
  defp apply_step(document, {:follow, text}), do: Document.append_text_and_follow(document, text)
  defp apply_step(document, {:insert, text}), do: Document.insert_text(document, text)
  defp apply_step(document, :delete_before), do: Document.delete_before(document)
  defp apply_step(document, :delete_at), do: Document.delete_at(document)
  defp apply_step(document, {:move, line, column}), do: Document.move_to(document, {line, column})

  defp appended_index(base, tail), do: {:appended, base, :array.from_list(tail)}

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

  @spec index_state(Document.t()) :: Generators.index_state()
  defp index_state(%Document{line_offsets: {:pending, _starts, _line, delta}}) when delta > 0,
    do: :pending_insert

  defp index_state(%Document{line_offsets: {:pending, _starts, _line, delta}}) when delta < 0,
    do: :pending_delete

  defp index_state(%Document{line_offsets: {:appended, _base, _tail}}), do: :appended
  defp index_state(%Document{line_offsets: nil}), do: :missing
  defp index_state(%Document{line_offsets: starts}) when is_tuple(starts), do: :clean

  @spec naive_line_starts(String.t()) :: [non_neg_integer()]
  defp naive_line_starts(text) do
    newline_ends =
      for {?\n, index} <- text |> :binary.bin_to_list() |> Enum.with_index(), do: index + 1

    [0 | newline_ends]
  end
end
