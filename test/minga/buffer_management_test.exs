defmodule Minga.BufferManagementTest do
  @moduledoc """
  Tests for multi-buffer management: opening, switching, closing buffers
  via keybindings and ex commands.

  Uses state-based assertions (Tier 2) instead of screen reads. Buffer
  management is a state concern: which buffer is active, how many are
  open, what index are we at. The screen is just a projection of this
  state and is tested separately in rendering tests.
  """

  use Minga.Test.EditorCase, async: true

  describe "single buffer baseline" do
    test "editor starts with one buffer" do
      ctx = start_editor("hello")
      assert buffer_count(ctx) == 1
      assert active_content(ctx) == "hello"
      assert editor_mode(ctx) == :normal
    end
  end

  describe ":e — open file via command mode" do
    @tag :tmp_dir
    test "opening a new file switches to it", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "first file")
      File.write!(path2, "second file")

      ctx = start_editor("first file", file_path: path1)
      assert active_content(ctx) == "first file"

      send_keys(ctx, ":e #{path2}<CR>")

      assert active_content(ctx) == "second file"
      assert buffer_count(ctx) == 2
      assert active_buffer_index(ctx) == 1
    end

    @tag :tmp_dir
    test "opening an already-open file switches to it without duplicating", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "first")
      File.write!(path2, "second")

      ctx = start_editor("first", file_path: path1)

      send_keys(ctx, ":e #{path2}<CR>")
      assert buffer_count(ctx) == 2

      # Open first file again: should switch back, not create a third buffer
      send_keys(ctx, ":e #{path1}<CR>")
      assert active_content(ctx) == "first"
      assert buffer_count(ctx) == 2
      assert active_buffer_index(ctx) == 0
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

      # Now on buffer 3/3 (gamma)
      assert active_content(ctx) == "gamma"
      assert active_buffer_index(ctx) == 2
      assert buffer_count(ctx) == 3

      # SPC b n wraps to buffer 1 (alpha)
      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "alpha"
      assert active_buffer_index(ctx) == 0

      # SPC b n to buffer 2 (beta)
      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "beta"
      assert active_buffer_index(ctx) == 1

      # SPC b p back to buffer 1 (alpha)
      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "alpha"
      assert active_buffer_index(ctx) == 0
    end

    test "next/prev with single buffer is a no-op" do
      ctx = start_editor("only one")

      send_keys_sync(ctx, "<SPC>bn")
      assert active_content(ctx) == "only one"
      assert buffer_count(ctx) == 1

      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "only one"
    end
  end

  describe "SPC b b — buffer picker" do
    @tag :tmp_dir
    test "SPC b b opens picker, Enter on first item switches buffer", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "x.txt")
      path2 = Path.join(tmp_dir, "y.txt")
      File.write!(path1, "ex")
      File.write!(path2, "why")

      ctx = start_editor("ex", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")
      assert active_content(ctx) == "why"

      # SPC b b opens picker, Enter selects first item
      send_keys_sync(ctx, "<SPC>bb")
      assert picker_open?(ctx)

      send_key_sync(ctx, 13)
      refute picker_open?(ctx)
      assert active_content(ctx) == "ex"
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
      assert buffer_count(ctx) == 2

      # On buffer 2/2, kill it
      send_keys_sync(ctx, "<SPC>bd")
      assert buffer_count(ctx) == 1
      assert active_content(ctx) == "first"
    end

    @tag :tmp_dir
    test "killing the only buffer creates a new empty buffer", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "solo.txt")
      File.write!(path, "alone")

      ctx = start_editor("alone", file_path: path)
      send_keys_sync(ctx, "<SPC>bd")

      assert buffer_count(ctx) == 1
      assert active_content(ctx) == ""
    end

    @tag :tmp_dir
    test "killing first buffer makes second active at index 0", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "p.txt")
      path2 = Path.join(tmp_dir, "q.txt")
      File.write!(path1, "papa")
      File.write!(path2, "quebec")

      ctx = start_editor("papa", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # Switch back to first buffer and kill it
      send_keys_sync(ctx, "<SPC>bp")
      assert active_content(ctx) == "papa"

      send_keys_sync(ctx, "<SPC>bd")
      assert active_content(ctx) == "quebec"
      assert buffer_count(ctx) == 1
    end
  end

  describe ":new — new empty buffer" do
    test "creates a new empty buffer" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, ":new<CR>")

      assert buffer_count(ctx) == 2
      assert active_content(ctx) == ""
    end

    test "successive :new increments buffer count" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, ":new<CR>")
      assert buffer_count(ctx) == 2

      send_keys_sync(ctx, ":new<CR>")
      assert buffer_count(ctx) == 3
    end

    test "new buffer is editable" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, ":new<CR>")
      send_keys_sync(ctx, "isome text<Esc>")
      assert active_content(ctx) == "some text"
    end
  end

  describe "SPC b N — new buffer via leader" do
    test "creates a new buffer" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bN")
      assert buffer_count(ctx) == 2
      assert active_content(ctx) == ""
    end
  end
end
