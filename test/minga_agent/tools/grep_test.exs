defmodule MingaAgent.Tools.GrepTest do
  # Spawns OS processes through rg/grep/git-backed ignore checks, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Grep

  defp with_fake_path(executables, fun) do
    old_path = System.get_env("PATH") || ""

    bin_dir =
      Path.join(System.tmp_dir!(), "minga-grep-bin-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)

    for {name, contents} <- executables do
      path = Path.join(bin_dir, name)
      File.write!(path, contents)
      File.chmod!(path, 0o755)
    end

    git = System.find_executable("git")
    if git, do: File.ln_s!(git, Path.join(bin_dir, "git"))

    sleep = System.find_executable("sleep")
    if sleep, do: File.ln_s!(sleep, Path.join(bin_dir, "sleep"))

    try do
      System.put_env("PATH", bin_dir)
      fun.()
    after
      System.put_env("PATH", old_path)
      File.rm_rf!(bin_dir)
    end
  end

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

    test "does not walk nested non-git ignored roots", %{dir: dir} do
      ignored_root = Path.join([dir, "node_modules", "pkg"])
      File.mkdir_p!(ignored_root)
      File.write!(Path.join(ignored_root, "leaked.txt"), "expensive_token")

      assert {:ok, "No matches found."} = Grep.execute("expensive_token", ignored_root)
    end

    test "passes dash-prefixed rg patterns after an option terminator", %{dir: dir} do
      rg = """
      #!/bin/sh
      case "$*" in
        *" -- --needle ."*) printf -- 'visible.txt:1:--needle\n' ;;
        *) echo "bad args: $*" >&2; exit 2 ;;
      esac
      """

      with_fake_path(%{"rg" => rg}, fn ->
        assert {:ok, output} = Grep.execute("--needle", dir)
        assert output =~ "visible.txt:1:--needle"
      end)
    end

    test "passes dash-prefixed grep fallback patterns after an option terminator", %{dir: dir} do
      grep = """
      #!/bin/sh
      case "$*" in
        *" -- --needle ."*) printf -- './visible.txt:1:--needle\n' ;;
        *) echo "bad args: $*" >&2; exit 2 ;;
      esac
      """

      with_fake_path(%{"grep" => grep}, fn ->
        assert {:ok, output} = Grep.execute("--needle", dir)
        assert output =~ "visible.txt:1:--needle"
      end)
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

    test "byte-caps many matching lines without splitting UTF-8", %{dir: dir} do
      lines = for index <- 1..100, do: "needle #{index} " <> String.duplicate("é", 400)
      File.write!(Path.join(dir, "huge.txt"), Enum.join(lines, "\n") <> "\n")

      assert {:ok, output} = Grep.execute("needle", dir)
      assert byte_size(output) < 52_200
      assert String.valid?(output)
      assert output =~ "truncated at 51KB"
    end

    test "does not walk a directly requested ignored search root", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")
      ignored_dir = Path.join(dir, "ignored_dir")
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join(ignored_dir, "leaked.txt"), "expensive_token")

      assert {:ok, "No matches found."} = Grep.execute("expensive_token", ignored_dir)
    end

    test "drops a truncated final line before ignore filtering", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_secret_file.txt\n")

      rg = """
      #!/bin/sh
      printf 'visible.txt:1:public\nignored_secret_file.txt:1:private\n'
      """

      with_fake_path(%{"rg" => rg}, fn ->
        assert {:ok, output} = Grep.execute("token", dir, %{}, max_output_bytes: 30)
        assert output =~ "visible.txt:1:public"
        refute output =~ "ignored_"
        refute output =~ "private"
      end)
    end

    test "drops a parseable truncated final result line", %{dir: dir} do
      rg = """
      #!/bin/sh
      printf 'visible.txt:1:public\nvisible.txt:2:private_secret'
      """

      with_fake_path(%{"rg" => rg}, fn ->
        assert {:ok, output} = Grep.execute("token", dir, %{}, max_output_bytes: 36)
        assert output =~ "visible.txt:1:public"
        refute output =~ "visible.txt:2:"
        refute output =~ "private"
      end)
    end

    test "returns timeout-specific errors for slow search commands", %{dir: dir} do
      rg = """
      #!/bin/sh
      printf 'visible.txt:1:public\n'
      sleep 2
      """

      with_fake_path(%{"rg" => rg}, fn ->
        assert {:error, message} = Grep.execute("token", dir, %{}, timeout_ms: 50)
        assert message == "Search timed out"
        refute message =~ "visible"
      end)
    end

    test "model-supplied hidden args cannot raise trusted caps or timeouts", %{dir: dir} do
      capped_rg = """
      #!/bin/sh
      printf 'visible.txt:1:public\nvisible.txt:2:private_secret'
      """

      with_fake_path(%{"rg" => capped_rg}, fn ->
        assert {:ok, output} =
                 Grep.execute("token", dir, %{"_max_output_bytes" => 100_000},
                   max_output_bytes: 36
                 )

        assert output =~ "visible.txt:1:public"
        refute output =~ "visible.txt:2:"
        refute output =~ "private"
      end)

      slow_rg = """
      #!/bin/sh
      printf 'visible.txt:1:public\nvisible.txt:2:private_secret'
      sleep 2
      """

      with_fake_path(%{"rg" => slow_rg}, fn ->
        assert {:error, message} =
                 Grep.execute("token", dir, %{"_timeout_ms" => 100_000}, timeout_ms: 50)

        assert message == "Search timed out"
        refute message =~ "visible"
      end)
    end

    test "returns error for invalid path", %{dir: dir} do
      bad_path = Path.join(dir, "nonexistent_dir")
      result = Grep.execute("test", bad_path)
      assert {:error, _} = result
    end
  end
end
