defmodule Minga.Test.SnapshotTest do
  use ExUnit.Case, async: true

  alias Minga.Test.Snapshot

  @base_metadata %{
    cursor: {1, 3},
    cursor_shape: :block,
    mode: :normal,
    width: 40,
    height: 5
  }

  describe "serialize/2" do
    test "produces header with cursor position, shape, mode, and dimensions" do
      rows = ["hello", "world", "", "", ""]
      result = Snapshot.serialize(rows, @base_metadata)

      assert result =~ "# Screen: 40x5"
      assert result =~ "# Cursor: (1, 3) block"
      assert result =~ "# Mode: normal"
    end

    test "includes row content with 2-digit indices" do
      rows = ["hello", "world", "third", "", ""]
      result = Snapshot.serialize(rows, @base_metadata)

      assert result =~ "00│hello"
      assert result =~ "01│world"
      assert result =~ "02│third"
    end

    test "includes separator lines" do
      rows = ["a", "b", "c", "d", "e"]
      result = Snapshot.serialize(rows, @base_metadata)

      separator = String.duplicate("─", 40)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 3) == separator
      assert Enum.at(lines, 9) == separator
    end

    test "handles empty rows" do
      rows = ["", "", "", "", ""]
      result = Snapshot.serialize(rows, @base_metadata)

      assert result =~ "00│"
      assert result =~ "04│"
    end

    test "handles unicode content" do
      rows = ["héllo wörld", "日本語", "", "", ""]
      result = Snapshot.serialize(rows, @base_metadata)

      assert result =~ "00│héllo wörld"
      assert result =~ "01│日本語"
    end

    test "uses insert mode and beam cursor shape" do
      metadata = %{@base_metadata | mode: :insert, cursor_shape: :beam}
      rows = ["test", "", "", "", ""]
      result = Snapshot.serialize(rows, metadata)

      assert result =~ "# Cursor: (1, 3) beam"
      assert result =~ "# Mode: insert"
    end

    test "cursor at origin" do
      metadata = %{@base_metadata | cursor: {0, 0}}
      rows = ["test", "", "", "", ""]
      result = Snapshot.serialize(rows, metadata)

      assert result =~ "# Cursor: (0, 0) block"
    end
  end

  describe "compare/2" do
    @tag :tmp_dir
    test "returns :match when content is identical", %{tmp_dir: dir} do
      path = Path.join(dir, "baseline.snap")
      content = "# Screen: 40x5\ntest content"
      File.write!(path, content)

      assert :match = Snapshot.compare(content, path)
    end

    @tag :tmp_dir
    test "returns {:mismatch, diff} when content differs", %{tmp_dir: dir} do
      path = Path.join(dir, "baseline.snap")
      File.write!(path, "line one\nline two\nline three")

      {:mismatch, diff} = Snapshot.compare("line one\nline CHANGED\nline three", path)

      assert diff =~ "- line two"
      assert diff =~ "+ line CHANGED"
    end

    @tag :tmp_dir
    test "ignores volatile modeline indicators in stored baselines and current output", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "baseline.snap")

      baseline = """
      # Screen: 80x24
      # Cursor: (1, 8) block
      # Mode: normal
      ────────────────────────────────────────────────────────────────────────────────
      22│NORMAL  [no file] ●                                            Text  1:4  Top
      ────────────────────────────────────────────────────────────────────────────────
      """

      current = """
      # Screen: 80x24
      # Cursor: (1, 8) block
      # Mode: normal
      ────────────────────────────────────────────────────────────────────────────────
      22│NORMAL  [no file] ●   ◯                                        Text  1:4  Top
      ────────────────────────────────────────────────────────────────────────────────
      """

      File.write!(path, baseline)

      assert :match = Snapshot.compare(current, path)
    end

    test "returns {:no_baseline, path} when file does not exist" do
      path = "/tmp/nonexistent_snapshot_#{System.unique_integer([:positive])}.snap"
      assert {:no_baseline, ^path} = Snapshot.compare("content", path)
    end

    @tag :tmp_dir
    test "diff shows unchanged lines without markers", %{tmp_dir: dir} do
      path = Path.join(dir, "baseline.snap")
      File.write!(path, "same\ndifferent\nsame")

      {:mismatch, diff} = Snapshot.compare("same\nchanged\nsame", path)

      lines = String.split(diff, "\n")
      assert Enum.at(lines, 0) == "  same"
      assert Enum.at(lines, 1) == "- different"
      assert Enum.at(lines, 2) == "+ changed"
      assert Enum.at(lines, 3) == "  same"
    end

    @tag :tmp_dir
    test "diff handles different line counts", %{tmp_dir: dir} do
      path = Path.join(dir, "baseline.snap")
      File.write!(path, "a\nb")

      {:mismatch, diff} = Snapshot.compare("a\nb\nc", path)

      assert diff =~ "+ c"
    end
  end

  describe "snapshot_path/2" do
    test "maps module and name to file path" do
      path = Snapshot.snapshot_path(Minga.IntegrationTest, "navigate_hjkl")

      assert path == "test/snapshots/minga/integration_test/navigate_hjkl.snap"
    end

    test "handles nested modules" do
      path = Snapshot.snapshot_path(MingaEditor.PickerUITest, "after_open")

      assert path == "test/snapshots/minga_editor/picker_ui_test/after_open.snap"
    end

    test "handles top-level module" do
      path = Snapshot.snapshot_path(SomeTest, "basic")

      assert path == "test/snapshots/some_test/basic.snap"
    end
  end

  describe "update_mode?/0" do
    test "returns false when env var is not set" do
      System.delete_env("UPDATE_SNAPSHOTS")
      refute Snapshot.update_mode?()
    end

    test "returns true when env var is set" do
      System.put_env("UPDATE_SNAPSHOTS", "1")
      assert Snapshot.update_mode?()
      System.delete_env("UPDATE_SNAPSHOTS")
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes content to the path", %{tmp_dir: dir} do
      path = Path.join(dir, "test.snap")
      Snapshot.write!(path, "hello")

      assert File.read!(path) == "hello"
    end

    @tag :tmp_dir
    test "creates intermediate directories", %{tmp_dir: dir} do
      path = Path.join([dir, "deep", "nested", "dir", "test.snap"])
      Snapshot.write!(path, "nested content")

      assert File.read!(path) == "nested content"
    end
  end
end
