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

    test "omits generated and dependency directories that bloat agent context", %{tmp_dir: dir} do
      for ignored <- [
            "_build",
            ".build",
            ".git",
            ".elixir_ls",
            ".expert",
            "deps",
            "node_modules",
            "DerivedData",
            "tmp"
          ] do
        File.mkdir_p!(Path.join(dir, ignored))
      end

      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, ".env"), "")
      File.write!(Path.join(dir, ".hidden"), "")

      assert {:ok, listing} = ListDirectory.execute(dir)
      lines = String.split(listing, "\n")

      assert "lib/" in lines
      assert ".hidden" in lines
      refute ".env" in lines

      for ignored <- [
            "_build/",
            ".build/",
            ".git/",
            ".elixir_ls/",
            ".expert/",
            "deps/",
            "node_modules/",
            "DerivedData/",
            "tmp/"
          ] do
        refute ignored in lines
      end
    end

    test "caps large directory listings", %{tmp_dir: dir} do
      for index <- 1..205 do
        File.write!(Path.join(dir, "file_#{index}.txt"), "")
      end

      assert {:ok, listing} = ListDirectory.execute(dir)
      lines = String.split(listing, "\n")

      assert length(lines) == 201
      assert List.last(lines) == "... (truncated, 5 more entries)"
    end

    test "omits entries ignored by project gitignore", %{tmp_dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\nignored_file.txt\n")
      File.mkdir_p!(Path.join(dir, "ignored_dir"))
      File.write!(Path.join(dir, "ignored_file.txt"), "")
      File.mkdir_p!(Path.join(dir, "visible_dir"))
      File.write!(Path.join(dir, "visible_file.txt"), "")

      assert {:ok, listing} = ListDirectory.execute(dir)
      lines = String.split(listing, "\n")

      assert "visible_dir/" in lines
      assert "visible_file.txt" in lines
      refute "ignored_dir/" in lines
      refute "ignored_file.txt" in lines
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
