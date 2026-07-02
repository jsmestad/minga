defmodule MingaEditor.MouseTest do
  @moduledoc """
  Focused mouse behavior tests at the `MingaEditor.Mouse` boundary.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Mode.VisualState
  alias MingaEditor.Commands.Movement
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceDomain
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.ChromeState

  @content_row 1
  @ctrl 0x02
  @super 0x08

  describe "scrolling" do
    test "vertical scroll moves viewport without moving the cursor" do
      {state, buffer} = start_mouse_state(lines(0..29))

      state = mouse(state, 0, 0, :wheel_down, :press)
      assert BufferProcess.cursor(buffer) == {0, 0}
      assert active_viewport(state).top == 3

      state = mouse(state, 0, 0, :wheel_up, :press)
      assert BufferProcess.cursor(buffer) == {0, 0}
      assert active_viewport(state).top == 0
    end

    test "scrolling an inactive split moves that window without stealing focus" do
      {state, _buffer} = start_mouse_state(lines(0..29))
      state = Movement.execute(state, :split_vertical)
      active_id = state.workspace.windows.active
      layout = Layout.get(state)

      {target_id, %{content: rect = {row, col, _width, _height}}} =
        rightmost_window_layout(layout)

      target_before = window_viewport(state, target_id).top
      active_before = window_viewport(state, active_id).top
      node = FocusNode.new(:buffer_content, rect, ref: target_id)

      state = Mouse.handle_at_node(state, node, row + 1, col + 1, :wheel_down, 0, :press, 1)

      assert state.workspace.windows.active == active_id
      assert window_viewport(state, active_id).top == active_before
      assert window_viewport(state, target_id).top > target_before
    end

    test "scrolling preserves the active editing mode" do
      {state, _buffer} = start_mouse_state(lines(0..29))
      state = EditorState.transition_mode(state, :insert)

      state = mouse(state, 0, 0, :wheel_down, :press)

      assert state.workspace.editing.mode == :insert
    end
  end

  describe "resident window scroll intent (#2661)" do
    test "an in-bounds report moves only the viewport, cursor untouched" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Mouse.handle_scroll_batch(state, win_id, 2, :down)

      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window_viewport(state, win_id).top == 42
    end

    test "a report that would breach scrolloff drags the cursor along with the viewport" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Mouse.handle_scroll_batch(state, win_id, 30, :down)

      {cursor_line, _col} = BufferProcess.cursor(buffer)
      new_top = window_viewport(state, win_id).top
      assert new_top == 70
      assert cursor_line >= new_top
    end

    test "a non-resident window keeps today's viewport-only behavior regardless of magnitude" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Mouse.handle_scroll_batch(state, win_id, 30, :down)

      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window_viewport(state, win_id).top == 70
    end

    test "a resident window on a non-GUI frontend never drags the cursor" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Mouse.handle_scroll_batch(state, win_id, 30, :down)

      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window_viewport(state, win_id).top == 70
    end

    test "handle_scroll_batch records the committed top as the free-scroll echo top" do
      {state, _buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)

      state = Mouse.handle_scroll_batch(state, win_id, 3, :down)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert window.scroll_echo_top == window.viewport.top
    end

    test "H resolves against the reported top after a scroll report (ordered channel, AC2)" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active

      state = Mouse.handle_scroll_batch(state, win_id, 10, :down)
      state = Movement.execute(state, {:move_to_screen, :top})

      {cursor_line, _col} = BufferProcess.cursor(buffer)
      assert cursor_line == window_viewport(state, win_id).top
      assert cursor_line == 10
    end
  end

  describe "active-window discrete wheel scroll (#2671)" do
    test "a resident GUI window free-scrolls via apply_scroll_intent, marking the echo top" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = mouse(state, 0, 0, :wheel_down, :press)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      # apply_scroll_intent marks the committed top as a free-scroll echo; the
      # viewport-only path never touches scroll_echo_top.
      assert window.scroll_echo_top == window.viewport.top
      assert BufferProcess.cursor(buffer) == {50, 0}
    end

    test "a resident GUI window drags the cursor once the wheel breaches scrolloff" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Enum.reduce(1..20, state, fn _, acc -> mouse(acc, 0, 0, :wheel_down, :press) end)

      {cursor_line, _col} = BufferProcess.cursor(buffer)
      window = Map.fetch!(state.workspace.windows.map, win_id)
      new_top = window.viewport.top
      assert window.scroll_echo_top == new_top
      assert cursor_line > 50
      assert cursor_line >= new_top
    end

    test "a resident GUI window scrolls up through apply_scroll_intent as well" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = mouse(state, 0, 0, :wheel_up, :press)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert window.scroll_echo_top == window.viewport.top
      assert window.viewport.top == 39
      assert BufferProcess.cursor(buffer) == {50, 0}
    end

    test "the TUI keeps viewport-only wheel behavior byte-identically (no cursor move, no echo)" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      win_id = state.workspace.windows.active
      # Resident, but a non-GUI frontend: the shared clause must NOT free-scroll.
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      before_top = window_viewport(state, win_id).top
      state = mouse(state, 0, 0, :wheel_down, :press)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert window.scroll_echo_top == nil
      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window.viewport.top > before_top
    end

    test "a non-resident GUI window keeps viewport-only wheel behavior byte-identically" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      before_top = window_viewport(state, win_id).top
      state = mouse(state, 0, 0, :wheel_down, :press)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert window.scroll_echo_top == nil
      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window.viewport.top > before_top
    end
  end

  describe "click-to-position" do
    test "left click moves the cursor to the clicked buffer position" do
      {state, buffer} = start_mouse_state("hello\nworld\nfoo bar baz")
      {row, col} = buffer_screen_pos(state, 1, 3)

      state = mouse(state, row, col, :left, :press)
      mouse(state, row, col, :left, :release)

      assert BufferProcess.cursor(buffer) == {1, 3}
    end

    test "clicking chrome or virtual rows leaves the cursor alone" do
      {state, buffer} = start_mouse_state("hello\nworld")
      original_cursor = BufferProcess.cursor(buffer)

      state = mouse(state, 8, 5, :left, :press)
      state = mouse(state, 9, 5, :left, :press)
      mouse(state, 5, 0, :left, :press)

      assert BufferProcess.cursor(buffer) == original_cursor
    end

    test "right click inside an active selection preserves it, outside clears it" do
      {state, buffer} = start_mouse_state("hello world\nsecond line")
      {inside_row, inside_col} = buffer_screen_pos(state, 0, 2)
      {outside_row, outside_col} = buffer_screen_pos(state, 1, 2)
      state = set_visual_selection(state, buffer, {0, 0}, {0, 4}, :char)

      state = mouse(state, inside_row, inside_col, :right, :press)

      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert BufferProcess.cursor(buffer) == {0, 4}

      state = mouse(state, outside_row, outside_col, :right, :press)

      assert state.workspace.editing.mode == :normal
      assert BufferProcess.cursor(buffer) == {1, 2}
    end

    test "wrapped visual row offset maps top-screen clicks into the visible continuation row" do
      {state, buffer} = start_mouse_state(String.duplicate("a", 120), width: 20)
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      state =
        EditorState.update_window(state, state.workspace.windows.active, fn window ->
          viewport = MingaEditor.Viewport.put_top_visual(window.viewport, 0, 1, 3)
          Window.set_viewport(window, viewport)
        end)

      {content_row, content_col} = active_content_origin(state)

      gutter_width =
        MingaEditor.Mouse.HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))

      target =
        MingaEditor.Mouse.HitTest.resolve_buffer(
          state,
          content_row,
          content_col + gutter_width + 2
        )

      assert {:buffer, target} = target
      assert MingaEditor.Mouse.Target.Buffer.position(target) == {0, 76}

      state = mouse(state, content_row, content_col + gutter_width + 2, :left, :press)

      assert BufferProcess.cursor(buffer) == {0, 76}
      assert active_viewport(state).visual_row_offset == 1
    end

    test "wrapped mouse hit testing uses composed inline virtual text wrap boundaries" do
      {state, buffer} = start_mouse_state(String.duplicate("a", 100))
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)

      BufferProcess.add_virtual_text(buffer, {0, 70},
        placement: :inline,
        segments: [{String.duplicate("V", 20), Minga.Core.Face.new()}]
      )

      {content_row, content_col} = active_content_origin(state)

      target = MingaEditor.Mouse.HitTest.resolve_buffer(state, content_row + 1, content_col)

      assert {:buffer, target} = target
      assert MingaEditor.Mouse.Target.Buffer.position(target) == {0, 70}
    end

    test "wrapped mouse hit testing does not adjust inline virtual text twice" do
      {state, buffer} = start_mouse_state(String.duplicate("a", 100))
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)

      BufferProcess.add_virtual_text(buffer, {0, 70},
        placement: :inline,
        segments: [{String.duplicate("V", 20), Minga.Core.Face.new()}]
      )

      {content_row, content_col} = active_content_origin(state)
      click_col_after_virtual_text = content_col + 25

      target =
        MingaEditor.Mouse.HitTest.resolve_buffer(
          state,
          content_row + 1,
          click_col_after_virtual_text
        )

      assert {:buffer, target} = target
      assert MingaEditor.Mouse.Target.Buffer.position(target) == {0, 79}
    end

    test "native GUI Ctrl-left click positions the cursor without TUI goto-definition feedback" do
      {state, buffer} = start_mouse_state("hello\nworld\nfoo bar baz")
      state = set_capabilities(state, :native_gui)
      {row, col} = buffer_screen_pos(state, 1, 3)

      state = mouse(state, row, col, :left, :press, @ctrl)

      assert BufferProcess.cursor(buffer) == {1, 3}
      refute EditorState.status_msg(state) == "No language server"
    end

    test "TUI Ctrl-left click keeps goto-definition feedback" do
      {state, buffer} = start_mouse_state("hello\nworld\nfoo bar baz")
      {row, col} = buffer_screen_pos(state, 1, 3)

      state = mouse(state, row, col, :left, :press, @ctrl)

      assert BufferProcess.cursor(buffer) == {1, 3}
      assert EditorState.status_msg(state) == "No language server"
    end

    test "double-click selects a Unicode word by character offsets" do
      {state, buffer} = start_mouse_state("éclair test")
      {row, col} = buffer_screen_pos(state, 0, 1)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 6}
      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
    end
  end

  describe "double-click word selection" do
    test "selects ASCII identifiers and snake_case as Vim words" do
      {state, buffer} = start_mouse_state("let foo_bar123 = value")
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 13}
      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 4}
    end

    test "selects punctuation runs separately from words" do
      {state, buffer} = start_mouse_state("foo...bar")
      {row, col} = buffer_screen_pos(state, 0, 4)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 5}
      assert state.workspace.editing.mode_state.visual_anchor == {0, 3}
    end

    test "keeps kebab-case hyphens as punctuation boundaries" do
      {state, buffer} = start_mouse_state("foo-bar")
      {row, col} = buffer_screen_pos(state, 0, 5)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 6}
      assert state.workspace.editing.mode_state.visual_anchor == {0, 4}
    end

    test "keeps module separators as punctuation boundaries" do
      {state, buffer} = start_mouse_state("Minga.Editor.State")
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 11}
      assert state.workspace.editing.mode_state.visual_anchor == {0, 6}
    end

    test "selects whitespace runs with inner-word semantics" do
      {state, buffer} = start_mouse_state("foo   bar")
      {row, col} = buffer_screen_pos(state, 0, 4)

      state = mouse(state, row, col, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 5}
      assert state.workspace.editing.mode_state.visual_anchor == {0, 3}
    end

    test "clicks at word start and end select the whole word" do
      {start_state, start_buffer} = start_mouse_state("hello world")
      {start_row, start_col} = buffer_screen_pos(start_state, 0, 0)
      start_state = mouse(start_state, start_row, start_col, :left, :press, 0, 2)

      assert BufferProcess.cursor(start_buffer) == {0, 4}
      assert start_state.workspace.editing.mode_state.visual_anchor == {0, 0}

      {end_state, end_buffer} = start_mouse_state("hello world")
      {end_row, end_col} = buffer_screen_pos(end_state, 0, 4)
      end_state = mouse(end_state, end_row, end_col, :left, :press, 0, 2)

      assert BufferProcess.cursor(end_buffer) == {0, 4}
      assert end_state.workspace.editing.mode_state.visual_anchor == {0, 0}
    end

    test "double-click drag extends backward by word boundaries" do
      {state, buffer} = start_mouse_state("alpha beta gamma")
      {press_row, press_col} = buffer_screen_pos(state, 0, 8)
      {drag_row, drag_col} = buffer_screen_pos(state, 0, 2)

      state = mouse(state, press_row, press_col, :left, :press, 0, 2)
      state = mouse(state, drag_row, drag_col, :left, :drag)

      assert BufferProcess.cursor(buffer) == {0, 0}
      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 9}
    end

    test "double-click drag extends forward by word boundaries" do
      {state, buffer} = start_mouse_state("alpha beta gamma")
      {press_row, press_col} = buffer_screen_pos(state, 0, 2)
      {drag_row, drag_col} = buffer_screen_pos(state, 0, 7)

      state = mouse(state, press_row, press_col, :left, :press, 0, 2)
      state = mouse(state, drag_row, drag_col, :left, :drag)

      assert BufferProcess.cursor(buffer) == {0, 9}
      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
    end

    test "double-click drag backward onto an empty line keeps the original word selected" do
      {state, buffer} = start_mouse_state("alpha\n\nbeta gamma")
      {press_row, press_col} = buffer_screen_pos(state, 2, 1)
      {drag_row, drag_col} = buffer_screen_pos(state, 1, 0)

      state = mouse(state, press_row, press_col, :left, :press, 0, 2)
      state = mouse(state, drag_row, drag_col, :left, :drag)

      assert BufferProcess.cursor(buffer) == {1, 0}
      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {2, 3}
    end
  end

  describe "split separators" do
    test "double-clicking a separator resets split size without entering visual mode" do
      {state, _buffer} = start_mouse_state("hello world")
      state = Movement.execute(state, :split_vertical)
      screen = Layout.get(state).editor_area
      {screen_row, screen_col, screen_width, screen_height} = screen
      row = screen_row + div(screen_height, 2)
      initial_sep_col = screen_col + div(screen_width - 1, 2)

      {:ok, {:vertical, sep_pos}} =
        WindowTree.separator_at(state.workspace.windows.tree, screen, row, initial_sep_col)

      {:ok, resized_tree} =
        WindowTree.resize_at(
          state.workspace.windows.tree,
          screen,
          :vertical,
          sep_pos,
          sep_pos - 5
        )

      state = set_window_tree(state, resized_tree)

      {:ok, {:vertical, resized_sep_pos}} =
        WindowTree.separator_at(state.workspace.windows.tree, screen, row, sep_pos - 5)

      state = mouse(state, row, resized_sep_pos, :left, :press, 0, 2)

      assert {:split, :vertical, _left, _right, 0} = state.workspace.windows.tree
      assert state.workspace.editing.mode == :normal
    end
  end

  describe "drag selection" do
    test "left press and drag creates a visual selection" do
      {state, buffer} = start_mouse_state("hello world foo")
      {press_row, press_col} = buffer_screen_pos(state, 0, 2)
      {drag_row, drag_col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, press_row, press_col, :left, :press)
      state = mouse(state, drag_row, drag_col, :left, :drag)

      assert BufferProcess.cursor(buffer) == {0, 8}
      assert state.workspace.editing.mode == :visual
    end

    test "release after drag stops dragging and keeps the selection" do
      {state, _buffer} = start_mouse_state("hello world foo")
      {press_row, press_col} = buffer_screen_pos(state, 0, 2)
      {drag_row, drag_col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, press_row, press_col, :left, :press)
      state = mouse(state, drag_row, drag_col, :left, :drag)
      assert state.workspace.editing.mode == :visual

      state = mouse(state, drag_row, drag_col, :left, :release)

      assert state.workspace.editing.mode == :visual
      refute state.workspace.mouse.dragging
    end

    test "dragging past the bottom and right edges autoscrolls while extending selection" do
      {state, buffer} =
        start_mouse_state(
          String.duplicate("abcdefghijklmnopqrstuvwxyz", 4) <> "\n" <> lines(1..29)
        )

      BufferProcess.set_option(buffer, :wrap, false)
      %{content: {row, col, width, height}} = active_window_layout(state)
      {press_row, press_col} = buffer_screen_pos(state, 0, 0)

      state = mouse(state, press_row, press_col, :left, :press)
      state = mouse(state, row + height, col + width, :left, :drag)

      assert active_viewport(state).top > 0 or active_viewport(state).left > 0
      assert state.workspace.editing.mode == :visual
    end

    test "dragging across a split boundary stays associated with the originating window" do
      {state, _buffer} = start_mouse_state("hello world\nsecond line\nthird line")
      state = Movement.execute(state, :split_vertical)
      origin_id = state.workspace.windows.active
      layout = Layout.get(state)

      {other_id, _other_layout} =
        Enum.find(layout.window_layouts, fn {id, _layout} -> id != origin_id end)

      other_state =
        EditorState.update_windows(state, &Windows.set_active(&1, other_id))

      {origin_press_row, origin_press_col} = buffer_screen_pos(state, 0, 0)
      {other_drag_row, other_drag_col} = buffer_screen_pos(other_state, 0, 0)

      state = mouse(state, origin_press_row, origin_press_col, :left, :press)
      state = mouse(state, other_drag_row, other_drag_col, :left, :drag)

      assert state.workspace.windows.active == origin_id
      assert state.workspace.mouse.drag_origin_window == origin_id
      assert state.workspace.editing.mode == :visual
    end

    test "drag events without an active drag are ignored" do
      {state, buffer} = start_mouse_state("hello world")
      {row, col} = buffer_screen_pos(state, 0, 5)
      original_cursor = BufferProcess.cursor(buffer)

      mouse(state, row, col, :left, :drag)

      assert BufferProcess.cursor(buffer) == original_cursor
    end
  end

  describe "block decoration clicks" do
    test "clicking a block decoration dispatches its on_click callback" do
      test_pid = self()
      {state, buffer} = start_mouse_state("agent output\nline two")

      BufferProcess.batch_decorations(buffer, fn decorations ->
        {_id, decorations} =
          Decorations.add_block_decoration(decorations, 0,
            placement: :above,
            render: fn _width -> [{"clickable", Minga.Core.Face.new()}] end,
            on_click: fn line_index, col -> send(test_pid, {:block_clicked, line_index, col}) end
          )

        decorations
      end)

      {row, col} = buffer_screen_pos(state, 0, 4)
      mouse(state, row, col, :left, :press)

      assert_receive {:block_clicked, 0, 4}
    end
  end

  describe "fold gutter clicks" do
    test "clicking a fold indicator toggles the window fold" do
      {state, _buffer} = start_mouse_state("defmodule Example do\n  def run, do: :ok\nend")
      state = set_active_fold_ranges(state, [FoldRange.new!(0, 2)])
      {row, col} = active_content_origin(state)

      state =
        mouse(state, row, col + MingaEditor.Renderer.Gutter.fold_column_offset(), :left, :press)

      assert FoldMap.fold_start?(EditorState.active_window_struct(state).fold_map, 0)

      {state, _buffer} = start_mouse_state("defmodule Example do\n  def run, do: :ok\nend")
      state = set_active_fold_ranges(state, [FoldRange.new!(0, 2)])
      state = fold_active_window_at(state, 0)
      {row, col} = active_content_origin(state)

      state =
        mouse(state, row, col + MingaEditor.Renderer.Gutter.fold_column_offset(), :left, :press)

      refute FoldMap.fold_start?(EditorState.active_window_struct(state).fold_map, 0)
    end

    test "clicking a decoration fold indicator opens the folded region" do
      {state, buffer} = start_mouse_state("agent output\nline two\nline three")

      BufferProcess.batch_decorations(buffer, fn decs ->
        {_id, decs} = Decorations.add_fold_region(decs, 0, 2, closed: true)
        decs
      end)

      {row, col} = active_content_origin(state)
      mouse(state, row, col + MingaEditor.Renderer.Gutter.fold_column_offset(), :left, :press)

      assert Decorations.closed_fold_regions(BufferProcess.decorations(buffer)) == []
    end
  end

  describe "tab bar clicks" do
    test "row 0 workspace clicks ignore row 1 tab actions" do
      {state, agent_workspace_id, agent_tab_id} = start_workspace_tab_state()
      [first_tab_id | _] = Enum.map(state.shell_state.tab_bar.tabs, & &1.id)
      close_tab_id = last_tab_id(state)

      state =
        set_tab_click_regions(state, [
          {1, 0, 4, {:tab_goto_id, first_tab_id}},
          {1, 5, 7, :"tab_close_#{close_tab_id}"},
          {0, 0, 4, {:workspace_goto, agent_workspace_id}}
        ])

      state = mouse(state, 0, 2, :left, :press)

      assert ChromeState.from_editor_state(state).active_workspace_id == agent_workspace_id
      assert state.shell_state.tab_bar.active_id == agent_tab_id
    end

    test "row 1 tab goto and close still work" do
      {state, _agent_workspace_id, _agent_tab_id} = start_workspace_tab_state()
      [first_tab_id | _] = Enum.map(state.shell_state.tab_bar.tabs, & &1.id)
      close_tab_id = last_tab_id(state)
      initial_count = length(state.shell_state.tab_bar.tabs)

      state =
        set_tab_click_regions(state, [
          {1, 0, 4, {:tab_goto_id, first_tab_id}},
          {1, 5, 7, :"tab_close_#{close_tab_id}"},
          {0, 0, 4, {:workspace_goto, 1}}
        ])

      state = mouse(state, 1, 2, :left, :press)

      assert state.shell_state.tab_bar.active_id == first_tab_id

      # The tab goto recomputes the layout, so re-inject the tab-bar rect before
      # the close click.
      state =
        set_tab_click_regions(state, [
          {1, 0, 4, {:tab_goto_id, first_tab_id}},
          {1, 5, 7, :"tab_close_#{close_tab_id}"},
          {0, 0, 4, {:workspace_goto, 1}}
        ])

      state = mouse(state, 1, 6, :left, :press)

      assert length(state.shell_state.tab_bar.tabs) == initial_count - 1
    end

    test "clicking workspace id 10 selects workspace id 10 instead of ordinal 10" do
      {state, _buffer} = start_mouse_state("manual one\nmanual two", width: 120)

      second_buffer = start_test_buffer(state, "agent tab", :workspace_tab)

      state = EditorState.add_buffer(state, second_buffer, context: :open)
      tab_bar = state.shell_state.tab_bar
      manual_workspace = hd(tab_bar.workspaces)
      workspace_10 = WorkspaceDomain.new_agent(10, "Tests", self())

      agent_tab_id = state.shell_state.tab_bar.active_id

      tab_bar =
        %{tab_bar | workspaces: [manual_workspace, workspace_10], next_workspace_id: 11}
        |> TabBar.move_tab_to_workspace(agent_tab_id, 10)

      state = EditorState.set_tab_bar(state, tab_bar)
      state = set_tab_click_regions(state, [{0, 0, 4, {:workspace_goto, 10}}])

      state = mouse(state, 0, 2, :left, :press)

      assert ChromeState.from_editor_state(state).active_workspace_id == 10
      assert state.shell_state.tab_bar.active_id == agent_tab_id
    end

    test "clicking tab close removes a non-last tab but leaves the final tab alone" do
      {state, _buf1, _buf2} = start_two_tab_state()
      initial_count = length(state.shell_state.tab_bar.tabs)
      active_id = state.shell_state.tab_bar.active_id
      state = set_tab_click_regions(state, [{0, 5, 7, :"tab_close_#{active_id}"}])

      state = mouse(state, 0, 6, :left, :press)

      assert length(state.shell_state.tab_bar.tabs) == initial_count - 1

      remaining_id = state.shell_state.tab_bar.active_id
      single_tab_bar = TabBar.keep_only(state.shell_state.tab_bar, remaining_id)
      state = EditorState.set_tab_bar(state, single_tab_bar)
      state = set_tab_click_regions(state, [{0, 5, 7, :"tab_close_#{remaining_id}"}])

      state = mouse(state, 0, 6, :left, :press)

      assert Enum.count(state.shell_state.tab_bar.tabs) == 1
    end

    test "clicking tab goto switches tabs without closing" do
      {state, _buf1, _buf2} = start_two_tab_state()
      initial_count = length(state.shell_state.tab_bar.tabs)
      active_id = state.shell_state.tab_bar.active_id
      other_id = Enum.find(state.shell_state.tab_bar.tabs, &(&1.id != active_id)).id

      state =
        set_tab_click_regions(state, [
          {0, 0, 4, {:tab_goto_id, other_id}},
          {0, 5, 7, :"tab_close_#{other_id}"}
        ])

      state = mouse(state, 0, 2, :left, :press)

      assert length(state.shell_state.tab_bar.tabs) == initial_count
      assert state.shell_state.tab_bar.active_id == other_id
    end

    test "middle-clicking a tab body closes the clicked tab" do
      {state, _buf1, _buf2} = start_two_tab_state()
      initial_count = length(state.shell_state.tab_bar.tabs)
      active_id = state.shell_state.tab_bar.active_id
      other_id = Enum.find(state.shell_state.tab_bar.tabs, &(&1.id != active_id)).id

      state =
        set_tab_click_regions(state, [
          {0, 0, 4, {:tab_goto_id, other_id}},
          {0, 5, 7, :"tab_close_#{other_id}"}
        ])

      state = mouse(state, 0, 2, :middle, :press)

      assert length(state.shell_state.tab_bar.tabs) == initial_count - 1
      refute Enum.any?(state.shell_state.tab_bar.tabs, &(&1.id == other_id))
      assert state.shell_state.tab_bar.active_id == active_id
    end
  end

  describe "invalid coordinates" do
    test "negative coordinates are ignored" do
      {state, buffer} = start_mouse_state("hello")
      original_cursor = BufferProcess.cursor(buffer)

      state = mouse(state, -1, 5, :left, :press)
      mouse(state, @content_row, -3, :left, :press)

      assert BufferProcess.cursor(buffer) == original_cursor
    end
  end

  describe "sticky hover popup motion (#2629)" do
    test "motion inside the popup rect keeps the popup open" do
      {state, rect} = state_with_hover_popup()
      {row, col, _w, _h} = rect

      # A free-motion event landing inside the popup's rect must not dismiss it.
      state = Mouse.handle(state, row, col, :none, 0, :motion, 1)

      assert state.shell_state.hover_popup != nil
    end

    test "motion outside the popup rect dismisses and restarts the hover debounce" do
      {state, rect} = state_with_hover_popup()
      {row, col, _w, height} = rect

      # The row directly below the popup's bottom edge is outside it (and below
      # the popup, which is anchored above the symbol), so motion there dismisses.
      out_row = row + height
      state = Mouse.handle(state, out_row, col, :none, 0, :motion, 1)

      assert state.shell_state.hover_popup == nil

      # Dismissing must also restart hover tracking at the new position, otherwise
      # hovering a symbol after closing a popup would never re-open one. Guards
      # against simplifying the dismiss branch down to just dismiss_hover_popup/1.
      assert state.workspace.mouse.hover_pos == {out_row, col}
    end
  end

  describe "Cmd/Ctrl+hover link preview (#2630)" do
    test "Cmd+motion over a symbol sets the link decoration on the full word range" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @super)

      # "world" spans bytes 6..10 inclusive; the decoration range is end-exclusive.
      assert state.workspace.cmd_hover_link == {{0, 6}, {0, 11}}
    end

    test "releasing the modifier clears the link decoration" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link != nil

      # Same position, modifier released: the preview clears immediately.
      state = mouse(state, row, col, :none, :motion, 0)
      assert state.workspace.cmd_hover_link == nil
    end

    test "moving onto whitespace while Cmd is held clears the link decoration" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {word_row, word_col} = buffer_screen_pos(state, 0, 8)
      {space_row, space_col} = buffer_screen_pos(state, 0, 5)

      state = mouse(state, word_row, word_col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link != nil

      state = mouse(state, space_row, space_col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link == nil
    end

    test "Cmd+motion over whitespace sets no link decoration" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {row, col} = buffer_screen_pos(state, 0, 5)

      state = mouse(state, row, col, :none, :motion, @super)

      assert state.workspace.cmd_hover_link == nil
    end

    test "Ctrl+motion previews the link on the TUI" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      state = set_capabilities(state, :tui)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @ctrl)

      assert state.workspace.cmd_hover_link == {{0, 6}, {0, 11}}
    end

    test "Ctrl+motion does not preview on native GUI (context-menu modifier)" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      state = set_capabilities(state, :native_gui)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @ctrl)

      assert state.workspace.cmd_hover_link == nil
    end

    test "Cmd+click go-to-definition clears the link preview before navigating" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link != nil

      # Cmd+click navigates (possibly to another buffer); the stale underline and
      # GUI hand cursor (derived from cmd_hover_link != nil) must clear.
      state = mouse(state, row, col, :left, :press, @super)
      assert state.workspace.cmd_hover_link == nil
      assert state.workspace.cmd_hover_cell == nil
    end

    test "switching tabs clears a standing link preview" do
      {state, _buf1, _buf2} = start_two_tab_state()
      [first_tab_id | _] = Enum.map(state.shell_state.tab_bar.tabs, & &1.id)
      {row, col} = buffer_screen_pos(state, 0, 2)

      state = mouse(state, row, col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link != nil

      # A keyboard tab switch swaps the active buffer with no intervening motion;
      # the link preview must not carry over to the new buffer's coordinates.
      state = EditorState.switch_tab(state, first_tab_id)
      assert state.workspace.cmd_hover_link == nil
      assert state.workspace.cmd_hover_cell == nil
    end

    test "focusing another window clears a standing link preview" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      state = Movement.execute(state, :split_vertical)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link != nil

      other_id =
        Enum.find(Map.keys(state.workspace.windows.map), &(&1 != state.workspace.windows.active))

      state = EditorState.focus_window(state, other_id)
      assert state.workspace.cmd_hover_link == nil
      assert state.workspace.cmd_hover_cell == nil
    end

    test "a repeated motion at the same cell preserves the link without re-resolving" do
      {state, _buffer} = start_mouse_state("hello world\nfoo bar baz", width: 80)
      {row, col} = buffer_screen_pos(state, 0, 8)

      state = mouse(state, row, col, :none, :motion, @super)
      assert state.workspace.cmd_hover_link == {{0, 6}, {0, 11}}
      assert state.workspace.cmd_hover_cell == {row, col}

      # Same cell again: the dedup short-circuit returns unchanged state.
      again = mouse(state, row, col, :none, :motion, @super)
      assert again.workspace.cmd_hover_link == state.workspace.cmd_hover_link
      assert again.workspace.cmd_hover_cell == {row, col}
    end
  end

  # Builds a state with an open hover popup and returns its placed screen rect.
  defp state_with_hover_popup do
    {state, _buffer} = start_mouse_state("hello\nworld\nfoo bar", width: 80, height: 24)
    # Headless backend so set_hover does not start a real debounce timer.
    state = %{state | backend: :headless}

    popup = MingaEditor.HoverPopup.new("Documentation for symbol", 12, 10)
    state = EditorState.set_hover_popup(state, popup)

    rect = MingaEditor.Layout.SurfaceRegistry.rect_for(state, :hover_popup)
    assert rect != nil, "expected the hover popup to be placed in the focus tree"

    {state, rect}
  end

  defp start_mouse_state(content, opts \\ []) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"#{__MODULE__}.Events.#{id}"
    project_root = Path.join(System.tmp_dir!(), "minga-mouse-#{id}")
    File.rm_rf!(project_root)
    File.mkdir_p!(project_root)
    start_supervised!({Minga.Events, name: events_registry}, id: {:events, id})
    sidebar_registry = start_sidebar_registry(id)

    options_server =
      start_supervised!({Minga.Config.Options, name: nil, events_registry: events_registry},
        id: {:options, id}
      )

    buffer =
      start_supervised!(
        {BufferProcess,
         content: content, events_registry: events_registry, options_server: options_server},
        id: {:buffer, id}
      )

    BufferProcess.set_option(buffer, :clipboard, :none)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        buffer: buffer,
        width: Keyword.get(opts, :width, 40),
        height: Keyword.get(opts, :height, 10),
        editing_model: :vim,
        options_server: options_server,
        events_registry: events_registry,
        sidebar_registry: sidebar_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {state, buffer}
  end

  defp start_sidebar_registry(id) do
    name = Module.concat(__MODULE__, "Sidebar#{id}")
    start_supervised!({Sidebar, name: name, notify: false}, id: {:sidebars, id})
    name
  end

  defp start_two_tab_state do
    {state, buf1} = start_mouse_state("hello", width: 80)
    buf2 = start_test_buffer(state, "world", :two_tab)
    state = EditorState.add_buffer(state, buf2, context: :open)
    {state, buf1, buf2}
  end

  defp mouse(state, row, col, button, event_type, mods \\ 0, click_count \\ 1) do
    Mouse.handle(state, row, col, button, mods, event_type, click_count)
  end

  defp start_test_buffer(state, content, id_prefix) do
    start_supervised!(
      {BufferProcess,
       [
         content: content,
         events_registry: state.events_registry,
         options_server: state.options_server
       ]},
      id: {id_prefix, System.unique_integer([:positive])}
    )
  end

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")

  defp rightmost_window_layout(layout) do
    Enum.max_by(layout.window_layouts, fn {_id, %{content: {_row, content_col, _w, _h}}} ->
      content_col
    end)
  end

  defp window_viewport(state, window_id),
    do: Map.fetch!(state.workspace.windows.map, window_id).viewport

  defp native_gui_state(state),
    do: %{state | capabilities: %Capabilities{frontend_type: :native_gui}}

  defp mark_resident(state, window_id),
    do: EditorState.update_window(state, window_id, &Window.set_resident(&1, true))

  defp set_window_top(state, window_id, top) do
    EditorState.update_window(state, window_id, fn window ->
      %{window | viewport: %{window.viewport | top: top}}
    end)
  end

  defp active_viewport(state), do: EditorState.active_window_struct(state).viewport

  defp active_window_layout(state), do: Layout.active_window_layout(Layout.get(state), state)

  defp active_content_origin(state) do
    %{content: {row, col, _width, _height}} = active_window_layout(state)
    {row, col}
  end

  defp buffer_screen_pos(state, buffer_line, buffer_col) do
    {content_row, content_col} = active_content_origin(state)
    buffer = state.workspace.buffers.active
    total_lines = BufferProcess.line_count(buffer)
    gutter_width = MingaEditor.Mouse.HitTest.buffer_gutter_width(buffer, total_lines)

    {content_row + buffer_line, content_col + gutter_width + buffer_col}
  end

  defp last_tab_id(state), do: Enum.at(state.shell_state.tab_bar.tabs, -1).id

  defp set_visual_selection(state, buffer, anchor, cursor, visual_type) do
    BufferProcess.move_to(buffer, cursor)

    EditorState.transition_mode(state, :visual, %VisualState{
      visual_anchor: anchor,
      visual_type: visual_type
    })
  end

  defp set_capabilities(state, frontend_type) do
    %{state | capabilities: %Capabilities{frontend_type: frontend_type}}
  end

  defp set_window_tree(state, tree) do
    windows = Windows.set_tree(state.workspace.windows, tree)
    EditorState.set_windows(state, windows)
  end

  defp set_active_fold_ranges(state, ranges) do
    EditorState.update_window(
      state,
      state.workspace.windows.active,
      &Window.set_fold_ranges(&1, ranges)
    )
  end

  defp fold_active_window_at(state, line) do
    EditorState.update_window(state, state.workspace.windows.active, &Window.fold_at(&1, line))
  end

  defp set_tab_click_regions(state, regions) do
    # The semantic GUI layout reserves no BEAM row for the tab bar; the frontend
    # renders it natively and sends `select_tab`/`close_tab` gui_actions. The
    # legacy cell-coordinate hit-test (`Mouse.tab_bar_click`) still exists and
    # is what these tests exercise, so inject an explicit tab-bar rect (rows 0-1,
    # covering the workspace and tab rows) onto the cached layout.
    state
    |> EditorState.update_shell_state(&%{&1 | tab_bar_click_regions: regions})
    |> with_tab_bar_rect()
  end

  defp with_tab_bar_rect(state) do
    %Layout{} = base_layout = Layout.get(state)
    {_, _, width, _} = base_layout.terminal
    %{state | layout: %Layout{base_layout | tab_bar: {0, 0, width, 2}}}
  end

  defp start_workspace_tab_state do
    {state, _buf1} = start_mouse_state("manual one\nmanual two", width: 120)

    buf2 = start_test_buffer(state, "agent tab", :workspace_tab)
    buf3 = start_test_buffer(state, "manual three", :workspace_tab)

    state = EditorState.add_buffer(state, buf2, context: :open)
    state = EditorState.add_buffer(state, buf3, context: :open)

    agent_tab_id = state.shell_state.tab_bar.active_id
    {tab_bar, agent_workspace} = TabBar.add_workspace(state.shell_state.tab_bar, "Tests", self())
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, agent_tab_id, agent_workspace.id)

    state = EditorState.set_tab_bar(state, tab_bar)
    {state, agent_workspace.id, agent_tab_id}
  end
end
