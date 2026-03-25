defmodule Minga.Editor.MouseTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

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

    test "scroll down clamps cursor to respect scroll margin" do
      {editor, buffer} = start_mouse_editor()
      # Default scroll_lines is 1. Cursor at 0 gets pushed to respect
      # scroll_margin (vim scrolloff behavior: cursor stays within
      # the margin zone when viewport scrolls).
      # With height=10, reserved=2, visible_rows=8, margin=5,
      # effective_margin = min(5, div(7,2)) = 3, new_top=1:
      # cursor pushed to 1 + 3 = 4.
      send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 4
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
      # Scroll down twice (2 lines), move cursor down, then scroll up
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      BufferServer.move_to(buffer, {5, 0})
      _ = :sys.get_state(editor)
      send_mouse(editor, 0, 0, :wheel_up, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line == 5
    end

    test "scroll clamps cursor when it falls outside viewport" do
      {editor, buffer} = start_mouse_editor()
      # Scroll down enough that cursor at line 0 is off-screen
      for _i <- 1..3, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferServer.cursor(buffer)
      assert line >= 1
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
    # Gutter width for ≤99 lines = 5 (2 sign column + 2 digits + 1 space).
    # Screen col = gutter_width + buffer_col.
    @gutter 5

    test "left click moves cursor to clicked position" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")
      # Row @content_row + 1 = screen row 2 = buffer line 1
      send_mouse(editor, @content_row + 1, @gutter + 3, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 3, :left, :release)
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

      # Scroll down then click. Default scroll_lines=1, so 4 scrolls = viewport top at 4.
      for _i <- 1..4, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, @content_row + 2, 0, :left, :press)
      send_mouse(editor, @content_row + 2, 0, :left, :release)
      {line, _col} = BufferServer.cursor(buffer)
      # Verify cursor moved past the initial view (scrolled at least 4 lines).
      assert line >= 4
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
      send_mouse(editor, @content_row, 10, :left, :press)
      send_mouse(editor, @content_row, 10, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "left click in visual mode cancels selection, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end

    test "left click in command mode cancels command, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?:)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end

    test "left click in insert mode moves cursor, stays functional" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?i)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)

      {line, col} = BufferServer.cursor(buffer)
      assert line == 1
      assert col == 2
    end
  end

  describe "mouse drag selection" do
    @gutter 5

    test "left press + drag creates visual selection" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, @content_row, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row, @gutter + 8, :left, :drag)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col == 8
    end

    test "release after drag keeps visual selection active" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, @content_row, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row, @gutter + 8, :left, :drag)
      send_mouse(editor, @content_row, @gutter + 8, :left, :release)
      {_line, col} = BufferServer.cursor(buffer)
      assert col == 8
      s = state(editor)
      assert s.workspace.vim.mode == :visual
      assert s.workspace.mouse.dragging == false
      send_key(editor, ?y)
      assert Process.alive?(editor)
    end

    test "release without movement (click) returns to normal mode" do
      {editor, _buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, 3, :left, :press)
      send_mouse(editor, @content_row, 3, :left, :release)
      s = state(editor)
      assert s.workspace.vim.mode == :normal
      assert s.workspace.mouse.dragging == false
    end

    test "drag clamps to buffer bounds" do
      {editor, buffer} = start_editor("hi\nworld")
      send_mouse(editor, @content_row, 0, :left, :press)
      send_mouse(editor, @content_row, 50, :left, :drag)
      {line, col} = BufferServer.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "drag ignores events when not dragging" do
      {editor, buffer} = start_editor("hello world")
      original = BufferServer.cursor(buffer)
      send_mouse(editor, @content_row, 5, :left, :drag)
      assert BufferServer.cursor(buffer) == original
    end
  end

  describe "mouse with no buffer" do
    test "mouse events with no buffer don't crash" do
      editor = start_editor_no_buffer()
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, @content_row, 0, :left, :press)
      send_mouse(editor, @content_row, 5, :left, :drag)
      send_mouse(editor, @content_row, 5, :left, :release)
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
      send_mouse(editor, @content_row, -3, :left, :press)
      assert BufferServer.cursor(buffer) == original
    end
  end

  describe "tab close button click" do
    alias Minga.Editor.State.TabBar

    defp start_two_tab_editor do
      {:ok, buf1} = BufferServer.start_link(content: "hello")
      {:ok, buf2} = BufferServer.start_link(content: "world")

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buf1,
          width: 80,
          height: 10
        )

      # Inject a second tab directly via state manipulation
      :sys.replace_state(editor, fn s ->
        {tb, _tab} = TabBar.add(s.shell_state.tab_bar, :file, "world.ex")
        buffers = %{s.workspace.buffers | list: [buf1, buf2]}
        Minga.Editor.State.set_tab_bar(%{s | workspace: %{s.workspace | buffers: buffers}}, tb)
      end)

      {editor, buf1, buf2}
    end

    defp inject_click_regions(editor, regions) do
      :sys.replace_state(editor, fn state ->
        %{state | tab_bar_click_regions: regions}
      end)
    end

    test "clicking tab_close region closes the tab" do
      {editor, _buf1, _buf2} = start_two_tab_editor()

      s = state(editor)
      assert length(s.shell_state.tab_bar.tabs) == 2

      # The active tab is tab 2 (we just added it). Inject a close region for it.
      active_id = s.shell_state.tab_bar.active_id
      inject_click_regions(editor, [{5, 7, :"tab_close_#{active_id}"}])

      # Click the close region on the tab bar row (row 0)
      send_mouse(editor, 0, 6, :left, :press)

      s = state(editor)
      assert length(s.shell_state.tab_bar.tabs) == 1
    end

    test "clicking tab_close on the last remaining tab does nothing" do
      {editor, _buffer} = start_editor("hello")

      s = state(editor)
      assert length(s.shell_state.tab_bar.tabs) == 1
      active_id = s.shell_state.tab_bar.active_id

      inject_click_regions(editor, [{5, 7, :"tab_close_#{active_id}"}])
      send_mouse(editor, 0, 6, :left, :press)

      s = state(editor)
      assert length(s.shell_state.tab_bar.tabs) == 1
    end

    test "clicking tab_goto region switches tab without closing" do
      {editor, _buf1, _buf2} = start_two_tab_editor()

      s = state(editor)
      active_id = s.shell_state.tab_bar.active_id
      other_id = Enum.find(s.shell_state.tab_bar.tabs, &(&1.id != active_id)).id

      inject_click_regions(editor, [
        {0, 4, :"tab_goto_#{other_id}"},
        {5, 7, :"tab_close_#{other_id}"}
      ])

      # Click the goto region (not the close region)
      send_mouse(editor, 0, 2, :left, :press)

      s = state(editor)
      assert length(s.shell_state.tab_bar.tabs) == 2
      assert s.shell_state.tab_bar.active_id == other_id
    end
  end
end
