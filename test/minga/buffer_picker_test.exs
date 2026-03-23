defmodule Minga.BufferPickerTest do
  @moduledoc """
  Tests for the buffer picker (SPC b b).

  Most assertions are state-based (picker open, item count, selected item,
  active buffer content). Screen assertions are kept only for rendering
  verification that can't be checked via state (snapshot baselines).
  """

  use Minga.Test.EditorCase, async: true

  # EditorCase full-stack overhead (GenServer + HeadlessPort + buffers, ~300-500ms).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  describe "opening the picker" do
    @tag :tmp_dir
    test "SPC b b opens a picker with buffer items", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "alpha.txt")
      path2 = Path.join(tmp_dir, "beta.txt")
      File.write!(path1, "alpha content")
      File.write!(path2, "beta content")

      ctx = start_editor("alpha content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      send_keys_sync(ctx, "<SPC>bb")

      assert picker_open?(ctx)
      picker = picker_state(ctx)
      labels = Enum.map(picker.items, & &1.label)
      assert Enum.any?(labels, &String.contains?(&1, "alpha.txt"))
      assert Enum.any?(labels, &String.contains?(&1, "beta.txt"))
    end

    test "SPC b b with single buffer still opens picker" do
      ctx = start_editor("hello")
      send_keys_sync(ctx, "<SPC>bb")
      assert picker_open?(ctx)
    end
  end

  describe "filtering" do
    @tag :tmp_dir
    test "typing filters the buffer list", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "xylo.txt")
      path2 = Path.join(tmp_dir, "zap.txt")
      path3 = Path.join(tmp_dir, "zen.txt")
      File.write!(path1, "xylo")
      File.write!(path2, "zap")
      File.write!(path3, "zen")

      ctx = start_editor("xylo", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")
      send_keys(ctx, ":e #{path3}<CR>")

      send_keys_sync(ctx, "<SPC>bb")
      send_key_sync(ctx, ?z)
      send_key_sync(ctx, ?e)

      picker = picker_state(ctx)
      filtered_labels = Enum.map(picker.filtered, & &1.label)
      assert Enum.any?(filtered_labels, &String.contains?(&1, "zen.txt"))
      refute Enum.any?(filtered_labels, &String.contains?(&1, "xylo.txt"))
    end
  end

  describe "navigation" do
    @tag :tmp_dir
    test "pressing C-j advances the selection index", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "first.txt")
      path2 = Path.join(tmp_dir, "second.txt")
      File.write!(path1, "first file content")
      File.write!(path2, "second file content")

      ctx = start_editor("first file content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      send_keys_sync(ctx, "<SPC>bb")
      idx_before = picker_state(ctx).selected

      send_key_sync(ctx, ?j, 0x02)
      idx_after = picker_state(ctx).selected

      assert idx_after > idx_before
    end

    @tag :tmp_dir
    test "pressing C-k retreats the selection index", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "first.txt")
      path2 = Path.join(tmp_dir, "second.txt")
      File.write!(path1, "first file content")
      File.write!(path2, "second file content")

      ctx = start_editor("first file content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      send_keys_sync(ctx, "<SPC>bb")

      # Move down first, then back up
      send_key_sync(ctx, ?j, 0x02)
      idx_down = picker_state(ctx).selected

      send_key_sync(ctx, ?k, 0x02)
      idx_up = picker_state(ctx).selected

      assert idx_up < idx_down
    end
  end

  describe "selecting" do
    @tag :tmp_dir
    test "Enter selects the buffer and closes picker", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "one.txt")
      path2 = Path.join(tmp_dir, "two.txt")
      File.write!(path1, "one content")
      File.write!(path2, "two content")

      ctx = start_editor("one content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      # On buffer 2 (two), open picker, select first item (one)
      send_keys_sync(ctx, "<SPC>bb")
      assert picker_open?(ctx)

      send_key_sync(ctx, 13)
      refute picker_open?(ctx)
      assert active_content(ctx) == "one content"
    end

    @tag :tmp_dir
    test "filtering then Enter selects the filtered item", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.txt")
      path2 = Path.join(tmp_dir, "bbb.txt")
      File.write!(path1, "aaa content")
      File.write!(path2, "bbb content")

      ctx = start_editor("aaa content", file_path: path1)
      send_keys(ctx, ":e #{path2}<CR>")

      send_keys_sync(ctx, "<SPC>bb")
      # Filter to just "bbb"
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, ?b)
      send_key_sync(ctx, 13)

      refute picker_open?(ctx)
      assert active_content(ctx) == "bbb content"
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
      assert active_content(ctx) == "bbb content"

      send_keys_sync(ctx, "<SPC>bb")
      assert picker_open?(ctx)

      send_key_sync(ctx, 27)
      refute picker_open?(ctx)
      assert active_content(ctx) == "bbb content"
    end
  end

  describe "dirty indicator" do
    @tag :tmp_dir
    test "modified buffers show [+] in picker item label", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dirty.txt")
      File.write!(path, "clean")

      ctx = start_editor("clean", file_path: path)

      # Modify the buffer
      send_keys_sync(ctx, "ix<Esc>")

      # Open picker and check item labels for dirty marker
      send_keys_sync(ctx, "<SPC>bb")
      assert picker_open?(ctx)

      picker = picker_state(ctx)
      labels = Enum.map(picker.items, & &1.label)

      assert Enum.any?(labels, &String.contains?(&1, "[+]")),
             "Expected [+] dirty indicator in picker item labels, got: #{inspect(labels)}"
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
