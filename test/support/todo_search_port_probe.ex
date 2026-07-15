defmodule Minga.Test.TodoSearchPortProbe do
  @moduledoc "A process-local TODO Port probe for authorization-boundary tests."

  @behaviour MingaEditor.Effects.TodoSearch.Port

  @mode_key {__MODULE__, :mode}

  @type mode :: :success | :failure | {:search_output, String.t()}

  @doc "Configures the probe response mode for the calling test process."
  @spec configure(mode()) :: :ok
  def configure(mode) when mode in [:success, :failure] do
    Process.put(@mode_key, mode)
    :ok
  end

  def configure({:search_output, output} = mode) when is_binary(output) do
    Process.put(@mode_key, mode)
    :ok
  end

  @doc "Records an attempted Port operation and returns a deterministic command result."
  @impl true
  @spec run(String.t(), [String.t()]) :: MingaEditor.Effects.TodoSearch.Port.result()
  def run(command, args) do
    send(self(), {:todo_search_port_opened, command, args})
    response(Process.get(@mode_key, :success), command, args)
  end

  @spec response(mode(), String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  defp response(:success, "git", [_flag, _root, "rev-parse" | _rest]), do: {"true\n", 0}
  defp response(:success, "git", _args), do: {"lib/example.ex\0" <> "1\0# TODO probe\n", 0}
  defp response(:success, _command, _args), do: {"example.ex\0" <> "1:# TODO probe\n", 0}
  defp response(:failure, "git", [_flag, _root, "rev-parse" | _rest]), do: {"", 1}
  defp response(:failure, _command, _args), do: {"probe failure", 2}

  defp response({:search_output, _output}, "git", [_flag, _root, "rev-parse" | _rest]),
    do: {"true\n", 0}

  defp response({:search_output, output}, _command, _args), do: {output, 0}
end
