defmodule MingaAgent.Tools.ProcessBackend.System do
  @moduledoc """
  Production process backend for agent discovery and shell tools.
  """

  @behaviour MingaAgent.Tools.ProcessBackend

  alias MingaAgent.Tools.Find
  alias MingaAgent.Tools.Grep
  alias MingaAgent.Tools.Shell

  @impl true
  @spec find(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def find(pattern, path, opts, exec_opts) do
    Find.execute(pattern, path, opts, exec_opts)
  end

  @impl true
  @spec grep(String.t(), String.t(), map(), keyword()) :: MingaAgent.Tools.ProcessBackend.result()
  def grep(pattern, path, opts, exec_opts) do
    Grep.execute(pattern, path, opts, exec_opts)
  end

  @impl true
  @spec shell(String.t(), String.t(), pos_integer(), keyword()) ::
          MingaAgent.Tools.ProcessBackend.result()
  def shell(command, cwd, timeout_secs, opts) do
    Shell.execute(command, cwd, timeout_secs, opts)
  end
end
