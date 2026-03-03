defmodule Minga.LSP.RootDetectorTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.RootDetector

  @moduletag :tmp_dir

  describe "find_root/2" do
    test "finds root when marker exists in parent directory", %{tmp_dir: tmp} do
      # Create: tmp/project/mix.exs and tmp/project/lib/foo.ex
      project = Path.join(tmp, "project")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      file = Path.join(lib, "foo.ex")
      File.write!(file, "")

      assert RootDetector.find_root(file, ["mix.exs"]) == project
    end

    test "finds root when marker is several levels up", %{tmp_dir: tmp} do
      # Create: tmp/project/Cargo.toml and tmp/project/src/deep/nested/file.rs
      project = Path.join(tmp, "project")
      deep = Path.join([project, "src", "deep", "nested"])
      File.mkdir_p!(deep)
      File.write!(Path.join(project, "Cargo.toml"), "")
      file = Path.join(deep, "file.rs")
      File.write!(file, "")

      assert RootDetector.find_root(file, ["Cargo.toml"]) == project
    end

    test "uses first matching marker when multiple exist", %{tmp_dir: tmp} do
      # Create both go.mod and go.sum at project root
      project = Path.join(tmp, "project")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "go.mod"), "")
      File.write!(Path.join(project, "go.sum"), "")
      file = Path.join(project, "main.go")
      File.write!(file, "")

      # Should find the directory containing either marker
      assert RootDetector.find_root(file, ["go.mod", "go.sum"]) == project
    end

    test "finds nearest root in nested projects", %{tmp_dir: tmp} do
      # Create: tmp/outer/mix.exs and tmp/outer/apps/inner/mix.exs
      outer = Path.join(tmp, "outer")
      inner = Path.join([outer, "apps", "inner"])
      lib = Path.join(inner, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(outer, "mix.exs"), "")
      File.write!(Path.join(inner, "mix.exs"), "")
      file = Path.join(lib, "foo.ex")
      File.write!(file, "")

      # Should find inner, not outer
      assert RootDetector.find_root(file, ["mix.exs"]) == inner
    end

    test "falls back to cwd when no marker found", %{tmp_dir: tmp} do
      file = Path.join(tmp, "orphan.txt")
      File.write!(file, "")

      assert RootDetector.find_root(file, ["nonexistent_marker.xyz"]) == File.cwd!()
    end

    test "falls back to cwd with empty markers list", %{tmp_dir: tmp} do
      file = Path.join(tmp, "orphan.txt")
      File.write!(file, "")

      assert RootDetector.find_root(file, []) == File.cwd!()
    end

    test "handles file in root directory", %{tmp_dir: tmp} do
      # Marker is in the same directory as the file
      File.write!(Path.join(tmp, "package.json"), "")
      file = Path.join(tmp, "index.js")
      File.write!(file, "")

      assert RootDetector.find_root(file, ["package.json"]) == tmp
    end

    test "handles relative paths by expanding them", %{tmp_dir: _tmp} do
      # find_root expands relative paths, so it should work with
      # the current project's mix.exs
      result = RootDetector.find_root("lib/minga/editor.ex", ["mix.exs"])
      assert File.exists?(Path.join(result, "mix.exs"))
    end
  end
end
