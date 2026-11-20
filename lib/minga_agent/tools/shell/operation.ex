defmodule MingaAgent.Tools.Shell.Operation do
  @moduledoc "Starts one native shell operation and cancels it through its own Port."

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

  @doc "Requests cancellation and waits for the helper to finish group teardown."
  @spec cancel(port()) :: :ok
  def cancel(port) do
    previous = Process.flag(:trap_exit, true)

    try do
      Port.command(port, <<1>>)
      await_exit(port, System.monotonic_time(:millisecond) + @cancel_wait_ms)
    after
      Process.flag(:trap_exit, previous)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec await_exit(port(), integer()) :: :ok
  defp await_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close(port)
    else
      receive do
        {^port, {:exit_status, _status}} -> close(port)
        {^port, {:data, _bytes}} -> await_exit(port, deadline)
        {^port, :eof} -> await_exit(port, deadline)
        {:EXIT, ^port, _reason} -> :ok
      after
        remaining -> close(port)
      end
    end
  end

  @spec close(port()) :: :ok
  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
