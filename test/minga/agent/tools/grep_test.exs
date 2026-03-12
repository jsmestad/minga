defmodule Minga.Agent.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Grep

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Create test files
    File.write!(Path.join(dir, "hello.ex"), ~S"""
    defmodule Hello do
      def greet(name) do
        "Hello, #{name}!"
      end
    end
    """)

    File.write!(Path.join(dir, "world.ex"), """
    defmodule World do
      def planet, do: "Earth"
    end
    """)

    File.mkdir_p!(Path.join(dir, "sub"))

    File.write!(Path.join(dir, "sub/nested.txt"), """
    This is a nested file.
    It contains some text.
    And more text here.
    """)

    %{dir: dir}
  end

  describe "execute/3" do
    test "finds matches in files", %{dir: dir} do
      assert {:ok, output} = Grep.execute("defmodule", dir)
      assert output =~ "Hello"
      assert output =~ "World"
    end

    test "returns no matches message when pattern not found", %{dir: dir} do
      assert {:ok, "No matches found."} = Grep.execute("nonexistent_pattern_xyz", dir)
    end

    test "respects glob filter", %{dir: dir} do
      assert {:ok, output} = Grep.execute("text", dir, %{"glob" => "*.txt"})
      assert output =~ "nested.txt"
      refute output =~ ".ex"
    end

    test "case insensitive search", %{dir: dir} do
      assert {:ok, output} = Grep.execute("hello", dir, %{"case_sensitive" => false})
      assert output =~ "Hello"
    end

    test "case sensitive search misses different case", %{dir: dir} do
      assert {:ok, output} = Grep.execute("hello", dir, %{"case_sensitive" => true})
      # "hello" (lowercase) should not match "Hello" (capitalized)
      # The only match would be the string interpolation template
      refute output =~ "defmodule Hello"
    end

    test "context lines includes surrounding lines", %{dir: dir} do
      assert {:ok, output} = Grep.execute("planet", dir, %{"context_lines" => 1})
      # Should include surrounding lines
      assert output =~ "World"
    end

    test "searches subdirectories", %{dir: dir} do
      assert {:ok, output} = Grep.execute("nested", dir)
      assert output =~ "nested"
    end

    test "returns error for invalid path", %{dir: dir} do
      bad_path = Path.join(dir, "nonexistent_dir")
      result = Grep.execute("test", bad_path)
      assert {:error, _} = result
    end
  end
end
