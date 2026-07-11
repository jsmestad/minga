defmodule MingaAgent.Test.RecordingProcessBackend do
  @moduledoc false

  @behaviour MingaAgent.Tools.ProcessBackend

  @impl true
  @spec find(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def find(pattern, path, opts, exec_opts) do
    {:ok,
     "find pattern=#{pattern} path=#{path} opts=#{inspect(opts)} exec_opts=#{inspect(exec_opts)}"}
  end

  @impl true
  @spec grep(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def grep(pattern, path, opts, exec_opts) do
    {:ok,
     "grep pattern=#{pattern} path=#{path} opts=#{inspect(opts)} exec_opts=#{inspect(exec_opts)}"}
  end

  @impl true
  @spec shell(String.t(), String.t(), pos_integer(), keyword()) ::
          MingaAgent.Tools.ProcessBackend.result()
  def shell(command, cwd, timeout_secs, opts) do
    {:ok, "shell command=#{command} cwd=#{cwd} timeout=#{timeout_secs} opts=#{inspect(opts)}"}
  end
end
