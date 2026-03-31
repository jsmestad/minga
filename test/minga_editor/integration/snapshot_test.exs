defmodule Minga.Integration.SnapshotTest do
  @moduledoc """
  Screen snapshot integration tests.

  Each test sets up an editor state and asserts the full rendered screen
  matches a stored baseline. Catches visual regressions that targeted
  assertions miss: wrong cursor column, missing gutter numbers, modeline
  layout shifts, tilde row count changes.

  Run `UPDATE_SNAPSHOTS=1 mix test test/minga/integration/snapshot_test.exs`
  to accept new baselines after intentional visual changes.
  """

  use Minga.Test.EditorCase, async: true

  describe "initial render" do
    test "single line file" do
      ctx = start_editor("hello world")
      assert_screen_snapshot(ctx, "initial_single_line")
    end

    test "multi-line file" do
      ctx = start_editor("hello world\nsecond line\nthird line")
      assert_screen_snapshot(ctx, "initial_multi_line")
    end

    test "empty buffer" do
      ctx = start_editor("")
      assert_screen_snapshot(ctx, "initial_empty")
    end
  end

  describe "normal mode navigation" do
    test "cursor after ll (two right moves)" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?l)
      send_key(ctx, ?l)

      assert_screen_snapshot(ctx, "nav_ll")
    end

    test "cursor after jj (two down moves)" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?j)
      send_key(ctx, ?j)

      assert_screen_snapshot(ctx, "nav_jj")
    end

    test "cursor after $ (end of line)" do
      ctx = start_editor("hello world\nsecond line")

      send_keys_sync(ctx, "$")

      assert_screen_snapshot(ctx, "nav_end_of_line")
    end

    test "cursor after 0 (start of line)" do
      ctx = start_editor("hello world\nsecond line")

      send_keys_sync(ctx, "ll0")

      assert_screen_snapshot(ctx, "nav_start_of_line")
    end
  end

  describe "insert mode" do
    test "screen after entering insert mode" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)

      assert_screen_snapshot(ctx, "insert_mode_entered")
    end

    test "screen after typing text in insert mode" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      type_text(ctx, "abc")

      assert_screen_snapshot(ctx, "insert_typed_abc")
    end

    test "screen after escape back to normal mode" do
      ctx = start_editor("hello")

      send_keys_sync(ctx, "iabc<Esc>")

      assert_screen_snapshot(ctx, "insert_then_escape")
    end
  end

  describe "delete operations" do
    test "screen after dd (delete line)" do
      ctx = start_editor("first\nsecond\nthird")

      send_keys_sync(ctx, "dd")

      assert_screen_snapshot(ctx, "dd_first_line")
    end

    test "screen after x (delete char)" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "x")

      assert_screen_snapshot(ctx, "x_delete_char")
    end
  end

  describe "undo" do
    test "screen after dd then undo" do
      ctx = start_editor("first\nsecond\nthird")

      send_keys_sync(ctx, "dd")
      send_key(ctx, ?u)

      assert_screen_snapshot(ctx, "dd_then_undo")
    end
  end

  describe "visual mode" do
    test "screen after entering visual mode" do
      ctx = start_editor("hello world\nsecond line")

      send_key(ctx, ?v)

      assert_screen_snapshot(ctx, "visual_mode_entered")
    end

    test "screen after visual selection with lll" do
      ctx = start_editor("hello world\nsecond line")

      send_keys_sync(ctx, "vlll")

      assert_screen_snapshot(ctx, "visual_select_lll")
    end
  end

  describe "command mode" do
    test "screen after pressing colon" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":")

      assert_screen_snapshot(ctx, "command_mode_entered")
    end

    test "screen after typing a command" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":set")

      assert_screen_snapshot(ctx, "command_mode_typed_set")
    end

    test "screen after escaping command mode" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":set<Esc>")

      assert_screen_snapshot(ctx, "command_mode_escaped")
    end
  end

  describe "full workflow" do
    test "navigate, insert, delete, undo" do
      ctx = start_editor("line one\nline two\nline three")

      # Navigate to line 2, col 3
      send_key_sync(ctx, ?j)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)

      # Insert text
      send_keys_sync(ctx, "iXY<Esc>")

      assert_screen_snapshot(ctx, "workflow_after_insert")

      # Delete the line
      send_keys_sync(ctx, "dd")

      assert_screen_snapshot(ctx, "workflow_after_dd")

      # Undo
      send_key(ctx, ?u)

      assert_screen_snapshot(ctx, "workflow_after_undo")
    end
  end
end
