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

    test "ignores generated and dependency directories", %{dir: dir} do
      File.mkdir_p!(Path.join([dir, "node_modules", "pkg"]))
      File.mkdir_p!(Path.join([dir, "_build", "test"]))
      File.write!(Path.join([dir, "node_modules", "pkg", "leaked.ex"]), "defmodule Leaked")
      File.write!(Path.join([dir, "_build", "test", "compiled.ex"]), "defmodule Compiled")

      assert {:ok, output} = Find.execute("*.ex", dir, %{"type" => "any"})
      refute output =~ "node_modules"
      refute output =~ "_build"
    end

    test "respects project gitignore when discovering files", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")
      File.mkdir_p!(Path.join([dir, "ignored_dir"]))
      File.write!(Path.join([dir, "ignored_dir", "leaked.ex"]), "defmodule Leaked")

      assert {:ok, output} = Find.execute("*.ex", dir)
      refute output =~ "ignored_dir"
      refute output =~ "leaked.ex"
    end

    test "marks truncated results when more matches exist than the model result cap", %{dir: dir} do
      for index <- 1..205 do
        File.write!(Path.join(dir, "many_#{index}.txt"), "many")
      end

      assert {:ok, output} = Find.execute("many_*.txt", dir)
      lines = String.split(output, "\n", trim: true)
      assert length(Enum.reject(lines, &String.starts_with?(&1, "... (truncated"))) == 200
      assert List.last(lines) == "... (truncated, refine the pattern or path for fewer results)"
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
