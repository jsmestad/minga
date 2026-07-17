defmodule Minga.Project.FileFindTest do
  # This suite spawns git and file-discovery OS processes, which cannot run concurrently safely.
  use ExUnit.Case, async: false

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

    test "rejects broad roots without literal current-flow confirmation", %{tmp_dir: tmp_dir} do
      assert {:error, :broad_root_confirmation_required} = Root.directory(Path.expand("~"))
      assert {:error, :broad_root_confirmation_required} = Root.directory("/")

      assert {:error, :invalid_broad_root_confirmation} =
               Root.directory(tmp_dir, broad_root_confirmed: nil)

      unauthorized_root = %Root{kind: :directory, path: "/", broad_root_confirmed?: nil}
      assert {:error, error} = FileFind.list_files(unauthorized_root)
      assert error =~ "confirmation must be true or false"

      assert {:ok, confirmed_root} = Root.directory("/", broad_root_confirmed: true)
      assert Root.inventory_path(confirmed_root) == {:ok, "/"}
      assert Root.broad_path?("/Volumes/External")
      assert Root.broad_path?("/mnt/external")
    end

    test "canonicalizes directory symlinks before broad-root authorization", %{tmp_dir: tmp_dir} do
      broad_alias = Path.join(tmp_dir, "broad-alias")
      safe_target = Path.join(tmp_dir, "safe-target")
      safe_alias = Path.join(tmp_dir, "safe-alias")
      File.mkdir_p!(safe_target)
      File.ln_s!("/", broad_alias)
      File.ln_s!(safe_target, safe_alias)

      assert {:error, :broad_root_confirmation_required} = Root.directory(broad_alias)
      assert {:ok, %Root{path: ^safe_target}} = Root.directory(safe_alias)
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

  describe "Root.resolve_file/2" do
    setup do
      tmp_dir = make_tmp_dir("minga_root_resolve_file")
      File.write!(Path.join(tmp_dir, "inside.txt"), "inside")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, root: directory_root!(tmp_dir)}
    end

    test "returns the canonical target for an authorized workspace-relative file", %{
      tmp_dir: tmp_dir,
      root: root
    } do
      assert Root.resolve_file(root, "inside.txt") ==
               {:ok, Path.join(tmp_dir, "inside.txt")}
    end

    test "returns the canonical target of an in-workspace symlink", %{
      tmp_dir: tmp_dir,
      root: root
    } do
      File.ln_s!("inside.txt", Path.join(tmp_dir, "inside-link.txt"))

      assert Root.resolve_file(root, "inside-link.txt") ==
               {:ok, Path.join(tmp_dir, "inside.txt")}
    end

    test "returns the filesystem error when the target is missing", %{root: root} do
      assert Root.resolve_file(root, "missing.txt") == {:error, :enoent}
    end

    test "accepts an existing file beneath a literally confirmed broad root", %{tmp_dir: tmp_dir} do
      {:ok, root} = Root.directory("/", broad_root_confirmed: true)
      relative_path = Path.relative_to(tmp_dir, "/") |> Path.join("inside.txt")
      {:ok, canonical_target} = Root.canonical_path(Path.join(tmp_dir, "inside.txt"))

      assert Root.resolve_file(root, relative_path) == {:ok, canonical_target}
    end

    test "rejects absolute paths and parent traversal before joining", %{
      tmp_dir: tmp_dir,
      root: root
    } do
      assert Root.resolve_file(root, Path.join(tmp_dir, "inside.txt")) ==
               {:error, :absolute_path}

      assert Root.resolve_file(root, "../outside.txt") == {:error, :parent_traversal}
      assert Root.resolve_file(root, "lib/../inside.txt") == {:error, :parent_traversal}

      assert Root.resolve_file(root, "../#{Path.basename(tmp_dir)}/inside.txt") ==
               {:error, :parent_traversal}
    end

    test "rejects a symlink whose canonical target escapes the workspace", %{
      tmp_dir: tmp_dir,
      root: root
    } do
      outside = Path.join(Path.dirname(tmp_dir), "outside-#{System.unique_integer([:positive])}")
      File.write!(outside, "outside")
      File.ln_s!(outside, Path.join(tmp_dir, "escape.txt"))
      on_exit(fn -> File.rm(outside) end)

      assert Root.resolve_file(root, "escape.txt") == {:error, :outside_workspace}
    end

    test "reuses inventory authorization for broad and non-directory roots", %{tmp_dir: tmp_dir} do
      {:ok, confirmed_home} = Root.directory(Path.expand("~"), broad_root_confirmed: true)

      unauthorized_home = %Root{
        kind: :directory,
        path: confirmed_home.path,
        broad_root_confirmed?: false
      }

      assert Root.resolve_file(unauthorized_home, "anything") ==
               {:error, :broad_root_confirmation_required}

      assert Root.resolve_file(Root.file(Path.join(tmp_dir, "inside.txt")), "inside.txt") ==
               {:error, :not_a_directory_root}
    end

    test "rejects a root whose canonical target changed after authorization", %{
      tmp_dir: tmp_dir,
      root: root
    } do
      original_workspace = Path.join(Path.dirname(tmp_dir), "original-#{Path.basename(tmp_dir)}")
      replacement = Path.join(Path.dirname(tmp_dir), "replacement-#{Path.basename(tmp_dir)}")

      File.rename!(tmp_dir, original_workspace)
      File.mkdir_p!(replacement)
      File.ln_s!(replacement, tmp_dir)

      on_exit(fn ->
        File.rm(tmp_dir)
        File.rm_rf!(original_workspace)
        File.rm_rf!(replacement)
      end)

      assert Root.resolve_file(root, "inside.txt") == {:error, :root_changed}
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
