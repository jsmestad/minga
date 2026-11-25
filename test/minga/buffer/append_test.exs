defmodule Minga.Buffer.AppendTest do
  @moduledoc "Appended command output: what the buffer records, where the cursor rests, and what a chunk costs."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RendererConsume
  alias Minga.Events.BufferChangedEvent

  defp start_buffer(content, opts \\ []) do
    start_supervised!({Buffer, [content: content, read_only: true] ++ opts},
      id: {:buffer, System.unique_integer([:positive])}
    )
  end

  # Registers the renderer as a reader, as the first frame of a window does.
  defp consume(buffer), do: Buffer.renderer_consume(buffer, nil)

  describe "what one chunk records" do
    test "a chunk is one insertion at the old end, read once by the renderer" do
      buffer = start_buffer("one\ntw")
      %RendererConsume{version: version} = consume(buffer)

      assert :ok = Buffer.append(buffer, "o\nthree")

      assert %RendererConsume{
               version: new_version,
               line_count: 3,
               changes: {:ok, [%EditDelta{} = delta]},
               snapshot: snapshot
             } = consume(buffer)

      assert new_version == version + 1
      assert {delta.start_byte, delta.old_end_byte, delta.new_end_byte} == {6, 6, 13}
      assert delta.start_position == {1, 2}
      assert delta.old_end_position == {1, 2}
      assert delta.new_end_position == {2, 5}
      assert delta.inserted_text == "o\nthree"
      assert snapshot.lines == ["two", "three"]

      assert %RendererConsume{changes: {:ok, []}} = consume(buffer)
    end

    test "a chunk that ends inside a line is completed by the next one on the same line" do
      buffer = start_buffer("")
      consume(buffer)

      Buffer.append(buffer, "compil")
      Buffer.append(buffer, "ing\ndone")

      assert %RendererConsume{line_count: 2, changes: {:ok, [first, second]}} = consume(buffer)
      assert {first.start_position, first.new_end_position} == {{0, 0}, {0, 6}}
      assert {second.start_position, second.new_end_position} == {{0, 6}, {1, 4}}
      assert EditDelta.affected_line_range([first, second]) == {0, 1}
      assert Buffer.content(buffer) == "compiling\ndone"
    end

    test "a chunk that splits a character keeps every byte and joins it with the next chunk" do
      buffer = start_buffer("")
      <<first_byte::binary-size(1), second_byte::binary>> = "é"

      Buffer.append(buffer, "caf" <> first_byte)
      assert Buffer.content(buffer) == "caf" <> first_byte

      Buffer.append(buffer, second_byte <> "\n")
      assert Buffer.content(buffer) == "café\n"
      assert Buffer.cursor(buffer) == {1, 0}
      assert Buffer.lines(buffer, 0, 2) == ["café", ""]
    end

    test "output is not the user's edit: the buffer stays clean and there is nothing to undo" do
      buffer = start_buffer("")

      Buffer.append(buffer, "output\n")

      refute Buffer.dirty?(buffer)
      Buffer.undo(buffer)
      assert Buffer.content(buffer) == "output\n"
    end

    test "an empty chunk changes nothing" do
      buffer = start_buffer("kept")
      %RendererConsume{version: version} = consume(buffer)

      assert :ok = Buffer.append(buffer, "")

      assert %RendererConsume{version: ^version, changes: {:ok, []}} = consume(buffer)
      assert Buffer.cursor(buffer) == {0, 0}
    end

    test "subscribers receive the chunk as a delta with the new version" do
      registry = :"append_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})
      Minga.Events.subscribe(:buffer_changed, registry)
      buffer = start_buffer("a", events_registry: registry)
      version = Buffer.version(buffer)

      Buffer.append(buffer, "b\n")

      assert_receive {:minga_event, :buffer_changed,
                      %BufferChangedEvent{buffer: ^buffer, delta: %EditDelta{} = delta} = event}

      assert delta.inserted_text == "b\n"
      assert event.version == version + 1
      assert event.sequence > 0
    end
  end

  describe "where the cursor rests" do
    for {label, content, chunk, expected} <- [
          {"on the last character of a line the chunk leaves open", "", "abc", {0, 2}},
          {"at the start of the empty line after a final line break", "abc", "\n", {1, 0}},
          {"at the start of the empty line after a final CRLF", "abc", "\r\n", {1, 0}},
          {"on a last character of several bytes", "a\n", "bé", {1, 1}},
          {"on the only character of a one-character chunk", "ab", "c", {0, 2}}
        ] do
      test label do
        buffer = start_buffer(unquote(content))

        Buffer.append(buffer, unquote(chunk))

        assert Buffer.cursor(buffer) == unquote(expected)
      end
    end

    for {label, chunks, expected} <- [
          {"a combining mark", ["e", "\u0301"], "e\u0301"},
          {"a UTF-8 character", [<<0xC3>>, <<0xA9>>], "é"},
          {"a four-byte character", [<<0xF0, 0x9F, 0x91>>, <<0xA9>>], "👩"},
          {"a grapheme with a split combining mark", ["e" <> <<0xCC>>, <<0x81>>], "e\u0301"},
          {"a joined emoji", ["👩", "\u200D", "💻"], "👩‍💻"}
        ] do
      test "rests before #{label} split over chunks on an open line" do
        buffer = start_buffer("prefix ")
        Enum.each(unquote(chunks), &Buffer.append(buffer, &1))

        assert Buffer.content(buffer) == "prefix " <> unquote(expected)
        assert Buffer.cursor(buffer) == {0, 7}
      end
    end

    test "an incomplete UTF-8 byte after an emoji stays visible and can be completed" do
      buffer = start_buffer("")
      assert :ok = Buffer.append(buffer, "👩")
      assert :ok = Buffer.append(buffer, <<0xC3>>)
      assert Buffer.content(buffer) == "👩" <> <<0xC3>>
      assert Buffer.cursor(buffer) == {0, 4}

      assert :ok = Buffer.append(buffer, <<0xA9>>)
      assert Buffer.content(buffer) == "👩é"
      assert Buffer.cursor(buffer) == {0, 4}
    end

    test "a cursor the reader moved up follows the next chunk to the end" do
      buffer = start_buffer("one\ntwo\n")
      Buffer.move_to(buffer, {0, 1})

      Buffer.append(buffer, "three")

      assert Buffer.cursor(buffer) == {2, 4}
      assert Buffer.content(buffer) == "one\ntwo\nthree"
    end
  end

  describe "what a chunk costs" do
    @line "test/minga/foo_test.exs:12: an ordinary line of test output\n"
    @chunk String.duplicate(@line, 20)

    # The work is counted in the buffer process's reductions, so it does not depend on how busy the machine is.
    # Every append is followed by what a frame asks the buffer for: the unseen deltas with the changed lines.
    # A line index whose cost is only deferred to the next read therefore shows up here.
    defp append_work(buffer, chunks, opts) do
      chunk = Keyword.get(opts, :chunk, fn _ -> @chunk end)
      read = Keyword.get(opts, :read, &consume/1)

      consume(buffer)

      for i <- 1..Keyword.get(opts, :warm_up, 0)//1,
          do: {Buffer.append(buffer, chunk.(i)), read.(buffer)}

      {:reductions, before} = Process.info(buffer, :reductions)

      for i <- 1..chunks do
        :ok = Buffer.append(buffer, chunk.(i))
        read.(buffer)
      end

      {:reductions, later} = Process.info(buffer, :reductions)
      later - before
    end

    for {label, chunk} <- [
          {"of whole lines", quote(do: fn _ -> @chunk end)},
          {"that ends inside a line", quote(do: fn _ -> @chunk <> "partial" end)},
          {"without a line break, every second time",
           quote(do: fn i -> if rem(i, 2) == 0, do: "no line break ", else: @chunk end)}
        ] do
      test "a chunk #{label} costs the same on a 200,000-line log as on an empty buffer" do
        chunk = unquote(chunk)
        empty = start_buffer("")
        long = start_buffer(String.duplicate(@line, 200_000))
        assert Buffer.line_count(long) == 200_001

        empty_work = append_work(empty, 200, chunk: chunk)
        long_work = append_work(long, 200, chunk: chunk)
        ratio = long_work / empty_work

        # An append that rebuilt the line index or the content costs in proportion to the lines held:
        # 72x here before the fix.
        assert ratio < 2,
               "200 chunks cost #{long_work} reductions on 200,000 lines and #{empty_work} on an empty buffer " <>
                 "(#{Float.round(ratio, 1)}x); expected the same order"
      end
    end

    test "an unterminated log line can keep growing without increasing each append's work" do
      chunks = [
        fn _ -> "progress 123 abc\r" end,
        fn index -> if rem(index, 2) == 1, do: <<0xC3>>, else: <<0xA9, ?x>> end
      ]

      for chunk <- chunks do
        empty = start_buffer("")
        long = start_buffer(String.duplicate("界", 100_000))

        # Seed the anchor outside the measurement. No viewport read measures the cost of drawing the line.
        measure = fn buffer ->
          append_work(buffer, 100, warm_up: 1, chunk: chunk, read: fn _ -> :ok end)
        end

        assert measure.(long) < 2 * measure.(empty)
      end
    end

    test "a window parked inside the appended lines reads them at the cost of a window at the top" do
      parked_at = 70_000
      read_at = fn line -> &{consume(&1), Buffer.render_snapshot(&1, line, 40)} end
      top = start_buffer(String.duplicate(@line, 66_000))
      parked = start_buffer(String.duplicate(@line, 66_000))

      # 1,000 chunks put 20,000 lines after the 66,000 the buffer started with, so line 70,000 is one of them.
      top_work = append_work(top, 300, warm_up: 1_000, read: read_at.(0))
      parked_work = append_work(parked, 300, warm_up: 1_000, read: read_at.(parked_at))
      ratio = parked_work / top_work

      assert ratio < 1.5,
             "300 chunks cost #{parked_work} reductions with the window at line #{parked_at} and #{top_work} " <>
               "with it at the top (#{Float.round(ratio, 1)}x)"
    end

    test "twice the chunks cost twice the work" do
      # The change log keeps the last 1,000 deltas and every read scans what it keeps, so a chunk's cost
      # rises until the log is full. Both buffers start counting after that point.
      work = append_work(start_buffer(""), 1_500, warm_up: 1_000)
      double_work = append_work(start_buffer(""), 3_000, warm_up: 1_000)
      ratio = double_work / work

      # Work that grew with the lines held would give about 3x here; the fix measured 2.1x.
      assert ratio < 2.5,
             "3,000 chunks cost #{double_work} reductions, #{Float.round(ratio, 1)}x the #{work} of 1,500; " <>
               "expected about 2x"
    end
  end
end
