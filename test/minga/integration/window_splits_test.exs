defmodule Minga.Integration.WindowSplitsTest do
  @moduledoc """
  Tests for window splitting: vertical/horizontal splits, navigation
  between panes, closing splits, and layout correctness.

  Uses `send_keys_sync` + `sync_screen` instead of `send_keys` to avoid
  races with the which-key timer that fires during leader sequences.
  `send_keys` captures a frame after each keystroke, but the which-key
  timer can produce an extra render that satisfies the wrong frame waiter.
  `send_keys_sync` uses a state barrier (no frame capture), then
  `sync_screen` ensures the port has processed the final render before
  the snapshot assertion reads the grid.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.Window.Content

  # ── Vertical split ─────────────────────────────────────────────────────────

  describe "vertical split (SPC w v)" do
    test "creates two windows" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")

      assert window_count(ctx) == 2
      assert has_split?(ctx)
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "vsplit_basic")
    end

    test "both windows share the same buffer" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")

      state = editor_state(ctx)

      window_bufs =
        state.workspace.windows.map |> Map.values() |> Enum.map(&Content.buffer_pid(&1.content))

      assert length(Enum.uniq(window_bufs)) == 1
    end
  end

  # ── Horizontal split ───────────────────────────────────────────────────────

  describe "horizontal split (SPC w s)" do
    test "creates two windows" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>ws")

      assert window_count(ctx) == 2
      assert has_split?(ctx)
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "hsplit_basic")
    end
  end

  # ── Navigation between splits ──────────────────────────────────────────────

  describe "split navigation (SPC w h/l)" do
    test "SPC w l moves focus to other pane" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      win_before = active_window_id(ctx)

      send_keys_sync(ctx, "<Space>wl")
      win_after = active_window_id(ctx)

      assert win_before != win_after
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "vsplit_focus_right")
    end

    test "SPC w h moves focus back" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      send_keys_sync(ctx, "<Space>wl")
      win_right = active_window_id(ctx)

      send_keys_sync(ctx, "<Space>wh")
      win_left = active_window_id(ctx)

      assert win_left != win_right
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "vsplit_focus_left")
    end
  end

  # ── Independent editing ────────────────────────────────────────────────────

  describe "independent editing in splits" do
    test "typing in one pane changes the shared buffer" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      send_keys_sync(ctx, "iNEW TEXT<Esc>")

      assert editor_mode(ctx) == :normal
      assert String.contains?(active_content(ctx), "NEW TEXT")
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "vsplit_edit")
    end
  end

  # ── Closing a split ────────────────────────────────────────────────────────

  describe "closing a split" do
    test "closing one pane restores single window" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      assert window_count(ctx) == 2
      assert has_split?(ctx)

      send_keys_sync(ctx, "<Space>wd")

      assert window_count(ctx) == 1
      refute has_split?(ctx)
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "vsplit_close")
    end
  end

  # ── Cursor memory ─────────────────────────────────────────────────────────

  describe "cursor memory across splits" do
    test "switching away and back preserves cursor position" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      send_keys_sync(ctx, "lllll")
      cursor_left = buffer_cursor(ctx)

      send_keys_sync(ctx, "<Space>wl")
      send_keys_sync(ctx, "<Space>wh")

      assert buffer_cursor(ctx) == cursor_left
    end
  end

  # ── Three-way split ───────────────────────────────────────────────────────

  describe "three-way split" do
    test "splitting twice creates three windows" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>wv")
      send_keys_sync(ctx, "<Space>wv")

      assert window_count(ctx) == 3
      sync_screen(ctx)
      assert_screen_snapshot(ctx, "three_way_split")
    end
  end
end
