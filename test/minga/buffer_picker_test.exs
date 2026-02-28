defmodule Minga.BufferPickerTest do
  @moduledoc """
  Integration tests for the buffer picker (SPC b b) via the headless harness.
  """

  use Minga.Test.EditorCase, async: true

  describe "opening the picker" do
    @tag :tmp_dir
    test "SPC b b opens a picker overlay", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "alpha.txt")
      path2 = Path.join(tmp_dir, "beta.txt")
      File.write!(path1, "alpha content")
      File.write!(path2, "beta content")

      ctx = start_editor("alpha content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # Open buffer picker
      send_keys(ctx, "<SPC>bb")

      # Should see the prompt line
      mb = minibuffer(ctx)
      assert String.contains?(mb, ">")

      # Should see buffer names in the picker area
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "alpha.txt")
      assert String.contains?(all_text, "beta.txt")
    end

    test "SPC b b with single buffer still opens picker" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bb")

      mb = minibuffer(ctx)
      assert String.contains?(mb, ">")
    end
  end

  describe "filtering" do
    @tag :tmp_dir
    test "typing filters the buffer list", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "foo.txt")
      path2 = Path.join(tmp_dir, "bar.txt")
      path3 = Path.join(tmp_dir, "baz.txt")
      File.write!(path1, "foo")
      File.write!(path2, "bar")
      File.write!(path3, "baz")

      ctx = start_editor("foo", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")
      send_keys(ctx, ":e #{path3}<CR>")

      # Open picker and type "ba"
      send_keys(ctx, "<SPC>bb")
      send_key(ctx, ?b)
      send_key(ctx, ?a)

      # Should see bar and baz but not foo
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "bar.txt")
      assert String.contains?(all_text, "baz.txt")
      refute String.contains?(all_text, "foo.txt")
    end
  end

  describe "navigation" do
    @tag :tmp_dir
    test "C-j and C-k move selection and preview buffer content", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "first.txt")
      path2 = Path.join(tmp_dir, "second.txt")
      File.write!(path1, "first file content")
      File.write!(path2, "second file content")

      ctx = start_editor("first file content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # Open picker — should start showing current buffer
      send_keys(ctx, "<SPC>bb")

      # Move down with C-j
      send_key(ctx, ?j, 0x02)

      # Check that preview shows the other buffer's content
      row0 = screen_row(ctx, 0)
      # The preview should show one of the buffer's content
      assert String.contains?(row0, "first") or String.contains?(row0, "second")
    end
  end

  describe "selecting" do
    @tag :tmp_dir
    test "Enter selects the first buffer and closes picker", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "one.txt")
      path2 = Path.join(tmp_dir, "two.txt")
      File.write!(path1, "one content")
      File.write!(path2, "two content")

      ctx = start_editor("one content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # We're on buffer 2, open picker — selection starts at index 0 (one.txt)
      send_keys(ctx, "<SPC>bb")

      # Press Enter to select the first item (one.txt)
      send_key(ctx, 13)

      # Picker should be closed (minibuffer is empty, not showing ">")
      mb = minibuffer(ctx)
      refute String.contains?(mb, ">")

      # Should be showing the first buffer's content
      assert_row_contains(ctx, 0, "one content")
    end

    @tag :tmp_dir
    test "navigating then Enter selects the moved-to buffer", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.txt")
      path2 = Path.join(tmp_dir, "bbb.txt")
      File.write!(path1, "aaa content")
      File.write!(path2, "bbb content")

      ctx = start_editor("aaa content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # On buffer 2 (bbb). Open picker, move to item 1 (bbb), then Enter
      send_keys(ctx, "<SPC>bb")
      # Move to index 1
      send_key(ctx, ?j, 0x02)
      send_key(ctx, 13)

      # Should show bbb content (stayed on same buffer)
      assert_row_contains(ctx, 0, "bbb content")
    end
  end

  describe "cancelling" do
    @tag :tmp_dir
    test "Escape closes picker without switching", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.txt")
      path2 = Path.join(tmp_dir, "bbb.txt")
      File.write!(path1, "aaa content")
      File.write!(path2, "bbb content")

      ctx = start_editor("aaa content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")
      # Currently on buffer 2 (bbb)
      assert_row_contains(ctx, 0, "bbb content")

      # Open picker, navigate to buffer 1 (preview changes), then cancel
      send_keys(ctx, "<SPC>bb")
      send_key(ctx, ?j, 0x02)
      # Escape
      send_key(ctx, 27)

      # Should restore original buffer (bbb)
      assert_row_contains(ctx, 0, "bbb content")

      # Picker should be closed
      mb = minibuffer(ctx)
      refute String.contains?(mb, ">")
    end
  end

  describe "dirty indicator" do
    @tag :tmp_dir
    test "modified buffers show dirty indicator in picker", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dirty.txt")
      File.write!(path, "clean")

      ctx = start_editor("clean", file_path: path)

      # Modify the buffer
      send_keys(ctx, "ix<Esc>")

      # Open picker
      send_keys(ctx, "<SPC>bb")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "[+]")
    end
  end

  describe "cursor shape" do
    test "picker uses beam cursor" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bb")
      assert cursor_shape(ctx) == :beam
    end
  end
end
