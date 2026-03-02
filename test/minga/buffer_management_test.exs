defmodule Minga.BufferManagementTest do
  @moduledoc """
  Tests for multi-buffer management: opening, switching, closing buffers
  via keybindings and ex commands, verified through the headless harness.

  Note: `*scratch*` and `*Messages*` are stored separately from the buffer
  list, so they don't affect buffer counts or indicators.
  """

  use Minga.Test.EditorCase, async: true

  describe "single buffer baseline" do
    test "editor starts with one buffer" do
      ctx = start_editor("hello")
      assert_row_contains(ctx, 0, "hello")
      assert_mode(ctx, :normal)
    end

    test "no buffer indicator shown with single buffer" do
      ctx = start_editor("hello")
      ml = modeline(ctx)
      refute String.contains?(ml, "[1/")
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
      assert_row_contains(ctx, 0, "first file")

      # Open second file via :e
      send_keys(ctx, ":e #{path2}<CR>")

      assert_row_contains(ctx, 0, "second file")
      assert_modeline_contains(ctx, "file2.txt")
      assert_modeline_contains(ctx, "[2/2]")
    end

    @tag :tmp_dir
    test "opening an already-open file switches to it without duplicating", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.txt")
      path2 = Path.join(tmp_dir, "file2.txt")
      File.write!(path1, "first")
      File.write!(path2, "second")

      ctx = start_editor("first", file_path: path1)

      # Open second file
      send_keys(ctx, ":e #{path2}<CR>")
      assert_modeline_contains(ctx, "[2/2]")

      # Open first file again — should switch back, not create a third buffer
      send_keys(ctx, ":e #{path1}<CR>")
      assert_row_contains(ctx, 0, "first")
      assert_modeline_contains(ctx, "[1/2]")
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
      assert_row_contains(ctx, 0, "gamma")
      assert_modeline_contains(ctx, "[3/3]")

      # SPC b n → wraps to buffer 1 (alpha)
      send_keys(ctx, "<SPC>bn")
      assert_row_contains(ctx, 0, "alpha")
      assert_modeline_contains(ctx, "[1/3]")

      # SPC b n → buffer 2 (beta)
      send_keys(ctx, "<SPC>bn")
      assert_row_contains(ctx, 0, "beta")
      assert_modeline_contains(ctx, "[2/3]")

      # SPC b p → back to buffer 1 (alpha)
      send_keys(ctx, "<SPC>bp")
      assert_row_contains(ctx, 0, "alpha")
      assert_modeline_contains(ctx, "[1/3]")
    end

    test "next/prev with single buffer is a no-op" do
      ctx = start_editor("only one")

      send_keys(ctx, "<SPC>bn")
      assert_row_contains(ctx, 0, "only one")

      send_keys(ctx, "<SPC>bp")
      assert_row_contains(ctx, 0, "only one")
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
      assert_row_contains(ctx, 0, "why")

      # SPC b b → opens picker, first item is x.txt, Enter selects it
      send_keys(ctx, "<SPC>bb")
      send_key(ctx, 13)
      assert_row_contains(ctx, 0, "ex")
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

      # On buffer 2/2, kill it
      send_keys(ctx, "<SPC>bd")

      # Should switch to the remaining buffer
      assert_row_contains(ctx, 0, "first")
      # No buffer indicator with single buffer
      ml = modeline(ctx)
      refute String.contains?(ml, "[")
    end

    @tag :tmp_dir
    test "killing the only buffer falls back to scratch", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "solo.txt")
      File.write!(path, "alone")

      ctx = start_editor("alone", file_path: path)
      send_keys(ctx, "<SPC>bd")

      # Should show scratch buffer as fallback
      row0 = screen_row(ctx, 0)
      assert String.contains?(row0, ";;") or String.contains?(row0, "Minga")
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
      send_keys(ctx, "<SPC>bp")
      assert_row_contains(ctx, 0, "papa")

      send_keys(ctx, "<SPC>bd")
      assert_row_contains(ctx, 0, "quebec")
      ml = modeline(ctx)
      refute String.contains?(ml, "[")
    end
  end

  describe "modeline buffer indicator" do
    @tag :tmp_dir
    test "shows [N/M] when multiple buffers are open", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "m1.txt")
      path2 = Path.join(tmp_dir, "m2.txt")
      File.write!(path1, "one")
      File.write!(path2, "two")

      ctx = start_editor("one", file_path: path1)
      ml = modeline(ctx)
      refute String.contains?(ml, "[1/")

      send_keys(ctx, ":e #{path2}<CR>")
      assert_modeline_contains(ctx, "[2/2]")

      send_keys(ctx, "<SPC>bp")
      assert_modeline_contains(ctx, "[1/2]")
    end
  end

  describe "SPC b s — switch to scratch" do
    test "SPC b s shows scratch buffer" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bs")
      assert_row_contains(ctx, 0, ";; This buffer is for notes")
    end

    test "scratch buffer is editable" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bs")
      send_keys(ctx, "ggIedited: <Esc>")
      assert_row_contains(ctx, 0, "edited:")
    end
  end

  describe ":new — new empty buffer" do
    test "creates a new unnamed buffer" do
      ctx = start_editor("hello")
      send_keys(ctx, ":new<CR>")

      # Should show empty buffer with [new 1] name
      assert_modeline_contains(ctx, "[new 1]")
    end

    test "successive :new increments the number" do
      ctx = start_editor("hello")
      send_keys(ctx, ":new<CR>")
      assert_modeline_contains(ctx, "[new 1]")

      send_keys(ctx, ":new<CR>")
      assert_modeline_contains(ctx, "[new 2]")
    end

    test "new buffer is editable" do
      ctx = start_editor("hello")
      send_keys(ctx, ":new<CR>")
      send_keys(ctx, "isome text<Esc>")
      assert_row_contains(ctx, 0, "some text")
    end
  end

  describe "SPC b N — new buffer via leader" do
    test "creates a new buffer" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bN")
      assert_modeline_contains(ctx, "[new 1]")
    end
  end
end
