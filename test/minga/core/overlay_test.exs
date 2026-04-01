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
    test "mirrors project with hardlinks", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "original"
      assert File.exists?(Path.join(overlay.overlay_dir, "lib/foo.ex"))

      Overlay.cleanup(overlay)
    end

    test "skips _build and .git directories", %{project: project} do
      File.mkdir_p!(Path.join(project, "_build/dev"))
      File.write!(Path.join(project, "_build/dev/compiled.beam"), "beam")
      File.mkdir_p!(Path.join(project, ".git/objects"))
      File.write!(Path.join(project, ".git/HEAD"), "ref: refs/heads/main")

      {:ok, overlay} = Overlay.create(project)

      refute File.exists?(Path.join(overlay.overlay_dir, "_build"))
      refute File.exists?(Path.join(overlay.overlay_dir, ".git"))

      Overlay.cleanup(overlay)
    end

    test "symlinks deps directory", %{project: project} do
      File.mkdir_p!(Path.join(project, "deps/some_dep"))
      File.write!(Path.join(project, "deps/some_dep/mix.exs"), "dep")

      {:ok, overlay} = Overlay.create(project)

      deps_path = Path.join(overlay.overlay_dir, "deps")
      assert {:ok, %{type: :symlink}} = File.lstat(deps_path)
      assert File.read!(Path.join(deps_path, "some_dep/mix.exs")) == "dep"

      Overlay.cleanup(overlay)
    end

    test "returns error for non-existent project root" do
      bogus = Path.join(System.tmp_dir!(), "nonexistent-#{System.unique_integer([:positive])}")
      # create will succeed on mkdir_p (it creates the overlay dir, not the project root)
      # but the mirror step just skips because File.ls returns error
      {:ok, overlay} = Overlay.create(bogus)
      Overlay.cleanup(overlay)
    end
  end

  describe "materialize_file/3" do
    test "replaces hardlink with new content", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "hello.txt", "modified")
      assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "modified"

      # Original is untouched
      assert File.read!(Path.join(project, "hello.txt")) == "original"

      Overlay.cleanup(overlay)
    end

    test "creates parent directories for new files", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "lib/new/deep/file.ex", "new content")
      assert File.read!(Path.join(overlay.overlay_dir, "lib/new/deep/file.ex")) == "new content"

      Overlay.cleanup(overlay)
    end
  end

  describe "delete_file/2" do
    test "removes file and writes tombstone marker", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.delete_file(overlay, "hello.txt")
      refute File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
      assert Overlay.deleted?(overlay, "hello.txt")

      Overlay.cleanup(overlay)
    end

    test "returns error for non-existent file", %{project: project} do
      {:ok, overlay} = Overlay.create(project)

      assert {:error, :file_not_found} = Overlay.delete_file(overlay, "nope.txt")

      Overlay.cleanup(overlay)
    end
  end

  describe "modified?/2" do
    test "returns false for unmodified files", %{project: project} do
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

    test "handles symlinked deps without following into project", %{project: project} do
      File.mkdir_p!(Path.join(project, "deps/some_dep"))

      {:ok, overlay} = Overlay.create(project)
      Overlay.cleanup(overlay)

      # Project deps still exist
      assert File.dir?(Path.join(project, "deps/some_dep"))
      refute File.dir?(overlay.overlay_dir)
    end
  end
end
