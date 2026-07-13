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
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @ctrl 0x02
  @super 0x08

  describe "resident window scroll intent (#2661)" do
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

    test "M and L resolve against the reported top after a scroll report (ordered channel, AC2)" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active

      state = Mouse.handle_scroll_batch(state, win_id, 10, :down)
      vp = window_viewport(state, win_id)
      visible_rows = Viewport.content_rows(vp)

      state = Movement.execute(state, {:move_to_screen, :middle})
      {middle_line, _col} = BufferProcess.cursor(buffer)
      assert middle_line == 10 + div(visible_rows, 2)

      Movement.execute(state, {:move_to_screen, :bottom})
      {bottom_line, _col} = BufferProcess.cursor(buffer)
      assert bottom_line == 10 + visible_rows - 1
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

    test "a resident GUI window never moves the cursor no matter how far the wheel scrolls (#2684)" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      state = Enum.reduce(1..20, state, fn _, acc -> mouse(acc, 0, 0, :wheel_down, :press) end)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      new_top = window.viewport.top
      # The viewport scrolled well past the cursor line, yet the cursor is unchanged
      # and every committed top stayed a free-scroll echo.
      assert new_top > 50
      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window.scroll_echo_top == new_top
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

    test "an eligible GUI window uses semantic free-scroll without renderer residence state" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = set_window_top(state, win_id, 40)
      BufferProcess.move_to(buffer, {50, 0})

      before_top = window_viewport(state, win_id).top
      state = mouse(state, 0, 0, :wheel_down, :press)

      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert window.scroll_echo_top == window.viewport.top
      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window.viewport.top > before_top
    end
  end

  describe "scrollbar thumb-drag commit (:scroll_to_line, #2665)" do
    test "echo-marks the committed top so the drag's own commit does not bump scroll_seq" do
      {state, _buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)

      state = GuiActionHandler.dispatch(state, {:scroll_to_line, 30})

      window = Map.fetch!(state.workspace.windows.map, win_id)
      # The committed top is recorded as a free-scroll echo, exactly like the wheel
      # path, so settle_scroll_seq/1 treats it as an echo and never bumps scroll_seq.
      assert window.viewport.top == 30
      assert window.scroll_echo_top == 30
    end

    test "never moves the cursor even when the target scrolls it off-screen (#2691)" do
      {state, buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      BufferProcess.move_to(buffer, {50, 0})

      state = GuiActionHandler.dispatch(state, {:scroll_to_line, 0})

      window = Map.fetch!(state.workspace.windows.map, win_id)
      # Thumb drag is VSCode-style viewport-only: the cursor stays put and
      # scroll_detach_cursor is armed so cursor-follow will not re-anchor the view.
      # Without the detach the viewport would snap back toward the cursor (line 50);
      # it must stay on the dragged top instead.
      assert window.viewport.top == 0
      assert BufferProcess.cursor(buffer) == {50, 0}
      assert window.scroll_detach_cursor == {50, 0}
      assert window.scroll_echo_top == window.viewport.top
    end

    test "commits the exact dragged top so the frontend offset reconciles to zero" do
      {state, _buffer} = start_mouse_state(lines(0..99), width: 40, height: 20)
      state = native_gui_state(state)
      win_id = state.workspace.windows.active
      state = mark_resident(state, win_id)
      state = set_window_top(state, win_id, 10)

      state = GuiActionHandler.dispatch(state, {:scroll_to_line, 72})

      window = Map.fetch!(state.workspace.windows.map, win_id)
      # The committed anchor lands exactly on the requested line so the frontend's
      # local presentation offset (target - anchorTop) drains to zero on grid.
      assert window.viewport.top == 72
      assert window.scroll_echo_top == 72
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
      [first_tab_id | _] = Enum.map(EditorState.tab_bar(state).tabs, & &1.id)
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

  defp window_viewport(state, window_id),
    do: Map.fetch!(state.workspace.windows.map, window_id).viewport

  defp native_gui_state(state),
    do: %{state | capabilities: %Capabilities{frontend_type: :native_gui}}

  defp mark_resident(state, _window_id), do: state

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
end
