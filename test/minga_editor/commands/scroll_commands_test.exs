defmodule MingaEditor.Commands.ScrollCommandsTest do
  @moduledoc """
  Layer 1 command/state-handler coverage for scroll commands.

  These tests call `MingaEditor.Commands.Movement.execute/2` directly on constructed state and assert observable cursor and active-window viewport outcomes. Key-to-command routing is covered separately in `Minga.Mode.NormalMovementDispatchTest`, so this file does not boot the `MingaEditor` GenServer.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Movement
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
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

  describe "Layer 1 command/state handler — Ctrl-e scroll_down_line" do
    test "scrolls viewport down and clamps cursor when off-screen" do
      buf = start_buffer(lines(0..99))
      state = build_state(buf)

      state = Movement.execute(state, :scroll_down_line)

      assert active_viewport(state).top == 1
      {cursor_line, _} = BufferProcess.cursor(buf)
      assert cursor_line >= 1
    end

    test "does not scroll past end of file" do
      buf = start_buffer("a\nb\nc")
      BufferProcess.move_to(buf, {2, 0})
      state = build_state(buf)

      state = Movement.execute(state, :scroll_down_line)

      assert active_viewport(state).top == 0
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
