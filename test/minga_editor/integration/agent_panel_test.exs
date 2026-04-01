defmodule Minga.Integration.AgentPanelTest do
  @moduledoc """
  Integration tests for agent panel: toggle, focus management, and tab switching.

  The agent view is a separate tab (not a split pane). Toggling SPC a a
  switches between the file tab and the agent tab. Each tab has its own
  window context and keymap scope.
  """
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Layout
  alias MingaEditor.State.FileTree
  alias Minga.Test.StubServer

  # ── Test helpers ───────────────────────────────────────────────────────────

  # Wraps start_editor to inject a stub agent session, preventing the
  # real provider startup (~700ms per test) when the agent panel is opened.
  defp start_editor_with_fake_session(content, opts \\ []) do
    ctx = start_editor(content, opts)
    {:ok, fake} = StubServer.start_link()

    :sys.replace_state(ctx.editor, fn state ->
      MingaEditor.State.AgentAccess.update_agent(state, fn a -> %{a | session: fake} end)
    end)

    ctx
  end

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "agent tab toggle (SPC a a)" do
    test "switches to agent tab" do
      ctx = start_editor_with_fake_session("hello world")

      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :editor

      send_keys_sync(ctx, "<Space>aa")
      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :agent,
             "SPC a a should switch to agent tab (scope :agent), got #{state.workspace.keymap_scope}"
    end

    test "toggles back to file tab" do
      ctx = start_editor_with_fake_session("hello world")

      send_keys_sync(ctx, "<Space>aa")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :agent

      send_keys_sync(ctx, "<Space>aa")
      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :editor,
             "second SPC a a should return to file tab (scope :editor), got #{state.workspace.keymap_scope}"
    end

    test "buffer content is preserved through toggle cycle" do
      ctx = start_editor_with_fake_session("hello world")

      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "<Space>aa")

      content = buffer_content(ctx)
      assert content == "hello world"
      assert editor_mode(ctx) == :normal
    end
  end

  # ── Focus management ───────────────────────────────────────────────────────

  describe "focus and scope" do
    test "SPC a a from file tab sets :agent scope" do
      ctx = start_editor_with_fake_session("hello world")
      send_keys_sync(ctx, "<Space>aa")

      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :agent
    end

    test "file editing works after returning from agent tab" do
      ctx = start_editor_with_fake_session("hello world")

      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "<Space>aa")

      # x should delete a character because we're back in editor scope
      send_keys_sync(ctx, "x")
      content = buffer_content(ctx)
      refute content == "hello world", "buffer should be editable after toggling back"
    end
  end

  # ── Layout ─────────────────────────────────────────────────────────────────

  describe "layout" do
    test "editor alone uses full terminal width" do
      ctx = start_editor_with_fake_session("hello world")

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)
      {_r, c, w, _h} = layout.editor_area

      assert c == 0, "editor should start at column 0"
      assert w == ctx.width, "editor should use full width (#{ctx.width}), got #{w}"
    end

    test "file tree open: tree on left, editor on right" do
      ctx = start_editor_with_fake_session("hello world")

      send_keys_sync(ctx, "<Space>op")

      wait_until(
        ctx,
        fn state ->
          state.workspace.file_tree != nil and FileTree.open?(state.workspace.file_tree)
        end,
        message: "file tree never opened"
      )

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)

      assert layout.file_tree != nil, "file_tree rect should be set"
      {_r, ft_col, _ft_w, _h} = layout.file_tree
      assert ft_col == 0, "file tree should start at column 0"

      {_r, ed_col, _ed_w, _h} = layout.editor_area
      assert ed_col > 0, "editor should not start at column 0 when file tree is open"
    end

    test "agent tab uses full terminal width" do
      ctx = start_editor_with_fake_session("hello world")
      send_keys_sync(ctx, "<Space>aa")

      state = :sys.get_state(ctx.editor)
      layout = Layout.get(state)
      {_r, c, w, _h} = layout.editor_area

      assert c == 0, "agent tab editor area should start at column 0"
      assert w == ctx.width, "agent tab should use full width (#{ctx.width}), got #{w}"
    end
  end

  # ── Rendering consistency ──────────────────────────────────────────────────

  describe "rendering after toggle" do
    test "modeline preserved after toggle cycle" do
      ctx = start_editor_with_fake_session("hello world")

      ml_before = modeline(ctx)

      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "<Space>aa")

      ml_after = modeline(ctx)

      assert String.contains?(ml_after, "NORMAL"),
             "modeline should show NORMAL after toggle back, got: #{inspect(ml_after)}"

      assert String.contains?(ml_before, "[no file]")
      assert String.contains?(ml_after, "[no file]")
    end

    test "no stale separator chars on file tab" do
      ctx = start_editor_with_fake_session("hello world\nsecond line\nthird line")

      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "<Space>aa")

      for row_idx <- 1..3 do
        row = screen_row(ctx, row_idx)

        refute String.contains?(row, "│"),
               "row #{row_idx} should have no separator on file tab, got: #{inspect(row)}"
      end
    end
  end
end
