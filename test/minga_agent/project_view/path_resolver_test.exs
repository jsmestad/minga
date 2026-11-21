defmodule MingaAgent.ProjectView.PathResolverTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView.PathResolver

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(Path.expand(dir), "project")
    File.mkdir_p!(root)
    %{root: root}
  end

  describe "logical_path/2" do
    test "relative paths are already logical and pass through unchanged", %{root: root} do
      assert PathResolver.logical_path(root, "notes.md") == {:ok, "notes.md"}
      assert PathResolver.logical_path(root, "lib/a.ex") == {:ok, "lib/a.ex"}
    end

    test "an absolute path inside the root becomes root-relative", %{root: root} do
      assert PathResolver.logical_path(root, Path.join(root, "notes.md")) == {:ok, "notes.md"}
      assert PathResolver.logical_path(root, Path.join(root, "lib/a.ex")) == {:ok, "lib/a.ex"}
    end

    test "the root itself maps to the logical root", %{root: root} do
      assert PathResolver.logical_path(root, root) == {:ok, "."}
      assert PathResolver.logical_path(root, root <> "/") == {:ok, "."}
    end

    test "an absolute path outside the root is rejected", %{root: root} do
      assert PathResolver.logical_path(root, "/etc/passwd") == {:error, :path_traversal}
    end

    test "a sibling directory sharing the root's name prefix is outside the root", %{root: root} do
      assert PathResolver.logical_path(root, root <> "-other/notes.md") ==
               {:error, :path_traversal}
    end

    test "an absolute path under a different agent root is rejected, never joined under the root",
         %{root: root, tmp_dir: dir} do
      launch_dir = Path.join(Path.expand(dir), "launch")
      File.mkdir_p!(launch_dir)

      assert PathResolver.logical_path(root, Path.join(launch_dir, "notes.md")) ==
               {:error, :path_traversal}
    end

    test "an absolute path that escapes the root through .. is rejected", %{root: root} do
      assert PathResolver.logical_path(root, Path.join(root, "../outside.md")) ==
               {:error, :path_traversal}

      assert PathResolver.logical_path(root, Path.join(root, "lib/../notes.md")) ==
               {:ok, "notes.md"}
    end

    test "a symlink-resolved path matches a root written through a symlink", %{
      root: root,
      tmp_dir: dir
    } do
      link = Path.join(Path.expand(dir), "project-link")
      File.ln_s!(root, link)

      assert PathResolver.logical_path(link, Path.join(root, "notes.md")) == {:ok, "notes.md"}
      assert PathResolver.logical_path(link, Path.join(link, "notes.md")) == {:ok, "notes.md"}
    end
  end
end
