defmodule MingaEditor.Effects.TodoSearch.PortTest do
  # These tests serialize because real OS Port processes can trigger erl_child_setup EPIPE races.
  use ExUnit.Case, async: false

  alias MingaEditor.Effects.TodoSearch.Port, as: TodoSearchPort

  @moduletag :heavy
  @moduletag :tmp_dir

  test "uses an absolute five-second deadline and kills the direct child", %{tmp_dir: dir} do
    {task, os_pid} = start_process_probe(dir, "exec sleep 60")
    started_at = System.monotonic_time(:millisecond)

    assert Task.await(task, 8_000) == {"command timed out", 124}

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 4_500
    assert elapsed_ms < 8_000
    refute process_alive?(os_pid)
  end

  test "kills an infinite producer after crossing the total byte ceiling", %{tmp_dir: dir} do
    {task, os_pid} = start_process_probe(dir, "exec yes x")

    assert Task.await(task, 8_000) ==
             {"command output exceeded 8388608 bytes", 125}

    refute process_alive?(os_pid)
  end

  @spec start_process_probe(String.t(), String.t()) :: {Task.t(), String.t()}
  defp start_process_probe(dir, mode) do
    fifo = Path.join(dir, "todo-port-pid-#{System.unique_integer([:positive])}")
    mkfifo = System.find_executable("mkfifo") || raise "mkfifo executable not found"
    assert {"", 0} = System.cmd(mkfifo, [fifo])

    probe = open_fifo_probe(fifo)
    probe_ref = Port.monitor(probe)
    command = "printf '%s\\n' \"$$\" > \"$1\"; #{mode}"

    task =
      Task.async(fn ->
        TodoSearchPort.run("sh", ["-c", command, "todo-search-port-probe", fifo])
      end)

    os_pid = read_probed_pid(probe)
    assert_receive {:DOWN, ^probe_ref, :port, ^probe, _reason}, 1_000
    drain_probe_messages(probe)
    assert process_alive?(os_pid)
    {task, os_pid}
  end

  @spec open_fifo_probe(String.t()) :: port()
  defp open_fifo_probe(fifo) do
    cat = System.find_executable("cat") || raise "cat executable not found"
    Port.open({:spawn_executable, cat}, [:binary, :exit_status, {:args, [fifo]}])
  end

  @spec read_probed_pid(port()) :: String.t()
  defp read_probed_pid(probe) do
    receive do
      {^probe, {:data, os_pid}} -> String.trim(os_pid)
    after
      1_000 -> flunk("TODO search child did not publish its PID")
    end
  end

  @spec drain_probe_messages(port()) :: :ok
  defp drain_probe_messages(probe) do
    receive do
      {^probe, _message} -> drain_probe_messages(probe)
    after
      0 -> :ok
    end
  end

  @spec process_alive?(String.t()) :: boolean()
  defp process_alive?(os_pid) do
    kill = System.find_executable("kill") || raise "kill executable not found"
    {_output, status} = System.cmd(kill, ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end
end
