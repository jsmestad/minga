defmodule MingaAgent.Tools.ListDirectoryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.ListDirectory

  @moduletag :tmp_dir

  describe "execute/1" do
    test "lists files and directories", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "")
      File.mkdir_p!(Path.join(dir, "subdir"))

      assert {:ok, listing} = ListDirectory.execute(dir)
      lines = String.split(listing, "\n")

      assert "subdir/" in lines
      assert "file.txt" in lines
    end

    test "directories come before files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "aaa.txt"), "")
      File.mkdir_p!(Path.join(dir, "zzz_dir"))

      assert {:ok, listing} = ListDirectory.execute(dir)
      lines = String.split(listing, "\n")

      dir_index = Enum.find_index(lines, &(&1 == "zzz_dir/"))
      file_index = Enum.find_index(lines, &(&1 == "aaa.txt"))
      assert dir_index < file_index
    end

    test "includes hidden files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".hidden"), "")
      File.write!(Path.join(dir, "visible.txt"), "")

      assert {:ok, listing} = ListDirectory.execute(dir)
      assert listing =~ ".hidden"
    end

    test "returns error for nonexistent directory" do
      assert {:error, msg} = ListDirectory.execute("/nonexistent/dir")
      assert msg =~ "directory not found"
    end

    test "returns error when path is a file", %{tmp_dir: dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "")

      assert {:error, msg} = ListDirectory.execute(path)
      assert msg =~ "is a file"
    end

    test "handles empty directories", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty")
      File.mkdir_p!(empty)

      assert {:ok, ""} = ListDirectory.execute(empty)
    end
  end
end
