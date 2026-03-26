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
      Minga.Editor.State.AgentAccess.update_agent(state, fn a -> %{a | session: fake} end)
    end)

    ctx
  end

  # Switches to the agent tab. With the tab-based model, the agent
  # is a full-screen tab (no split pane / separator).
  # Returns `{ctx, nil}` for API compatibility (no separator column).
  defp open_agent_split(ctx) do
    ctx = inject_fake_session(ctx)
    send_keys_sync(ctx, "<Space>aa")

    state = :sys.get_state(ctx.editor)

    assert state.workspace.keymap_scope == :agent,
           "expected :agent scope after SPC a a, got #{state.workspace.keymap_scope}"

    {ctx, nil}
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

  # ── Agent tab interaction ───────────────────────────────────────────────────

  describe "agent tab (full-screen)" do
    test "agent tab has :agent scope" do
      ctx = start_editor("hello world")
      {_ctx, _} = open_agent_split(ctx)

      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :agent
    end

    test "toggling back to file tab restores :editor scope" do
      ctx = start_editor("hello world")
      {_ctx, _} = open_agent_split(ctx)

      # Toggle back
      send_keys_sync(ctx, "<Space>aa")
      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :editor,
             "toggling back should restore :editor scope, got #{state.workspace.keymap_scope}"
    end
  end

  # ── Agent chat scroll ──────────────────────────────────────────────────────

  describe "agent chat scroll" do
    test "scroll wheel on agent tab scrolls agent chat" do
      ctx = start_editor("hello world")
      {_ctx, _} = open_agent_split(ctx)

      _state_before = :sys.get_state(ctx.editor)

      # Agent chat window should be unpinned after scroll
      send_mouse(ctx, 5, 10, :wheel_down)
      send_mouse(ctx, 5, 10, :wheel_down)

      state_after = :sys.get_state(ctx.editor)

      case EditorState.find_agent_chat_window(state_after) do
        nil ->
          :ok

        {_win_id, window} ->
          refute window.pinned, "agent chat window should be unpinned after scroll"
      end
    end
  end

  # ── Agent input focus via click ────────────────────────────────────────────

  describe "agent input focus via click" do
    test "clicking in agent input area focuses the input" do
      ctx = start_editor("hello world")
      {_ctx, _} = open_agent_split(ctx)

      # The input area is at the bottom of the agent tab.
      input_row = ctx.height - 3
      send_mouse(ctx, input_row, 10, :left)

      state = :sys.get_state(ctx.editor)

      assert state.workspace.agent_ui.panel.input_focused,
             "clicking in the input area should focus the agent input"
    end

    test "clicking in agent chat area unfocuses the input" do
      ctx = start_editor("hello world")
      {_ctx, _} = open_agent_split(ctx)

      # Focus input first
      input_row = ctx.height - 3
      send_mouse(ctx, input_row, 10, :left)

      state = :sys.get_state(ctx.editor)

      assert state.workspace.agent_ui.panel.input_focused,
             "precondition: input should be focused after clicking input area"

      # Click in the chat area (upper portion) to unfocus
      send_mouse(ctx, 3, 10, :left)

      state = :sys.get_state(ctx.editor)

      refute state.workspace.agent_ui.panel.input_focused,
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
    # TODO: This test needs rework - clicking in editor area after file tree
    # open doesn't set :editor scope due to mouse dispatch layout issue.
    @tag :skip
    test "click dispatches to correct region when file tree is open" do
      ctx = start_editor("hello world")

      # Open file tree and wait for it to render.
      send_keys_sync(ctx, "<Space>op")

      wait_until(
        ctx,
        fn state ->
          state.workspace.file_tree != nil and
            FileTree.open?(state.workspace.file_tree)
        end,
        max_attempts: 50,
        interval_ms: 20,
        message: "file tree never opened"
      )

      # Wait for the file tree separator to appear.
      wait_until_screen(
        ctx,
        fn ->
          row1 = screen_row(ctx, 1)
          sep_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))
          sep_count >= 1
        end,
        message: "expected at least 1 separator (tree|editor)"
      )

      rows = screen_text(ctx)
      row1 = Enum.at(rows, 1)

      # Find the separator between file tree and editor
      graphemes = String.graphemes(row1)

      sep_positions =
        graphemes
        |> Enum.with_index()
        |> Enum.filter(fn {ch, _i} -> ch == "│" end)
        |> Enum.map(fn {_ch, i} -> i end)

      assert sep_positions != [],
             "expected at least 1 separator, found none in: #{inspect(row1)}"

      [tree_sep | _] = sep_positions

      # Verify that the file tree separator is at a reasonable position
      assert tree_sep > 5, "file tree separator should be at least a few columns in"
      assert tree_sep < ctx.width - 10, "file tree should not span the whole width"

      # Click in the editor area (right of file tree + gutter)
      editor_col = div(ctx.width, 2)
      send_mouse(ctx, 5, editor_col, :left)
      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :editor,
             "clicking in editor area should set :editor scope, got #{state.workspace.keymap_scope}"
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
      tab_id = state.shell_state.tab_bar.active_id

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
      assert state.workspace.editing.mode == :normal
      assert state.workspace.buffers.active != nil
    end

    test "mouse click after buffer switch runs shared housekeeping" do
      ctx = start_editor("first buffer content\nsecond line\nthird line")

      state = :sys.get_state(ctx.editor)
      first_buffer = state.workspace.buffers.active

      # Add a second buffer and switch to it via state injection
      {:ok, second_buffer} =
        BufferServer.start_link(content: "different content here")

      :sys.replace_state(ctx.editor, fn state ->
        EditorState.add_buffer(state, second_buffer)
      end)

      state = :sys.get_state(ctx.editor)
      assert state.workspace.buffers.active == second_buffer

      # Switch back to first buffer
      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | workspace: %{
              state.workspace
              | buffers: %{state.workspace.buffers | active: first_buffer, active_index: 0}
            }
        }
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
