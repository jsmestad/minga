defmodule Minga.Editor.MouseMultiClickTest do
  @moduledoc "Tests for multi-click selection, modifier clicks, and new mouse features."
  use Minga.Test.EditingModelCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @gutter 5
  # Content starts at row 1 because the tab bar occupies row 0.
  @content_row 1

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

  defp send_mouse(editor, row, col, button, event_type, mods \\ 0, click_count \\ 1) do
    send(editor, {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}})
    _ = :sys.get_state(editor)
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  defp active_window_viewport(editor) do
    s = state(editor)
    win = Map.get(s.workspace.windows.map, s.workspace.windows.active)
    win.viewport
  end

  describe "double-click word selection" do
    test "double-click selects word under cursor" do
      {editor, buffer} = start_editor("hello world foo")
      # Double-click on "world" (col 6 in buffer, +gutter)
      send_mouse(editor, @content_row, @gutter + 6, :left, :press, 0, 2)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_type == :char
      # Anchor should be at start of "world" (col 6)
      {_anchor_line, anchor_col} = s.workspace.editing.mode_state.visual_anchor
      assert anchor_col == 6

      # Cursor should be at end of "world" (col 10)
      {_line, cursor_col} = BufferServer.cursor(buffer)
      assert cursor_col == 10
    end

    test "double-click on first word selects it" do
      {editor, buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, @gutter + 2, :left, :press, 0, 2)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      {_line, anchor_col} = s.workspace.editing.mode_state.visual_anchor
      assert anchor_col == 0

      {_line, cursor_col} = BufferServer.cursor(buffer)
      assert cursor_col == 4
    end

    test "double-click on space selects the space" do
      {editor, _buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, @gutter + 5, :left, :press, 0, 2)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
    end
  end

  describe "triple-click line selection" do
    test "triple-click selects entire line in visual line mode" do
      {editor, _buffer} = start_editor("hello\nworld\nfoo")
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press, 0, 3)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_type == :line
      {anchor_line, anchor_col} = s.workspace.editing.mode_state.visual_anchor
      assert anchor_line == 1
      assert anchor_col == 0
    end
  end

  describe "shift+click extends selection" do
    test "shift+click from normal mode starts visual selection" do
      {editor, buffer} = start_editor("hello world foo bar")
      # Position cursor at col 0
      send_mouse(editor, @content_row, @gutter + 0, :left, :press)
      send_mouse(editor, @content_row, @gutter + 0, :left, :release)

      # Shift+click at col 10
      send_mouse(editor, @content_row, @gutter + 10, :left, :press, 0x01)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      {_line, anchor_col} = s.workspace.editing.mode_state.visual_anchor
      assert anchor_col == 0

      {_line, cursor_col} = BufferServer.cursor(buffer)
      assert cursor_col == 10
    end

    test "shift+click in visual mode extends existing selection" do
      {editor, buffer} = start_editor("hello world foo bar")
      # Enter visual mode manually
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)

      # Shift+click further right
      send_mouse(editor, @content_row, @gutter + 15, :left, :press, 0x01)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      {_line, cursor_col} = BufferServer.cursor(buffer)
      assert cursor_col == 15
    end
  end

  describe "middle-click paste" do
    test "middle-click moves cursor to click position" do
      {editor, buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, @gutter + 5, :middle, :press)

      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col == 5
    end

    test "middle-click doesn't crash when no yank register content" do
      {editor, _buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, @gutter + 5, :middle, :press)
      assert Process.alive?(editor)
    end
  end

  describe "horizontal scroll" do
    test "wheel_right shifts viewport left offset" do
      {editor, _buffer} =
        start_editor(
          "a very long line that extends beyond the viewport width for testing horizontal scroll"
        )

      send_mouse(editor, 0, 0, :wheel_right, :press)

      vp = active_window_viewport(editor)
      assert vp.left == 6
    end

    test "wheel_left shifts viewport left offset back" do
      {editor, _buffer} =
        start_editor(
          "a very long line that extends beyond the viewport width for testing horizontal scroll"
        )

      send_mouse(editor, 0, 0, :wheel_right, :press)
      send_mouse(editor, 0, 0, :wheel_left, :press)

      vp = active_window_viewport(editor)
      assert vp.left == 0
    end

    test "wheel_left doesn't go negative" do
      {editor, _buffer} = start_editor("hello")
      send_mouse(editor, 0, 0, :wheel_left, :press)

      vp = active_window_viewport(editor)
      assert vp.left == 0
    end
  end

  describe "modifier+click go-to-definition" do
    test "ctrl+click moves cursor and doesn't crash" do
      {editor, buffer} = start_editor("hello world")
      # Ctrl+click (0x02 is ctrl modifier)
      send_mouse(editor, @content_row, @gutter + 3, :left, :press, 0x02)

      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col == 3
      assert Process.alive?(editor)
    end
  end

  describe "negative coordinates" do
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
