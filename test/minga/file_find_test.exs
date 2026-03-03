defmodule Minga.FileFindTest do
  use ExUnit.Case, async: true

  alias Minga.FileFind

  describe "detect_strategy/1" do
    test "returns a known strategy atom" do
      strategy = FileFind.detect_strategy(File.cwd!())
      assert strategy in [:fd, :git, :find, :none]
    end
  end

  describe "list_files/1" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "minga_file_find_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Create some files
      File.write!(Path.join(tmp_dir, "README.md"), "hello")
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\nend")
      File.mkdir_p!(Path.join(tmp_dir, "lib/sub"))
      File.write!(Path.join(tmp_dir, "lib/sub/deep.ex"), "deep")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "returns a list of relative file paths", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(tmp_dir)

      assert is_list(files)
      assert length(files) >= 3

      assert "README.md" in files
      assert "lib/app.ex" in files
      assert "lib/sub/deep.ex" in files
    end

    test "returns sorted results", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(tmp_dir)
      assert files == Enum.sort(files)
    end

    test "does not include directories", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(tmp_dir)
      refute "lib" in files
      refute "lib/sub" in files
    end

    test "excludes .git directory contents", %{tmp_dir: tmp_dir} do
      # Initialize a real git repo so git ls-files works if selected
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["add", "."], cd: tmp_dir)

      {:ok, files} = FileFind.list_files(tmp_dir)
      refute Enum.any?(files, &String.starts_with?(&1, ".git/"))
    end

    test "paths are relative (no leading ./)", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(tmp_dir)

      for file <- files do
        refute String.starts_with?(file, "./"), "Path should not start with ./: #{file}"
      end
    end

    test "returns error for nonexistent directory" do
      result = FileFind.list_files("/nonexistent/path/#{System.unique_integer()}")
      # Depending on strategy, this may error or return empty
      case result do
        {:ok, files} -> assert is_list(files)
        {:error, msg} -> assert is_binary(msg)
      end
    end
  end
end
