defmodule MingaAgent.Tools.FindTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.Find

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "hello.ex"), "defmodule Hello")
    File.write!(Path.join(dir, "world.ex"), "defmodule World")
    File.write!(Path.join(dir, "README.md"), "# Readme")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join([dir, "lib", "app.ex"]), "defmodule App")
    File.mkdir_p!(Path.join([dir, "lib", "sub"]))
    File.write!(Path.join([dir, "lib", "sub", "nested.ex"]), "defmodule Nested")

    %{dir: dir}
  end

  describe "execute/3" do
    test "finds files matching a glob pattern", %{dir: dir} do
      assert {:ok, output} = Find.execute("*.ex", dir)
      assert output =~ "hello.ex"
      assert output =~ "world.ex"
      refute output =~ "README.md"
    end

    test "finds files in subdirectories", %{dir: dir} do
      assert {:ok, output} = Find.execute("*.ex", dir)
      assert output =~ "nested.ex"
    end

    test "returns no matches message when nothing found", %{dir: dir} do
      assert {:ok, "No matches found."} = Find.execute("*.xyz", dir)
    end

    test "finds directories when type is directory", %{dir: dir} do
      assert {:ok, output} = Find.execute("sub", dir, %{"type" => "directory"})
      assert output =~ "sub"
    end

    test "respects max_depth", %{dir: dir} do
      assert {:ok, output} = Find.execute("*.ex", dir, %{"max_depth" => 1})
      assert output =~ "hello.ex"
      refute output =~ "nested.ex"
    end

    test "results are sorted", %{dir: dir} do
      assert {:ok, output} = Find.execute("*.ex", dir)
      lines = String.split(output, "\n", trim: true)
      assert lines == Enum.sort(lines)
    end

    test "returns error for invalid path", %{dir: dir} do
      bad_path = Path.join(dir, "nonexistent_dir")
      result = Find.execute("*.ex", bad_path)
      assert {:error, _} = result
    end
  end
end
