defmodule Minga.CommandOutputTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.CommandOutput

  # Polls until the command's buffer contains the expected text.
  # Much faster than a fixed Process.sleep since most commands finish
  # in a few milliseconds.
  defp wait_for_output(name, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_output(name, expected, deadline)
  end

  defp do_wait_for_output(name, expected, deadline) do
    case check_output(name, expected) do
      :ok ->
        :ok

      {:not_ready, context} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Timed out waiting for #{inspect(expected)} in command output. #{context}")
        else
          Process.sleep(5)
          do_wait_for_output(name, expected, deadline)
        end
    end
  end

  defp check_output(name, expected) do
    case CommandOutput.buffer(name) do
      nil ->
        {:not_ready, "Buffer not yet created for #{name}"}

      buf ->
        content = BufferServer.content(buf)

        if String.contains?(content, expected) do
          :ok
        else
          {:not_ready, "Got: #{inspect(content)}"}
        end
    end
  end

  # Polls until running?/1 returns false.
  defp wait_until_done(name, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_done(name, deadline)
  end

  defp do_wait_until_done(name, deadline) when is_integer(deadline) do
    if CommandOutput.running?(name) do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for command #{name} to finish")
      else
        Process.sleep(5)
        do_wait_until_done(name, deadline)
      end
    else
      :ok
    end
  end

  describe "run/3" do
    test "creates a buffer and streams command output" do
      name = "test_output_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo hello")
      wait_for_output(name, "hello")

      buf = CommandOutput.buffer(name)
      assert is_pid(buf)

      content = BufferServer.content(buf)
      assert content =~ "$ echo hello"
      assert content =~ "hello"
    end

    test "includes exit code in output" do
      name = "test_exit_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo done")
      wait_for_output(name, "[Process exited with code 0]")

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      assert content =~ "[Process exited with code 0]"
    end

    test "captures non-zero exit code" do
      name = "test_fail_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "bash -c 'exit 42'")
      wait_for_output(name, "[Process exited with code 42]")

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      assert content =~ "[Process exited with code 42]"
    end

    test "clears buffer on re-run" do
      name = "test_rerun_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo first")
      wait_for_output(name, "first")

      :ok = CommandOutput.run(name, "echo second")
      wait_for_output(name, "second")

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      refute content =~ "first"
      assert content =~ "second"
    end

    test "streams stderr alongside stdout" do
      name = "test_stderr_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo out; echo err >&2")
      wait_for_output(name, "out")

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      assert content =~ "out"
      assert content =~ "err"
    end
  end

  describe "running?/1" do
    test "returns true while command is executing" do
      name = "test_running_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "sleep 5")

      assert CommandOutput.running?(name)

      CommandOutput.kill(name)
    end

    test "returns false after command exits" do
      name = "test_done_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo fast")
      wait_until_done(name)

      refute CommandOutput.running?(name)
    end

    test "returns false for unknown name" do
      refute CommandOutput.running?("nonexistent_#{System.unique_integer([:positive])}")
    end
  end

  describe "kill/1" do
    test "stops a running command" do
      name = "test_kill_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "sleep 60")
      assert CommandOutput.running?(name)

      :ok = CommandOutput.kill(name)
      refute CommandOutput.running?(name)
    end

    test "is a no-op for unknown name" do
      assert :ok = CommandOutput.kill("nonexistent_#{System.unique_integer([:positive])}")
    end
  end

  describe "buffer/1" do
    test "returns nil for unknown name" do
      assert nil == CommandOutput.buffer("nonexistent_#{System.unique_integer([:positive])}")
    end

    test "returns the buffer pid after run" do
      name = "test_buf_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo hi")
      wait_for_output(name, "hi")

      buf = CommandOutput.buffer(name)
      assert is_pid(buf)
      assert Process.alive?(buf)
    end
  end
end
