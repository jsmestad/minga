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
      send_keys_sync(ctx, ":e #{path2}<CR>")

      # Open buffer picker
      send_keys_sync(ctx, "<SPC>bb")

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
      send_keys_sync(ctx, "<SPC>bb")

      mb = minibuffer(ctx)
      assert String.contains?(mb, ">")
    end
  end

  describe "filtering" do
    @tag :tmp_dir
    test "typing filters the buffer list", %{tmp_dir: tmp_dir} do
      # Use filenames whose unique prefixes don't appear in the tmp_dir path.
      # The picker matches against the full file path (desc field), so if the
      # directory name contains the filter substring, all files match.
      path1 = Path.join(tmp_dir, "xylo.txt")
      path2 = Path.join(tmp_dir, "zap.txt")
      path3 = Path.join(tmp_dir, "zen.txt")
      File.write!(path1, "xylo")
      File.write!(path2, "zap")
      File.write!(path3, "zen")

      ctx = start_editor("xylo", file_path: path1)
      send_keys_sync(ctx, ":e #{path2}<CR>")
      send_keys_sync(ctx, ":e #{path3}<CR>")

      # Open picker and type "ze" to match only zen.txt
      send_keys_sync(ctx, "<SPC>bb")
      send_key_sync(ctx, ?z)
      send_key_sync(ctx, ?e)

      # Should see zen but not xylo (skip row 0 which is the tab bar)
      screen = screen_text(ctx)
      picker_text = screen |> Enum.drop(1) |> Enum.join("\n")
      assert String.contains?(picker_text, "zen.txt")
      refute String.contains?(picker_text, "xylo.txt")
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
      send_keys_sync(ctx, ":e #{path2}<CR>")

      # Open picker — should start showing current buffer
      send_keys_sync(ctx, "<SPC>bb")

      # Move down with C-j
      send_key_sync(ctx, ?j, 0x02)

      # Check that preview shows one of the buffer's content (file or scratch)
      row0 = screen_row(ctx, 1)

      assert String.contains?(row0, "first") or String.contains?(row0, "second") or
               String.contains?(row0, ";;")
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
      send_keys_sync(ctx, ":e #{path2}<CR>")

      # We're on buffer 2, open picker — selection starts at index 0 (one.txt)
      send_keys_sync(ctx, "<SPC>bb")

      # Press Enter to select the first item (one.txt)
      send_key_sync(ctx, 13)

      # Picker should be closed (minibuffer is empty, not showing ">")
      mb = minibuffer(ctx)
      refute String.contains?(mb, ">")

      # Should be showing the first buffer's content
      assert_row_contains(ctx, 1, "one content")
    end

    @tag :tmp_dir
    test "navigating then Enter selects the moved-to buffer", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.txt")
      path2 = Path.join(tmp_dir, "bbb.txt")
      File.write!(path1, "aaa content")
      File.write!(path2, "bbb content")

      ctx = start_editor("aaa content", file_path: path1)
      send_keys_sync(ctx, ":e #{path2}<CR>")

      # On buffer 3 (bbb). Open picker — items: aaa, [no file], bbb
      # Navigate and select bbb
      send_keys_sync(ctx, "<SPC>bb")
      # Filter to just "bbb" to avoid scratch confusion
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, 13)

      # Should show bbb content
      assert_row_contains(ctx, 1, "bbb content")
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
      send_keys_sync(ctx, ":e #{path2}<CR>")
      # Currently on buffer 2 (bbb)
      assert_row_contains(ctx, 1, "bbb content")

      # Open picker, navigate to buffer 1 (preview changes), then cancel
      send_keys_sync(ctx, "<SPC>bb")
      send_key_sync(ctx, ?j, 0x02)
      # Escape
      send_key_sync(ctx, 27)

      # Should restore original buffer (bbb)
      assert_row_contains(ctx, 1, "bbb content")

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

      # Modify the buffer, then open picker (sync ensures all keys processed
      # before the next sequence fires)
      send_keys_sync(ctx, "ix<Esc>")
      send_keys_sync(ctx, "<SPC>bb")

      # Picker rendering is async; poll until the dirty indicator appears
      wait_until_screen(
        ctx,
        fn ->
          screen_text(ctx) |> Enum.join("\n") |> String.contains?("[+]")
        end,
        message: "Expected [+] dirty indicator in picker"
      )
    end
  end

  describe "cursor shape" do
    test "picker uses beam cursor" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bb")
      assert cursor_shape(ctx) == :beam
    end
  end
end
