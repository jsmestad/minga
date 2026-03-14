defmodule Minga.Agent.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Shell

  @moduletag :tmp_dir

  # Drains all shell chunks from the mailbox. Uses a short timeout since
  # Shell.execute blocks until the command completes, so by the time we
  # call this the chunks are already in the mailbox.
  defp collect_shell_chunks(timeout \\ 50) do
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
      chunks = collect_shell_chunks()
      combined = IO.iodata_to_binary(chunks)
      assert combined =~ "line1"
      assert combined =~ "line3"

      # Final result should contain all lines
      assert output =~ "line1"
      assert output =~ "line3"
    end

    test "debounces rapid output into batched callbacks", %{tmp_dir: dir} do
      test_pid = self()
      callback_count = :counters.new(1, [:atomics])

      on_output = fn chunk ->
        :counters.add(callback_count, 1, 1)
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      # Generate 20 lines as fast as possible. Without debouncing, each Port
      # data chunk would fire its own callback. With debouncing, they get
      # batched into fewer callbacks.
      assert {:ok, _output} =
               Shell.execute(
                 "for i in $(seq 1 20); do echo \"line $i\"; done",
                 dir,
                 5,
                 on_output: on_output
               )

      chunks = collect_shell_chunks()
      combined = IO.iodata_to_binary(chunks)

      # All 20 lines must appear in the combined output
      assert combined =~ "line 1"
      assert combined =~ "line 20"

      # The callback count should be fewer than 20 (debounced batches)
      # At minimum 1 callback, but definitely not 20 separate ones
      count = :counters.get(callback_count, 1)
      assert count >= 1
    end

    test "sends running indicator for silent commands", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      # Sleep for 1 second (longer than our 200ms running indicator threshold)
      assert {:ok, _output} =
               Shell.execute("sleep 1 && echo done", dir, 5,
                 on_output: on_output,
                 running_indicator_ms: 200
               )

      chunks = collect_shell_chunks()
      combined = IO.iodata_to_binary(chunks)

      # Should have received at least one running indicator
      assert combined =~ "[running...]"
      # And the final output
      assert combined =~ "done"
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
