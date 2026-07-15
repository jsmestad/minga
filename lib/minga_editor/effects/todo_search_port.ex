defmodule MingaEditor.Effects.TodoSearch.Port do
  @moduledoc """
  Executes the bounded git and grep Ports used by TODO search.

  Commands have a five-second timeout and an 8 MiB total-output ceiling. The
  Port is closed as soon as either bound is crossed, before excess output is
  appended. Workspace authorization remains in `MingaEditor.Effects.TodoSearch`
  and must complete before this module is called.
  """

  @command_timeout_ms 5_000
  @max_output_bytes 8 * 1_024 * 1_024
  @output_limit_status 125

  @typedoc "A completed TODO-search command result."
  @type result :: {String.t(), non_neg_integer()}

  @doc "Runs one TODO-search command through a Port with bounded time and output."
  @callback run(String.t(), [String.t()]) :: result()

  @spec run(String.t(), [String.t()]) :: result()
  def run(command, args) when is_binary(command) and is_list(args) do
    case System.find_executable(command) do
      nil -> {"#{command} executable not found", 127}
      executable -> open_port(executable, args)
    end
  rescue
    error -> {Exception.message(error), 1}
  end

  @spec open_port(String.t(), [String.t()]) :: result()
  defp open_port(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, args},
        {:line, 65_536}
      ])

    deadline = System.monotonic_time(:millisecond) + @command_timeout_ms
    collect_port_output(port, [], 0, deadline)
  end

  @spec collect_port_output(port(), iodata(), non_neg_integer(), integer()) :: result()
  defp collect_port_output(port, acc, byte_count, deadline) do
    case remaining_timeout(deadline) do
      0 ->
        timeout(port)

      timeout_ms ->
        receive do
          {^port, {:data, {:eol, chunk}}} ->
            collect_chunk(port, acc, byte_count, chunk, "\n", deadline)

          {^port, {:data, {:noeol, chunk}}} ->
            collect_chunk(port, acc, byte_count, chunk, "", deadline)

          {^port, {:exit_status, status}} ->
            {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
        after
          timeout_ms -> timeout(port)
        end
    end
  end

  @spec collect_chunk(port(), iodata(), non_neg_integer(), binary(), binary(), integer()) ::
          result()
  defp collect_chunk(port, acc, byte_count, chunk, suffix, deadline) do
    next_byte_count = byte_count + byte_size(chunk) + byte_size(suffix)

    if next_byte_count > @max_output_bytes do
      Port.close(port)
      {"command output exceeded #{@max_output_bytes} bytes", @output_limit_status}
    else
      collect_port_output(port, [suffix, chunk | acc], next_byte_count, deadline)
    end
  end

  @spec timeout(port()) :: result()
  defp timeout(port) do
    Port.close(port)
    {"command timed out", 124}
  end

  @spec remaining_timeout(integer()) :: non_neg_integer()
  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
