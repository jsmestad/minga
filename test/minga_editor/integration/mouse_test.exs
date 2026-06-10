defmodule Minga.Integration.MouseTest do
  @moduledoc """
  Thin integration smoke tests for mouse events crossing the live Editor GenServer boundary.

  Gesture details live in `MingaEditor.MouseTest` and `MingaEditor.MouseMultiClickTest`. This file keeps only the cases that need the full input router, shell state, renderer, or GUI action path.
  """
  # Mutates the global built-in FileTree sidebar registry while rendering through live editors.
  use Minga.Test.EditorCase, async: false

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree
  alias Minga.Test.StubServer

  defp start_editor_with_project(content) do
    id = :erlang.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "minga-integration-mouse-#{id}")
    File.mkdir_p!(root)
    start_editor(content, project_root: root)
  end

  defp inject_fake_session(%{editor: editor} = ctx) do
    {:ok, fake} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      tb = state.shell_state.tab_bar

      target_tab =
        MingaEditor.State.TabBar.find_by_kind(tb, :agent) ||
          MingaEditor.State.TabBar.active(tb)

      case target_tab do
        nil -> state
        tab -> MingaEditor.State.set_tab_session(state, tab.id, fake)
      end
    end)

    ctx
  end

  defp open_agent_tab(ctx) do
    ctx = inject_fake_session(ctx)
    send_keys_sync(ctx, "<Space>aa")
    ctx
  end

  describe "live editor mouse routing" do
    test "left click moves the buffer cursor through the input router" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 2, 6, :left)

      assert {1, _col} = buffer_cursor(ctx)
      assert screen_contains?(ctx, "second line")
    end

    test "file tree and editor clicks route to the matching focus scope" do
      ctx = start_editor_with_project("hello world")

      send_keys_sync(ctx, "<Space>op")
      assert file_tree_open?(ctx)
      tree_width = EditorState.file_tree_state(editor_state(ctx)).tree_width

      send_mouse(ctx, 5, div(ctx.width, 2), :left)

      send_mouse(ctx, 5, max(tree_width - 2, 0), :left)
      state = editor_state(ctx)

      assert FileTree.focused?(EditorState.file_tree_state(state)),
             "clicking file tree should focus it"
    end
  end

  describe "agent tab mouse routing" do
    test "clicks focus the agent input and wheel events reach the agent chat" do
      ctx =
        "hello world"
        |> start_editor()
        |> open_agent_tab()

      input_row = ctx.height - 3
      send_mouse(ctx, input_row, 10, :left)

      state = editor_state(ctx)
      assert state.workspace.agent_ui.panel.input_focused

      send_mouse(ctx, 3, 10, :left)
      state = editor_state(ctx)
      refute state.workspace.agent_ui.panel.input_focused

      send_mouse(ctx, 5, 10, :wheel_down)

      state = editor_state(ctx)
      assert {_win_id, window} = EditorState.find_agent_chat_window(state)
      refute window.pinned, "agent chat window should be unpinned after scrolling"
    end
  end

  describe "Go TUI event-stream parity (#2229)" do
    # These tests assert what the editor does with the exact (button, event_type,
    # click_count) tuples the Go TUI forwards. They are the empirical evidence
    # for the #2229 verification: AC1 multi-click works via BEAM synthesis when
    # the frontend sends click_count=1; AC2 drag selection requires the frontend
    # to distinguish a button-held drag (:drag) from a free-moving hover
    # (:motion). The Go TUI must therefore send :drag for held-button motion.

    # Screen row 1 maps to buffer line 0; gutter is ~6 cols wide, so screen
    # col 8 lands inside the first word ("hello"). Row 0 is the header/tab bar.
    test "double-click word selection works when the frontend sends click_count=1 (AC1)" do
      ctx = start_editor("hello world\nsecond line")

      # Two rapid presses at the same cell, each with the click_count=1 the Go
      # TUI sends. record_press/4 synthesizes click_count=2 from the timing.
      send_mouse(ctx, 1, 8, :left, 0, :press, 1)
      send_mouse(ctx, 1, 8, :left, 0, :press, 1)

      state = editor_state(ctx)
      assert editor_mode(ctx) == :visual
      assert state.workspace.editing.mode_state.visual_type == :char

      # The selection covers a whole word (anchor and cursor on the same line,
      # spanning more than one column), which is the double-click behavior.
      {anchor_line, anchor_col} = state.workspace.editing.mode_state.visual_anchor
      {cursor_line, cursor_col} = buffer_cursor(ctx)
      assert anchor_line == cursor_line
      assert abs(cursor_col - anchor_col) >= 1
    end

    test "triple-click line selection works when the frontend sends click_count=1 (AC1)" do
      ctx = start_editor("hello world\nsecond line")

      send_mouse(ctx, 1, 8, :left, 0, :press, 1)
      send_mouse(ctx, 1, 8, :left, 0, :press, 1)
      send_mouse(ctx, 1, 8, :left, 0, :press, 1)

      state = editor_state(ctx)
      assert editor_mode(ctx) == :visual
      assert state.workspace.editing.mode_state.visual_type == :line
    end

    test "a button-held drag (event_type :drag) produces a visual selection (AC2)" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 1, 8, :left, 0, :press, 1)
      assert editor_mode(ctx) == :normal

      # Held-button motion arrives as :drag. This is what the Go TUI must send
      # for MouseMotionMsg while a button is down.
      send_mouse(ctx, 3, 12, :left, 0, :drag, 1)

      assert editor_mode(ctx) == :visual,
             "a left-button drag should extend a visual selection from the press anchor"
    end

    test "free pointer motion (event_type :motion) does NOT start a selection" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 1, 8, :left, 0, :press, 1)

      # Free motion (no button held) is hover, not drag. The Go TUI must send
      # :motion for these so the BEAM treats them as hover, not drag. The press
      # above left an active drag anchor, so this proves :motion is inert for
      # selection while :drag (previous test) extends it.
      send_mouse(ctx, 3, 12, :none, 0, :motion, 1)

      assert editor_mode(ctx) == :normal,
             "free pointer motion must not extend a selection; only :drag does"
    end
  end

  describe "shared post-action housekeeping" do
    test "mouse clicks exit visual mode and clear LSP selection ranges" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_keys_sync(ctx, "v")
      assert editor_mode(ctx) == :visual

      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | lsp:
              MingaEditor.State.LSP.set_selection_ranges(state.lsp, [%{"range" => %{}}])
              |> Map.put(:selection_range_index, 1)
        }
      end)

      assert editor_state(ctx).lsp.selection_ranges != nil

      send_mouse(ctx, 2, 5, :left)

      assert editor_mode(ctx) == :normal

      state = editor_state(ctx)
      assert state.lsp.selection_ranges == nil
      assert state.lsp.selection_range_index == 0
    end
  end
end
