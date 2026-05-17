defmodule MingaEditor.Commands.MovementCommandTest do
  @moduledoc """
  Layer 1 command/state-handler coverage for movement commands.

  These tests call `MingaEditor.Commands.Movement.execute/2` directly on constructed editor state with a real buffer process. They verify observable cursor and content outcomes without booting the `MingaEditor` GenServer.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Movement
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  defp build_state(buf, opts \\ []) do
    rows = Keyword.get(opts, :rows, 10)
    cols = Keyword.get(opts, :cols, 40)
    editing = Keyword.get(opts, :editing, VimState.new())
    window = Window.new(1, buf, rows, cols)

    %EditorState{
      port_manager: nil,
      terminal_viewport: Viewport.new(rows, cols),
      workspace: %WorkspaceState{
        viewport: Viewport.new(rows, cols),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{tree: {:leaf, 1}, map: %{1 => window}, active: 1, next_id: 2},
        editing: editing
      }
    }
  end

  defp execute_all(state, commands) do
    Enum.reduce(commands, state, &Movement.execute(&2, &1))
  end

  describe "Layer 1 command/state handler — basic movement" do
    test "h and l move within normal-mode line boundaries without wrapping" do
      buf = start_buffer("hi\nworld")
      state = build_state(buf)

      execute_all(state, [:move_to_line_end, :move_right])
      assert BufferProcess.cursor(buf) == {0, 1}

      BufferProcess.move_to(buf, {1, 0})
      execute_all(state, [:move_left])
      assert BufferProcess.cursor(buf) == {1, 0}
    end

    test "j and k move between lines" do
      buf = start_buffer("hello\nworld")
      state = build_state(buf)

      execute_all(state, [:move_down])
      assert elem(BufferProcess.cursor(buf), 0) == 1

      execute_all(state, [:move_up])
      assert elem(BufferProcess.cursor(buf), 0) == 0
    end

    test "line start and line end commands move to expected columns" do
      buf = start_buffer("hello")
      state = build_state(buf)

      execute_all(state, [:move_to_line_end])
      assert BufferProcess.cursor(buf) == {0, 4}

      execute_all(state, [:move_to_line_start])
      assert BufferProcess.cursor(buf) == {0, 0}
    end

    test "movement commands do not change buffer content" do
      buf = start_buffer("hello\nworld\nfoo")
      state = build_state(buf)
      original = BufferProcess.content(buf)

      execute_all(state, [:move_right, :move_right, :move_down, :move_up, :move_left])

      assert BufferProcess.content(buf) == original
      assert BufferProcess.cursor(buf) == {0, 1}
    end
  end

  describe "Layer 1 command/state handler — insert movement semantics" do
    test "left and right wrap across lines in insert mode" do
      buf = start_buffer("ab\ncd")
      insert_editing = VimState.transition(VimState.new(), :insert, nil)
      state = build_state(buf, editing: insert_editing)

      execute_all(state, [:move_right, :move_right, :move_right])
      assert BufferProcess.cursor(buf) == {1, 0}

      execute_all(state, [:move_left])
      assert BufferProcess.cursor(buf) == {0, 2}
    end
  end

  describe "Layer 1 command/state handler — page movement" do
    test "half-page and page commands move the cursor by viewport content rows" do
      buf = start_buffer(lines(0..29))
      state = build_state(buf, rows: 10)

      execute_all(state, [:half_page_down])
      assert BufferProcess.cursor(buf) == {4, 0}

      execute_all(state, [:page_down])
      assert BufferProcess.cursor(buf) == {12, 0}

      execute_all(state, [:half_page_up])
      assert BufferProcess.cursor(buf) == {8, 0}

      execute_all(state, [:page_up])
      assert BufferProcess.cursor(buf) == {0, 0}
    end

    test "page commands clamp cursor at buffer boundaries and line lengths" do
      buf = start_buffer(lines(0..29))
      state = build_state(buf, rows: 10)

      BufferProcess.move_to(buf, {28, 0})
      execute_all(state, [:half_page_down])
      assert BufferProcess.cursor(buf) == {29, 0}

      BufferProcess.move_to(buf, {2, 0})
      execute_all(state, [:half_page_up])
      assert BufferProcess.cursor(buf) == {0, 0}

      BufferProcess.move_to(buf, {29, 6})
      execute_all(state, [:page_up])
      {_line, col} = BufferProcess.cursor(buf)
      assert col <= 6
    end
  end

  describe "Layer 1 command/state handler — find-char repeats" do
    test "find-char and repeat commands update cursor positions" do
      buf = start_buffer("banana split")
      state = build_state(buf)

      state = Movement.execute(state, {:find_char, :f, "a"})
      assert BufferProcess.cursor(buf) == {0, 1}

      state = Movement.execute(state, :repeat_find_char)
      assert BufferProcess.cursor(buf) == {0, 3}

      state = Movement.execute(state, :repeat_find_char)
      assert BufferProcess.cursor(buf) == {0, 5}

      Movement.execute(state, :repeat_find_char_reverse)
      assert BufferProcess.cursor(buf) == {0, 3}
    end

    test "till motion lands before target and can advance to the next target" do
      buf = start_buffer("x_abc_abc_end")
      state = build_state(buf)

      state = Movement.execute(state, {:find_char, :t, "a"})
      assert BufferProcess.cursor(buf) == {0, 1}

      state = Movement.execute(state, {:find_char, :f, "a"})
      assert BufferProcess.cursor(buf) == {0, 2}

      Movement.execute(state, {:find_char, :t, "a"})
      assert BufferProcess.cursor(buf) == {0, 5}
    end

    test "backward find repeats backward" do
      buf = start_buffer("banana split")
      state = build_state(buf)

      execute_all(state, [:move_to_line_end])
      assert elem(BufferProcess.cursor(buf), 1) > 0

      state = Movement.execute(state, {:find_char, :F, "a"})
      assert BufferProcess.cursor(buf) == {0, 5}

      Movement.execute(state, :repeat_find_char)
      assert elem(BufferProcess.cursor(buf), 1) < 5
    end
  end

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")
end
