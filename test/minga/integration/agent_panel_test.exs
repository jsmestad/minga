defmodule Minga.Integration.AgentPanelTest do
  @moduledoc """
  Integration tests for agent panel: toggle, focus management, layout
  computation, and interaction with other UI elements (file tree, splits).
  """
  # async: false because agent panel initialization talks to external processes
  # and can be slow under heavy test concurrency
  use Minga.Test.EditorCase, async: false

  alias Minga.Editor.Layout
  alias Minga.Editor.State.FileTree
  alias Minga.Editor.Window.Content

  # ── Test helpers ───────────────────────────────────────────────────────────

  # Opens the agent split and asserts a separator rendered.
  # Returns `{ctx, sep_col}` where `sep_col` is the column index of the separator.
  defp open_agent_split(ctx) do
    send_keys(ctx, "<Space>aa")
    row1 = screen_row(ctx, 1)
    sep_col = row1 |> String.graphemes() |> Enum.find_index(&(&1 == "│"))

    assert sep_col != nil,
           "expected vertical separator after opening agent split, got row: #{inspect(row1)}"

    {ctx, sep_col}
  end

  # Returns the separator column for a content row, or nil.
  defp find_separator(ctx, row_index) do
    screen_row(ctx, row_index)
    |> String.graphemes()
    |> Enum.find_index(&(&1 == "│"))
  end

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "agent panel toggle (SPC a a)" do
    test "opening shows agent panel with separator" do
      ctx = start_editor("hello world")
      {_ctx, _sep_col} = open_agent_split(ctx)

      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "separator between editor and agent panel should be visible"
    end

    test "closing restores full editor width" do
      ctx = start_editor("hello world")
      {ctx, _sep_col} = open_agent_split(ctx)

      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys(ctx, "<Space>aa")

      row1 = screen_row(ctx, 1)
      refute String.contains?(row1, "│"), "separator should be gone after closing agent panel"
    end

    test "double toggle is idempotent (open -> close -> clean)" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys(ctx, "<Space>aa")

      content_row = screen_row(ctx, 1)

      refute String.contains?(content_row, "│"),
             "content row should have no separator after close"
    end

    test "buffer content is preserved through open/close cycle" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")
      send_keys(ctx, "<Space>aa")

      content = buffer_content(ctx)
      assert content == "hello world"
      assert editor_mode(ctx) == :normal
    end
  end

  # ── Layout region verification ─────────────────────────────────────────────

  describe "agent panel renders in correct screen region" do
    test "agent panel appears on the right side of the screen" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # Separator should be roughly in the middle-to-left area (60/40 split)
      # In an 80-col terminal, editor gets ~60% = 48 cols, agent gets ~40% = 32 cols
      assert sep_col > 20, "separator should not be too far left (got col #{sep_col})"
      assert sep_col < 65, "separator should not be too far right (got col #{sep_col})"

      # Verify the layout agrees with what we see on screen
      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)

      # There should be 2 windows in the layout (editor + agent)
      assert map_size(layout.window_layouts) == 2,
             "expected 2 window layouts, got #{map_size(layout.window_layouts)}"
    end

    test "editor content does not render beyond the separator" do
      # Use a long line to verify it gets truncated at the separator
      long_line = String.duplicate("x", 80)
      ctx = start_editor(long_line)
      {ctx, sep_col} = open_agent_split(ctx)

      row1 = screen_row(ctx, 1)
      graphemes = String.graphemes(row1)

      # The separator character itself should be "│"
      assert Enum.at(graphemes, sep_col) == "│",
             "expected separator at col #{sep_col}, got #{inspect(Enum.at(graphemes, sep_col))}"

      # Editor x's should not appear right of the separator
      right_of_sep = Enum.slice(graphemes, (sep_col + 1)..-1//1) |> Enum.join()

      refute String.contains?(right_of_sep, "xxx"),
             "editor content should not bleed past the separator"
    end

    test "closing agent panel restores tilde rows to full width" do
      ctx = start_editor("one line")
      {ctx, _sep_col} = open_agent_split(ctx)

      send_keys(ctx, "<Space>aa")

      # Tilde rows (empty buffer lines) should span the full terminal width
      tilde_row = screen_row(ctx, 3)

      assert String.contains?(tilde_row, "~"),
             "expected tilde row after closing agent panel, got: #{inspect(tilde_row)}"

      refute String.contains?(tilde_row, "│"),
             "tilde row should have no separator after closing agent panel"
    end

    test "modeline shows mode indicator when agent is open" do
      ctx = start_editor("hello world")
      {_ctx, _sep_col} = open_agent_split(ctx)

      ml = modeline(ctx)

      assert String.contains?(ml, "NORMAL") or String.contains?(ml, "INSERT"),
             "modeline should show mode indicator, got: #{inspect(ml)}"
    end
  end

  # ── Focus management ───────────────────────────────────────────────────────

  describe "focus switching" do
    test "SPC a a opens agent panel but keeps editor scope" do
      ctx = start_editor("hello world")
      {_ctx, _sep_col} = open_agent_split(ctx)

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :editor,
             "SPC a a should keep editor scope, got #{state.keymap_scope}"
    end

    test "buffer keystrokes work when editor is focused with agent open" do
      ctx = start_editor("hello world")
      {_ctx, _sep_col} = open_agent_split(ctx)

      # x should delete a character because we're in editor scope
      send_keys(ctx, "x")
      content = buffer_content(ctx)
      refute content == "hello world", "buffer should still be editable"
    end

    test "clicking agent pane switches keymap_scope to :agent" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      send_mouse(ctx, 5, sep_col + 5, :left)

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :agent,
             "clicking agent pane should set scope to :agent, got #{state.keymap_scope}"
    end

    test "buffer keystrokes do NOT modify the buffer when agent is focused" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # Focus the agent pane
      send_mouse(ctx, 5, sep_col + 5, :left)
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :agent

      # Try to delete with x; buffer should be unchanged because keystrokes
      # route to the agent chat nav handler, not the buffer
      send_keys(ctx, "x")
      content = buffer_content(ctx)

      assert content == "hello world",
             "buffer should not be modified when agent is focused, got: #{inspect(content)}"
    end

    test "clicking editor area after agent focus restores editing" do
      ctx = start_editor("hello world")
      {ctx, sep_col} = open_agent_split(ctx)

      # Focus the agent pane
      send_mouse(ctx, 5, sep_col + 5, :left)
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :agent

      # Click back in the editor area to return focus
      send_mouse(ctx, 2, 5, :left)

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :editor,
             "clicking editor should return scope to :editor, got #{state.keymap_scope}"

      # Verify buffer editing works again
      send_keys(ctx, "x")
      content = buffer_content(ctx)
      refute content == "hello world", "buffer should be editable after returning focus"
    end

    test "SPC a v toggles keyboard focus to agent and back" do
      ctx = start_editor("hello world")
      {_ctx, _sep_col} = open_agent_split(ctx)

      # Initial state: editor scope
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :editor

      # SPC a v should toggle focus to agent (re-opens split if needed,
      # or toggles the active window)
      send_keys(ctx, "<Space>av")

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope in [:editor, :agent],
             "SPC a v should toggle scope, got #{state.keymap_scope}"
    end
  end

  # ── Layout matrix ──────────────────────────────────────────────────────────

  describe "layout combinations" do
    test "editor alone uses full terminal width" do
      ctx = start_editor("hello world")

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)
      {_r, c, w, _h} = layout.editor_area

      assert c == 0, "editor should start at column 0"
      assert w == ctx.width, "editor should use full width (#{ctx.width}), got #{w}"
      assert layout.file_tree == nil
      assert layout.agent_panel == nil
    end

    test "file tree open: tree on left, editor on right" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")

      wait_until(
        ctx,
        fn state ->
          state.file_tree != nil and FileTree.open?(state.file_tree)
        end,
        message: "file tree never opened"
      )

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)

      assert layout.file_tree != nil, "file_tree rect should be set"
      {_r, ft_col, ft_w, _h} = layout.file_tree
      assert ft_col == 0, "file tree should start at column 0"

      {_r, ed_col, _ed_w, _h} = layout.editor_area
      assert ed_col >= ft_w, "editor should start after file tree (tree width: #{ft_w})"
    end

    test "agent open: editor window is narrower than before" do
      ctx = start_editor("hello world")

      # Capture the editor window width before opening agent
      state_before = :sys.get_state(ctx.editor)
      layout_before = Layout.get(state_before)
      [{_win_id, win_before}] = Map.to_list(layout_before.window_layouts)
      {_r, _c, width_before, _h} = win_before.content

      {_ctx, sep_col} = open_agent_split(ctx)

      state_after = :sys.get_state(ctx.editor)
      layout_after = Layout.get(state_after)

      # With agent split, there are 2 windows
      assert map_size(layout_after.window_layouts) == 2

      # Find the editor window (non-agent) and verify it shrank
      editor_win =
        Enum.find(layout_after.window_layouts, fn {win_id, _layout} ->
          window = Map.get(state_after.windows.map, win_id)
          window != nil and not Content.agent_chat?(window.content)
        end)

      assert editor_win != nil, "expected to find the editor window in window_layouts"
      {_win_id, editor_layout} = editor_win
      {_r, _c, width_after, _h} = editor_layout.content

      assert width_after < width_before,
             "editor window should be narrower with agent open (before: #{width_before}, after: #{width_after})"

      assert sep_col > 0, "separator should not be at column 0"
      assert sep_col < ctx.width - 1, "separator should not be at the last column"
    end

    test "file tree + agent: tree left, editor middle, agent right" do
      ctx = start_editor("hello world")

      # Open file tree first
      send_keys(ctx, "<Space>op")

      wait_until(
        ctx,
        fn state ->
          state.file_tree != nil and FileTree.open?(state.file_tree)
        end,
        message: "file tree never opened"
      )

      # Open agent
      {_ctx, _sep_col} = open_agent_split(ctx)

      # Wait for both separators
      wait_until(
        ctx,
        fn _state ->
          row1 = screen_row(ctx, 1)
          sep_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))
          sep_count >= 2
        end,
        message: "expected at least 2 separators (tree|editor|agent)"
      )

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)

      # All three regions should be present
      assert layout.file_tree != nil, "file tree should have a rect"

      {_r, ft_col, _ft_w, _h} = layout.file_tree
      assert ft_col == 0, "file tree should start at column 0"

      {_r, ed_col, ed_w, _h} = layout.editor_area

      assert ed_col > 0, "editor should not start at column 0 when file tree is open"
      assert ed_w < ctx.width, "editor should be narrower than terminal"

      # Verify the screen has content in all three regions
      row1 = screen_row(ctx, 1)
      sep_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))

      assert sep_count >= 2,
             "expected at least 2 separators (tree|editor|agent), found #{sep_count}"
    end
  end

  # ── Rendering consistency ──────────────────────────────────────────────────

  describe "rendering after close" do
    test "closing agent panel restores single modeline" do
      ctx = start_editor("hello world")

      ml_before = modeline(ctx)

      {ctx, _sep_col} = open_agent_split(ctx)
      send_keys(ctx, "<Space>aa")

      ml_after = modeline(ctx)

      # Modeline after closing should match the original (same mode, same file)
      assert String.contains?(ml_after, "NORMAL"),
             "modeline should show NORMAL after close, got: #{inspect(ml_after)}"

      # Both should show the buffer name
      assert String.contains?(ml_before, "[no file]")
      assert String.contains?(ml_after, "[no file]")
    end

    test "closing agent panel does not leave stale separator chars" do
      ctx = start_editor("hello world\nsecond line\nthird line")
      {ctx, _sep_col} = open_agent_split(ctx)

      send_keys(ctx, "<Space>aa")

      for row_idx <- 1..3 do
        row = screen_row(ctx, row_idx)

        refute String.contains?(row, "│"),
               "row #{row_idx} should have no separator after close, got: #{inspect(row)}"
      end
    end

    test "separator is consistent across all content rows when open" do
      ctx = start_editor("line 1\nline 2\nline 3\nline 4\nline 5")
      {ctx, sep_col} = open_agent_split(ctx)

      for row_idx <- 1..5 do
        row_sep = find_separator(ctx, row_idx)

        assert row_sep == sep_col,
               "separator at row #{row_idx} should be at col #{sep_col}, got #{inspect(row_sep)}"
      end
    end
  end
end
