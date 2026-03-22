defmodule Minga.CommandOutputTest do
  # async: false — spawns OS processes via Port; concurrent Port teardown
  # can race with ExUnit's :standard_error capture/restore lifecycle
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.CommandOutput
  alias Minga.Events

  setup do
    # Subscribe to command_done events so we can await completion
    # without polling. Idempotent: safe to call in every test.
    Events.subscribe(:command_done)
    :ok
  end

  # Waits for the command to finish by receiving the :command_done event.
  # Returns the exit code.
  defp await_done(name, timeout \\ 2000) do
    receive do
      {:minga_event, :command_done, %Events.CommandDoneEvent{name: ^name, exit_code: code}} ->
        code
    after
      timeout -> flunk("Command #{name} did not finish within #{timeout}ms")
    end
  end

  describe "run/3" do
    test "creates a buffer and streams command output" do
      name = "test_output_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo hello")
      await_done(name)

      buf = CommandOutput.buffer(name)
      assert is_pid(buf)

      content = BufferServer.content(buf)
      assert content =~ "$ echo hello"
      assert content =~ "hello"
    end

    test "includes exit code in output" do
      name = "test_exit_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo done")
      code = await_done(name)

      assert code == 0

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      assert content =~ "[Process exited with code 0]"
    end

    test "captures non-zero exit code" do
      name = "test_fail_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "bash -c 'exit 42'")
      code = await_done(name)

      assert code == 42

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      assert content =~ "[Process exited with code 42]"
    end

    test "clears buffer on re-run" do
      name = "test_rerun_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo first")
      await_done(name)

      :ok = CommandOutput.run(name, "echo second")
      await_done(name)

      buf = CommandOutput.buffer(name)
      content = BufferServer.content(buf)
      refute content =~ "first"
      assert content =~ "second"
    end

    test "streams stderr alongside stdout" do
      name = "test_stderr_#{System.unique_integer([:positive])}"
      :ok = CommandOutput.run(name, "echo out; echo err >&2")
      await_done(name)

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
      await_done(name)

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
      await_done(name)

      buf = CommandOutput.buffer(name)
      assert is_pid(buf)
    end
  end
end
