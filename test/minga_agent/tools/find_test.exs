defmodule MingaAgent.Tools.FindTest do
  # Spawns OS processes through fd/find/git-backed ignore checks, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Find

  defp with_fake_path(executables, fun) do
    old_path = System.get_env("PATH") || ""

    bin_dir =
      Path.join(System.tmp_dir!(), "minga-find-bin-#{:erlang.unique_integer([:positive])}")

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
      Path.join(System.tmp_dir!(), "minga-find-") <>
        Integer.to_string(:erlang.unique_integer([:positive]))

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "hello.ex"), "defmodule Hello")
    File.write!(Path.join(dir, "world.ex"), "defmodule World")
    File.write!(Path.join(dir, "README.md"), "# Readme")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join([dir, "lib", "app.ex"]), "defmodule App")
    File.mkdir_p!(Path.join([dir, "lib", "sub"]))
    File.write!(Path.join([dir, "lib", "sub", "nested.ex"]), "defmodule Nested")

    {:ok, dir: dir}
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

    test "suppresses secret env files while keeping visible matches", %{dir: dir} do
      File.write!(Path.join(dir, ".env.local"), "secret")
      File.write!(Path.join(dir, ".npmrc"), "secret")
      File.write!(Path.join(dir, "visible_secret.txt"), "visible")

      assert {:ok, output} = Find.execute("*", dir, %{"type" => "file"})
      assert output =~ "visible_secret.txt"
      refute output =~ ".env.local"
      refute output =~ ".npmrc"
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

    test "does not walk a directly requested ignored search root", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")
      ignored_dir = Path.join(dir, "ignored_dir")
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join(ignored_dir, "leaked.ex"), "defmodule Leaked")

      assert {:ok, "No matches found."} = Find.execute("*.ex", ignored_dir)
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

    test "byte-caps very long result paths without splitting UTF-8", %{dir: dir} do
      segment = String.duplicate("é", 60)
      long_dir = Path.join([dir, segment, segment, segment, segment])
      File.mkdir_p!(long_dir)

      for index <- 1..205 do
        File.write!(Path.join(long_dir, "long_#{index}.txt"), "many")
      end

      assert {:ok, output} = Find.execute("long_*.txt", dir, %{"max_depth" => 5})
      assert byte_size(output) < 65_000
      assert String.valid?(output)
      assert output =~ "truncated at 64KB"
    end

    test "drops a truncated final line before ignore filtering", %{dir: dir} do
      {_out, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      File.write!(Path.join(dir, ".gitignore"), "ignored_secret_file.txt\n")

      fd = """
      #!/bin/sh
      printf 'visible.txt\nignored_secret_file.txt\n'
      """

      with_fake_path(%{"fd" => fd}, fn ->
        assert {:ok, output} = Find.execute("*", dir, %{}, max_output_bytes: 20)
        assert output =~ "visible.txt"
        refute output =~ "ignored_"
        refute output =~ "ignored_secret_file"
      end)
    end

    test "returns timeout-specific errors for slow discovery commands", %{dir: dir} do
      fd = """
      #!/bin/sh
      printf 'partial.txt\n'
      sleep 2
      """

      with_fake_path(%{"fd" => fd}, fn ->
        assert {:error, message} = Find.execute("*", dir, %{}, timeout_ms: 50)
        assert message == "Find timed out"
        refute message =~ "partial"
      end)
    end

    test "model-supplied hidden args cannot raise trusted caps or timeouts", %{dir: dir} do
      capped_fd = """
      #!/bin/sh
      printf 'visible.txt\nprivate_tail.txt\n'
      """

      with_fake_path(%{"fd" => capped_fd}, fn ->
        assert {:ok, output} =
                 Find.execute("*", dir, %{"_max_output_bytes" => 100_000}, max_output_bytes: 15)

        assert output =~ "visible.txt"
        refute output =~ "private"
      end)

      slow_fd = """
      #!/bin/sh
      printf 'visible.txt\nignored_secret_file.txt\n'
      sleep 2
      """

      with_fake_path(%{"fd" => slow_fd}, fn ->
        assert {:error, message} =
                 Find.execute("*", dir, %{"_timeout_ms" => 100_000}, timeout_ms: 50)

        assert message == "Find timed out"
        refute message =~ "visible"
      end)
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
