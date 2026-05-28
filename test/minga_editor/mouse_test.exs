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

  describe "scrolling" do
    test "vertical scroll keeps the cursor inside the visible buffer" do
      {state, buffer} = start_mouse_state(lines(0..29))

      state = mouse(state, 0, 0, :wheel_down, :press)
      assert BufferProcess.cursor(buffer) == {4, 0}
      assert active_viewport(state).top == 1

      BufferProcess.move_to(buffer, {5, 0})
      state = mouse(state, 0, 0, :wheel_up, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line in 0..29
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

      assert length(state.shell_state.tab_bar.tabs) == 1
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

  defp last_tab_id(state), do: List.last(state.shell_state.tab_bar.tabs).id

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
    EditorState.update_shell_state(state, &%{&1 | tab_bar_click_regions: regions})
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
