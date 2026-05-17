defmodule MingaEditor.Commands.ScrollCommandsTest do
  @moduledoc """
  Layer 1 command/state-handler coverage for scroll commands.

  These tests call `MingaEditor.Commands.Movement.execute/2` directly on constructed state and assert observable cursor and active-window viewport outcomes. Key-to-command routing is covered separately in `Minga.Mode.NormalMovementDispatchTest`, so this file does not boot the `MingaEditor` GenServer.
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
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp start_editor(content, opts) do
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

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content, filetype: :elixir})
  end

  defp build_state(buf, opts \\ []) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    window = Window.new(1, buf, rows, cols)

    %EditorState{
      port_manager: nil,
      terminal_viewport: Viewport.new(rows, cols),
      workspace: %WorkspaceState{
        viewport: Viewport.new(rows, cols),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{tree: {:leaf, 1}, map: %{1 => window}, active: 1, next_id: 2}
      }
    }
  end

  defp active_viewport(state), do: EditorState.current_viewport(state)

  defp state(editor), do: :sys.get_state(editor)

  defp active_window(editor) do
    s = state(editor)
    Map.get(s.workspace.windows.map, s.workspace.windows.active)
  end

  @ctrl 0x02
  @wrapped_cursor_col 500

  defp wrapped_scroll_state do
    state =
      TestHelpers.base_state(
        content: String.duplicate("a", 600) <> "\n" <> "tail",
        rows: 10,
        cols: 40
      )

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

  describe "Layer 1 command/state handler — Ctrl-e scroll_down_line" do
    test "scrolls viewport down and clamps cursor when off-screen" do
      buf = start_buffer(lines(0..99))
      state = build_state(buf)

      state = Movement.execute(state, :scroll_down_line)

      assert active_viewport(state).top == 1
      {cursor_line, _} = BufferProcess.cursor(buf)
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
      assert active_window(editor).viewport.visual_row_offset == 0

      send_key(editor, ?y, @ctrl)
      assert BufferProcess.cursor(buffer) == original_cursor
      assert active_window(editor).viewport.visual_row_offset == 0
    end

    test "does not scroll past end of file" do
      buf = start_buffer("a\nb\nc")
      BufferProcess.move_to(buf, {2, 0})
      state = build_state(buf)

      state = Movement.execute(state, :scroll_down_line)

      assert active_viewport(state).top == 0
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

    test "preserves cursor when it stays visible" do
      buf = start_buffer(lines(0..99))
      BufferProcess.move_to(buf, {10, 0})
      state = build_state(buf)

      Movement.execute(state, :scroll_down_line)

      assert BufferProcess.cursor(buf) == {10, 0}
    end
  end

  describe "Layer 1 command/state handler — Ctrl-y scroll_up_line" do
    test "scrolls viewport up and clamps cursor when off-screen" do
      buf = start_buffer(lines(0..99))
      state = build_state(buf)

      state =
        Enum.reduce(1..5, state, fn _step, acc -> Movement.execute(acc, :scroll_down_line) end)

      max_visible = active_viewport(state).top + 20
      BufferProcess.move_to(buf, {max_visible, 0})

      state = Movement.execute(state, :scroll_up_line)

      assert active_viewport(state).top == 4
      {cursor_line, _} = BufferProcess.cursor(buf)

      assert cursor_line <=
               active_viewport(state).top + Viewport.content_rows(active_viewport(state)) - 1
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

    test "clamps wrapped eof rows to the final visual row span" do
      state =
        TestHelpers.base_state(
          content: "head\n" <> String.duplicate("a", 600),
          rows: 10,
          cols: 40
        )

      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [head_entry, eof_entry] =
        WrapMap.compute(["head", String.duplicate("a", 600)], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      head_rows = length(head_entry)
      eof_visual_rows = length(eof_entry)
      visible = Viewport.content_rows(EditorState.active_window_struct(state).viewport)
      expected_top_offset = head_rows + max(eof_visual_rows - visible, 0)

      BufferProcess.move_to(buffer, {1, List.last(eof_entry).byte_offset})

      state = Movement.execute(state, :scroll_center)
      win = EditorState.active_window_struct(state)
      bottom_row = win.viewport.top + win.viewport.visual_row_offset + visible - 1

      assert win.viewport.top + win.viewport.visual_row_offset == expected_top_offset
      assert bottom_row == head_rows + eof_visual_rows - 1
    end
  end

  describe "zt (scroll_cursor_top)" do
    test "scrolls a wrapped visual row to the top of the viewport" do
      state = wrapped_scroll_state()
      buffer = state.workspace.buffers.active
      content_width = wrapped_content_width(state, buffer)
      cursor_visual_row = wrapped_cursor_visual_row(state, buffer)

      total_visual_rows =
        [String.duplicate("a", 600), "tail"]
        |> WrapMap.compute(content_width)
        |> WrapMap.visual_row_count()

      state = Movement.execute(state, :scroll_cursor_top)
      win = EditorState.active_window_struct(state)
      visible = MingaEditor.Viewport.content_rows(win.viewport)
      expected = min(cursor_visual_row, max(total_visual_rows - visible, 0))

      assert win.viewport.top + win.viewport.visual_row_offset == expected
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

    test "clamps wrapped eof rows so the viewport ends at eof" do
      state =
        TestHelpers.base_state(
          content: "head\n" <> String.duplicate("a", 600),
          rows: 10,
          cols: 40
        )

      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [head_entry, eof_entry] =
        WrapMap.compute(["head", String.duplicate("a", 600)], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      head_rows = length(head_entry)
      eof_visual_rows = length(eof_entry)
      visible = Viewport.content_rows(EditorState.active_window_struct(state).viewport)

      BufferProcess.move_to(buffer, {1, List.last(eof_entry).byte_offset})

      state = Movement.execute(state, :scroll_cursor_bottom)
      win = EditorState.active_window_struct(state)
      bottom_row = win.viewport.top + win.viewport.visual_row_offset + visible - 1

      assert bottom_row == head_rows + eof_visual_rows - 1

      assert win.viewport.top + win.viewport.visual_row_offset ==
               head_rows + max(eof_visual_rows - visible, 0)
    end
  end

  describe "Layer 1 command/state handler — z-prefixed viewport positioning" do
    test "zz centers viewport on cursor" do
      buf = start_buffer(lines(0..99))
      BufferProcess.move_to(buf, {50, 0})
      state = build_state(buf, rows: 24)

      state = Movement.execute(state, :scroll_center)
      viewport = active_viewport(state)
      midpoint = viewport.top + div(Viewport.content_rows(viewport), 2)

      assert abs(midpoint - 50) <= 1
    end

    test "zt scrolls cursor near the top of the viewport" do
      buf = start_buffer(lines(0..99))
      BufferProcess.move_to(buf, {50, 0})
      state = build_state(buf, rows: 24)

      state = Movement.execute(state, :scroll_cursor_top)
      viewport = active_viewport(state)
      visible = Viewport.content_rows(viewport)

      assert viewport.top <= 50 and viewport.top >= 50 - visible + 1
    end

    test "zb scrolls cursor near the bottom of the viewport" do
      buf = start_buffer(lines(0..99))
      BufferProcess.move_to(buf, {50, 0})
      state = build_state(buf, rows: 24)

      state = Movement.execute(state, :scroll_cursor_bottom)
      viewport = active_viewport(state)
      bottom = viewport.top + Viewport.content_rows(viewport) - 1

      assert abs(bottom - 50) <= 6
    end
  end

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")
end
