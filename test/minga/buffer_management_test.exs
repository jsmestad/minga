defmodule Minga.BufferManagementTest do
  @moduledoc """
  Wiring tests for multi-buffer management: verifies that keybindings and
  ex commands correctly dispatch to buffer lifecycle operations.

  Buffer count, index, and state-level invariants are tested as pure
  functions in `MingaEditor.State.BufferLifecycleTest`. These tests focus on
  the keystroke-to-state-change plumbing.
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

      send_keys(ctx, ":e #{path2}<CR>")
      assert active_content(ctx) == "second"

      send_keys(ctx, ":e #{path1}<CR>")
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

      send_keys(ctx, ":e #{path2}<CR>")
      send_keys(ctx, ":e #{path3}<CR>")

      assert active_content(ctx) == "gamma"

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "alpha"

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "beta"

      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "alpha"
    end

    @tag :tmp_dir
    test "leader keys keep working through buffer cycling after :e", %{tmp_dir: tmp_dir} do
      # Regression for #1476 (the snapshot bug surfaced via #1477's
      # smart-cycle): after `:e <path>` the leaving mode's CommandState
      # used to leak into the tab's editing.mode_state snapshot. When
      # smart-cycle later restored that tab via tab-switch, the next
      # leader keypress crashed with `KeyError, key :leader_trie not
      # found in: %CommandState{}`. With the fix in #1476, every tab
      # snapshot is a valid resting state, so leader handling stays
      # alive across multiple cycle/`<SPC>` rounds.
      path1 = Path.join(tmp_dir, "a.txt")
      path2 = Path.join(tmp_dir, "b.txt")
      path3 = Path.join(tmp_dir, "c.txt")
      File.write!(path1, "alpha")
      File.write!(path2, "beta")
      File.write!(path3, "gamma")

      ctx = start_editor("alpha", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")
      send_keys(ctx, ":e #{path3}<CR>")

      # Several leader rounds across cycle should never raise.
      send_keys_sync(ctx, "<SPC>bn")
      send_keys_sync(ctx, "<SPC>bn")
      send_keys_sync(ctx, "<SPC>bp")
      send_keys_sync(ctx, "<SPC>bn")

      # The synchronous content query proves the editor is still alive and processing keys.
      assert active_content(ctx) in ["alpha", "beta", "gamma"]
    end

    test "next/prev with single buffer is a no-op" do
      ctx = start_editor("only one")

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "only one"

      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "only one"
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
      send_keys(ctx, ":e #{path2}<CR>")

      # On buffer 2/2, kill it — should switch back to first
      send_keys_sync(ctx, "<SPC>bd")
      assert active_content(ctx) == "first"
    end

    @tag :tmp_dir
    test "killing the only buffer creates a new empty buffer", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "solo.txt")
      File.write!(path, "alone")

      ctx = start_editor("alone", file_path: path)
      send_keys_sync(ctx, "<SPC>bd")

      assert active_content(ctx) == ""
    end
  end

  describe "new buffers" do
    test ":new creates an editable empty buffer" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, ":new<CR>")
      send_keys_sync(ctx, "isome text<Esc>")

      assert active_content(ctx) == "some text"
    end

    test "SPC b d closes the active scratch buffer when multiple scratch buffers are open" do
      ctx = start_editor("")
      send_keys_sync(ctx, "<SPC>bN")
      send_keys_sync(ctx, "iHey there<Esc>")

      assert active_content(ctx) == "Hey there"

      send_keys_sync(ctx, "<SPC>bd")

      assert active_content(ctx) == ""
      refute status_msg(ctx) == "Cannot close the last window"
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

    test "SPC b N creates an empty buffer" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bN")

      assert active_content(ctx) == ""
    end
  end
end
