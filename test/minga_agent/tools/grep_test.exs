defmodule MingaAgent.Tools.GrepTest do
  # Spawns OS processes through rg/grep/git-backed ignore checks, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Grep

  setup do
    dir =
      Path.join(System.tmp_dir!(), "minga-grep-") <>
        Integer.to_string(:erlang.unique_integer([:positive]))

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

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

    {:ok, dir: dir}
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

    test "ignores generated and dependency directories", %{dir: dir} do
      File.write!(Path.join(dir, "visible.txt"), "expensive_token")
      File.mkdir_p!(Path.join([dir, "node_modules", "pkg"]))
      File.mkdir_p!(Path.join([dir, "_build", "test"]))
      File.write!(Path.join([dir, "node_modules", "pkg", "leaked.txt"]), "expensive_token")
      File.write!(Path.join([dir, "_build", "test", "compiled.txt"]), "expensive_token")

      assert {:ok, output} = Grep.execute("expensive_token", dir)
      assert output =~ "visible.txt"
      refute output =~ "node_modules"
      refute output =~ "_build"
    end

    test "suppresses secret env files while keeping visible matches", %{dir: dir} do
      File.write!(Path.join(dir, "visible_secret.txt"), "shared_secret_token")
      File.write!(Path.join(dir, ".env.local"), "shared_secret_token")
      File.write!(Path.join(dir, ".npmrc"), "shared_secret_token")

      assert {:ok, output} = Grep.execute("shared_secret_token", dir)
      assert output =~ "visible_secret.txt"
      refute output =~ ".env.local"
      refute output =~ ".npmrc"
    end

    test "byte-caps very long matching lines without splitting UTF-8", %{dir: dir} do
      File.write!(Path.join(dir, "huge.txt"), "needle " <> String.duplicate("é", 70_000))

      assert {:ok, output} = Grep.execute("needle", dir)
      assert byte_size(output) < 65_000
      assert String.valid?(output)
      assert output =~ "truncated at 64KB"
    end

    test "does not walk a directly requested ignored search root", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")
      ignored_dir = Path.join(dir, "ignored_dir")
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join(ignored_dir, "leaked.txt"), "expensive_token")

      assert {:ok, "No matches found."} = Grep.execute("expensive_token", ignored_dir)
    end

    test "returns error for invalid path", %{dir: dir} do
      bad_path = Path.join(dir, "nonexistent_dir")
      result = Grep.execute("test", bad_path)
      assert {:error, _} = result
    end
  end
end
