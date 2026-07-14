defmodule MingaEditor.Effects.TodoSearch.Port do
  @moduledoc """
  Executes the bounded git and grep Ports used by TODO search.

  This is a focused execution seam for TODO search. Workspace authorization
  remains in `MingaEditor.Effects.TodoSearch` and must complete before this
  module is called.
  """

  @command_timeout_ms 5_000

  @typedoc "A completed TODO-search command result."
  @type result :: {String.t(), non_neg_integer()}

  @doc "Runs one TODO-search command through a Port with a bounded timeout."
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

    collect_port_output(port, [])
  end

  @spec collect_port_output(port(), iodata()) :: result()
  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> collect_port_output(port, ["\n", chunk | acc])
      {^port, {:data, {:noeol, chunk}}} -> collect_port_output(port, [chunk | acc])
      {^port, {:exit_status, status}} -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      @command_timeout_ms ->
        Port.close(port)
        {"command timed out", 124}
    end
  end
end
