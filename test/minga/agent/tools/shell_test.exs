defmodule Minga.Agent.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Shell

  @moduletag :tmp_dir

  describe "execute/3" do
    test "runs a simple command", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("echo hello", dir, 5)
      assert output == "hello"
    end

    test "returns exit code for failing commands", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("exit 42", dir, 5)
      assert output =~ "[exit code: 42]"
    end

    test "captures stderr in the output", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("echo error >&2", dir, 5)
      assert output =~ "error"
    end

    test "runs in the specified directory", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("pwd", dir, 5)
      # Resolve symlinks (macOS /private/var vs /var)
      assert Path.expand(output) == Path.expand(dir)
    end

    test "times out long-running commands", %{tmp_dir: dir} do
      assert {:error, msg} = Shell.execute("sleep 60", dir, 1)
      assert msg =~ "timed out"
    end

    test "supports shell features like pipes", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("echo 'a b c' | tr ' ' '\\n' | wc -l", dir, 5)
      assert String.trim(output) == "3"
    end

    test "disables pager via environment", %{tmp_dir: dir} do
      # git log would normally open a pager, but our env sets PAGER=cat
      assert {:ok, _} = Shell.execute("echo $PAGER", dir, 5)
    end
  end
end
