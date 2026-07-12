defmodule Minga.Integration.SnapshotTest do
  @moduledoc """
  Representative full-screen regression snapshots.

  Cursor motion, editing, undo, and mode semantics are covered at cheaper boundaries. These snapshots retain one baseline and representative visual, command, and multi-step workflow surfaces.
  """

  use Minga.Test.EditorCase, async: true

  test "multi-line initial render" do
    ctx = start_editor("hello world\nsecond line\nthird line")
    assert_screen_snapshot(ctx, "initial_multi_line")
  end

  test "visual selection render" do
    ctx = start_editor("hello world\nsecond line")
    send_keys_sync(ctx, "vlll")
    assert_screen_snapshot(ctx, "visual_select_lll")
  end

  test "command input render" do
    ctx = start_editor("hello world")
    send_keys_sync(ctx, ":set")
    assert_screen_snapshot(ctx, "command_mode_typed_set")
  end

  test "navigate, insert, delete, and undo workflow" do
    ctx = start_editor("line one\nline two\nline three")

    send_keys_sync(ctx, "jlliXY<Esc>")
    assert_screen_snapshot(ctx, "workflow_after_insert")

    send_keys_sync(ctx, "dd")
    assert_screen_snapshot(ctx, "workflow_after_dd")

    send_key_sync(ctx, ?u)
    assert_screen_snapshot(ctx, "workflow_after_undo")
  end
end
