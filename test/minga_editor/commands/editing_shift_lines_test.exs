defmodule MingaEditor.Commands.EditingShiftLinesTest do
  @moduledoc """
  Consumer-boundary contract for multiline `>` and `<` (#3499).

  The command layer is the client of the buffer edit: these tests pin the observable results that any implementation of multiline shifting must keep, including the edit deltas that parser and LSP clients replay.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.Commands.Editing

  @mixed "alpha\n\n\tTabbed ✓\n  two spaces 世界\n      six spaces\n\nomega é"

  describe "indent" do
    test "a line selection shifts every line, including blank and Unicode lines, by one configured unit" do
      buffer = spaces_buffer(@mixed, 4)
      BufferProcess.move_to(buffer, {6, 2})
      state = buffer |> command_state() |> with_visual_selection({0, 0}, :line)
      before = sync_point(buffer)

      Editing.execute(state, :indent_visual_selection)

      assert BufferProcess.content(buffer) ==
               "    alpha\n    \n    \tTabbed ✓\n      two spaces 世界\n          six spaces\n    \n    omega é"

      assert BufferProcess.cursor(buffer) == {6, 6}
      assert_deltas_replay(buffer, before)
    end

    test "tab indentation inserts one tab per line and moves the cursor one byte" do
      buffer = start_buffer("one\n  two\nthree")
      BufferProcess.set_option(buffer, :indent_with, :tabs)
      BufferProcess.move_to(buffer, {1, 2})

      Editing.execute(command_state(buffer), {:indent_lines, 2})

      assert BufferProcess.content(buffer) == "one\n\t  two\n\tthree"
      assert BufferProcess.cursor(buffer) == {1, 3}
    end

    test "a reversed visual line selection indents only the selected lines and leaves a cursor outside the edit alone" do
      buffer = spaces_buffer("a\nb\nc\nd\ne", 2)
      BufferProcess.move_to(buffer, {1, 0})
      state = buffer |> command_state() |> with_visual_selection({3, 0}, :line)

      Editing.execute(state, :indent_visual_selection)

      assert BufferProcess.content(buffer) == "a\n  b\n  c\n  d\ne"
      assert BufferProcess.cursor(buffer) == {1, 2}
    end

    test "one undo restores the original text with the cursor at the first shifted line, and one redo restores the shifted text" do
      buffer = spaces_buffer(@mixed, 2)
      BufferProcess.move_to(buffer, {3, 5})
      Editing.execute(command_state(buffer), {:indent_lines, 4})
      shifted = BufferProcess.content(buffer)

      BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == @mixed
      assert BufferProcess.cursor(buffer) == {3, 0}

      BufferProcess.redo(buffer)
      assert BufferProcess.content(buffer) == shifted
      assert BufferProcess.cursor(buffer) == {3, 7}
    end

    test "the shift is one undo step after an earlier edit" do
      buffer = spaces_buffer("x\ny\nz", 2)
      BufferProcess.move_to(buffer, {0, 1})
      BufferProcess.insert_text(buffer, "!")
      BufferProcess.break_undo_coalescing(buffer)
      BufferProcess.move_to(buffer, {0, 0})

      Editing.execute(command_state(buffer), {:indent_lines, 3})
      BufferProcess.undo(buffer)

      assert BufferProcess.content(buffer) == "x!\ny\nz"
    end

    test "a highlight on a shifted line moves with its text" do
      buffer = spaces_buffer("first\nsecond word\nthird", 2)
      add_highlight(buffer, {1, 7}, {1, 11})
      BufferProcess.move_to(buffer, {0, 0})

      Editing.execute(command_state(buffer), {:indent_lines, 3})

      assert [%{start: {1, 9}, end_: {1, 13}}] =
               buffer |> BufferProcess.decorations() |> Decorations.highlights_for_line(1)
    end

    test "subscribers receive one change event per shifted line, each with a newer version and sequence" do
      registry = :"shift_lines_events_#{System.unique_integer([:positive])}"
      start_supervised!({Minga.Events, name: registry})
      :ok = Minga.Events.subscribe(:buffer_changed, registry: registry)
      buffer = start_buffer("a\nb\nc", events_registry: registry)
      BufferProcess.set_option(buffer, :indent_with, :spaces)
      BufferProcess.set_option(buffer, :tab_width, 2)
      version = BufferProcess.version(buffer)

      Editing.execute(command_state(buffer), {:indent_lines, 3})
      BufferProcess.version(buffer)

      events =
        for _line <- 0..2 do
          assert_receive {:minga_event, :buffer_changed, %{buffer: ^buffer} = event}
          event
        end

      refute_received {:minga_event, :buffer_changed, %{buffer: ^buffer}}
      assert Enum.map(events, & &1.version) == [version + 1, version + 2, version + 3]
      assert Enum.map(events, & &1.delta.start_position) == [{0, 0}, {1, 0}, {2, 0}]

      assert events
             |> Enum.map(& &1.sequence)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b == a + 1 end)
    end

    test "a read-only buffer is left unchanged" do
      buffer = spaces_buffer("a\nb", 2)
      BufferProcess.set_read_only(buffer, true)

      Editing.execute(command_state(buffer), {:indent_lines, 2})

      assert BufferProcess.content(buffer) == "a\nb"
    end
  end

  describe "dedent" do
    test "a line selection dedent removes one level per line: one leading tab, or up to the configured spaces" do
      buffer = spaces_buffer(@mixed, 4)
      BufferProcess.move_to(buffer, {4, 8})
      state = buffer |> command_state() |> with_visual_selection({0, 0}, :line)
      before = sync_point(buffer)

      Editing.execute(state, :dedent_visual_selection)

      assert BufferProcess.content(buffer) ==
               "alpha\n\nTabbed ✓\ntwo spaces 世界\n  six spaces\n\nomega é"

      assert BufferProcess.cursor(buffer) == {4, 4}
      assert_deltas_replay(buffer, before)
    end

    test "a cursor inside the removed indentation clamps to column zero" do
      buffer = spaces_buffer("    a\n  b", 4)
      BufferProcess.move_to(buffer, {1, 1})

      Editing.execute(command_state(buffer), {:dedent_motion, :document_start})

      assert BufferProcess.content(buffer) == "a\nb"
      assert BufferProcess.cursor(buffer) == {1, 0}
    end

    test "one undo restores every dedented line" do
      buffer = spaces_buffer(@mixed, 4)
      BufferProcess.move_to(buffer, {0, 0})

      Editing.execute(command_state(buffer), {:dedent_lines, 7})
      BufferProcess.undo(buffer)

      assert BufferProcess.content(buffer) == @mixed
    end

    test "a selection with no indentation makes no edit" do
      buffer = spaces_buffer("a\nb", 2)
      before = sync_point(buffer)
      version = BufferProcess.version(buffer)

      Editing.execute(command_state(buffer), {:dedent_lines, 2})

      assert BufferProcess.content(buffer) == "a\nb"
      assert BufferProcess.version(buffer) == version
      assert {:ok, _sequence, []} = BufferProcess.changes_since(buffer, before.sequence)
    end
  end

  defp spaces_buffer(text, width) do
    buffer = start_buffer(text)
    BufferProcess.set_option(buffer, :indent_with, :spaces)
    BufferProcess.set_option(buffer, :tab_width, width)
    buffer
  end

  defp add_highlight(buffer, from, to) do
    :ok =
      BufferProcess.batch_decorations(buffer, fn decs ->
        {_id, decs} = Decorations.add_highlight(decs, from, to, style: Face.new(fg: 0xFF0000))
        decs
      end)
  end

  defp sync_point(buffer) do
    {:ok, sequence, _} = BufferProcess.changes_since(buffer, 0)
    %{sequence: sequence, content: BufferProcess.content(buffer)}
  end

  # Parser and LSP clients replay deltas in order against their copy of the
  # text. Each delta must describe the bytes and positions of the document as
  # it stood after the previous delta, and touch only the start of one line.
  defp assert_deltas_replay(buffer, %{sequence: sequence, content: original}) do
    assert {:ok, _sequence, [_ | _] = deltas} = BufferProcess.changes_since(buffer, sequence)

    replayed =
      Enum.reduce(deltas, original, fn %EditDelta{} = delta, text ->
        assert_line_start_delta(delta, text)
        prefix = binary_part(text, 0, delta.start_byte)
        suffix = binary_part(text, delta.old_end_byte, byte_size(text) - delta.old_end_byte)
        prefix <> delta.inserted_text <> suffix
      end)

    assert replayed == BufferProcess.content(buffer)
  end

  defp assert_line_start_delta(%EditDelta{} = delta, text) do
    {line, 0} = delta.start_position
    assert line_start_byte(text, line) == delta.start_byte

    {^line, old_col} = delta.old_end_position
    {^line, new_col} = delta.new_end_position
    assert delta.old_end_byte - delta.start_byte == old_col
    assert delta.new_end_byte - delta.start_byte == new_col
    assert byte_size(delta.inserted_text) == new_col
    refute String.contains?(delta.inserted_text, "\n")
  end

  defp line_start_byte(_text, 0), do: 0

  defp line_start_byte(text, line) do
    {offset, 1} = text |> :binary.matches("\n") |> Enum.at(line - 1)
    offset + 1
  end
end
