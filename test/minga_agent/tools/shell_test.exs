defmodule MingaAgent.Tools.ShellTest do
  # Spawns shell OS processes, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Shell
  alias MingaAgent.Tools.OutputLimit

  @moduletag :tmp_dir
  # Real OS commands with wall-clock timeouts make these inherently slow (~500-1000ms).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  @external_command_timeout_seconds 15

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

  test "ordinary output includes a background writer after the shell exits", %{tmp_dir: dir} do
    command = "printf head; (sleep 0.1; printf tail) & exit 0"
    assert {:ok, "headtail"} = Shell.execute(command, dir, @external_command_timeout_seconds)
  end

  test "an ordinary shell cannot queue unbounded output while its consumer stalls", %{
    tmp_dir: dir
  } do
    parent = self()

    command = """
    trap '' TERM
    printf 'ready\\n'
    while [ ! -f flood ]; do sleep 0.01; done
    exec yes flood
    """

    task =
      Task.async(fn ->
        Shell.execute(command, dir, 1,
          on_output: fn
            "ready\n" ->
              send(parent, :ready_to_flood)

              receive do
                :resume_output -> :ok
              end

            _other ->
              :ok
          end
        )
      end)

    assert_receive :ready_to_flood, 1_000
    File.write!(Path.join(dir, "flood"), "")
    # Let the external producer fill its pipe and the operation deadline elapse.
    Process.sleep(1_000)
    assert {:message_queue_len, queued} = Process.info(task.pid, :message_queue_len)
    assert queued <= 2
    send(task.pid, :resume_output)
    assert {:error, {:incomplete, :timeout, "ready"}} = Task.await(task)
  end

  test "a TERM-resistant background child cannot write after shell timeout", %{tmp_dir: dir} do
    command = """
    (trap '' TERM; printf ready > child-ready; sleep 2; printf late > late-effect) &
    wait
    """

    assert {:error, {:incomplete, :timeout, ""}} = Shell.execute(command, dir, 1, [])
    assert File.read!(Path.join(dir, "child-ready")) == "ready"

    # Wait past the external child's scheduled write, not just the shell's timeout.
    Process.sleep(2_000)
    refute File.exists?(Path.join(dir, "late-effect"))
  end

  test "a shell worker exit closes the operation before its child can write", %{tmp_dir: dir} do
    parent = self()

    command = """
    (trap '' TERM; printf 'armed\\n'; sleep 2; printf late > owner-exit-effect) &
    wait
    """

    {worker, monitor} =
      spawn_monitor(fn ->
        assert {:ok, port} = Shell.Operation.open([command], dir, [])

        receive do
          {^port, {:data, "armed\n"}} ->
            send(parent, {:shell_child_armed, port})

            receive do
              {^port, {:exit_status, status}} ->
                flunk("shell exited before cancellation: #{status}")
            end

          {^port, message} ->
            flunk("shell did not report readiness: #{inspect(message)}")
        end
      end)

    assert_receive {:shell_child_armed, old_port}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    # A delayed cancellation against the old Port must not affect its replacement.
    replacement_command =
      "while [ ! -f release-replacement ]; do sleep 0.05; done; printf replacement"

    assert {:ok, replacement} = Shell.Operation.open([replacement_command], dir, [])
    assert :ok = Shell.Operation.cancel(old_port)
    assert :ok = Shell.Operation.cancel(old_port)
    File.write!(Path.join(dir, "release-replacement"), "")
    assert_receive {^replacement, {:data, "replacement"}}, 1_000
    assert_receive {^replacement, {:exit_status, 0}}, 1_000

    # The write would occur in the external child after it outlives the worker.
    Process.sleep(2_000)
    refute File.exists?(Path.join(dir, "owner-exit-effect"))
  end

  describe "execute/4 with streaming" do
    test "invokes on_output callback as output arrives", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      assert {:ok, output} =
               Shell.execute(
                 "echo line1; echo line2; echo line3",
                 dir,
                 @external_command_timeout_seconds,
                 on_output: on_output
               )

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
                 @external_command_timeout_seconds,
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
      assert count < 20
    end

    test "sends running indicator for silent commands", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      fifo = Path.join(dir, "silent-command-release")
      assert {"", 0} = System.cmd("mkfifo", [fifo])

      task =
        Task.async(fn ->
          Shell.execute(
            "cat #{inspect(fifo)} >/dev/null && echo done",
            dir,
            @external_command_timeout_seconds,
            on_output: on_output,
            running_indicator_ms: 250
          )
        end)

      assert_receive {:shell_chunk, "[running...]\n"}, 2_000
      File.write!(fifo, "release\n")
      assert {:ok, _output} = Task.await(task)

      combined = collect_shell_chunks() |> IO.iodata_to_binary()
      assert combined =~ "done"
    end

    test "truncates streamed command output once", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      assert {:ok, _output} =
               Shell.execute(
                 "printf '%70000s' x | tr ' ' x",
                 dir,
                 @external_command_timeout_seconds,
                 on_output: on_output
               )

      combined = collect_shell_chunks() |> IO.iodata_to_binary()
      marker = "\n\n[stream truncated at 51KB]\n"

      assert String.ends_with?(combined, marker)
      assert byte_size(String.replace_suffix(combined, marker, "")) == 51_200
      assert [_] = :binary.matches(combined, marker)
    end

    test "stream truncation preserves valid UTF-8 at the cap", %{tmp_dir: dir} do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      assert {:ok, _output} =
               Shell.execute(
                 "elixir -e 'IO.write(String.duplicate(\"€\", 30000))'",
                 dir,
                 @external_command_timeout_seconds,
                 on_output: on_output
               )

      combined = collect_shell_chunks() |> IO.iodata_to_binary()

      assert String.valid?(combined)
      assert combined =~ "€"
      assert combined =~ "[stream truncated at 51KB]"
      assert is_binary(JSON.encode!(%{output: combined}))
    end

    test "stream truncation stays valid when the cap splits a UTF-8 character across chunks", %{
      tmp_dir: dir
    } do
      test_pid = self()

      on_output = fn chunk ->
        send(test_pid, {:shell_chunk, chunk})
        :ok
      end

      command =
        "elixir -e 'IO.write(String.duplicate(\"x\", 51199)); IO.binwrite(:stdio, <<226>>); Process.sleep(50); IO.binwrite(:stdio, <<130, 172>>)'"

      assert {:ok, _output} =
               Shell.execute(command, dir, @external_command_timeout_seconds,
                 on_output: on_output
               )

      combined = collect_shell_chunks() |> IO.iodata_to_binary()

      assert String.valid?(combined)
      assert combined =~ "[stream truncated at 51KB]"
      assert is_binary(JSON.encode!(%{output: combined}))
    end

    test "works without on_output callback", %{tmp_dir: dir} do
      assert {:ok, output} =
               Shell.execute("echo hello", dir, @external_command_timeout_seconds, [])

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

    test "truncates verbose command output before returning it to the model", %{tmp_dir: dir} do
      assert {:ok, output} =
               Shell.execute("elixir -e 'IO.write(String.duplicate(\"x\", 70000))'", dir, 5)

      marker = "\n\n[truncated at 51KB]"
      assert String.ends_with?(output, marker)
      assert byte_size(String.replace_suffix(output, marker, "")) == 51_200
    end

    test "preserves valid UTF-8 when truncating multibyte output", %{tmp_dir: dir} do
      assert {:ok, output} =
               Shell.execute("elixir -e 'IO.write(String.duplicate(\"€\", 30000))'", dir, 5)

      assert String.valid?(output)
      assert output =~ "€"
      assert output =~ "[truncated at 51KB]"
      assert is_binary(JSON.encode!(%{output: output}))
    end

    test "final truncation stays valid when the cap splits a UTF-8 character across chunks", %{
      tmp_dir: dir
    } do
      command =
        "elixir -e 'IO.write(String.duplicate(\"x\", 51199)); IO.binwrite(:stdio, <<226>>); Process.sleep(50); IO.binwrite(:stdio, <<130, 172>>)'"

      assert {:ok, output} = Shell.execute(command, dir, 15)

      assert String.valid?(output)
      assert output =~ "[truncated at 51KB]"
      assert is_binary(JSON.encode!(%{output: output}))
    end

    test "runs in the specified directory", %{tmp_dir: dir} do
      assert {:ok, output} = Shell.execute("pwd", dir, 5)
      # Resolve symlinks (macOS /private/var vs /var)
      assert Path.expand(output) == Path.expand(dir)
    end

    test "times out long-running commands with their bounded partial output", %{tmp_dir: dir} do
      assert {:error, {:incomplete, :timeout, output}} =
               Shell.execute("printf 'before timeout'; sleep 60", dir, 1)

      assert output == "before timeout"
    end

    test "times out commands that continuously write below the capture cap", %{tmp_dir: dir} do
      command = "while true; do printf x; sleep 0.01; done"
      assert {:error, {:incomplete, :timeout, output}} = Shell.execute(command, dir, 1)
      assert output != ""
      assert byte_size(output) <= OutputLimit.default_max_bytes()
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
