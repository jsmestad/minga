defmodule MingaAgent.Supervisor do
  @moduledoc """
  DynamicSupervisor for AI agent session processes.

  Each agent session (and its provider) runs under this supervisor with
  `:one_for_one` strategy. A crash in one agent session is completely
  isolated from the editor, buffers, and other agent sessions.
  """

  use DynamicSupervisor

  @doc "Starts the agent supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Starts a new agent session under this supervisor."
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {MingaAgent.Session, opts})
  end

  @doc "Stops a running agent session."
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "Lists all running agent session pids."
  @spec sessions() :: [pid()]
  def sessions do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
