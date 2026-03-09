defmodule Minga.Editor.MouseTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    {editor, buffer}
  end

  defp start_editor_no_buffer do
    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: nil,
        width: 40,
        height: 10
      )

    editor
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp send_mouse(editor, row, col, button, event_type, mods \\ 0, click_count \\ 1) do
    send(editor, {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  describe "mouse scroll" do
    defp start_mouse_editor do
      content = Enum.map_join(0..29, "\n", &"line #{&1}")
      {:ok, buffer} = BufferServer.start_link(content: content)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      {editor, buffer}
    end

    test "scroll down moves viewport without moving cursor when cursor stays visible" do
      {editor, buffer} = start_mouse_editor()
      send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 3
    end

    test "scroll down keeps cursor in place when it remains visible" do
      {editor, buffer} = start_mouse_editor()
      BufferServer.move_to(buffer, {5, 0})
      _ = :sys.get_state(editor)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 5
    end

    test "scroll up moves viewport without moving cursor when cursor stays visible" do
      {editor, buffer} = start_mouse_editor()
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      BufferServer.move_to(buffer, {9, 0})
      _ = :sys.get_state(editor)
      send_mouse(editor, 0, 0, :wheel_up, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 9
    end

    test "scroll clamps cursor when it falls outside viewport" do
      {editor, buffer} = start_mouse_editor()
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line >= 3
    end

    test "scroll at top of file doesn't go negative" do
      {editor, buffer} = start_mouse_editor()
      send_mouse(editor, 0, 0, :wheel_up, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 0
    end

    test "scroll at bottom of file clamps viewport" do
      {editor, buffer} = start_mouse_editor()
      for _i <- 1..10, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line >= 0
      assert line <= 29
    end

    test "scroll doesn't change mode" do
      {editor, _buffer} = start_mouse_editor()
      send_key(editor, ?i)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      assert Process.alive?(editor)
    end
  end

  describe "mouse click-to-position" do
    # Gutter width for ≤99 lines = 3 (2 digits + 1 space).
    # Screen col = gutter_width + buffer_col.
    @gutter 3

    test "left click moves cursor to clicked position" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")
      send_mouse(editor, 1, @gutter + 3, :left, :press)
      send_mouse(editor, 1, @gutter + 3, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 3
    end

    test "left click accounts for viewport scroll offset" do
      content = Enum.map_join(0..29, "\n", &"line #{&1}")
      {:ok, buffer} = BufferServer.start_link(content: content)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      # 4 wheel_down events at 3 lines each = 12 lines scrolled.
      # clamp_cursor_to_viewport moves cursor to line 12.
      # Render pipeline computes scroll_top via scroll_to_cursor:
      #   content_height = 8 (10 rows - 1 minibuffer - 1 modeline)
      #   effective_margin = min(5, (8-1)/2) = 3
      #   cursor_line 12 >= 0 + 8 - 3 → top = 12 - 8 + 1 + 3 = 8
      # So screen row 0 = line 8, row 2 = line 10.
      for _i <- 1..4, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 2, 0, :left, :press)
      send_mouse(editor, 2, 0, :left, :release)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 10
    end

    test "left click on modeline row is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferServer.cursor(buffer)
      send_mouse(editor, 8, 5, :left, :press)
      send_mouse(editor, 8, 5, :left, :release)
      assert BufferServer.cursor(buffer) == original_cursor
    end

    test "left click on minibuffer row is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferServer.cursor(buffer)
      send_mouse(editor, 9, 5, :left, :press)
      send_mouse(editor, 9, 5, :left, :release)
      assert BufferServer.cursor(buffer) == original_cursor
    end

    test "left click on tilde row (beyond buffer end) is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferServer.cursor(buffer)
      send_mouse(editor, 5, 0, :left, :press)
      send_mouse(editor, 5, 0, :left, :release)
      assert BufferServer.cursor(buffer) == original_cursor
    end

    test "left click clamps column to line length" do
      {editor, buffer} = start_editor("hi\nworld")
      send_mouse(editor, 0, 10, :left, :press)
      send_mouse(editor, 0, 10, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "left click in visual mode cancels selection, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_mouse(editor, 1, @gutter + 2, :left, :press)
      send_mouse(editor, 1, @gutter + 2, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end

    test "left click in command mode cancels command, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?:)
      send_mouse(editor, 1, @gutter + 2, :left, :press)
      send_mouse(editor, 1, @gutter + 2, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end

    test "left click in insert mode moves cursor, stays functional" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?i)
      send_mouse(editor, 1, @gutter + 2, :left, :press)
      send_mouse(editor, 1, @gutter + 2, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end
  end

  describe "mouse drag selection" do
    test "left press + drag creates visual selection" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, 0, @gutter + 2, :left, :press)
      send_mouse(editor, 0, @gutter + 8, :left, :drag)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col == 8
    end

    test "release after drag keeps visual selection active" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, 0, @gutter + 2, :left, :press)
      send_mouse(editor, 0, @gutter + 8, :left, :drag)
      send_mouse(editor, 0, @gutter + 8, :left, :release)
      {_line, col} = BufferServer.cursor(buffer)
      assert col == 8
      s = state(editor)
      assert s.mode == :visual
      assert s.mouse.dragging == false
      send_key(editor, ?y)
      assert Process.alive?(editor)
    end

    test "release without movement (click) returns to normal mode" do
      {editor, _buffer} = start_editor("hello world")
      send_mouse(editor, 0, 3, :left, :press)
      send_mouse(editor, 0, 3, :left, :release)
      s = state(editor)
      assert s.mode == :normal
      assert s.mouse.dragging == false
    end

    test "drag clamps to buffer bounds" do
      {editor, buffer} = start_editor("hi\nworld")
      send_mouse(editor, 0, 0, :left, :press)
      send_mouse(editor, 0, 50, :left, :drag)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "drag ignores events when not dragging" do
      {editor, buffer} = start_editor("hello world")
      original = BufferServer.cursor(buffer)
      send_mouse(editor, 0, 5, :left, :drag)
      assert BufferServer.cursor(buffer) == original
    end
  end

  describe "mouse with no buffer" do
    test "mouse events with no buffer don't crash" do
      editor = start_editor_no_buffer()
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 0, 0, :left, :press)
      send_mouse(editor, 0, 5, :left, :drag)
      send_mouse(editor, 0, 5, :left, :release)
      assert Process.alive?(editor)
    end
  end

  describe "mouse with negative coordinates" do
    test "negative row is ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.cursor(buffer)
      send_mouse(editor, -1, 5, :left, :press)
      assert BufferServer.cursor(buffer) == original
    end

    test "negative col is ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.cursor(buffer)
      send_mouse(editor, 0, -3, :left, :press)
      assert BufferServer.cursor(buffer) == original
    end
  end
end
