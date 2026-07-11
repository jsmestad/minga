defmodule Minga.BufferManagementTest do
  @moduledoc """
  Wiring tests for multi-buffer management: verifies that keybindings and ex commands correctly dispatch to buffer lifecycle operations.

  Buffer count, index, and state-level invariants are tested as pure functions in `MingaEditor.State.BufferLifecycleTest`. These tests focus on the keystroke-to-state-change plumbing.
  """

  use Minga.Test.EditorCase, async: true

  describe ":e — open file via command mode" do
    @tag :tmp_dir
    test "opens a new file and reactivates an existing file", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "first")
      File.write!(path2, "second")

      ctx = start_editor("first", file_path: path1)

      send_ex_sync(ctx, "e #{path2}")
      assert active_content(ctx) == "second"

      send_ex_sync(ctx, "e #{path1}")
      assert active_content(ctx) == "first"
    end
  end

  describe "SPC b n / SPC b p — cycle buffers" do
    @tag :tmp_dir
    test "next/prev cycle through open buffers", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "a.txt")
      path2 = Path.join(tmp_dir, "b.txt")
      path3 = Path.join(tmp_dir, "c.txt")
      File.write!(path1, "alpha")
      File.write!(path2, "beta")
      File.write!(path3, "gamma")

      ctx = start_editor("alpha", file_path: path1)
      send_ex_sync(ctx, "e #{path2}")
      send_ex_sync(ctx, "e #{path3}")

      assert active_content(ctx) == "gamma"

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "alpha"

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "beta"

      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "alpha"

      # Regression for #1476: after `:e <path>`, cycling restores a valid resting mode state.
      # Another leader command must then remain usable.
      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "beta"
    end
  end

  describe "SPC b d — kill buffer" do
    @tag :tmp_dir
    test "killing a buffer switches to the next one", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "one.txt")
      path2 = Path.join(tmp_dir, "two.txt")
      File.write!(path1, "first")
      File.write!(path2, "second")

      ctx = start_editor("first", file_path: path1)
      send_ex_sync(ctx, "e #{path2}")

      send_keys_sync(ctx, "<SPC>bd")
      assert active_content(ctx) == "first"
    end
  end

  describe "new buffers" do
    test ":new creates an editable empty buffer" do
      ctx = start_editor("hello")
      send_ex_sync(ctx, "new")
      send_keys_sync(ctx, "isome text<Esc>")

      assert active_content(ctx) == "some text"
    end

    @tag :tmp_dir
    test "SPC b d closes the active scratch buffer while the file tree is visible", %{
      tmp_dir: tmp_dir
    } do
      ctx = start_editor("", project_root: tmp_dir)
      send_keys_sync(ctx, "<SPC>op")
      send_keys_sync(ctx, "<SPC>bN")
      send_keys_sync(ctx, "iHey there<Esc>")

      assert active_content(ctx) == "Hey there"

      send_keys_sync(ctx, "<SPC>bd")

      assert active_content(ctx) == ""
      refute status_msg(ctx) == "Cannot close the last window"
    end
  end
end
