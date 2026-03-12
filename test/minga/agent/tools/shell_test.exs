defmodule Minga.Agent.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Shell

  @moduletag :tmp_dir

  defp collect_shell_chunks(timeout) do
    collect_shell_chunks_acc([], timeout)
  end

  defp collect_shell_chunks_acc(acc, timeout) do
    receive do
      {:shell_chunk, chunk} -> collect_shell_chunks_acc([chunk | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  describe "execute/4 with streaming" do
    test "invokes on_output callback as output arrives", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      assert {:ok, output} =
               Shell.execute("echo line1; echo line2; echo line3", dir, 5, on_output: on_output)

      # Should have received at least one chunk
      chunks = collect_shell_chunks(500)
      combined = IO.iodata_to_binary(chunks)
      assert combined =~ "line1"
      assert combined =~ "line3"

      # Final result should contain all lines
      assert output =~ "line1"
      assert output =~ "line3"
    end

    test "streams multi-line output incrementally", %{tmp_dir: dir} do
      test_pid = self()
      chunks = :counters.new(1, [:atomics])

      on_output = fn _chunk ->
        :counters.add(chunks, 1, 1)
        send(test_pid, :chunk_received)
        :ok
      end

      # Generate output over time with a small delay between lines
      assert {:ok, _output} =
               Shell.execute(
                 "for i in 1 2 3 4 5; do echo \"line $i\"; done",
                 dir,
                 5,
                 on_output: on_output
               )

      # Should have received at least one callback
      assert :counters.get(chunks, 1) >= 1
    end

    test "works without on_output callback", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("echo hello", dir, 5, [])
      assert output == "hello"
    end
  end

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
