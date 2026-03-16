defmodule Minga.Editor.Commands.ScrollCommandsTest do
  @moduledoc """
  Integration tests for scroll commands (Ctrl-e/y, zz/zt/zb).

  Verifies the full execute path: read cursor, scroll viewport,
  clamp cursor, write to the correct window's viewport.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content, opts \\ []) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: Keyword.get(opts, :width, 80),
        height: Keyword.get(opts, :height, 24)
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  defp active_window(editor) do
    s = state(editor)
    Map.get(s.windows.map, s.windows.active)
  end

  @ctrl 0x02

  describe "Ctrl-e (scroll_down_line)" do
    test "scrolls viewport down and clamps cursor when off-screen" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content)

      # Cursor is at line 0. Scroll down once.
      send_key(editor, ?e, @ctrl)

      win = active_window(editor)
      assert win.viewport.top == 1

      # Cursor should be clamped to stay visible (at least line 1)
      {cursor_line, _} = BufferServer.cursor(buffer)
      assert cursor_line >= 1
    end

    test "does not scroll past end of file" do
      {editor, buffer} = start_editor("a\nb\nc")

      # Move cursor to last line
      BufferServer.move_to(buffer, {2, 0})
      _ = :sys.get_state(editor)

      # Try to scroll down past EOF
      send_key(editor, ?e, @ctrl)

      win = active_window(editor)
      # With only 3 lines and a tall viewport, top should stay 0
      assert win.viewport.top == 0
    end

    test "preserves cursor when it stays visible" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content)

      # Move cursor to line 10 (well within view after 1 scroll)
      BufferServer.move_to(buffer, {10, 0})
      _ = :sys.get_state(editor)

      send_key(editor, ?e, @ctrl)

      {cursor_line, _} = BufferServer.cursor(buffer)
      assert cursor_line == 10
    end
  end

  describe "Ctrl-y (scroll_up_line)" do
    test "scrolls viewport up and clamps cursor when off-screen" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content)

      # First scroll down enough to have room to scroll up
      for _ <- 1..5, do: send_key(editor, ?e, @ctrl)

      # Move cursor to line that will be below viewport after scroll up
      win = active_window(editor)
      max_visible = win.viewport.top + 20
      BufferServer.move_to(buffer, {max_visible, 0})
      _ = :sys.get_state(editor)

      send_key(editor, ?y, @ctrl)

      win_after = active_window(editor)
      assert win_after.viewport.top == 4
    end
  end

  describe "zz (scroll_center)" do
    test "centers viewport on cursor" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content, height: 24)

      # Move cursor to line 50
      BufferServer.move_to(buffer, {50, 0})
      _ = :sys.get_state(editor)

      # Press z then z
      send_key(editor, ?z)
      send_key(editor, ?z)

      win = active_window(editor)
      # The viewport should be centered on line 50.
      # visible_rows = 24 - 2 (footer) = 22, so top should be ~50 - 11 = 39
      # But window viewport has reserved: 2, so content_rows = 22
      # center_on: 50 - div(22, 2) = 50 - 11 = 39
      assert win.viewport.top >= 38 and win.viewport.top <= 42
    end
  end

  describe "zt (scroll_cursor_top)" do
    test "scrolls cursor to top of viewport" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content, height: 24)

      BufferServer.move_to(buffer, {50, 0})
      _ = :sys.get_state(editor)

      # Press z then t
      send_key(editor, ?z)
      send_key(editor, ?t)

      win = active_window(editor)
      # With scroll_margin (default 5), top should be around 50 - 5 = 45
      assert win.viewport.top >= 44 and win.viewport.top <= 50
    end
  end

  describe "zb (scroll_cursor_bottom)" do
    test "scrolls cursor to bottom of viewport" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content, height: 24)

      BufferServer.move_to(buffer, {50, 0})
      _ = :sys.get_state(editor)

      # Press z then b
      send_key(editor, ?z)
      send_key(editor, ?b)

      win = active_window(editor)
      # visible_rows = max(24 - 2, 1) = 22, cursor at 50
      # bottom_on: target_top = 50 - 22 + 1 + margin(5) = 34
      assert win.viewport.top >= 30 and win.viewport.top <= 40,
             "expected viewport.top between 30-40, got #{win.viewport.top}"
    end
  end
end
