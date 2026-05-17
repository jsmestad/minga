defmodule MingaEditor.MouseTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias MingaEditor
  alias MingaEditor.Commands.Movement
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias Minga.Mode.VisualState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Workspace.State, as: WorkspaceState

  # Content starts at row 1 because the tab bar occupies row 0.
  @content_row 1
  @sync_timeout 15_000

  defp start_editor(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"mouse_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {editor, buffer}
  end

  defp start_editor_no_buffer do
    id = :erlang.unique_integer([:positive])
    events_registry = :"mouse_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: nil,
        width: 40,
        height: 10,
        editing_model: :vim,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    editor
  end

  defp isolated_project_root(id) do
    root = Path.join(System.tmp_dir!(), "minga-mouse-#{id}")
    File.mkdir_p!(root)
    root
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor, @sync_timeout)
  end

  defp send_mouse(editor, row, col, button, event_type, mods \\ 0, click_count \\ 1) do
    send(editor, {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}})
    _ = :sys.get_state(editor, @sync_timeout)
  end

  defp state(editor), do: :sys.get_state(editor, @sync_timeout)

  defp rightmost_window_layout(layout) do
    Enum.max_by(layout.window_layouts, fn {_id, %{content: {_row, content_col, _w, _h}}} ->
      content_col
    end)
  end

  defp set_gui_capabilities(editor) do
    send(
      editor,
      {:minga_input, {:capabilities_updated, %Capabilities{frontend_type: :native_gui}}}
    )

    _ = :sys.get_state(editor, @sync_timeout)
  end

  defp set_visual_selection(editor, buffer, anchor, cursor, visual_type) do
    BufferProcess.move_to(buffer, cursor)

    :sys.replace_state(editor, fn state ->
      EditorState.transition_mode(state, :visual, %VisualState{
        visual_anchor: anchor,
        visual_type: visual_type
      })
    end)

    _ = :sys.get_state(editor, @sync_timeout)
  end

  describe "mouse scroll" do
    defp start_mouse_editor do
      start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))
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
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 4
    end

    test "scroll down keeps cursor in place when it remains visible" do
      {editor, buffer} = start_mouse_editor()
      BufferProcess.move_to(buffer, {5, 0})
      _ = :sys.get_state(editor)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 5
    end

    test "scroll up moves viewport without moving cursor when cursor stays visible" do
      {editor, buffer} = start_mouse_editor()
      # Scroll down twice (2 lines), move cursor down, then scroll up
      send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      BufferProcess.move_to(buffer, {5, 0})
      _ = :sys.get_state(editor)
      send_mouse(editor, 0, 0, :wheel_up, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 5
    end

    test "scroll clamps cursor when it falls outside viewport" do
      {editor, buffer} = start_mouse_editor()
      # Scroll down enough that cursor at line 0 is off-screen
      for _i <- 1..3, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line >= 1
    end

    test "scroll at top of file doesn't go negative" do
      {editor, buffer} = start_mouse_editor()
      send_mouse(editor, 0, 0, :wheel_up, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 0
    end

    test "scroll at bottom of file clamps viewport" do
      {editor, buffer} = start_mouse_editor()
      for _i <- 1..10, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      {line, _col} = BufferProcess.cursor(buffer)
      assert line >= 0
      assert line <= 29
    end

    test "scroll over an inactive split window scrolls that window without moving focus" do
      {editor, _buffer} = start_mouse_editor()

      :sys.replace_state(editor, fn state -> Movement.execute(state, :split_vertical) end)
      state = state(editor)
      active_id = state.workspace.windows.active
      layout = Layout.get(state)

      {target_id, %{content: {row, col, _width, _height}}} =
        rightmost_window_layout(layout)

      assert target_id != active_id
      target_before = Map.fetch!(state.workspace.windows.map, target_id).viewport.top
      active_before = Map.fetch!(state.workspace.windows.map, active_id).viewport.top

      send_mouse(editor, row + 1, col + 1, :wheel_down, :press)
      state = state(editor)

      assert state.workspace.windows.active == active_id
      assert Map.fetch!(state.workspace.windows.map, active_id).viewport.top == active_before
      assert Map.fetch!(state.workspace.windows.map, target_id).viewport.top > target_before
    end

    test "scroll doesn't change mode" do
      {editor, _buffer} = start_mouse_editor()
      send_key(editor, ?i)
      send_mouse(editor, 0, 0, :wheel_down, :press)
      assert state(editor).workspace.editing.mode == :insert
    end
  end

  describe "mouse click-to-position" do
    # Gutter width for ≤99 lines = 6 (2 sign column + 1 fold column + 2 digits + 1 space).
    # Screen col = gutter_width + buffer_col.
    @gutter 6

    test "left click moves cursor to clicked position" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")
      # Row @content_row + 1 = screen row 2 = buffer line 1
      send_mouse(editor, @content_row + 1, @gutter + 3, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 3, :left, :release)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 1
      assert col == 3
    end

    test "right click positions cursor without starting selection drag" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")

      send_mouse(editor, @content_row + 1, @gutter + 3, :right, :press)

      assert BufferProcess.cursor(buffer) == {1, 3}
      assert state(editor).workspace.mouse.dragging == false
    end

    test "native GUI Ctrl-left click positions cursor without goto-definition" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")
      set_gui_capabilities(editor)

      send_mouse(editor, @content_row, @gutter + 3, :left, :press, 0x02)

      s = state(editor)
      assert BufferProcess.cursor(buffer) == {1, 3}
      assert s.workspace.mouse.dragging == false
      refute EditorState.status_msg(s) == "No language server"
    end

    test "TUI Ctrl-left click keeps goto-definition behavior" do
      {editor, buffer} = start_editor("hello\nworld\nfoo bar baz")

      send_mouse(editor, @content_row + 1, @gutter + 3, :left, :press, 0x02)

      assert BufferProcess.cursor(buffer) == {1, 3}
      assert EditorState.status_msg(state(editor)) == "No language server"
    end

    test "left click accounts for viewport scroll offset" do
      {editor, buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))

      # Scroll down then click. Default scroll_lines=1, so 4 scrolls = viewport top at 4.
      for _i <- 1..4, do: send_mouse(editor, 0, 0, :wheel_down, :press)
      send_mouse(editor, @content_row + 2, 0, :left, :press)
      send_mouse(editor, @content_row + 2, 0, :left, :release)
      {line, _col} = BufferProcess.cursor(buffer)
      # Verify cursor moved past the initial view (scrolled at least 4 lines).
      assert line >= 4
    end

    test "left click in an inactive split window focuses that window" do
      {editor, _buffer} = start_mouse_editor()

      :sys.replace_state(editor, fn state -> Movement.execute(state, :split_vertical) end)
      state = state(editor)
      active_id = state.workspace.windows.active
      layout = Layout.get(state)

      {target_id, %{content: {row, col, _width, _height}}} =
        rightmost_window_layout(layout)

      assert target_id != active_id

      send_mouse(editor, row + 1, col + 1, :left, :press)
      send_mouse(editor, row + 1, col + 1, :left, :release)

      assert state(editor).workspace.windows.active == target_id
    end

    test "left click in a horizontally scrolled inactive split uses that window's scroll" do
      {editor, buffer} = start_editor(String.duplicate("abcdefghijklmnopqrstuvwxyz", 2))

      :sys.replace_state(editor, fn state -> Movement.execute(state, :split_vertical) end)
      state = state(editor)
      active_id = state.workspace.windows.active
      layout = Layout.get(state)

      {target_id, %{content: {row, col, _width, _height}}} =
        rightmost_window_layout(layout)

      assert target_id != active_id

      send_mouse(editor, row, col + @gutter, :wheel_right, :press)
      state = state(editor)
      scrolled_left = Map.fetch!(state.workspace.windows.map, target_id).viewport.left
      assert scrolled_left > 0
      assert state.workspace.windows.active == active_id

      send_mouse(editor, row, col + @gutter, :left, :press)

      {_line, cursor_col} = BufferProcess.cursor(buffer)
      assert state(editor).workspace.windows.active == target_id
      assert cursor_col == scrolled_left
    end

    test "left click on modeline row is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferProcess.cursor(buffer)
      send_mouse(editor, 8, 5, :left, :press)
      send_mouse(editor, 8, 5, :left, :release)
      assert BufferProcess.cursor(buffer) == original_cursor
    end

    test "left click on minibuffer row is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferProcess.cursor(buffer)
      send_mouse(editor, 9, 5, :left, :press)
      send_mouse(editor, 9, 5, :left, :release)
      assert BufferProcess.cursor(buffer) == original_cursor
    end

    test "left click on tilde row (beyond buffer end) is ignored" do
      {editor, buffer} = start_editor("hello\nworld")
      original_cursor = BufferProcess.cursor(buffer)
      send_mouse(editor, 5, 0, :left, :press)
      send_mouse(editor, 5, 0, :left, :release)
      assert BufferProcess.cursor(buffer) == original_cursor
    end

    test "left click clamps column to line length" do
      {editor, buffer} = start_editor("hi\nworld")
      send_mouse(editor, @content_row, 10, :left, :press)
      send_mouse(editor, @content_row, 10, :left, :release)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "left click in visual mode cancels selection, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 1
      assert col == 2
      assert state(editor).workspace.editing.mode == :normal
    end

    test "right click inside visual char selection preserves selection" do
      {editor, buffer} = start_editor("hello world\nsecond line")
      set_visual_selection(editor, buffer, {0, 0}, {0, 4}, :char)

      send_mouse(editor, @content_row, @gutter + 2, :right, :press)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert s.workspace.editing.mode_state.visual_type == :char
      assert BufferProcess.cursor(buffer) == {0, 4}
    end

    test "right click inside visual line selection preserves selection" do
      {editor, buffer} = start_editor("one\ntwo\nthree\nfour")
      set_visual_selection(editor, buffer, {0, 0}, {2, 0}, :line)

      send_mouse(editor, @content_row + 1, @gutter + 2, :right, :press)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert s.workspace.editing.mode_state.visual_type == :line
      assert BufferProcess.cursor(buffer) == {2, 0}
    end

    test "right click outside visual char selection clears selection" do
      {editor, buffer} = start_editor("hello world\nsecond line")
      set_visual_selection(editor, buffer, {0, 0}, {0, 4}, :char)

      send_mouse(editor, @content_row + 1, @gutter + 2, :right, :press)

      assert state(editor).workspace.editing.mode == :normal
      assert BufferProcess.cursor(buffer) == {1, 2}
    end

    test "native GUI Ctrl-left click inside selection preserves it" do
      {editor, buffer} = start_editor("hello world\nsecond line")
      set_gui_capabilities(editor)
      set_visual_selection(editor, buffer, {0, 0}, {0, 4}, :char)

      send_mouse(editor, 0, @gutter + 2, :left, :press, 0x02)

      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert s.workspace.editing.mode_state.visual_type == :char
      assert BufferProcess.cursor(buffer) == {0, 4}
    end

    test "native GUI Ctrl-left click outside selection clears it" do
      {editor, buffer} = start_editor("hello world\nsecond line")
      set_gui_capabilities(editor)
      set_visual_selection(editor, buffer, {0, 0}, {0, 4}, :char)

      send_mouse(editor, 1, @gutter + 2, :left, :press, 0x02)

      assert state(editor).workspace.editing.mode == :normal
      assert BufferProcess.cursor(buffer) == {1, 2}
    end

    test "left click in command mode cancels command, returns to normal" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?:)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 1
      assert col == 2
      assert state(editor).workspace.editing.mode == :normal
    end

    test "left click in insert mode moves cursor, stays functional" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?i)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row + 1, @gutter + 2, :left, :release)

      {line, col} = BufferProcess.cursor(buffer)
      assert line == 1
      assert col == 2
    end
  end

  describe "mouse multi-click selection" do
    @gutter 6

    test "double-click selects full Unicode word using byte offsets" do
      {editor, buffer} = start_editor("éclair test")

      send_mouse(editor, @content_row, @gutter + 1, :left, :press, 0, 2)

      assert BufferProcess.cursor(buffer) == {0, 6}
      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_anchor == {0, 0}
    end
  end

  describe "split separator double-click" do
    test "double-clicking a separator resets split size without entering visual mode" do
      {editor, _buffer} = start_editor("hello world")

      :sys.replace_state(editor, fn state -> Movement.execute(state, :split_vertical) end)
      state = state(editor)
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

      :sys.replace_state(editor, fn state ->
        windows = Windows.set_tree(state.workspace.windows, resized_tree)

        MingaEditor.State.update_workspace(state, fn workspace ->
          WorkspaceState.set_windows(workspace, windows)
        end)
      end)

      state = state(editor)
      screen = Layout.get(state).editor_area

      {:ok, {:vertical, resized_sep_pos}} =
        WindowTree.separator_at(state.workspace.windows.tree, screen, row, sep_pos - 5)

      send_mouse(editor, row, resized_sep_pos, :left, :press, 0, 2)

      assert {:split, :vertical, _left, _right, 0} = state(editor).workspace.windows.tree
      assert state(editor).workspace.editing.mode == :normal
    end
  end

  describe "mouse drag selection" do
    @gutter 6

    test "left press + drag creates visual selection" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, @content_row, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row, @gutter + 8, :left, :drag)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 0
      assert col == 8
    end

    test "release after drag keeps visual selection active" do
      {editor, buffer} = start_editor("hello world foo")
      send_mouse(editor, @content_row, @gutter + 2, :left, :press)
      send_mouse(editor, @content_row, @gutter + 8, :left, :drag)
      send_mouse(editor, @content_row, @gutter + 8, :left, :release)
      {_line, col} = BufferProcess.cursor(buffer)
      assert col == 8
      s = state(editor)
      assert s.workspace.editing.mode == :visual
      assert s.workspace.mouse.dragging == false
      send_key(editor, ?y)
      assert Process.alive?(editor)
    end

    test "rapid repeated presses still drive double-click drag semantics" do
      {editor, buffer} = start_editor(Enum.map_join(0..29, "\n", fn _ -> "alpha beta gamma" end))
      s = state(editor)
      %{content: {row, col, _width, height}} = Layout.active_window_layout(Layout.get(s), s)

      start_col = col + @gutter + 3
      drag_col = col + @gutter + 8

      send_mouse(editor, row, start_col, :left, :press)
      send_mouse(editor, row, start_col, :left, :press)
      send_mouse(editor, row + height, drag_col, :left, :drag)

      s = state(editor)
      {line, cursor_col} = BufferProcess.cursor(buffer)

      assert s.workspace.mouse.drag_click_count == 2
      assert s.workspace.editing.mode == :visual
      assert s.workspace.editing.mode_state.visual_type == :char
      assert s.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert line > 0
      assert cursor_col == 9
      assert EditorState.active_window_struct(s).viewport.top > 0
    end

    test "release outside buffer content after drag clears drag state" do
      {editor, _buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))
      s = state(editor)
      %{content: {row, col, width, height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row, col + @gutter, :left, :press)
      send_mouse(editor, row + height, col + width, :left, :drag)
      send_mouse(editor, row + height, col + width, :left, :release)

      assert state(editor).workspace.mouse.dragging == false
    end

    test "release without movement (click) returns to normal mode" do
      {editor, _buffer} = start_editor("hello world")
      send_mouse(editor, @content_row, 3, :left, :press)
      send_mouse(editor, @content_row, 3, :left, :release)
      s = state(editor)
      assert s.workspace.editing.mode == :normal
      assert s.workspace.mouse.dragging == false
    end

    test "drag event at the original buffer position does not enter visual mode" do
      {editor, _buffer} = start_editor("hello world")

      send_mouse(editor, @content_row, @gutter + 3, :left, :press)
      send_mouse(editor, @content_row, @gutter + 3, :left, :drag)

      assert state(editor).workspace.editing.mode == :normal

      send_mouse(editor, @content_row, @gutter + 3, :left, :release)
      assert state(editor).workspace.mouse.dragging == false
    end

    test "scroll after click jitter stays in normal mode" do
      {editor, _buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))

      send_mouse(editor, @content_row, @gutter + 3, :left, :press)
      send_mouse(editor, @content_row, @gutter + 3, :left, :drag)
      send_mouse(editor, @content_row, @gutter + 3, :left, :release)
      send_mouse(editor, @content_row, @gutter + 3, :wheel_down, :press)

      assert state(editor).workspace.editing.mode == :normal
    end

    test "drag clamps to buffer bounds" do
      {editor, buffer} = start_editor("hi\nworld")
      send_mouse(editor, @content_row, 0, :left, :press)
      send_mouse(editor, @content_row, 50, :left, :drag)
      {line, col} = BufferProcess.cursor(buffer)
      assert line == 0
      assert col <= 1
    end

    test "drag below viewport scrolls down and extends selection" do
      {editor, buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))
      s = state(editor)
      %{content: {row, col, width, height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row, col + @gutter, :left, :press)
      send_mouse(editor, row + height, col + width, :left, :drag)

      s = state(editor)
      window = EditorState.active_window_struct(s)
      {line, _col} = BufferProcess.cursor(buffer)

      assert window.viewport.top > 0
      assert line >= height
      assert s.workspace.editing.mode == :visual
    end

    test "drag below from bottom visible line still autoscrolls" do
      {editor, _buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))
      s = state(editor)
      %{content: {row, col, _width, height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row + height - 1, col + @gutter, :left, :press)
      send_mouse(editor, row + height, col + @gutter, :left, :drag)

      s = state(editor)

      assert EditorState.active_window_struct(s).viewport.top > 0
      assert s.workspace.editing.mode == :visual
    end

    test "drag above viewport scrolls up and extends selection" do
      {editor, buffer} = start_editor(Enum.map_join(0..29, "\n", &"line #{&1}"))

      :sys.replace_state(editor, fn state ->
        EditorState.update_window(
          state,
          state.workspace.windows.active,
          &Window.scroll_viewport(&1, 5, 30)
        )
      end)

      s = state(editor)
      %{content: {row, col, _width, _height}} = Layout.active_window_layout(Layout.get(s), s)
      before_top = EditorState.active_window_struct(s).viewport.top

      send_mouse(editor, row + 2, col + @gutter, :left, :press)
      send_mouse(editor, row - 1, col + @gutter, :left, :drag)

      s = state(editor)
      window = EditorState.active_window_struct(s)
      {line, _col} = BufferProcess.cursor(buffer)

      assert before_top > 0
      assert window.viewport.top < before_top
      assert line <= before_top
      assert s.workspace.editing.mode == :visual
    end

    test "drag past right edge scrolls horizontally and extends selection" do
      {editor, buffer} = start_editor(String.duplicate("abcdefghijklmnopqrstuvwxyz", 4))
      s = state(editor)
      %{content: {row, col, width, _height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row, col + @gutter, :left, :press)
      send_mouse(editor, row, col + width, :left, :drag)

      s = state(editor)
      window = EditorState.active_window_struct(s)
      {_line, cursor_col} = BufferProcess.cursor(buffer)

      assert window.viewport.left > 0
      assert cursor_col > 0
      assert s.workspace.editing.mode == :visual
    end

    test "drag right from right visible column still autoscrolls" do
      {editor, _buffer} = start_editor(String.duplicate("abcdefghijklmnopqrstuvwxyz", 4))
      s = state(editor)
      %{content: {row, col, width, _height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row, col + width - 1, :left, :press)
      send_mouse(editor, row, col + width, :left, :drag)

      s = state(editor)

      assert EditorState.active_window_struct(s).viewport.left > 0
      assert s.workspace.editing.mode == :visual
    end

    test "drag back left reverses horizontal scroll without losing anchor" do
      {editor, _buffer} = start_editor(String.duplicate("abcdefghijklmnopqrstuvwxyz", 4))
      s = state(editor)
      %{content: {row, col, width, _height}} = Layout.active_window_layout(Layout.get(s), s)

      send_mouse(editor, row, col + @gutter + 10, :left, :press)
      send_mouse(editor, row, col + width, :left, :drag)
      right_scrolled_left = EditorState.active_window_struct(state(editor)).viewport.left

      send_mouse(editor, row, col - 1, :left, :drag)

      s = state(editor)
      window = EditorState.active_window_struct(s)

      assert right_scrolled_left > 0
      assert window.viewport.left < right_scrolled_left
      assert s.workspace.editing.mode_state.visual_anchor == {0, 10}
    end

    test "drag crossing split boundary stays associated with originating window" do
      {editor, _buffer} = start_editor("hello world\nsecond line\nthird line")

      :sys.replace_state(editor, fn state -> Movement.execute(state, :split_vertical) end)
      s = state(editor)
      origin_id = s.workspace.windows.active
      layout = Layout.get(s)
      origin_layout = Map.fetch!(layout.window_layouts, origin_id)

      {_other_id, %{content: {other_row, other_col, _other_width, _other_height}}} =
        Enum.find(layout.window_layouts, fn {id, _layout} -> id != origin_id end)

      %{content: {origin_row, origin_col, _origin_width, _origin_height}} = origin_layout

      send_mouse(editor, origin_row, origin_col + @gutter, :left, :press)
      send_mouse(editor, other_row, other_col + @gutter, :left, :drag)

      s = state(editor)

      assert s.workspace.windows.active == origin_id
      assert s.workspace.mouse.drag_origin_window == origin_id
      assert s.workspace.editing.mode == :visual
    end

    test "drag ignores events when not dragging" do
      {editor, buffer} = start_editor("hello world")
      original = BufferProcess.cursor(buffer)
      send_mouse(editor, @content_row, 5, :left, :drag)
      assert BufferProcess.cursor(buffer) == original
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

  describe "fold gutter clicks" do
    defp set_active_fold_ranges(editor, ranges) do
      :sys.replace_state(editor, fn state ->
        EditorState.update_window(
          state,
          state.workspace.windows.active,
          &Window.set_fold_ranges(&1, ranges)
        )
      end)
    end

    defp active_content_origin(editor) do
      s = state(editor)
      %{content: {row, col, _width, _height}} = Layout.active_window_layout(Layout.get(s), s)
      {row, col}
    end

    test "clicking an expanded fold indicator folds that range" do
      {editor, _buffer} = start_editor("defmodule Example do\n  def run, do: :ok\nend")
      set_active_fold_ranges(editor, [FoldRange.new!(0, 2)])
      {row, col} = active_content_origin(editor)

      send_mouse(
        editor,
        row,
        col + MingaEditor.Renderer.Gutter.fold_column_offset(),
        :left,
        :press
      )

      window = EditorState.active_window_struct(state(editor))
      assert FoldMap.fold_start?(window.fold_map, 0)
    end

    test "clicking a folded indicator unfolds that range" do
      {editor, _buffer} = start_editor("defmodule Example do\n  def run, do: :ok\nend")
      range = FoldRange.new!(0, 2)
      set_active_fold_ranges(editor, [range])

      :sys.replace_state(editor, fn state ->
        EditorState.update_window(state, state.workspace.windows.active, &Window.fold_at(&1, 0))
      end)

      {row, col} = active_content_origin(editor)

      send_mouse(
        editor,
        row,
        col + MingaEditor.Renderer.Gutter.fold_column_offset(),
        :left,
        :press
      )

      window = EditorState.active_window_struct(state(editor))
      refute FoldMap.fold_start?(window.fold_map, 0)
    end

    test "clicking a decoration fold indicator opens that fold region" do
      {editor, buffer} = start_editor("agent output\nline two\nline three")

      BufferProcess.batch_decorations(buffer, fn decs ->
        {_id, decs} = Decorations.add_fold_region(decs, 0, 2, closed: true)
        decs
      end)

      {row, col} = active_content_origin(editor)

      send_mouse(
        editor,
        row,
        col + MingaEditor.Renderer.Gutter.fold_column_offset(),
        :left,
        :press
      )

      assert Decorations.closed_fold_regions(BufferProcess.decorations(buffer)) == []
    end

    test "clicking outside the fold indicator column does not toggle" do
      {editor, _buffer} = start_editor("defmodule Example do\n  def run, do: :ok\nend")
      set_active_fold_ranges(editor, [FoldRange.new!(0, 2)])
      {row, col} = active_content_origin(editor)

      send_mouse(editor, row, col + 1, :left, :press)

      window = EditorState.active_window_struct(state(editor))
      refute FoldMap.fold_start?(window.fold_map, 0)
    end

    test "clicking the fold indicator column on a non-fold-start line does not toggle" do
      {editor, _buffer} = start_editor("defmodule Example do\n  def run, do: :ok\nend")
      set_active_fold_ranges(editor, [FoldRange.new!(0, 2)])
      {row, col} = active_content_origin(editor)

      send_mouse(
        editor,
        row + 1,
        col + MingaEditor.Renderer.Gutter.fold_column_offset(),
        :left,
        :press
      )

      window = EditorState.active_window_struct(state(editor))
      refute FoldMap.fold_start?(window.fold_map, 0)
    end
  end

  describe "mouse with negative coordinates" do
    test "negative row is ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferProcess.cursor(buffer)
      send_mouse(editor, -1, 5, :left, :press)
      assert BufferProcess.cursor(buffer) == original
    end

    test "negative col is ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferProcess.cursor(buffer)
      send_mouse(editor, @content_row, -3, :left, :press)
      assert BufferProcess.cursor(buffer) == original
    end
  end

  describe "tab close button click" do
    alias MingaEditor.State.TabBar

    defp start_two_tab_editor do
      id = :erlang.unique_integer([:positive])
      events_registry = :"mouse_tab_events_#{id}"
      project_root = isolated_project_root(id)
      start_supervised!({Minga.Events, name: events_registry})

      {:ok, buf1} = BufferProcess.start_link(content: "hello", events_registry: events_registry)
      {:ok, buf2} = BufferProcess.start_link(content: "world", events_registry: events_registry)

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_#{id}",
          port_manager: nil,
          buffer: buf1,
          width: 80,
          height: 10,
          editing_model: :vim,
          events_registry: events_registry,
          project_root: project_root,
          suppress_tool_prompts: true
        )

      # Inject a second tab directly via state manipulation
      :sys.replace_state(editor, fn s ->
        {tb, _tab} = TabBar.add(s.shell_state.tab_bar, :file, "world.ex")
        buffers = %{s.workspace.buffers | list: [buf1, buf2]}
        MingaEditor.State.set_tab_bar(%{s | workspace: %{s.workspace | buffers: buffers}}, tb)
      end)

      {editor, buf1, buf2}
    end

    defp inject_click_regions(editor, regions) do
      :sys.replace_state(editor, fn state ->
        MingaEditor.State.update_shell_state(state, &%{&1 | tab_bar_click_regions: regions})
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
