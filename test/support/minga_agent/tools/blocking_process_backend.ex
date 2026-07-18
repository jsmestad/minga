defmodule MingaAgent.Test.BlockingProcessBackend do
  @moduledoc false

  @behaviour MingaAgent.Tools.ProcessBackend

  @impl true
  @spec find(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

  @impl true
  @spec grep(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

  @impl true
  @spec shell(String.t(), String.t(), pos_integer(), keyword()) ::
          MingaAgent.Tools.ProcessBackend.result()
  def shell(_command, _cwd, _timeout_secs, _opts) do
    receive do
      :stop -> {:ok, "stopped"}
    end
  end
end
