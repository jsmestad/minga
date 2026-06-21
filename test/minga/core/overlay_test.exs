defmodule Minga.Core.OverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Overlay

  setup do
    dir = Path.join(System.tmp_dir!(), "overlay-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.txt"), "original")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/foo.ex"), "defmodule Foo do\nend")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{project: dir}
  end

  describe "create/1" do
    test "creates an empty lazy overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert File.dir?(overlay.overlay_dir)
      refute File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
      refute File.exists?(Path.join(overlay.overlay_dir, "lib/foo.ex"))

      Overlay.cleanup(overlay)
    end

    test "does not copy generated and cache directories", %{project: project} do
      for dir <- [
            "_build/dev",
            ".git/objects",
            ".elixir_ls",
            ".expert",
            ".zig-cache",
            "zig/.zig-cache",
            "node_modules/pkg",
            ".hex/cache"
          ] do
        File.mkdir_p!(Path.join(project, dir))
        File.write!(Path.join([project, dir, "cache.bin"]), "cache")
      end

      {:ok, overlay} = Overlay.create(project)

      for dir <- [
            "_build",
            ".git",
            ".elixir_ls",
            ".expert",
            ".zig-cache",
            "zig",
            "node_modules",
            ".hex"
          ] do
        refute File.exists?(Path.join(overlay.overlay_dir, dir))
      end

      Overlay.cleanup(overlay)
    end

    test "returns error for non-existent project root" do
      bogus = Path.join(System.tmp_dir!(), "nonexistent-#{System.unique_integer([:positive])}")

      assert {:error, {:invalid_project_root, ^bogus}} = Overlay.create(bogus)
    end
  end

  describe "materialize_project/1" do
    test "copies source files only when command execution needs a writable view", %{
      project: project
    } do
      {:ok, overlay} = Overlay.create(project)

      assert {:ok, %{copied_files: copied_files, copied_bytes: copied_bytes}} =
               Overlay.materialize_project(overlay)

      assert copied_files >= 2
      assert copied_bytes > 0
      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "original"
      assert File.exists?(Path.join(overlay.overlay_dir, "lib/foo.ex"))

      Overlay.cleanup(overlay)
    end

    test "skips cache directories during command materialization", %{project: project} do
      File.mkdir_p!(Path.join(project, "_build/dev"))
      File.write!(Path.join(project, "_build/dev/compiled.beam"), "beam")
      File.mkdir_p!(Path.join(project, ".expert"))
      File.write!(Path.join(project, ".expert/index"), "index")
      File.mkdir_p!(Path.join(project, "zig/.zig-cache"))
      File.write!(Path.join(project, "zig/.zig-cache/cache.bin"), "cache")
      File.mkdir_p!(Path.join(project, "deps/some_dep/lib"))
      File.write!(Path.join(project, "deps/some_dep/lib/real.ex"), "dep")

      {:ok, overlay} = Overlay.create(project)
      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      refute File.exists?(Path.join(overlay.overlay_dir, "_build"))
      refute File.exists?(Path.join(overlay.overlay_dir, ".expert"))
      assert File.dir?(Path.join(overlay.overlay_dir, "zig"))
      refute File.exists?(Path.join(overlay.overlay_dir, "zig/.zig-cache"))
      refute File.exists?(Path.join(overlay.overlay_dir, "deps"))

      Overlay.cleanup(overlay)
    end

    test "keeps materialized edits and tombstones over project files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "hello.txt", "changed")
      :ok = Overlay.delete_file(overlay, "lib/foo.ex")
      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "changed"
      refute File.exists?(Path.join(overlay.overlay_dir, "lib/foo.ex"))
      assert File.read!(Path.join(project, "hello.txt")) == "original"

      Overlay.cleanup(overlay)
    end

    test "rejects overlay directory symlinks before materializing", %{project: project} do
      outside =
        Path.join(System.tmp_dir!(), "overlay-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      {:ok, overlay} = Overlay.create(project)
      File.ln_s!(outside, Path.join(overlay.overlay_dir, "lib"))

      assert {:error, :symlink_traversal} = Overlay.materialize_project(overlay)
      refute File.exists?(Path.join(outside, "foo.ex"))

      Overlay.cleanup(overlay)
      File.rm_rf!(outside)
    end

    test "rejects overlay file symlinks before materializing", %{project: project} do
      outside =
        Path.join(System.tmp_dir!(), "overlay-outside-#{System.unique_integer([:positive])}.txt")

      {:ok, overlay} = Overlay.create(project)
      File.ln_s!(outside, Path.join(overlay.overlay_dir, "hello.txt"))

      assert {:error, :symlink_traversal} = Overlay.materialize_project(overlay)
      refute File.exists?(outside)

      Overlay.cleanup(overlay)
    end

    test "rejects overlay file symlinks to existing targets", %{project: project} do
      outside =
        Path.join(System.tmp_dir!(), "overlay-outside-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "outside")
      {:ok, overlay} = Overlay.create(project)
      File.ln_s!(outside, Path.join(overlay.overlay_dir, "hello.txt"))

      assert {:error, :symlink_traversal} = Overlay.materialize_project(overlay)
      assert File.read!(outside) == "outside"

      Overlay.cleanup(overlay)
      File.rm!(outside)
    end
  end

  describe "materialize_file/3" do
    test "writes new content without touching the project root", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "hello.txt", "modified")
      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "modified"
      assert File.read!(Path.join(project, "hello.txt")) == "original"

      Overlay.cleanup(overlay)
    end

    test "creates parent directories for new files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "lib/new/deep/file.ex", "new content")
      assert File.read!(Path.join(overlay.overlay_dir, "lib/new/deep/file.ex")) == "new content"

      Overlay.cleanup(overlay)
    end

    test "rejects traversal that escapes the overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)
      escaped_name = "escape-#{System.unique_integer([:positive])}.txt"
      escaped = Path.join(Path.dirname(overlay.overlay_dir), escaped_name)

      assert {:error, :path_traversal} =
               Overlay.materialize_file(overlay, "../#{escaped_name}", "pwned")

      refute File.exists?(escaped)

      Overlay.cleanup(overlay)
    end

    test "allows normalized paths that stay inside the overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "./lib/../hello.txt", "updated")
      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "updated"
      assert File.read!(Path.join(project, "hello.txt")) == "original"

      Overlay.cleanup(overlay)
    end

    test "rejects tombstone-suffix paths", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert {:error, :invalid_path} =
               Overlay.materialize_file(overlay, "ghost.__changeset_deleted__", "updated")

      assert {:error, :invalid_path} =
               Overlay.materialize_file(
                 overlay,
                 "nested/ghost.__changeset_deleted__/file.txt",
                 "updated"
               )

      assert {:error, :invalid_path} =
               Overlay.delete_file(overlay, "nested/ghost.__changeset_deleted__/file.txt")

      Overlay.cleanup(overlay)
    end

    test "materializes dependency paths instead of writing through to deps", %{project: project} do
      dep_file = Path.join(project, "deps/some_dep/lib/real.ex")
      File.mkdir_p!(Path.dirname(dep_file))
      File.write!(dep_file, "original_dep")
      {:ok, overlay} = Overlay.create(project)

      assert :ok = Overlay.materialize_file(overlay, "deps/some_dep/lib/real.ex", "mutated")
      assert File.read!(dep_file) == "original_dep"
      assert File.read!(Path.join(overlay.overlay_dir, "deps/some_dep/lib/real.ex")) == "mutated"

      Overlay.cleanup(overlay)
    end
  end

  describe "delete_file/2" do
    test "writes tombstone for a lazy project-root file", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.delete_file(overlay, "hello.txt")
      refute File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
      assert Overlay.deleted?(overlay, "hello.txt")
      assert File.exists?(Path.join(project, "hello.txt"))

      Overlay.cleanup(overlay)
    end

    test "deleted? raises for traversal that escapes the overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert_raise ArgumentError, fn -> Overlay.deleted?(overlay, "../hello.txt") end

      Overlay.cleanup(overlay)
    end

    test "returns error for non-existent file", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert {:error, :file_not_found} = Overlay.delete_file(overlay, "nope.txt")

      Overlay.cleanup(overlay)
    end

    test "rejects traversal that escapes the overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert {:error, :path_traversal} = Overlay.delete_file(overlay, "../hello.txt")

      Overlay.cleanup(overlay)
    end

    test "rejects tombstone-suffix paths", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert {:error, :invalid_path} = Overlay.delete_file(overlay, "ghost.__changeset_deleted__")

      assert {:error, :invalid_path} =
               Overlay.delete_file(overlay, "nested/ghost.__changeset_deleted__/file.txt")

      Overlay.cleanup(overlay)
    end
  end

  describe "modified?/2" do
    test "returns false for unmaterialized project files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      refute Overlay.modified?(overlay, "hello.txt")

      Overlay.cleanup(overlay)
    end

    test "returns true after materialization", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "hello.txt", "changed")
      assert Overlay.modified?(overlay, "hello.txt")

      Overlay.cleanup(overlay)
    end

    test "returns true for new files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "brand_new.txt", "new")
      assert Overlay.modified?(overlay, "brand_new.txt")

      Overlay.cleanup(overlay)
    end

    test "returns true for deleted files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.delete_file(overlay, "hello.txt")
      assert Overlay.modified?(overlay, "hello.txt")

      Overlay.cleanup(overlay)
    end

    test "raises for traversal that escapes the overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert_raise ArgumentError, fn -> Overlay.modified?(overlay, "../hello.txt") end

      Overlay.cleanup(overlay)
    end
  end

  describe "list_directory/2" do
    test "merges project files, overlay files, and tombstones", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "lib/new.ex", "new")
      :ok = Overlay.delete_file(overlay, "lib/foo.ex")

      assert {:ok, entries} = Overlay.list_directory(overlay, "lib")
      assert %{name: "new.ex", type: :file} in entries
      refute Enum.any?(entries, &(&1.name == "foo.ex"))

      Overlay.cleanup(overlay)
    end
  end

  describe "command_env/1" do
    test "returns environment with isolated build path", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      env = Overlay.command_env(overlay)
      env_map = Map.new(env)

      assert env_map["MIX_BUILD_PATH"] == overlay.build_dir
      assert env_map["MIX_DEPS_PATH"] == Path.join(project, "deps")

      Overlay.cleanup(overlay)
    end
  end

  describe "cleanup/1" do
    test "removes the overlay directory", %{project: project} do
      {:ok, overlay} = Overlay.create(project)
      assert File.dir?(overlay.overlay_dir)

      Overlay.cleanup(overlay)
      refute File.dir?(overlay.overlay_dir)
    end
  end
end
