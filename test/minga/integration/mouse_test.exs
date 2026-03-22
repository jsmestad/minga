defmodule Minga.Integration.MouseTest do
  @moduledoc """
  Integration tests for mouse interactions: click-to-position,
  double-click word select, triple-click line select, scroll wheel,
  and region dispatch.

  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer

  # ── Test helpers ───────────────────────────────────────────────────────────

  # Sends a gui_action to the editor and waits for the frame to render.
  defp send_gui_action(%{editor: editor, port: port}, action) do
    _ = :sys.get_state(editor)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:gui_action, action}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref)
    Process.put({:last_frame_snapshot, port}, snapshot)
    :ok
  end

  # Injects a stub agent session to avoid the ~700ms provider startup.
  defp inject_fake_session(%{editor: editor} = ctx) do
    {:ok, fake} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      put_in(state.agent.session, fake)
    end)

    ctx
  end

  # Opens the agent split pane and returns the separator column.
  # Fails the test if the separator can't be found (layout didn't render).
  defp open_agent_split(ctx) do
    ctx = inject_fake_session(ctx)
    send_keys_sync(ctx, "<Space>aa")
    row1 = screen_row(ctx, 1)
    sep_col = row1 |> String.graphemes() |> Enum.find_index(&(&1 == "│"))

    assert sep_col != nil,
           "expected vertical separator after opening agent split, got row: #{inspect(row1)}"

    {ctx, sep_col}
  end

  # ── Click to position ──────────────────────────────────────────────────────

  describe "single left click" do
    test "positions cursor at clicked cell in editor area" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Click on "second" at row 2, accounting for gutter width
      # Gutter is ~3 chars ("1 "), so col 3 = start of text
      send_mouse(ctx, 2, 5, :left)

      {line, _col} = buffer_cursor(ctx)
      assert line == 1, "clicking row 2 should place cursor on buffer line 1"
      assert_screen_snapshot(ctx, "mouse_click_position")
    end

    test "click at different position moves cursor" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 1, 7, :left)
      cursor1 = buffer_cursor(ctx)

      send_mouse(ctx, 3, 5, :left)
      cursor2 = buffer_cursor(ctx)

      assert cursor1 != cursor2, "clicking different positions should move cursor"
    end
  end

  # ── Double-click word select ───────────────────────────────────────────────

  describe "double-click word select" do
    test "selects word under cursor" do
      ctx = start_editor("hello world")

      # Double-click on "hello" (row 1, within text area)
      send_mouse(ctx, 1, 5, :left, 0, :press, 2)

      assert editor_mode(ctx) == :visual
      assert_screen_snapshot(ctx, "mouse_double_click_word")
    end
  end

  # ── Triple-click line select ───────────────────────────────────────────────

  describe "triple-click line select" do
    test "selects entire line" do
      ctx = start_editor("hello world\nsecond line")

      # Triple-click on first content row
      send_mouse(ctx, 1, 5, :left, 0, :press, 3)

      mode = editor_mode(ctx)

      assert mode in [:visual, :visual_line],
             "triple-click should enter visual or visual-line mode"

      assert_screen_snapshot(ctx, "mouse_triple_click_line")
    end
  end

  # ── Scroll wheel ───────────────────────────────────────────────────────────

  describe "scroll wheel" do
    @long_content Enum.map_join(1..50, "\n", &"line #{&1}")

    test "wheel down scrolls viewport" do
      ctx = start_editor(@long_content)

      # Scroll down a few times
      send_mouse(ctx, 10, 10, :wheel_down)
      send_mouse(ctx, 10, 10, :wheel_down)
      send_mouse(ctx, 10, 10, :wheel_down)

      # Viewport should have scrolled; later lines should be visible
      assert screen_contains?(ctx, "line 4") or screen_contains?(ctx, "line 5")
      assert_screen_snapshot(ctx, "mouse_scroll_down")
    end

    test "wheel up scrolls viewport back" do
      ctx = start_editor(@long_content)

      # Scroll down then back up
      for _ <- 1..5, do: send_mouse(ctx, 10, 10, :wheel_down)
      for _ <- 1..5, do: send_mouse(ctx, 10, 10, :wheel_up)

      # Should be back near the top
      assert screen_contains?(ctx, "line 1")
    end
  end

  # ── Click in file tree ────────────────────────────────────────────────────

  describe "click in file tree region" do
    test "clicking in tree area doesn't move buffer cursor" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      cursor_before = buffer_cursor(ctx)

      # Click in the tree area (col 2, well within tree panel)
      send_mouse(ctx, 3, 2, :left)

      cursor_after = buffer_cursor(ctx)
      assert cursor_after == cursor_before, "clicking tree should not move buffer cursor"
    end
  end

  # ── Click-and-drag ──────────────────────────────────────────────────────────

  describe "click-and-drag" do
    test "drag creates visual selection" do
      ctx = start_editor("hello world foo bar")

      # Press at one position
      send_mouse(ctx, 1, 5, :left, 0, :press, 1)
      # Drag to another position
      send_mouse(ctx, 1, 15, :left, 0, :drag, 1)

      assert editor_mode(ctx) == :visual,
             "dragging should enter visual mode, got #{editor_mode(ctx)}"
    end

    test "releasing after drag keeps selection" do
      ctx = start_editor("hello world foo bar")

      send_mouse(ctx, 1, 5, :left, 0, :press, 1)
      send_mouse(ctx, 1, 15, :left, 0, :drag, 1)
      send_mouse(ctx, 1, 15, :left, 0, :release, 1)

      assert editor_mode(ctx) == :visual
    end
  end

  # ── Click in gutter ────────────────────────────────────────────────────────

  describe "click in gutter area" do
    test "clicking in the gutter does not position cursor at col 0" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Click in the gutter area (col 0 or 1, where line numbers are)
      send_mouse(ctx, 2, 0, :left)

      {_line, col} = buffer_cursor(ctx)
      # Cursor should be at col 0 of the text (start of line), not in the gutter
      assert col == 0
    end
  end

  # ── Click in agent panel ──────────────────────────────────────────────────

  describe "click in agent split pane" do
    test "clicking in agent pane does not move buffer cursor" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # Click in the agent panel area (right of separator)
      send_mouse(ctx, 5, sep_col + 5, :left)

      # Buffer cursor should not have moved to the agent panel area
      {_, buf_col} = buffer_cursor(ctx)

      assert buf_col < sep_col,
             "buffer cursor should stay in editor area after clicking agent panel"
    end

    test "clicking in agent pane switches focus to agent window" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # SPC a a opens the split but keeps editor active.
      state_before = :sys.get_state(ctx.editor)
      assert state_before.keymap_scope == :editor

      editor_active_before = state_before.windows.active

      # Click in the agent pane to focus it
      send_mouse(ctx, 5, sep_col + 5, :left)

      state_after = :sys.get_state(ctx.editor)

      refute state_after.windows.active == editor_active_before,
             "clicking in agent pane should change active window"

      assert state_after.keymap_scope == :agent,
             "clicking in agent pane should set scope to :agent, got #{state_after.keymap_scope}"
    end

    test "clicking in editor area while agent split is open returns focus to editor" do
      ctx = start_editor("hello world\nsecond line\nthird line")
      {ctx, sep_col} = open_agent_split(ctx)

      # Click agent pane first to switch focus to agent
      send_mouse(ctx, 5, sep_col + 5, :left)
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :agent

      # Click in the editor area (left side, col 5)
      send_mouse(ctx, 2, 5, :left)

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :editor,
             "clicking in editor area should switch scope to :editor, got #{state.keymap_scope}"
    end
  end

  # ── Agent chat scroll ──────────────────────────────────────────────────────

  describe "agent chat scroll" do
    test "scroll wheel over agent pane scrolls chat, not editor buffer" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      state_before = :sys.get_state(ctx.editor)
      viewport_before = state_before.viewport.top

      # Scroll down in the agent pane area. After rendering convergence,
      # chat scroll unpins the window and passes through to Editor.Mouse
      # which scrolls the window viewport directly.
      send_mouse(ctx, 5, sep_col + 5, :wheel_down)
      send_mouse(ctx, 5, sep_col + 5, :wheel_down)

      state_after = :sys.get_state(ctx.editor)

      # Editor viewport should NOT have scrolled
      assert state_after.viewport.top == viewport_before,
             "scrolling over agent pane should not scroll editor viewport"

      # Agent chat window should be unpinned (scroll handled by standard mouse)
      case EditorState.find_agent_chat_window(state_after) do
        nil ->
          :ok

        {_win_id, window} ->
          refute window.pinned, "agent chat window should be unpinned after scroll"
      end
    end

    test "scroll wheel over editor area does not scroll agent chat" do
      ctx = start_editor(Enum.map_join(1..50, "\n", &"line #{&1}"))
      {_ctx, _sep_col} = open_agent_split(ctx)

      state_before = :sys.get_state(ctx.editor)
      agent_scroll_before = state_before.agent_ui.panel.scroll.offset

      # Scroll in the editor area (col 5, left of the separator)
      send_mouse(ctx, 5, 5, :wheel_down)
      send_mouse(ctx, 5, 5, :wheel_down)

      state_after = :sys.get_state(ctx.editor)

      # Agent scroll should not have changed
      assert state_after.agent_ui.panel.scroll.offset == agent_scroll_before,
             "scrolling in editor area should not affect agent chat scroll"

      # But editor window's viewport should have scrolled
      active_win_id = state_after.windows.active
      win_after = Map.get(state_after.windows.map, active_win_id)
      win_before = Map.get(state_before.windows.map, active_win_id)

      assert win_after.viewport.top > win_before.viewport.top,
             "scrolling in editor area should scroll the active window's viewport"
    end
  end

  # ── Agent input focus via click ────────────────────────────────────────────

  describe "agent input focus via click" do
    test "clicking in agent input area focuses the input" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # The input area is at the bottom of the agent pane.
      # Click near the bottom of the agent pane (2 rows above the global
      # modeline) to target the input area.
      input_row = ctx.height - 3
      send_mouse(ctx, input_row, sep_col + 5, :left)

      state = :sys.get_state(ctx.editor)

      assert state.agent_ui.panel.input_focused,
             "clicking in the input area should focus the agent input"
    end

    test "clicking in agent chat area unfocuses the input" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # Establish precondition: focus the input by clicking in the input area
      input_row = ctx.height - 3
      send_mouse(ctx, input_row, sep_col + 5, :left)

      state = :sys.get_state(ctx.editor)

      assert state.agent_ui.panel.input_focused,
             "precondition: input should be focused after clicking input area"

      # Now click in the chat area (upper portion of agent pane) to unfocus
      send_mouse(ctx, 3, sep_col + 5, :left)

      state = :sys.get_state(ctx.editor)

      refute state.agent_ui.panel.input_focused,
             "clicking in chat area should unfocus the agent input"
    end
  end

  # ── Modeline click ─────────────────────────────────────────────────────────

  describe "modeline click" do
    test "clicking in the modeline row does not reposition the buffer cursor" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Position cursor at a known location first
      send_mouse(ctx, 1, 5, :left)
      cursor_before = buffer_cursor(ctx)

      # Click in the modeline (second to last row)
      modeline_row = ctx.height - 2
      send_mouse(ctx, modeline_row, 10, :left)

      cursor_after = buffer_cursor(ctx)

      assert cursor_after == cursor_before,
             "clicking in the modeline should not move the buffer cursor"
    end

    test "clicking in the minibuffer row does not reposition the buffer cursor" do
      ctx = start_editor("hello world")

      send_mouse(ctx, 1, 5, :left)
      cursor_before = buffer_cursor(ctx)

      # Click in the minibuffer (last row)
      minibuffer_row = ctx.height - 1
      send_mouse(ctx, minibuffer_row, 10, :left)

      cursor_after = buffer_cursor(ctx)

      assert cursor_after == cursor_before,
             "clicking in the minibuffer should not move the buffer cursor"
    end
  end

  # ── Shift-click extend selection ───────────────────────────────────────────

  describe "shift-click extend selection" do
    @shift 0x01

    test "shift-click extends selection from cursor" do
      ctx = start_editor("hello world foo bar")

      # Click to position cursor
      send_mouse(ctx, 1, 5, :left)
      # Shift-click further right to extend selection
      send_mouse(ctx, 1, 15, :left, @shift)

      assert editor_mode(ctx) == :visual
      assert_screen_snapshot(ctx, "mouse_shift_click_select")
    end
  end

  # ── Multi-region dispatch ──────────────────────────────────────────────────

  describe "multi-region dispatch" do
    test "click dispatches to correct region when file tree and agent are both open" do
      ctx = start_editor("hello world")

      # Open file tree and wait for it to render.
      # Bump polling budget for CI runners where layout settling takes longer.
      send_keys_sync(ctx, "<Space>op")

      wait_until(
        ctx,
        fn state ->
          state.file_tree != nil and
            FileTree.open?(state.file_tree)
        end,
        max_attempts: 50,
        interval_ms: 20,
        message: "file tree never opened"
      )

      # Open agent panel (inject fake session to skip ~700ms provider startup)
      inject_fake_session(ctx)
      send_keys_sync(ctx, "<Space>aa")

      # Wait for both separators to appear (file tree | editor | agent).
      # Use wait_until_screen to sync the HeadlessPort before reading the
      # grid, preventing a race where the editor has rendered but the port
      # hasn't flushed yet.
      wait_until_screen(
        ctx,
        fn ->
          row1 = screen_row(ctx, 1)
          sep_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))
          sep_count >= 2
        end,
        message: "expected at least 2 separators (tree|editor|agent)"
      )

      rows = screen_text(ctx)
      row1 = Enum.at(rows, 1)

      # Find the two separators to know the three region boundaries
      graphemes = String.graphemes(row1)

      sep_positions =
        graphemes
        |> Enum.with_index()
        |> Enum.filter(fn {ch, _i} -> ch == "│" end)
        |> Enum.map(fn {_ch, i} -> i end)

      assert length(sep_positions) >= 2,
             "expected at least 2 separators, found #{length(sep_positions)} in: #{inspect(row1)}"

      [tree_sep, agent_sep | _] = sep_positions

      # Click in the file tree (left of first separator)
      cursor_before = buffer_cursor(ctx)
      send_mouse(ctx, 3, div(tree_sep, 2), :left)
      cursor_after = buffer_cursor(ctx)

      assert cursor_after == cursor_before,
             "clicking in file tree should not move buffer cursor"

      # Click in the agent area first (right of second separator)
      # to switch to :agent scope
      agent_col = agent_sep + 5
      send_mouse(ctx, 5, agent_col, :left)
      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :agent,
             "clicking in agent area should set scope to :agent, got #{state.keymap_scope}"

      # Now click in the editor area (between separators) to switch back
      editor_col = tree_sep + div(agent_sep - tree_sep, 2)
      send_mouse(ctx, 2, editor_col, :left)
      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :editor,
             "clicking in editor area should set scope to :editor, got #{state.keymap_scope}"
    end
  end

  # ── Post-action housekeeping (shared pipeline) ────────────────────────────
  #
  # These tests verify that mouse and GUI action events run through the same
  # housekeeping pipeline as keyboard input (highlight reset, reparse,
  # selection range cleanup). Before the shared pipeline refactoring, mouse
  # events only ran inlay hints + render, and GUI actions only ran render.

  describe "post-action housekeeping via mouse" do
    test "clicking exits visual mode and clears LSP selection ranges" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Enter visual mode via keyboard
      send_keys_sync(ctx, "v")
      assert editor_mode(ctx) == :visual

      # Inject LSP selection ranges into state (normally set by an LSP response)
      :sys.replace_state(ctx.editor, fn state ->
        %{state | selection_ranges: [%{"range" => %{}}], selection_range_index: 1}
      end)

      # Verify precondition
      state = :sys.get_state(ctx.editor)
      assert state.selection_ranges != nil

      # Click to exit visual mode; post_action_housekeeping should clear ranges
      send_mouse(ctx, 2, 5, :left)

      assert editor_mode(ctx) == :normal

      state = :sys.get_state(ctx.editor)

      assert state.selection_ranges == nil,
             "mouse click exiting visual mode should clear LSP selection ranges"

      assert state.selection_range_index == 0
    end

    test "gui_action select_tab runs full housekeeping pipeline" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      state = :sys.get_state(ctx.editor)
      tab_id = state.tab_bar.active_id

      # Send a gui_action (select current tab). Before the refactoring,
      # gui_action handlers only called Renderer.render, skipping highlight
      # reset, reparse, selection cleanup, and doc highlight scheduling.
      # Now they run the full post_action_housekeeping pipeline. If any
      # step crashes (e.g., highlight reset with a nil parser), the test
      # fails.
      send_gui_action(ctx, {:select_tab, tab_id})

      # Verify the editor is still in a consistent state after the full
      # housekeeping pipeline ran.
      state = :sys.get_state(ctx.editor)
      assert state.vim.mode == :normal
      assert state.buffers.active != nil
    end

    test "mouse click after buffer switch runs shared housekeeping" do
      ctx = start_editor("first buffer content\nsecond line\nthird line")

      state = :sys.get_state(ctx.editor)
      first_buffer = state.buffers.active

      # Add a second buffer and switch to it via state injection
      {:ok, second_buffer} =
        BufferServer.start_link(content: "different content here")

      :sys.replace_state(ctx.editor, fn state ->
        EditorState.add_buffer(state, second_buffer)
      end)

      state = :sys.get_state(ctx.editor)
      assert state.buffers.active == second_buffer

      # Switch back to first buffer
      :sys.replace_state(ctx.editor, fn state ->
        %{state | buffers: %{state.buffers | active: first_buffer, active_index: 0}}
      end)

      # Mouse click triggers the shared housekeeping pipeline, which
      # includes maybe_reset_highlight. Before the refactoring, mouse
      # events skipped this step entirely. If it crashes, the test fails.
      send_mouse(ctx, 2, 5, :left)

      {line, _col} = buffer_cursor(ctx)
      assert line == 1, "cursor should have moved to clicked row"
    end
  end
end
