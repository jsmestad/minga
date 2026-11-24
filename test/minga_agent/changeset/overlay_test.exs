defmodule MingaAgent.Changeset.OverlayTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Changeset.Overlay

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
    test "creates an empty private lazy overlay", %{project: project} do
      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert File.dir?(overlay.overlay_dir)
      assert Bitwise.band(File.stat!(overlay.overlay_dir).mode, 0o777) == 0o700
      refute File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
      refute File.exists?(Path.join(overlay.overlay_dir, "lib/foo.ex"))
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

    test "skips a Rust target directory that sits next to Cargo.toml", %{project: project} do
      File.write!(Path.join(project, "Cargo.toml"), "[package]\nname = \"demo\"\n")
      File.mkdir_p!(Path.join(project, "target/debug"))
      File.write!(Path.join(project, "target/debug/demo"), "binary")
      File.mkdir_p!(Path.join(project, "crates/cli/target/debug"))
      File.write!(Path.join(project, "crates/cli/Cargo.toml"), "[package]\nname = \"cli\"\n")
      File.write!(Path.join(project, "crates/cli/target/debug/cli"), "binary")

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      assert File.exists?(Path.join(overlay.overlay_dir, "Cargo.toml"))
      refute File.exists?(Path.join(overlay.overlay_dir, "target"))
      assert File.exists?(Path.join(overlay.overlay_dir, "crates/cli/Cargo.toml"))
      refute File.exists?(Path.join(overlay.overlay_dir, "crates/cli/target"))
    end

    test "copies a target directory that is not a Cargo build directory", %{project: project} do
      File.mkdir_p!(Path.join(project, "lib/target"))
      File.write!(Path.join(project, "lib/target/spec.ex"), "defmodule Target do\nend")

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      assert File.read!(Path.join(overlay.overlay_dir, "lib/target/spec.ex")) ==
               "defmodule Target do\nend"
    end

    test "links installed JavaScript packages so they resolve from the overlay", %{
      project: project
    } do
      File.write!(Path.join(project, "package.json"), ~s({"name": "app"}))
      write_package(project, "node_modules/left-pad")
      write_package(project, "node_modules/@scope/util")
      File.write!(Path.join(project, "node_modules/left-pad/cli.js"), "#!/usr/bin/env node\n")
      File.mkdir_p!(Path.join(project, "node_modules/.bin"))
      File.ln_s!("../left-pad/cli.js", Path.join(project, "node_modules/.bin/left-pad"))
      write_package(project, "packages/web/node_modules/react")

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, %{copied_files: 3, linked_entries: 4}} = Overlay.materialize_project(overlay)

      for package <- ["left-pad", "@scope/util", ".bin/left-pad"] do
        overlay_path = Path.join([overlay.overlay_dir, "node_modules", package])
        project_path = Path.join([project, "node_modules", package])
        assert File.read_link!(overlay_path) == Path.expand(project_path)
      end

      assert resolved_from_project?(overlay, project, "node_modules/left-pad/package.json")
      assert resolved_from_project?(overlay, project, "node_modules/@scope/util/package.json")
      assert resolved_from_project?(overlay, project, "node_modules/.bin/left-pad")

      assert resolved_from_project?(
               overlay,
               project,
               "packages/web/node_modules/react/package.json"
             )

      # The overlay owns node_modules, each scope directory, and .bin, so new
      # packages, bin shims, and tool caches are created in the overlay.
      for dir <- ["node_modules", "node_modules/@scope", "node_modules/.bin"] do
        assert File.lstat!(Path.join(overlay.overlay_dir, dir)).type == :directory
      end
    end

    test "owns pnpm and bin directories so package-manager writes stay in the overlay", %{
      project: project
    } do
      store = "node_modules/.pnpm/left-pad@1.3.0/node_modules/left-pad"
      write_package(project, store)

      File.ln_s!(
        ".pnpm/left-pad@1.3.0/node_modules/left-pad",
        Path.join(project, "node_modules/left-pad")
      )

      File.mkdir_p!(Path.join(project, "node_modules/.pnpm/node_modules"))

      File.ln_s!(
        "../left-pad@1.3.0/node_modules/left-pad",
        Path.join(project, "node_modules/.pnpm/node_modules/left-pad")
      )

      File.write!(Path.join(project, "node_modules/.pnpm/lock.yaml"), "lockfileVersion: '9.0'\n")
      File.write!(Path.join(project, "node_modules/.modules.yaml"), "layoutVersion: 5\n")
      File.mkdir_p!(Path.join(project, "node_modules/.bin"))
      File.write!(Path.join(project, "node_modules/.bin/left-pad"), "#!/bin/sh\n")

      before = project_listing(project, "node_modules")

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      for dir <- ["node_modules/.bin", "node_modules/.pnpm", "node_modules/.pnpm/node_modules"] do
        assert File.lstat!(Path.join(overlay.overlay_dir, dir)).type == :directory
      end

      refute File.exists?(Path.join(overlay.overlay_dir, "node_modules/.modules.yaml"))
      assert resolved_from_project?(overlay, project, "node_modules/left-pad/package.json")
      assert resolved_from_project?(overlay, project, Path.join(store, "package.json"))

      assert resolved_from_project?(
               overlay,
               project,
               "node_modules/.pnpm/node_modules/left-pad/package.json"
             )

      # Small regular files such as pnpm bin shims and store metadata are copies.
      assert File.read!(Path.join(overlay.overlay_dir, "node_modules/.bin/left-pad")) ==
               "#!/bin/sh\n"

      refute resolved_from_project?(overlay, project, "node_modules/.bin/left-pad")
      refute resolved_from_project?(overlay, project, "node_modules/.pnpm/lock.yaml")

      File.write!(Path.join(overlay.overlay_dir, "node_modules/.bin/new-tool"), "#!/bin/sh\n")
      File.write!(Path.join(overlay.overlay_dir, "node_modules/.bin/left-pad"), "changed")
      File.mkdir_p!(Path.join(overlay.overlay_dir, "node_modules/.pnpm/new-dep@1.0.0"))
      File.mkdir_p!(Path.join(overlay.overlay_dir, "node_modules/.pnpm/node_modules/new-dep"))
      File.write!(Path.join(overlay.overlay_dir, "node_modules/.pnpm/lock.yaml"), "changed")

      assert project_listing(project, "node_modules") == before
      assert File.read!(Path.join(project, "node_modules/.bin/left-pad")) == "#!/bin/sh\n"

      assert File.read!(Path.join(project, "node_modules/.pnpm/lock.yaml")) ==
               "lockfileVersion: '9.0'\n"
    end

    test "keeps tool caches and new installs in the overlay without touching the project", %{
      project: project
    } do
      write_package(project, "node_modules/left-pad")
      File.mkdir_p!(Path.join(project, "node_modules/.vite"))
      File.write!(Path.join(project, "node_modules/.vite/deps.json"), "{}")
      File.write!(Path.join(project, "node_modules/.package-lock.json"), "{}")

      {:ok, overlay} = Overlay.create(project)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      refute File.exists?(Path.join(overlay.overlay_dir, "node_modules/.vite"))
      refute File.exists?(Path.join(overlay.overlay_dir, "node_modules/.package-lock.json"))

      write_package(overlay.overlay_dir, "node_modules/new-dep")
      File.mkdir_p!(Path.join(overlay.overlay_dir, "node_modules/.cache"))

      assert {:ok, %{linked_entries: 0}} = Overlay.materialize_project(overlay)

      Overlay.cleanup(overlay)

      assert Enum.sort(File.ls!(Path.join(project, "node_modules"))) ==
               [".package-lock.json", ".vite", "left-pad"]

      assert File.read!(Path.join(project, "node_modules/left-pad/package.json")) =~ "left-pad"
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

    test "re-materialization keeps an existing regular file in a package-manager directory", %{
      project: project
    } do
      # Set up a node_modules package with a .bin entry (a regular file copied
      # during materialization because .bin is an owned directory).
      write_package(project, "node_modules/left-pad")
      File.mkdir_p!(Path.join(project, "node_modules/.bin"))
      File.write!(Path.join(project, "node_modules/.bin/left-pad"), "#!/bin/sh\n")

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      # First materialization copies the .bin entry as a regular file.
      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      bin_path = Path.join(overlay.overlay_dir, "node_modules/.bin/left-pad")
      assert {:ok, %{type: :regular}} = File.lstat(bin_path)

      # A second materialization must succeed: the existing regular file is
      # kept, not rejected by the symlink traversal check.
      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      assert {:ok, %{type: :regular}} = File.lstat(bin_path)
    end

    test "re-materialization keeps an existing link when the package-manager source entry became a regular file",
         %{project: project} do
      write_package(project, "node_modules/left-pad")
      File.write!(Path.join(project, "node_modules/left-pad/cli.js"), "#!/usr/bin/env node\n")
      File.mkdir_p!(Path.join(project, "node_modules/.bin"))
      source_bin = Path.join(project, "node_modules/.bin/left-pad")
      File.ln_s!("../left-pad/cli.js", source_bin)

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      bin_path = Path.join(overlay.overlay_dir, "node_modules/.bin/left-pad")
      assert File.read_link!(bin_path) == Path.expand(source_bin)

      # A reinstall replaces the project's bin link with a regular shim.
      File.rm!(source_bin)
      File.write!(source_bin, "#!/bin/sh\nexec node ../left-pad/cli.js\n")

      assert {:ok, _stats} = Overlay.materialize_project(overlay)

      # The overlay keeps its own entry and copies nothing through it.
      assert File.read_link!(bin_path) == Path.expand(source_bin)
      assert File.read!(source_bin) == "#!/bin/sh\nexec node ../left-pad/cli.js\n"
    end

    test "re-materialization owns a package-manager directory whose project link became a real directory",
         %{project: project} do
      write_package(project, "packages/util")
      File.mkdir_p!(Path.join(project, "node_modules"))
      source_scope = Path.join(project, "node_modules/@scope")
      File.ln_s!(Path.join(project, "packages"), source_scope)

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      scope_path = Path.join(overlay.overlay_dir, "node_modules/@scope")
      assert File.read_link!(scope_path) == Path.expand(source_scope)

      File.rm!(source_scope)
      write_package(project, "node_modules/@scope/util")

      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      assert File.lstat!(scope_path).type == :directory

      assert File.read_link!(Path.join(scope_path, "util")) ==
               Path.expand(Path.join(source_scope, "util"))

      # A package installed into the scope now lands in the overlay.
      write_package(overlay.overlay_dir, "node_modules/@scope/other")
      assert File.ls!(source_scope) == ["util"]
      assert File.ls!(Path.join(project, "packages")) == ["util"]
    end

    test "re-materialization keeps a package-manager directory link that a command made",
         %{project: project} do
      write_package(project, "node_modules/@scope/util")
      elsewhere = Path.join(project, "vendor-scope")
      File.mkdir_p!(elsewhere)

      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)

      File.mkdir_p!(Path.join(overlay.overlay_dir, "node_modules"))
      scope_path = Path.join(overlay.overlay_dir, "node_modules/@scope")
      File.ln_s!(elsewhere, scope_path)

      assert {:ok, _stats} = Overlay.materialize_project(overlay)
      assert File.read_link!(scope_path) == elsewhere
      assert File.ls!(elsewhere) == []
    end
  end

  describe "commit_file/3" do
    @tag :tmp_dir
    test "prepared executable copies keep private ownership and source access permissions", %{
      tmp_dir: project
    } do
      source = Path.join(project, "run.sh")
      File.write!(source, "original\n")
      File.chmod!(source, 0o755)
      source_metadata = File.stat!(source)
      {:ok, overlay} = Overlay.create(project)
      on_exit(fn -> Overlay.cleanup(overlay) end)
      overlay_metadata = File.stat!(overlay.overlay_dir)

      assert :ok = Overlay.commit_file(overlay, "run.sh", "prepared\n")
      target = Path.join(overlay.overlay_dir, "run.sh")
      assert File.read!(target) == "prepared\n"
      metadata = File.stat!(target)
      assert {metadata.uid, metadata.gid} == {overlay_metadata.uid, overlay_metadata.gid}
      assert Bitwise.band(metadata.mode, 0o7777) == 0o755
      assert File.read!(source) == "original\n"

      assert Map.take(File.stat!(source), [:uid, :gid, :mode]) ==
               Map.take(source_metadata, [:uid, :gid, :mode])
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

    test "does not compare against content behind a symlink that leaves the project", %{
      project: project
    } do
      outside = project <> "-outside"
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.write!(Path.join(outside, "secret.txt"), "outside")
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(project, "link.txt"))
      {:ok, overlay} = Overlay.create(project)

      :ok = Overlay.materialize_file(overlay, "link.txt", "outside")

      assert Overlay.modified?(overlay, "link.txt")

      assert Overlay.read_project_file(overlay, "link.txt") ==
               {:error, {:outside_project_root, "link.txt"}}

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
      assert env_map["CARGO_TARGET_DIR"] == Path.join(overlay.build_dir, "cargo")
      assert String.starts_with?(env_map["CARGO_TARGET_DIR"], overlay.overlay_dir <> "/")

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

  # Every path under `relative_dir` without following symlinks, with each
  # regular file's content, so any write into the project is visible.
  defp project_listing(root, relative_dir) do
    dir = Path.join(root, relative_dir)

    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)
      relative = Path.join(relative_dir, entry)

      case File.lstat!(path).type do
        :directory -> [relative | project_listing(root, relative)]
        :regular -> [{relative, File.read!(path)}]
        :symlink -> [{relative, File.read_link!(path)}]
      end
    end)
  end

  defp write_package(root, relative_dir) do
    dir = Path.join(root, relative_dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), ~s({"name": "#{Path.basename(dir)}"}))
  end

  # Node resolves a package by walking up to the nearest node_modules and
  # following links, so the overlay path must reach the project's own file.
  defp resolved_from_project?(overlay, project, relative_path) do
    overlay_stat = File.stat!(Path.join(overlay.overlay_dir, relative_path))
    project_stat = File.stat!(Path.join(project, relative_path))

    {overlay_stat.major_device, overlay_stat.inode} ==
      {project_stat.major_device, project_stat.inode}
  end
end
