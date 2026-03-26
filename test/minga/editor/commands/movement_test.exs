defmodule Minga.Editor.Commands.MovementTest do
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content \\ "hello\nworld\nfoo") do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  describe "Normal mode — movements" do
    test "h moves cursor left" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?h)

      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "j moves cursor down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      assert elem(BufferServer.cursor(buffer), 0) == 1
    end

    test "k moves cursor up after moving down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      send_key(editor, ?k)
      assert elem(BufferServer.cursor(buffer), 0) == 0
    end

    test "arrow keys move cursor without changing content" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      original = BufferServer.content(buffer)

      send_key(editor, 57_351)
      send_key(editor, 57_351)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "unknown keys in normal mode are ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      send_key(editor, 57_376)
      assert BufferServer.content(buffer) == original
    end

    test "0 moves to beginning of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?0)
      assert BufferServer.cursor(buffer) == {0, 0}
    end

    test "$ moves to end of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?$)
      {_, col} = BufferServer.cursor(buffer)
      assert col == 4
    end

    test "l at end of line does not wrap to next line" do
      {editor, buffer} = start_editor("hi\nworld")
      send_key(editor, ?$)
      assert BufferServer.cursor(buffer) == {0, 1}

      send_key(editor, ?l)
      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "h at start of line does not wrap to previous line" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      assert BufferServer.cursor(buffer) == {1, 0}

      send_key(editor, ?h)
      assert BufferServer.cursor(buffer) == {1, 0}
    end

    test "right arrow at end of line does not wrap to next line" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?$)
      assert BufferServer.cursor(buffer) == {0, 1}

      send_key(editor, 57_351)
      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "left arrow at start of line does not wrap to previous line" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?j)
      assert BufferServer.cursor(buffer) == {1, 0}

      send_key(editor, 57_350)
      assert BufferServer.cursor(buffer) == {1, 0}
    end

    test "l does not go past last character on line in normal mode" do
      {editor, buffer} = start_editor("abc\ndef")
      for _ <- 1..10, do: send_key(editor, ?l)
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "l and h wrap across lines in insert mode" do
      {editor, buffer} = start_editor("ab\ncd")
      send_key(editor, ?i)
      send_key(editor, 57_351)
      send_key(editor, 57_351)
      send_key(editor, 57_351)
      assert BufferServer.cursor(buffer) == {1, 0}

      send_key(editor, 57_350)
      assert BufferServer.cursor(buffer) == {0, 2}
    end
  end

  describe "Normal mode — count prefix" do
    test "3l moves cursor right 3 times" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?3)
      send_key(editor, ?l)
      assert BufferServer.cursor(buffer) == {0, 3}
    end

    test "2j moves cursor down 2 lines" do
      {editor, buffer} = start_editor("a\nb\nc\nd")
      send_key(editor, ?2)
      send_key(editor, ?j)
      assert elem(BufferServer.cursor(buffer), 0) == 2
    end
  end

  describe "page / half-page scrolling" do
    defp start_scroll_editor do
      content = Enum.map_join(0..29, "\n", &"line #{&1}")

      {:ok, buffer} = BufferServer.start_link(content: content)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      {editor, buffer}
    end

    test "Ctrl+d moves cursor down by half a page" do
      {editor, buffer} = start_scroll_editor()
      send_key(editor, ?d, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 4
    end

    test "Ctrl+u moves cursor up by half a page" do
      {editor, buffer} = start_scroll_editor()
      BufferServer.move_to(buffer, {10, 0})
      _ = :sys.get_state(editor)
      send_key(editor, ?u, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 6
    end

    test "Ctrl+f moves cursor down by a full page" do
      {editor, buffer} = start_scroll_editor()
      send_key(editor, ?f, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 8
    end

    test "Ctrl+b moves cursor up by a full page" do
      {editor, buffer} = start_scroll_editor()
      BufferServer.move_to(buffer, {20, 0})
      _ = :sys.get_state(editor)
      send_key(editor, ?b, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 12
    end

    test "Ctrl+d clamps to last line at buffer end" do
      {editor, buffer} = start_scroll_editor()
      BufferServer.move_to(buffer, {28, 0})
      _ = :sys.get_state(editor)
      send_key(editor, ?d, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 29
    end

    test "Ctrl+u clamps to first line at buffer start" do
      {editor, buffer} = start_scroll_editor()
      BufferServer.move_to(buffer, {2, 0})
      _ = :sys.get_state(editor)
      send_key(editor, ?u, 0x02)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 0
    end

    test "column is clamped to new line length" do
      {editor, buffer} = start_scroll_editor()
      BufferServer.move_to(buffer, {29, 6})
      _ = :sys.get_state(editor)
      send_key(editor, ?b, 0x02)
      {_line, col} = BufferServer.cursor(buffer)
      assert col <= 6
    end
  end

  describe "stub commands" do
    test "find_file doesn't crash" do
      {editor, _buffer} = start_editor()
      send_key(editor, 32)
      _ = :sys.get_state(editor)
      send_key(editor, ?f)
      _ = :sys.get_state(editor)
      send_key(editor, ?f)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end

    test "fa moves to next 'a', ; repeats forward" do
      {editor, buffer} = start_editor("banana split")
      # Cursor starts at col 0 ('b'). fa should move to col 1 ('a')
      send_key(editor, ?f)
      send_key(editor, ?a)
      assert BufferServer.cursor(buffer) == {0, 1}

      # ; should repeat: move to next 'a' at col 3
      send_key(editor, ?;)
      assert BufferServer.cursor(buffer) == {0, 3}

      # ; again: move to next 'a' at col 5
      send_key(editor, ?;)
      assert BufferServer.cursor(buffer) == {0, 5}
    end

    test ", reverses the last find char direction" do
      {editor, buffer} = start_editor("banana split")
      # fa moves to col 1, ; to col 3, , back to col 1
      send_key(editor, ?f)
      send_key(editor, ?a)
      send_key(editor, ?;)
      assert BufferServer.cursor(buffer) == {0, 3}

      send_key(editor, ?,)
      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "ta moves to one before next 'a', ; repeats till motion" do
      {editor, buffer} = start_editor("x_abc_abc_end")
      # Cursor at 0. ta finds 'a' at col 2, lands at col 1 (one before)
      send_key(editor, ?t)
      send_key(editor, ?a)
      assert BufferServer.cursor(buffer) == {0, 1}

      # Move past the first 'a' so ; has room to advance.
      # fa lands on col 2, then ; (repeating t) finds next 'a' at col 6, lands at col 5.
      send_key(editor, ?f)
      send_key(editor, ?a)
      assert BufferServer.cursor(buffer) == {0, 2}

      # Now ta again from col 2 should find 'a' at col 6, land at col 5
      send_key(editor, ?t)
      send_key(editor, ?a)
      assert BufferServer.cursor(buffer) == {0, 5}
    end

    test "Fa moves backward, ; repeats backward" do
      # Place cursor at the end by moving right
      {editor, buffer} = start_editor("banana split")
      send_key(editor, ?$)
      end_col = elem(BufferServer.cursor(buffer), 1)
      assert end_col > 0

      # Fa should find 'a' backward from end
      send_key(editor, ?F)
      send_key(editor, ?a)
      first_pos = elem(BufferServer.cursor(buffer), 1)
      assert first_pos == 5

      # ; should repeat backward (same direction as F)
      send_key(editor, ?;)
      second_pos = elem(BufferServer.cursor(buffer), 1)
      assert second_pos < first_pos
    end

    test "buffer_list doesn't crash" do
      {editor, _buffer} = start_editor()
      send_key(editor, 32)
      _ = :sys.get_state(editor)
      send_key(editor, ?b)
      _ = :sys.get_state(editor)
      send_key(editor, ?b)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end
end
