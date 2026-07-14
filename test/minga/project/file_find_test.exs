defmodule Minga.Project.FileFindTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileFind
  alias Minga.Project.Root

  describe "detect_strategy/1" do
    test "returns a known strategy atom" do
      strategy = FileFind.detect_strategy(File.cwd!())
      assert strategy in [:fd, :git, :find, :none]
    end

    test "prefers git inside a git work tree" do
      tmp_dir = make_tmp_dir("minga_file_find_git")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {_out, 0} = System.cmd("git", ["init"], cd: tmp_dir, stderr_to_stdout: true)

      assert FileFind.detect_strategy(tmp_dir) == :git
    end

    test "uses fd or find outside a git repo, never git" do
      tmp_dir = make_tmp_dir("minga_file_find_nongit")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      strategy = FileFind.detect_strategy(tmp_dir)
      refute strategy == :git
      assert strategy in [:fd, :find, :none]
    end
  end

  describe "fd_args/1" do
    test "does not follow symlinks" do
      refute "--follow" in FileFind.fd_args([])
    end

    test "lists hidden files of type file under the current directory" do
      args = FileFind.fd_args([])
      assert "--type" in args
      assert "f" in args
      assert "--hidden" in args
      assert Enum.at(args, -1) == "."
    end

    test "passes configured excludes as --exclude pairs" do
      args = FileFind.fd_args(["node_modules", "vendor"])
      assert chunk_pairs(args) |> Enum.member?(["--exclude", "node_modules"])
      assert chunk_pairs(args) |> Enum.member?(["--exclude", "vendor"])
    end
  end

  describe "list_files/1" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "minga_file_find_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "hello")
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\nend")
      File.mkdir_p!(Path.join(tmp_dir, "lib/sub"))
      File.write!(Path.join(tmp_dir, "lib/sub/deep.ex"), "deep")

      {:ok, options_server} = start_supervised({Minga.Config.Options, name: nil})
      Process.put(:minga_config_options, options_server)

      on_exit(fn ->
        Process.delete(:minga_config_options)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, options_server: options_server}
    end

    test "returns a list of relative file paths", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))
      assert is_list(files)
      assert Enum.count(files) >= 3
      assert "README.md" in files
      assert "lib/app.ex" in files
      assert "lib/sub/deep.ex" in files
    end

    test "returns sorted results", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))
      assert files == Enum.sort(files)
    end

    test "does not include directories", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))
      refute "lib" in files
      refute "lib/sub" in files
    end

    test "paths are relative (no leading ./)", %{tmp_dir: tmp_dir} do
      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))

      for file <- files do
        refute String.starts_with?(file, "./"), "Path should not start with ./: #{file}"
      end
    end

    test "rejects raw paths and file roots at the inventory boundary", %{tmp_dir: tmp_dir} do
      assert {:error, raw_error} = FileFind.list_files(tmp_dir)
      assert raw_error =~ "explicit directory workspace root"

      assert {:error, file_error} =
               FileFind.list_files(Root.file(Path.join(tmp_dir, "README.md")))

      assert file_error =~ "explicit directory workspace root"
    end

    test "rejects broad roots without current-flow confirmation" do
      assert {:error, :broad_root_confirmation_required} = Root.directory(Path.expand("~"))
      assert {:error, :broad_root_confirmation_required} = Root.directory("/")
      assert {:ok, confirmed_root} = Root.directory("/", broad_root_confirmed: true)
      assert Root.inventory_path(confirmed_root) == {:ok, "/"}
      assert Root.broad_path?("/Volumes/External")
      assert Root.broad_path?("/mnt/external")
    end

    test "excludes directories listed in file_find_excludes", %{
      tmp_dir: tmp_dir,
      options_server: options_server
    } do
      File.mkdir_p!(Path.join(tmp_dir, "node_modules/pkg"))
      File.write!(Path.join(tmp_dir, "node_modules/pkg/index.js"), "module.exports = {}")
      File.mkdir_p!(Path.join(tmp_dir, "vendor/lib"))
      File.write!(Path.join(tmp_dir, "vendor/lib/dep.ex"), "defmodule Dep do\nend")

      Minga.Config.Options.set(
        options_server,
        :file_find_excludes,
        ["node_modules", "vendor"]
      )

      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))

      refute Enum.any?(files, &String.starts_with?(&1, "node_modules/"))
      refute Enum.any?(files, &String.starts_with?(&1, "vendor/"))
      assert "README.md" in files
      assert "lib/app.ex" in files
    end

    test "excludes file names listed in file_find_excludes", %{
      tmp_dir: tmp_dir,
      options_server: options_server
    } do
      File.write!(Path.join(tmp_dir, ".DS_Store"), "")
      File.write!(Path.join(tmp_dir, "lib/.DS_Store"), "")

      Minga.Config.Options.set(
        options_server,
        :file_find_excludes,
        [".DS_Store"]
      )

      {:ok, files} = FileFind.list_files(directory_root!(tmp_dir))

      refute ".DS_Store" in files
      refute "lib/.DS_Store" in files
      assert "README.md" in files
    end
  end

  @spec directory_root!(String.t()) :: Root.t()
  defp directory_root!(path) do
    {:ok, root} = Root.directory(path)
    root
  end

  defp make_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp chunk_pairs(args), do: Enum.chunk_every(args, 2, 1, :discard)
end
