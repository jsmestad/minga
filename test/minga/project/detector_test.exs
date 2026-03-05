defmodule Minga.Project.DetectorTest do
  use ExUnit.Case, async: true

  alias Minga.Project.Detector

  @moduletag :tmp_dir

  describe "detect/1 with default markers" do
    test "detects git project from nested file", %{tmp_dir: tmp} do
      project = Path.join(tmp, "myproject")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.mkdir_p!(Path.join(project, ".git"))
      file = Path.join(lib, "foo.ex")
      File.write!(file, "")

      assert {:ok, ^project, :git} = Detector.detect(file)
    end

    test "detects mix project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "elixir_app")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      file = Path.join(lib, "app.ex")
      File.write!(file, "")

      assert {:ok, ^project, :mix} = Detector.detect(file)
    end

    test "detects cargo project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "rust_app")
      src = Path.join(project, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(project, "Cargo.toml"), "")
      file = Path.join(src, "main.rs")
      File.write!(file, "")

      assert {:ok, ^project, :cargo} = Detector.detect(file)
    end

    test "detects node project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "node_app")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "package.json"), "")
      file = Path.join(project, "index.js")
      File.write!(file, "")

      assert {:ok, ^project, :node} = Detector.detect(file)
    end

    test "detects go project", %{tmp_dir: tmp} do
      project = Path.join(tmp, "go_app")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "go.mod"), "")
      file = Path.join(project, "main.go")
      File.write!(file, "")

      assert {:ok, ^project, :go} = Detector.detect(file)
    end

    test "detects .minga sentinel", %{tmp_dir: tmp} do
      project = Path.join(tmp, "custom")
      sub = Path.join(project, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(project, ".minga"), "")
      file = Path.join(sub, "file.txt")
      File.write!(file, "")

      assert {:ok, ^project, :minga} = Detector.detect(file)
    end

    test "returns :none when no marker found", %{tmp_dir: tmp} do
      file = Path.join(tmp, "orphan.txt")
      File.write!(file, "")

      assert :none = Detector.detect(file, [])
    end
  end

  describe "detect/2 with custom markers" do
    test "uses custom markers", %{tmp_dir: tmp} do
      project = Path.join(tmp, "custom_project")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "BUILD"), "")
      file = Path.join(project, "src.cc")
      File.write!(file, "")

      assert {:ok, ^project, :bazel} = Detector.detect(file, [{"BUILD", :bazel}])
    end

    test "finds nearest root in nested projects", %{tmp_dir: tmp} do
      outer = Path.join(tmp, "outer")
      inner = Path.join([outer, "apps", "inner"])
      lib = Path.join(inner, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(outer, "mix.exs"), "")
      File.write!(Path.join(inner, "mix.exs"), "")
      file = Path.join(lib, "foo.ex")
      File.write!(file, "")

      assert {:ok, ^inner, :mix} = Detector.detect(file, [{"mix.exs", :mix}])
    end

    test "finds root several levels up", %{tmp_dir: tmp} do
      project = Path.join(tmp, "deep_project")
      deep = Path.join([project, "a", "b", "c", "d"])
      File.mkdir_p!(deep)
      File.write!(Path.join(project, "Cargo.toml"), "")
      file = Path.join(deep, "file.rs")
      File.write!(file, "")

      assert {:ok, ^project, :cargo} = Detector.detect(file, [{"Cargo.toml", :cargo}])
    end
  end

  describe "find_root/2 (LSP compatibility)" do
    test "returns root path string", %{tmp_dir: tmp} do
      project = Path.join(tmp, "project")
      lib = Path.join(project, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(project, "mix.exs"), "")
      file = Path.join(lib, "foo.ex")
      File.write!(file, "")

      assert Detector.find_root(file, ["mix.exs"]) == project
    end

    test "falls back to cwd when no marker found", %{tmp_dir: tmp} do
      file = Path.join(tmp, "orphan.txt")
      File.write!(file, "")

      assert Detector.find_root(file, ["nonexistent.xyz"]) == File.cwd!()
    end

    test "falls back to cwd with empty markers list", %{tmp_dir: tmp} do
      file = Path.join(tmp, "orphan.txt")
      File.write!(file, "")

      assert Detector.find_root(file, []) == File.cwd!()
    end
  end

  describe "default_markers/0" do
    test "returns a non-empty list of {marker, type} tuples" do
      markers = Detector.default_markers()
      assert is_list(markers)
      assert [_ | _] = markers

      Enum.each(markers, fn {marker, type} ->
        assert is_binary(marker)
        assert is_atom(type)
      end)
    end

    test "includes common project types" do
      markers = Detector.default_markers()
      types = Enum.map(markers, &elem(&1, 1))

      assert :git in types
      assert :mix in types
      assert :cargo in types
      assert :node in types
      assert :go in types
    end
  end
end
