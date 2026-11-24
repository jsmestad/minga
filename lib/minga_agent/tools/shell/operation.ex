defmodule MingaAgent.Tools.Shell.Operation do
  @moduledoc """
  Starts one native shell operation in its own process group and cancels it
  through the hook runner's control protocol.

  Each operation runs inside `minga-hook-runner --shell`, which forks the
  command into a dedicated POSIX process group. Cancellation sends a protocol
  byte that triggers TERM, a bounded grace period, then KILL on the entire
  group. If the hook runner does not exit within `@cancel_wait_ms` after the
  cancel signal, the BEAM escalates to an OS-level SIGKILL on the hook runner
  process itself.
  """

  @cancel_wait_ms 1_000

  @doc "Starts a shell operation with the provided `/bin/sh -c` arguments."
  @spec open([String.t()], String.t(), [{charlist(), charlist()}], [atom()]) ::
          {:ok, port()} | {:error, String.t()}
  def open(args, cwd, env, options \\ []) do
    path = Path.join(:code.priv_dir(:minga), "minga-hook-runner")

    {:ok,
     Port.open({:spawn_executable, path}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       {:args, ["--shell" | args]},
       {:cd, cwd},
       {:env, env} | options
     ])}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Requests cancellation and waits for the helper to finish group teardown.

  Sends the cancel byte to the hook runner, which triggers TERM then KILL on
  the child process group. If the hook runner does not exit within
  `@cancel_wait_ms`, the BEAM sends SIGKILL to the hook runner process itself
  as a last resort. The Port is always closed and drained before returning.
  """
  @spec cancel(port()) :: :ok
  def cancel(port) do
    os_pid = port_os_pid(port)
    previous = Process.flag(:trap_exit, true)

    try do
      case send_cancel(port) do
        :ok ->
          case await_exit(port, System.monotonic_time(:millisecond) + @cancel_wait_ms) do
            :exited -> :ok
            :timeout -> kill_by_pid(os_pid)
          end

        :closed ->
          # Port already closed. The hook runner exited on its own and already
          # killed the process group (normal-exit cleanup in the Zig code).
          :ok
      end
    after
      close(port)
      Process.flag(:trap_exit, previous)
    end

    :ok
  end

  @spec send_cancel(port()) :: :ok | :closed
  defp send_cancel(port) do
    Port.command(port, <<1>>)
    :ok
  rescue
    ArgumentError -> :closed
  end

  @spec await_exit(port(), integer()) :: :exited | :timeout
  defp await_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      :timeout
    else
      receive do
        {^port, {:exit_status, _status}} -> :exited
        {^port, {:data, _bytes}} -> await_exit(port, deadline)
        {^port, :eof} -> await_exit(port, deadline)
        {:EXIT, ^port, _reason} -> :exited
      after
        remaining -> :timeout
      end
    end
  end

  @spec port_os_pid(port()) :: pos_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  @spec kill_by_pid(pos_integer() | nil) :: :ok
  defp kill_by_pid(nil), do: :ok

  defp kill_by_pid(os_pid) do
    System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @spec close(port()) :: :ok
  defp close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port)
  end

  @spec drain(port()) :: :ok
  defp drain(port) do
    receive do
      {^port, _msg} -> drain(port)
      {:EXIT, ^port, _reason} -> drain(port)
    after
      0 -> :ok
    end
  end
end
