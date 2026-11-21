defmodule Minga.Project.FileFind.WorkerTest do
  @moduledoc "Tests cancellation against a real external process tree."

  # This test spawns a real shell process and child, which requires serialized execution.
  use ExUnit.Case, async: false

  alias Minga.Project.FileFind.Worker

  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  test "cancelling discovery terminates the external process and descendants", %{tmp_dir: tmp_dir} do
    child_pid_file = Path.join(tmp_dir, "child.pid")
    script = Path.join(tmp_dir, "discovery.sh")

    File.write!(script, "#!/bin/sh\nsleep 60 &\necho $! > child.pid\nwait\n")
    File.chmod!(script, 0o755)

    command = {System.find_executable("sh"), [script], tmp_dir}
    {:ok, worker} = Worker.start(self(), command, fn output, status -> {output, status} end)
    ref = Process.monitor(worker)

    assert {:ok, child_pid} = await_nonempty_file(child_pid_file, 100)
    assert process_alive?(child_pid)

    Worker.cancel(worker)

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    refute process_alive?(child_pid)
  end

  test "owner shutdown terminates the external process and descendants", %{tmp_dir: tmp_dir} do
    child_pid_file = Path.join(tmp_dir, "owner-child.pid")
    script = Path.join(tmp_dir, "owner-discovery.sh")
    File.write!(script, "#!/bin/sh\nsleep 60 &\necho $! > owner-child.pid\nwait\n")
    File.chmod!(script, 0o755)
    parent = self()

    owner =
      spawn(fn ->
        command = {System.find_executable("sh"), [script], tmp_dir}
        {:ok, worker} = Worker.start(self(), command, fn output, status -> {output, status} end)
        send(parent, {:owner_worker, worker})

        receive do
          :keep_alive -> :ok
        end
      end)

    assert_receive {:owner_worker, worker}, 1_000
    ref = Process.monitor(worker)
    assert {:ok, child_pid} = await_nonempty_file(child_pid_file, 100)
    assert process_alive?(child_pid)

    Process.exit(owner, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    refute process_alive?(child_pid)
  end

  test "discovery accepts exact output limits and reports the first exceeded limit", %{
    tmp_dir: tmp_dir
  } do
    output = "first\nsecond\n"
    shell = System.find_executable("sh")
    script = ~S"""
    while [ ! -f "$1" ]; do sleep 0.01; done
    printf 'first\nsecond\n'
    if [ "$2" = hold ]; then exec sleep 60; fi
    """

    byte_limit = byte_size(output)

    cases = [
      {byte_limit, 2, "exit", {output, 0}},
      {byte_limit, 1, "hold", {:error, "Project file discovery exceeded the file-count limit"}},
      {byte_limit - 1, 1, "hold", {:error, "Project file discovery exceeded the byte limit"}}
    ]

    for {bytes, files, action, expected} <- cases do
      gate = Path.join(tmp_dir, "release-#{bytes}-#{files}")
      command = {shell, ["-c", script, "discovery", gate, action], tmp_dir}

      assert {:ok, worker} =
               Worker.start(self(), command, fn data, status -> {data, status} end,
                 max_output_bytes: bytes,
                 max_file_count: files
               )

      monitor = Process.monitor(worker)
      File.write!(gate, "")
      assert_receive {:file_find_done, ^worker, ^expected}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    end
  end

  @spec await_nonempty_file(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, File.posix()} | :timeout
  defp await_nonempty_file(_path, 0), do: :timeout

  defp await_nonempty_file(path, attempts) do
    case File.read(path) do
      {:ok, contents} -> await_file_contents(path, attempts, String.trim(contents))
      {:error, :enoent} -> retry_file_read(path, attempts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await_file_contents(String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, File.posix()} | :timeout
  defp await_file_contents(_path, _attempts, contents) when contents != "", do: {:ok, contents}
  defp await_file_contents(path, attempts, ""), do: retry_file_read(path, attempts)

  @spec retry_file_read(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, File.posix()} | :timeout
  defp retry_file_read(path, attempts) do
    receive do
    after
      10 -> await_nonempty_file(path, attempts - 1)
    end
  end

  @spec process_alive?(String.t()) :: boolean()
  defp process_alive?(pid) do
    ps = System.find_executable("ps")

    case System.cmd(ps, ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {state, 0} ->
        case String.trim(state) do
          "" -> false
          "Z" <> _rest -> false
          "X" <> _rest -> false
          _live_state -> true
        end

      {_output, _status} ->
        false
    end
  end
end
