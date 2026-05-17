defmodule MingaEditor.Commands.ScrollCommandsTest do
  @moduledoc """
  Integration tests for scroll commands (Ctrl-e/y, zz/zt/zb).

  Verifies the full execute path: read cursor, scroll viewport,
  clamp cursor, write to the correct window's viewport.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.WrapMap
  alias MingaEditor
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  defp start_editor(content, opts \\ []) do
    {:ok, buffer} = BufferProcess.start_link(content: content, filetype: :elixir)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: Keyword.get(opts, :width, 80),
        height: Keyword.get(opts, :height, 24),
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp state(editor), do: :sys.get_state(editor)

  defp active_window(editor) do
    s = state(editor)
    Map.get(s.workspace.windows.map, s.workspace.windows.active)
  end

  @ctrl 0x02
  @wrapped_cursor_col 500

  defp wrapped_scroll_state do
    state = TestHelpers.base_state(content: String.duplicate("a", 600) <> "\n" <> "tail", rows: 10, cols: 40)
    buffer = state.workspace.buffers.active

    _ = BufferProcess.set_option(buffer, :wrap, true)
    _ = BufferProcess.set_option(buffer, :line_numbers, :none)
    BufferProcess.move_to(buffer, {0, @wrapped_cursor_col})

    state
  end

  defp wrapped_cursor_visual_row(state, buffer) do
    content_width = wrapped_content_width(state, buffer)

    String.duplicate("a", 600)
    |> then(&WrapMap.compute([&1], content_width))
    |> hd()
    |> Enum.with_index()
    |> Enum.filter(fn {row, _idx} -> row.byte_offset <= @wrapped_cursor_col end)
    |> List.last()
    |> elem(1)
  end

  defp wrapped_content_width(state, buffer) do
    layout = Layout.get(state)

    content_width =
      case Layout.active_window_layout(layout, state) do
        %{content: {_row, _col, width, _height}} -> width
        nil -> elem(layout.editor_area, 2)
      end

    line_count = BufferProcess.line_count(buffer)

    gutter_width =
      case BufferProcess.get_option(buffer, :line_numbers) do
        :none -> Gutter.total_width(0)
        _ -> Gutter.total_width(Viewport.gutter_width(line_count))
      end

    max(content_width - gutter_width, 1)
  end

  describe "Ctrl-e (scroll_down_line)" do
    test "scrolls viewport down and clamps cursor when off-screen" do
      content = Enum.map_join(0..99, "\n", &"line #{&1}")
      {editor, buffer} = start_editor(content)

      # Cursor is at line 0. Scroll down once.
      send_key(editor, ?e, @ctrl)

      win = active_window(editor)
      assert win.viewport.top == 1

      # Cursor should be clamped to stay visible (at least line 1)
      {cursor_line, _} = BufferProcess.cursor(buffer)
      assert cursor_line >= 1
    end

    test "wrapped scroll preserves the cursor when it stays visible" do
      content =
        String.duplicate("a", 120) <> "\n" <> String.duplicate("b", 160) <> "\n" <> "tail\nfinal"

      {editor, buffer} = start_editor(content, width: 40, height: 10)
      BufferProcess.set_option(buffer, :wrap, true)

      BufferProcess.move_to(buffer, {1, 0})
      original_cursor = BufferProcess.cursor(buffer)

      send_key(editor, ?e, @ctrl)
      assert BufferProcess.cursor(buffer) == original_cursor
      assert active_window(editor).viewport.visual_row_offset == 1

      send_key(editor, ?y, @ctrl)
      assert BufferProcess.cursor(buffer) == original_cursor
      assert active_window(editor).viewport.visual_row_offset == 0
    end

    test "does not scroll past end of file" do
      {editor, buffer} = start_editor("a\nb\nc")

      # Move cursor to last line
      BufferProcess.move_to(buffer, {2, 0})
      _ = :sys.get_state(editor)

      # Try to scroll down past EOF
      send_key(editor, ?e, @ctrl)

      win = active_window(editor)
      # With only 3 lines and a tall viewport, top should stay 0
      assert win.viewport.top == 0
    end

    test "wrapped scroll nudges the cursor when it would leave the viewport" do
      content =
        String.duplicate("a", 120) <> "\n" <> String.duplicate("b", 160) <> "\n" <> "tail\nfinal"

      {editor, buffer} = start_editor(content, width: 40, height: 10)
      BufferProcess.set_option(buffer, :wrap, true)

      BufferProcess.move_to(buffer, {0, 0})
      original_cursor = BufferProcess.cursor(buffer)

      send_key(editor, ?e, @ctrl)

      {cursor_line, cursor_col} = BufferProcess.cursor(buffer)
      refute {cursor_line, cursor_col} == original_cursor
      assert cursor_line == 0
      assert cursor_col > 0
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
      BufferProcess.move_to(buffer, {max_visible, 0})
      _ = :sys.get_state(editor)

      send_key(editor, ?y, @ctrl)

      win_after = active_window(editor)
      assert win_after.viewport.top == 4
    end
  end

  describe "zz (scroll_center)" do
    test "centers the wrapped visual row on screen" do
      state = wrapped_scroll_state()
      buffer = state.workspace.buffers.active
      cursor_visual_row = wrapped_cursor_visual_row(state, buffer)

      state = Movement.execute(state, :scroll_center)
      win = EditorState.active_window_struct(state)
      visible = MingaEditor.Viewport.content_rows(win.viewport)
      centered_row = win.viewport.top + win.viewport.visual_row_offset + div(visible, 2)

      assert centered_row == cursor_visual_row
    end
  end

  describe "zt (scroll_cursor_top)" do
    test "scrolls a wrapped visual row to the top of the viewport" do
      state = wrapped_scroll_state()
      buffer = state.workspace.buffers.active
      cursor_visual_row = wrapped_cursor_visual_row(state, buffer)

      state = Movement.execute(state, :scroll_cursor_top)
      win = EditorState.active_window_struct(state)

      assert win.viewport.top + win.viewport.visual_row_offset == cursor_visual_row
    end
  end

  describe "zb (scroll_cursor_bottom)" do
    test "scrolls a wrapped visual row to the bottom of the viewport" do
      state = wrapped_scroll_state()
      buffer = state.workspace.buffers.active
      cursor_visual_row = wrapped_cursor_visual_row(state, buffer)

      state = Movement.execute(state, :scroll_cursor_bottom)
      win = EditorState.active_window_struct(state)
      visible = MingaEditor.Viewport.content_rows(win.viewport)
      bottom_row = win.viewport.top + win.viewport.visual_row_offset + visible - 1

      assert bottom_row == cursor_visual_row
    end
  end
end
