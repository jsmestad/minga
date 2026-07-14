defmodule Minga.Test.TodoSearchPortProbe do
  @moduledoc "A process-local TODO Port probe for authorization-boundary tests."

  @behaviour MingaEditor.Effects.TodoSearch.Port

  @mode_key {__MODULE__, :mode}

  @doc "Configures the probe response mode for the calling test process."
  @spec configure(:success | :failure) :: :ok
  def configure(mode) when mode in [:success, :failure] do
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

  @spec response(:success | :failure, String.t(), [String.t()]) ::
          {String.t(), non_neg_integer()}
  defp response(:success, "git", [_flag, _root, "rev-parse" | _rest]), do: {"true\n", 0}
  defp response(:success, "git", _args), do: {"lib/example.ex:1:# TODO probe\n", 0}
  defp response(:success, _command, _args), do: {"example.ex:1:# TODO probe\n", 0}
  defp response(:failure, "git", [_flag, _root, "rev-parse" | _rest]), do: {"", 1}
  defp response(:failure, _command, _args), do: {"probe failure", 2}
end
