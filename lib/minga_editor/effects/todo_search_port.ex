defmodule MingaEditor.Effects.TodoSearch.Port do
  @moduledoc """
  Executes the bounded git and grep Ports used by TODO search.

  Commands have a five-second timeout and an 8 MiB total-output ceiling. When
  either bound is crossed, the direct child is killed and its monitored Port is
  confirmed down before the result is returned. Workspace authorization remains
  in `MingaEditor.Effects.TodoSearch` and must complete before this module is
  called.
  """

  @command_timeout_ms 5_000
  @termination_timeout_ms 1_000
  @max_output_bytes 8 * 1_024 * 1_024
  @output_limit_status 125

  @typedoc "A completed TODO-search command result."
  @type result :: {String.t(), non_neg_integer()}

  @typep command_port :: {port(), os_pid :: pos_integer(), kill_executable :: String.t()}

  @doc "Runs one TODO-search command through a Port with bounded time and output."
  @callback run(String.t(), [String.t()]) :: result()

  @spec run(String.t(), [String.t()]) :: result()
  def run(command, args) when is_binary(command) and is_list(args) do
    case System.find_executable(command) do
      nil -> {"#{command} executable not found", 127}
      executable -> open_port(executable, args, kill_executable!())
    end
  rescue
    error -> {Exception.message(error), 1}
  end

  @spec open_port(String.t(), [String.t()], String.t()) :: result()
  defp open_port(executable, args, kill_executable) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, args}
      ])

    command_port = {port, port_os_pid!(port), kill_executable}
    deadline = System.monotonic_time(:millisecond) + @command_timeout_ms
    collect_port_output(command_port, [], 0, deadline)
  end

  @spec collect_port_output(command_port(), iodata(), non_neg_integer(), integer()) :: result()
  defp collect_port_output(
         {port, _os_pid, _kill_executable} = command_port,
         acc,
         byte_count,
         deadline
       ) do
    case remaining_timeout(deadline) do
      0 ->
        terminate(command_port, {"command timed out", 124})

      timeout_ms ->
        receive do
          {^port, {:data, chunk}} ->
            collect_chunk(command_port, acc, byte_count, chunk, deadline)

          {^port, {:exit_status, status}} ->
            {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
        after
          timeout_ms -> terminate(command_port, {"command timed out", 124})
        end
    end
  end

  @spec collect_chunk(command_port(), iodata(), non_neg_integer(), binary(), integer()) ::
          result()
  defp collect_chunk(command_port, acc, byte_count, chunk, deadline) do
    next_byte_count = byte_count + byte_size(chunk)

    if next_byte_count > @max_output_bytes do
      terminate(
        command_port,
        {"command output exceeded #{@max_output_bytes} bytes", @output_limit_status}
      )
    else
      collect_port_output(command_port, [chunk | acc], next_byte_count, deadline)
    end
  end

  @spec terminate(command_port(), result()) :: result()
  defp terminate({port, os_pid, kill_executable}, result) do
    monitor_ref = Port.monitor(port)
    {kill_port, kill_monitor_ref} = hard_kill(kill_executable, os_pid)

    wait_for_port_down(port, monitor_ref)
    wait_for_kill_port_down(kill_port, kill_monitor_ref)
    drain_port_messages(port, monitor_ref)
    drain_port_messages(kill_port, kill_monitor_ref)
    result
  end

  @spec hard_kill(String.t(), pos_integer()) :: {port(), reference()}
  defp hard_kill(kill_executable, os_pid) do
    kill_port =
      Port.open({:spawn_executable, kill_executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, ["-KILL", Integer.to_string(os_pid)]}
      ])

    {kill_port, Port.monitor(kill_port)}
  end

  @spec wait_for_port_down(port(), reference()) :: :ok
  defp wait_for_port_down(port, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :port, ^port, _reason} ->
        :ok
    after
      @termination_timeout_ms ->
        close_port(port)
        wait_for_closed_port_down(port, monitor_ref)
    end
  end

  @spec wait_for_closed_port_down(port(), reference()) :: :ok
  defp wait_for_closed_port_down(port, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :port, ^port, _reason} -> :ok
    after
      @termination_timeout_ms ->
        Port.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  @spec wait_for_kill_port_down(port(), reference()) :: :ok
  defp wait_for_kill_port_down(kill_port, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :port, ^kill_port, _reason} -> :ok
    after
      @termination_timeout_ms ->
        close_port(kill_port)
        Port.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  @spec drain_port_messages(port(), reference()) :: :ok
  defp drain_port_messages(port, monitor_ref) do
    receive do
      {^port, _message} -> drain_port_messages(port, monitor_ref)
      {:DOWN, ^monitor_ref, :port, ^port, _reason} -> drain_port_messages(port, monitor_ref)
    after
      0 -> :ok
    end
  end

  @spec port_os_pid!(port()) :: pos_integer()
  defp port_os_pid!(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 -> os_pid
      _other -> raise "TODO search Port did not expose an OS process ID"
    end
  end

  @spec kill_executable!() :: String.t()
  defp kill_executable! do
    System.find_executable("kill") || raise "kill executable not found"
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec remaining_timeout(integer()) :: non_neg_integer()
  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
