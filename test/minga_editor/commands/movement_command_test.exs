defmodule MingaEditor.Commands.MovementCommandTest do
  @moduledoc """
  Layer 1 command/state-handler coverage for movement commands.

  These tests call `MingaEditor.Commands.Movement.execute/2` directly on constructed editor state with a real buffer process. They verify observable cursor and content outcomes without booting the `MingaEditor` GenServer.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.WrapMap
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.Gutter
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

  defp update_active_window(state, fun) do
    EditorState.update_window(state, state.workspace.windows.active, fun)
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

  describe "Layer 1 command/state handler — wrap-aware movement" do
    test "wrapped j and k honor tab width when computing visual rows" do
      state =
        TestHelpers.base_state(content: "\t" <> String.duplicate("a", 30), cols: 7, rows: 10)

      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)
      _ = BufferProcess.set_option(buffer, :tab_width, 4)

      BufferProcess.move_to(buffer, {0, 4})

      _ = Movement.execute(state, :move_down)
      assert BufferProcess.cursor(buffer) == {0, 5}

      _ = Movement.execute(state, :move_up)
      assert BufferProcess.cursor(buffer) == {0, 4}
    end

    test "j/k/0/$ stay logical when folds are active" do
      content =
        [
          "visible top",
          "hidden one",
          "hidden two",
          "hidden three",
          String.duplicate("a", 120)
        ]
        |> Enum.join("\n")

      buffer = start_buffer(content)
      state = build_state(buffer)
      _ = BufferProcess.set_option(buffer, :wrap, true)

      state =
        state
        |> update_active_window(&Window.set_fold_ranges(&1, [FoldRange.new!(1, 3)]))
        |> update_active_window(&Window.fold_at(&1, 1))

      state = Movement.execute(state, :move_down)
      assert BufferProcess.cursor(buffer) == {1, 0}

      state = Movement.execute(state, :move_down)
      assert elem(BufferProcess.cursor(buffer), 0) == 4

      state = Movement.execute(state, :move_up)
      assert elem(BufferProcess.cursor(buffer), 0) == 1

      BufferProcess.move_to(buffer, {4, 90})
      _ = Movement.execute(state, :move_to_line_start)
      assert BufferProcess.cursor(buffer) == {4, 0}

      BufferProcess.move_to(buffer, {4, 90})
      _ = Movement.execute(state, :move_to_line_end)
      assert BufferProcess.cursor(buffer) == {4, 119}
    end

    test "wrapped j uses the active split window width" do
      state = TestHelpers.base_state(content: String.duplicate("a", 60) <> "\n" <> "second")
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)

      state = Movement.execute(state, :split_vertical)
      _ = Movement.execute(state, :move_down)

      expected_width = wrapped_content_width(state, buffer)

      expected_offset =
        WrapMap.compute([String.duplicate("a", 60)], expected_width)
        |> hd()
        |> Enum.at(1)
        |> Map.fetch!(:byte_offset)

      assert BufferProcess.cursor(buffer) == {0, expected_offset}
    end
  end

  describe "Layer 1 command/state handler — wrap-aware scroll positioning" do
    test "scroll_cursor_top keeps offset 0 when the wrapped file fits" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = "tail"

      state =
        TestHelpers.base_state(content: penultimate <> "\n" <> last_line, rows: 10, cols: 24)

      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      wrap_map =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      BufferProcess.move_to(buffer, {0, List.last(hd(wrap_map)).byte_offset})

      state = Movement.execute(state, :scroll_cursor_top)
      win = EditorState.active_window_struct(state)

      assert win.viewport.top == 0
      assert win.viewport.visual_row_offset == 0
    end

    test "scroll_cursor_top uses rows remaining to eof for penultimate wrapped lines" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = String.duplicate("omega psi ", 12)
      state = TestHelpers.base_state(content: penultimate <> "\n" <> last_line, rows: 5, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [penultimate_entry, last_entry] =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      total_visual_rows = WrapMap.visual_row_count([penultimate_entry, last_entry])
      visible = Viewport.content_rows(Viewport.new(5, 24, 0))
      cursor_visual_row = length(penultimate_entry) - 1

      assert total_visual_rows > visible

      BufferProcess.move_to(buffer, {0, List.last(penultimate_entry).byte_offset})

      state = Movement.execute(state, :scroll_cursor_top)
      win = EditorState.active_window_struct(state)

      assert win.viewport.top == 0

      assert win.viewport.visual_row_offset ==
               min(cursor_visual_row, max(total_visual_rows - visible, 0))
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
